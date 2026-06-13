const std = @import("std");

/// Determines the current user's home directory.
/// We query the environment because shell profiles and tool configurations (like SSH config)
/// are anchored to the user's home path.
pub fn discoverUserHomeDirectory(allocator: std.mem.Allocator) ?[]const u8 {
    var environment_variables = std.process.getEnvMap(allocator) catch return null;
    defer environment_variables.deinit();
    return locateHomeDirectoryInEnvironment(allocator, &environment_variables);
}

/// Discovers the home directory path from a populated environment variable map.
/// We check Windows-specific keys first ('USERPROFILE') before POSIX 'HOME' fallback because
/// Windows environments sometimes define 'HOME' inside emulation layers (like Git Bash), which 
/// might mismatch the native user profile path we want to target.
pub noinline fn locateHomeDirectoryInEnvironment(allocator: std.mem.Allocator, environment_variables: *const std.process.EnvMap) ?[]const u8 {
    if (environment_variables.get("USERPROFILE")) |user_profile| {
        return allocator.dupe(u8, user_profile) catch null;
    }
    if (environment_variables.get("HOME")) |posix_home| {
        return allocator.dupe(u8, posix_home) catch null;
    }
    if (environment_variables.get("HOMEDRIVE")) |drive| {
        if (environment_variables.get("HOMEPATH")) |path| {
            // Under older Windows setups, home is split across drive letter and directory path.
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ drive, path }) catch null;
        }
    }
    return null;
}

/// Resolves paths containing '~' by expanding it into the user's home directory.
/// This is essential to support standard user-friendly configuration locations (like ~/.config/zzh/config.zzhc)
/// regardless of the client operating system.
pub fn expandUserPath(allocator: std.mem.Allocator, raw_path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, raw_path, "~")) {
        if (discoverUserHomeDirectory(allocator)) |user_home| {
            defer allocator.free(user_home);
            var path_suffix = raw_path[1..];
            // Support both Unix-style '/' and Windows-style '\\' separators.
            if (std.mem.startsWith(u8, path_suffix, "/") or std.mem.startsWith(u8, path_suffix, "\\")) {
                path_suffix = path_suffix[1..];
            }
            return std.fs.path.join(allocator, &.{ user_home, path_suffix });
        }
    }
    return allocator.dupe(u8, raw_path);
}

/// Evaluates a wildcard-style glob pattern against a target input string.
/// Keeping glob evaluation simple and recursion-based avoids importing a heavy regex matching framework.
fn evaluateGlobWildcard(glob_pattern: []const u8, target_string: []const u8) bool {
    if (glob_pattern.len == 0) return target_string.len == 0;
    if (std.mem.eql(u8, glob_pattern, "*")) return true;

    if (glob_pattern[0] == '*') {
        var char_idx: usize = 0;
        while (char_idx <= target_string.len) : (char_idx += 1) {
            if (evaluateGlobWildcard(glob_pattern[1..], target_string[char_idx..])) return true;
        }
        return false;
    }

    if (target_string.len == 0) return false;

    if (glob_pattern[0] == '?' or glob_pattern[0] == target_string[0]) {
        return evaluateGlobWildcard(glob_pattern[1..], target_string[1..]);
    }

    return false;
}

/// Converts a basic regex string (like '.*') into a simpler wildcard pattern (like '*')
/// to keep our pattern matching system lightweight and dependency-free.
fn convertRegexToGlobPattern(allocator: std.mem.Allocator, regex_pattern: []const u8) ![]const u8 {
    var glob_buffer = std.ArrayList(u8).init(allocator);
    errdefer glob_buffer.deinit();

    var char_idx: usize = 0;
    while (char_idx < regex_pattern.len) {
        // Translate standard regex wildcards to glob equivalents.
        if (char_idx + 1 < regex_pattern.len and regex_pattern[char_idx] == '.' and regex_pattern[char_idx + 1] == '*') {
            try glob_buffer.append('*');
            char_idx += 2;
        } else {
            try glob_buffer.append(regex_pattern[char_idx]);
            char_idx += 1;
        }
    }
    return glob_buffer.toOwnedSlice();
}

/// Checks if a remote host matches a specified configuration pattern.
/// The configuration file uses host patterns (like "*.local" or "192.168.*") to group host-specific settings.
pub fn hostMatchesPattern(allocator: std.mem.Allocator, host_pattern: []const u8, host_name: []const u8) bool {
    var sanitized_pattern = host_pattern;
    if (sanitized_pattern.len >= 2 and sanitized_pattern[0] == '"' and sanitized_pattern[sanitized_pattern.len - 1] == '"') {
        sanitized_pattern = sanitized_pattern[1 .. sanitized_pattern.len - 1];
    } else if (sanitized_pattern.len >= 2 and sanitized_pattern[0] == '\'' and sanitized_pattern[sanitized_pattern.len - 1] == '\'') {
        sanitized_pattern = sanitized_pattern[1 .. sanitized_pattern.len - 1];
    }

    if (std.mem.eql(u8, sanitized_pattern, ".*") or std.mem.eql(u8, sanitized_pattern, "*")) {
        return true;
    }

    const glob = convertRegexToGlobPattern(allocator, sanitized_pattern) catch return false;
    defer allocator.free(glob);

    return evaluateGlobWildcard(glob, host_name);
}

/// Helper to strip leading and trailing quotes from configuration values.
/// Quotes are supported in the zzhc format to allow spaces and prevent parsing errors.
fn stripSurroundingQuotes(quoted_value: []const u8) []const u8 {
    var cleaned_value = quoted_value;
    if (cleaned_value.len >= 2 and cleaned_value[0] == '"' and cleaned_value[cleaned_value.len - 1] == '"') {
        cleaned_value = cleaned_value[1 .. cleaned_value.len - 1];
    } else if (cleaned_value.len >= 2 and cleaned_value[0] == '\'' and cleaned_value[cleaned_value.len - 1] == '\'') {
        cleaned_value = cleaned_value[1 .. cleaned_value.len - 1];
    }
    return cleaned_value;
}

/// Strip any comments (starting with '#') that are not inside quotes from a line.
fn stripCommentsFromLine(line: []const u8) []const u8 {
    var in_double = false;
    var in_single = false;
    for (line, 0..) |char, idx| {
        if (char == '"' and !in_single) {
            in_double = !in_double;
        } else if (char == '\'' and !in_double) {
            in_single = !in_single;
        } else if (char == '#' and !in_double and !in_single) {
            return line[0..idx];
        }
    }
    return line;
}

fn isBooleanConfigKey(key: []const u8) bool {
    const booleans = [_][]const u8{
        "+PP", "++password-prompt",
        "+i", "++install",
        "+if", "++install-force",
        "+iff", "++install-force-full",
        "++config-init", "+config-init",
        "++update",
        "++tmux",
        "+hhr", "++host-zzh-home-remove",
        "+v", "++verbose",
        "+vv", "++vverbose",
        "+q", "++quiet", "+quiet",
    };
    for (booleans) |b| {
        if (std.mem.eql(u8, key, b)) return true;
    }
    return false;
}

/// Reads the config.zzhc file and parses the host matching rules into a flat slice of arguments.
/// The config format is YAML-like, using indents to define sections, host matching patterns, and values.
pub noinline fn readAndParseConfigurationFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    target_host: []const u8,
    resolved_arguments: *std.ArrayList([]const u8)
) !void {
    const configuration_file = std.fs.openFileAbsolute(file_path, .{}) catch |err| {
        // If the configuration file is missing, we gracefully ignore it and rely entirely on CLI flags.
        if (err == error.FileNotFound) return;
        return err;
    };
    defer configuration_file.close();

    var buffer_reader = std.io.bufferedReader(configuration_file.reader());
    var line_stream = buffer_reader.reader();

    var line_buffer: [4096]u8 = undefined;
    var within_hosts_block = false;
    var within_settings_block = false;
    var is_matching_host = false;
    var current_array_key: ?[]const u8 = null;
    var list_item_added = false;
    defer {
        if (current_array_key) |key| allocator.free(key);
    }

    while (try line_stream.readUntilDelimiterOrEof(&line_buffer, '\n')) |raw_line| {
        var line: []const u8 = raw_line;
        // Strip trailing carriage return on Windows systems.
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        line = stripCommentsFromLine(line);

        // Measure indentation depth to identify parent/child block relationships.
        var indentation_depth: usize = 0;
        for (line) |char| {
            if (char == ' ') {
                indentation_depth += 1;
            } else if (char == '\t') {
                indentation_depth += 4;
            } else {
                break;
            }
        }

        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0 or trimmed_line[0] == '#') {
            continue;
        }

        // If indentation drops back, the active list block is complete.
        if (indentation_depth <= 4) {
            if (current_array_key) |key| {
                if (is_matching_host and !list_item_added) {
                    try resolved_arguments.append(key);
                } else {
                    allocator.free(key);
                }
                current_array_key = null;
            }
        }

        // Global block headers (indentation 0)
        if (indentation_depth == 0) {
            if (std.mem.startsWith(u8, trimmed_line, "hosts:")) {
                within_hosts_block = true;
                within_settings_block = false;
            } else if (std.mem.startsWith(u8, trimmed_line, "settings:")) {
                within_hosts_block = false;
                within_settings_block = true;
            } else {
                within_hosts_block = false;
                within_settings_block = false;
            }
            is_matching_host = false;
            continue;
        }

        if (within_settings_block and indentation_depth > 0) {
            if (std.mem.indexOfScalar(u8, trimmed_line, ':')) |colon_idx| {
                const key = std.mem.trim(u8, trimmed_line[0..colon_idx], " \t");
                const val = stripSurroundingQuotes(std.mem.trim(u8, trimmed_line[colon_idx + 1 ..], " \t"));
                if (val.len > 0) {
                    if (std.mem.eql(u8, key, "local_zzh_home")) {
                        try resolved_arguments.append(try allocator.dupe(u8, "+lh"));
                        try resolved_arguments.append(try allocator.dupe(u8, val));
                    } else if (std.mem.eql(u8, key, "host_zzh_home")) {
                        try resolved_arguments.append(try allocator.dupe(u8, "+hh"));
                        try resolved_arguments.append(try allocator.dupe(u8, val));
                    } else if (std.mem.eql(u8, key, "config_path")) {
                        try resolved_arguments.append(try allocator.dupe(u8, "+xc"));
                        try resolved_arguments.append(try allocator.dupe(u8, val));
                    }
                }
            }
            continue;
        }

        if (!within_hosts_block) continue;

        // Host patterns block (indentation 2)
        if (indentation_depth == 2) {
            is_matching_host = false;
            if (std.mem.endsWith(u8, trimmed_line, ":")) {
                const pattern = trimmed_line[0 .. trimmed_line.len - 1];
                if (hostMatchesPattern(allocator, pattern, target_host)) {
                    is_matching_host = true;
                }
            }
            continue;
        }

        if (!is_matching_host) continue;

        // Settings keys (indentation 4)
        if (indentation_depth == 4) {
            if (std.mem.indexOfScalar(u8, trimmed_line, ':')) |colon_idx| {
                const key = std.mem.trim(u8, trimmed_line[0..colon_idx], " \t");
                const val = stripSurroundingQuotes(std.mem.trim(u8, trimmed_line[colon_idx + 1 ..], " \t"));
                if (isBooleanConfigKey(key)) {
                    if (std.mem.eql(u8, val, "true") or val.len == 0) {
                        try resolved_arguments.append(try allocator.dupe(u8, key));
                    }
                } else if (val.len > 0) {
                    // Standard key-value pairs (e.g., '+s: zsh') are immediately flat-mapped.
                    try resolved_arguments.append(try allocator.dupe(u8, key));
                    try resolved_arguments.append(try allocator.dupe(u8, val));
                } else {
                    // Array/List elements (e.g. '+e:') trigger list-collection state.
                    current_array_key = try allocator.dupe(u8, key);
                    list_item_added = false;
                }
            }
        } else if (indentation_depth > 4) {
            // Nested list items (indentation > 4, prefixed with '- ')
            if (current_array_key) |key| {
                if (std.mem.startsWith(u8, trimmed_line, "- ")) {
                    const item_val = stripSurroundingQuotes(std.mem.trim(u8, trimmed_line[2..], " \t"));
                    try resolved_arguments.append(try allocator.dupe(u8, key));
                    try resolved_arguments.append(try allocator.dupe(u8, item_val));
                    list_item_added = true;
                }
            }
        }
    }

    if (current_array_key) |key| {
        if (is_matching_host and !list_item_added) {
            try resolved_arguments.append(key);
        } else {
            allocator.free(key);
        }
        current_array_key = null;
    }
}

fn replaceArchPlaceholder(allocator: std.mem.Allocator, raw_url: []const u8, target_arch: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var remaining = raw_url;
    while (true) {
        if (std.mem.indexOf(u8, remaining, "{arch}")) |index| {
            try result.appendSlice(remaining[0..index]);
            try result.appendSlice(target_arch);
            remaining = remaining[index + "{arch}".len ..];
        } else {
            try result.appendSlice(remaining);
            break;
        }
    }
    return result.toOwnedSlice();
}

/// Looks up a custom download URL for a given binary name or repository input under the 'bin_urls:' block.
pub fn lookupBinaryUrlInConfig(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    binary_name: []const u8,
    target_arch: []const u8,
) !?[]const u8 {
    const configuration_file = std.fs.openFileAbsolute(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer configuration_file.close();

    var buffer_reader = std.io.bufferedReader(configuration_file.reader());
    var line_stream = buffer_reader.reader();

    var line_buffer: [4096]u8 = undefined;
    var within_bin_urls_block = false;

    while (try line_stream.readUntilDelimiterOrEof(&line_buffer, '\n')) |raw_line| {
        var line: []const u8 = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        line = stripCommentsFromLine(line);

        var indentation_depth: usize = 0;
        for (line) |char| {
            if (char == ' ') {
                indentation_depth += 1;
            } else if (char == '\t') {
                indentation_depth += 4;
            } else {
                break;
            }
        }

        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0 or trimmed_line[0] == '#') {
            continue;
        }

        if (indentation_depth == 0) {
            if (std.mem.startsWith(u8, trimmed_line, "bin_urls:")) {
                within_bin_urls_block = true;
            } else {
                within_bin_urls_block = false;
            }
            continue;
        }

        if (within_bin_urls_block and indentation_depth > 0) {
            if (std.mem.indexOfScalar(u8, trimmed_line, ':')) |colon_idx| {
                const key = stripSurroundingQuotes(std.mem.trim(u8, trimmed_line[0..colon_idx], " \t"));
                const val = stripSurroundingQuotes(std.mem.trim(u8, trimmed_line[colon_idx + 1 ..], " \t"));
                if (std.mem.eql(u8, key, binary_name) and val.len > 0) {
                    return try replaceArchPlaceholder(allocator, val, target_arch);
                }
            }
        }
    }

    return null;
}

/// Returns a built-in default download URL for specific well-known binaries.
pub fn getBuiltinDefaultUrlForBinary(allocator: std.mem.Allocator, name: []const u8, target_arch: []const u8) !?[]const u8 {
    var clean_name = name;
    if (std.mem.indexOfScalar(u8, name, '@')) |idx| {
        clean_name = name[0..idx];
    }

    if (std.mem.eql(u8, clean_name, "BurntSushi/ripgrep") or 
        std.mem.eql(u8, clean_name, "ripgrep") or 
        std.mem.eql(u8, clean_name, "rg")) {
        const url = try std.fmt.allocPrint(allocator, "https://github.com/BurntSushi/ripgrep/releases/download/13.0.0/ripgrep-13.0.0-{s}-unknown-linux-musl.tar.gz", .{target_arch});
        return url;
    }

    if (std.mem.eql(u8, clean_name, "sharkdp/fd") or 
        std.mem.eql(u8, clean_name, "fd")) {
        const url = try std.fmt.allocPrint(allocator, "https://github.com/sharkdp/fd/releases/download/v8.7.0/fd-v8.7.0-{s}-unknown-linux-musl.tar.gz", .{target_arch});
        return url;
    }

    if (std.mem.eql(u8, clean_name, "sharkdp/bat") or 
        std.mem.eql(u8, clean_name, "bat")) {
        const url = try std.fmt.allocPrint(allocator, "https://github.com/sharkdp/bat/releases/download/v0.24.0/bat-v0.24.0-{s}-unknown-linux-musl.tar.gz", .{target_arch});
        return url;
    }

    return null;
}

fn canonicalizeBinaryName(name: []const u8) []const u8 {
    var clean = name;
    if (std.mem.indexOfScalar(u8, clean, '@')) |idx| {
        clean = clean[0..idx];
    }
    if (std.mem.indexOfScalar(u8, clean, '/')) |idx| {
        clean = clean[idx + 1 ..];
    }
    if (std.mem.eql(u8, clean, "ripgrep")) {
        return "rg";
    }
    return clean;
}

/// Checks if a static binary's default built-in URL has been enabled under the 'bin_urls:' block.
pub fn isBinaryDefaultUrlEnabled(
    file_path: []const u8,
    binary_name: []const u8,
) !bool {
    const configuration_file = std.fs.openFileAbsolute(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    defer configuration_file.close();

    var buffer_reader = std.io.bufferedReader(configuration_file.reader());
    var line_stream = buffer_reader.reader();

    var line_buffer: [4096]u8 = undefined;
    var within_bin_urls_block = false;

    const canonical_lookup = canonicalizeBinaryName(binary_name);

    while (try line_stream.readUntilDelimiterOrEof(&line_buffer, '\n')) |raw_line| {
        var line: []const u8 = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        line = stripCommentsFromLine(line);

        var indentation_depth: usize = 0;
        for (line) |char| {
            if (char == ' ') {
                indentation_depth += 1;
            } else if (char == '\t') {
                indentation_depth += 4;
            } else {
                break;
            }
        }

        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0 or trimmed_line[0] == '#') {
            continue;
        }

        if (indentation_depth == 0) {
            if (std.mem.startsWith(u8, trimmed_line, "bin_urls:")) {
                within_bin_urls_block = true;
            } else {
                within_bin_urls_block = false;
            }
            continue;
        }

        if (within_bin_urls_block and indentation_depth > 0) {
            var val = trimmed_line;
            if (std.mem.startsWith(u8, val, "- ")) {
                val = std.mem.trim(u8, val[2..], " \t");
            } else if (std.mem.indexOfScalar(u8, val, ':')) |colon_idx| {
                val = std.mem.trim(u8, val[0..colon_idx], " \t");
            }
            val = stripSurroundingQuotes(val);
            if (std.mem.endsWith(u8, val, ":")) {
                val = std.mem.trim(u8, val[0 .. val.len - 1], " \t");
            }

            if (std.mem.eql(u8, val, binary_name) or std.mem.eql(u8, canonicalizeBinaryName(val), canonical_lookup)) {
                return true;
            }
        }
    }

    return false;
}


/// Creates a default config.zzhc file under ~/.config/zzh/ if it doesn't already exist.
pub fn initializeDefaultConfigurationFile(allocator: std.mem.Allocator, custom_config_dir: ?[]const u8) !void {
    const config_dir_raw = custom_config_dir orelse "~/.config/zzh";
    const config_dir = try expandUserPath(allocator, config_dir_raw);
    defer allocator.free(config_dir);

    // Recursively create directory structure
    var char_idx: usize = 0;
    while (char_idx < config_dir.len) : (char_idx += 1) {
        if (config_dir[char_idx] == '/' or config_dir[char_idx] == '\\') {
            if (char_idx == 0) continue;
            if (char_idx == 2 and config_dir[1] == ':') continue; // Windows drive
            const sub_path = config_dir[0..char_idx];
            std.fs.makeDirAbsolute(sub_path) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }
    }
    std.fs.makeDirAbsolute(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const config_path = try std.fs.path.join(allocator, &.{ config_dir, "config.zzhc" });
    defer allocator.free(config_path);

    const file_exists = blk: {
        std.fs.accessAbsolute(config_path, .{}) catch { break :blk false; };
        break :blk true;
    };

    const standard_output = std.io.getStdErr().writer();
    if (file_exists) {
        try standard_output.print("Configuration file already exists at: {s}\n", .{config_path});
        return;
    }

    const default_content =
        \\# zzh Configuration File (config.zzhc)
        \\#
        \\# This file configures default shells, plugins, dotfiles, and binary utilities per-host.
        \\# Host names are matched using wildcard/glob patterns and merged sequentially.
        \\
        \\# Global application settings
        \\settings:
        \\  # Path to local zzh packages and binary cache (default: ~/.zzh)
        \\  local_zzh_home: "~/.zzh"
        \\  # Target remote execution directory (default: ~/.zzh)
        \\  host_zzh_home: "~/.zzh"
        \\  # Path to configuration file (default: ~/.config/zzh/config.zzhc)
        \\  config_path: "~/.config/zzh/config.zzhc"
        \\
        \\# Custom download links for static binaries. 
        \\# Bypasses the GitHub API lookup when downloading binaries using the '+b' command-line flag or hosts configuration.
        \\bin_urls:
        \\  BurntSushi/ripgrep: "https://github.com/BurntSushi/ripgrep/releases/download/13.0.0/ripgrep-13.0.0-{arch}-unknown-linux-musl.tar.gz"
        \\  sharkdp/fd: "https://github.com/sharkdp/fd/releases/download/v8.7.0/fd-v8.7.0-{arch}-unknown-linux-musl.tar.gz"
        \\  sharkdp/bat: "https://github.com/sharkdp/bat/releases/download/v0.24.0/bat-v0.24.0-{arch}-unknown-linux-musl.tar.gz"
        \\
        \\hosts:
        \\  # Default settings applied to every connection.
        \\  ".*":
        \\    +s: bash                        # Default shell to install and enter
        \\    +d:
        \\      - ~/.bashrc
        \\      - ~/.bash_aliases
        \\    +b:
        \\      - BurntSushi/ripgrep
        \\      - sharkdp/bat
        \\    ++tmux: true
        \\    +hhh: "~"                       # Remote base directory for payload execution
        \\
        \\  # Local testing configurations.
        \\  "127.0.0.1":
        \\    -p: 2222                        # Port for local test container
        \\    -i: ~/.ssh/xhh_test_key
        \\    +e:                             # Inject custom environment variables
        \\      - LANG="C.UTF-8"
        \\      - LC_ALL="C.UTF-8"
        \\
    ;

    var config_file = try std.fs.createFileAbsolute(config_path, .{});
    defer config_file.close();
    try config_file.writeAll(default_content);

    try standard_output.print("Created default configuration file at: {s}\n", .{config_path});
}

test "Config Parsing Test" {
    const testing = std.testing;
    const config_content =
        \\hosts:
        \\  ".*":
        \\    +s: xonsh
        \\    +hhh: "~"
        \\  "myhost":
        \\    -p: 2222
        \\    +if:
        \\    +e:
        \\      - OSH_THEME="simple"
        \\      - MY_VAR="val"
        \\  "otherhost":
        \\    -p: 3333
    ;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "config.zzhc", .data = config_content });

    var path_buf: [1024]u8 = undefined;
    const absolute_path = try tmp_dir.dir.realpath("config.zzhc", &path_buf);

    var args_list = std.ArrayList([]const u8).init(testing.allocator);
    defer {
        for (args_list.items) |arg| testing.allocator.free(arg);
        args_list.deinit();
    }

    try readAndParseConfigurationFile(testing.allocator, absolute_path, "myhost", &args_list);

    try testing.expect(args_list.items.len == 11);
    try testing.expectEqualStrings("+s", args_list.items[0]);
    try testing.expectEqualStrings("xonsh", args_list.items[1]);
    try testing.expectEqualStrings("+hhh", args_list.items[2]);
    try testing.expectEqualStrings("~", args_list.items[3]);
    try testing.expectEqualStrings("-p", args_list.items[4]);
    try testing.expectEqualStrings("2222", args_list.items[5]);
    try testing.expectEqualStrings("+if", args_list.items[6]);
    try testing.expectEqualStrings("+e", args_list.items[7]);
    try testing.expectEqualStrings("OSH_THEME=\"simple\"", args_list.items[8]);
}

test "Config Parsing Test - Extra cases and environments" {
    const testing = std.testing;

    // 1. Test getHomeDir environment branches
    var env_map = std.process.EnvMap.init(testing.allocator);
    defer env_map.deinit();

    // A. Test USERPROFILE branch
    try env_map.put("USERPROFILE", "mock_userprofile");
    const h_up = locateHomeDirectoryInEnvironment(testing.allocator, &env_map).?;
    try testing.expectEqualStrings("mock_userprofile", h_up);
    testing.allocator.free(h_up);

    // B. Test HOME branch (with USERPROFILE still there, USERPROFILE takes precedence)
    try env_map.put("HOME", "mock_home");
    const h_up2 = locateHomeDirectoryInEnvironment(testing.allocator, &env_map).?;
    try testing.expectEqualStrings("mock_userprofile", h_up2);
    testing.allocator.free(h_up2);

    // Now remove USERPROFILE to test HOME branch
    _ = env_map.remove("USERPROFILE");
    const h_home = locateHomeDirectoryInEnvironment(testing.allocator, &env_map).?;
    try testing.expectEqualStrings("mock_home", h_home);
    testing.allocator.free(h_home);

    // C. Test HOMEDRIVE and HOMEPATH branch
    _ = env_map.remove("HOME");
    try env_map.put("HOMEDRIVE", "C:");
    try env_map.put("HOMEPATH", "\\Users\\mock");
    const h_drive = locateHomeDirectoryInEnvironment(testing.allocator, &env_map).?;
    try testing.expectEqualStrings("C:\\Users\\mock", h_drive);
    testing.allocator.free(h_drive);

    // D. Test null fallback
    _ = env_map.remove("HOMEDRIVE");
    _ = env_map.remove("HOMEPATH");
    const home_null = locateHomeDirectoryInEnvironment(testing.allocator, &env_map);
    try testing.expect(home_null == null);

    // Call discoverUserHomeDirectory just to ensure the main wrapper gets covered.
    if (discoverUserHomeDirectory(testing.allocator)) |h| {
        testing.allocator.free(h);
    }

    // 2. Test glob matching with wildcards in the middle/start
    try testing.expect(hostMatchesPattern(testing.allocator, "*host", "myhost"));
    try testing.expect(hostMatchesPattern(testing.allocator, "prod*01", "prod-server-01"));
    try testing.expect(!hostMatchesPattern(testing.allocator, "prod*01", "dev-server-01"));

    // 3. Test failing allocator error path (OOM)
    try testing.expect(!hostMatchesPattern(testing.failing_allocator, "a*", "a"));

    // 4. Test non-existent config file (FileNotFound fallback)
    var err_args = std.ArrayList([]const u8).init(testing.allocator);
    defer err_args.deinit();
    try readAndParseConfigurationFile(testing.allocator, "/non/existent/file/path.zzhc", "myhost", &err_args);
    try testing.expect(err_args.items.len == 0);

    // 5. Test config with \r\n, tab indents, comments, empty lines, and trailing boolean flag
    const config_content =
        "other:\n" ++
        "  key: val\n" ++
        "hosts:\n" ++
        "  \".*\":\n" ++
        "    +s: xonsh\n" ++
        "\t# comment with tab\n" ++
        "\n" ++
        "    +hhh: \"~\"\n" ++
        "  \"myhost\":\n" ++
        "    -p: 2222\n" ++
        "    +if:\r\n";

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "config.zzhc", .data = config_content });
    var path_buf: [1024]u8 = undefined;
    const absolute_path = try tmp_dir.dir.realpath("config.zzhc", &path_buf);

    var args_list = std.ArrayList([]const u8).init(testing.allocator);
    defer {
        for (args_list.items) |arg| testing.allocator.free(arg);
        args_list.deinit();
    }
    try readAndParseConfigurationFile(testing.allocator, absolute_path, "myhost", &args_list);
    try testing.expect(args_list.items.len == 7);
    try testing.expectEqualStrings("+s", args_list.items[0]);
    try testing.expectEqualStrings("xonsh", args_list.items[1]);
    try testing.expectEqualStrings("+hhh", args_list.items[2]);
    try testing.expectEqualStrings("~", args_list.items[3]);
    try testing.expectEqualStrings("-p", args_list.items[4]);
    try testing.expectEqualStrings("2222", args_list.items[5]);
    try testing.expectEqualStrings("+if", args_list.items[6]);

    // 6. Test StreamTooLong error to trigger defer cleanup of current_key
    var long_line_buf: [5000]u8 = undefined;
    @memset(&long_line_buf, 'a');
    const long_config =
        "hosts:\n" ++
        "  \".*\":\n" ++
        "    +if:\n" ++
        long_line_buf[0..] ++ "\n";

    var tmp_dir2 = testing.tmpDir(.{});
    defer tmp_dir2.cleanup();
    try tmp_dir2.dir.writeFile(.{ .sub_path = "long_config.zzhc", .data = long_config });
    var path_buf2: [1024]u8 = undefined;
    const absolute_path2 = try tmp_dir2.dir.realpath("long_config.zzhc", &path_buf2);

    var args_list2 = std.ArrayList([]const u8).init(testing.allocator);
    defer {
        for (args_list2.items) |arg| testing.allocator.free(arg);
        args_list2.deinit();
    }
    const long_res = readAndParseConfigurationFile(testing.allocator, absolute_path2, "myhost", &args_list2);
    try testing.expectError(error.StreamTooLong, long_res);
}

test "Config Parsing Test - Settings and Binary URLs" {
    const testing = std.testing;
    const config_content =
        \\settings:
        \\  local_zzh_home: "~/.myzzh"
        \\  host_zzh_home: "/custom/home"
        \\  config_path: "/custom/config.zzhc"
        \\bin_urls:
        \\  BurntSushi/ripgrep: "https://example.com/ripgrep-{arch}.tar.gz"
        \\  sharkdp/fd: "https://example.com/fd-{arch}.tar.gz"
        \\  - "some/other-tool"
        \\hosts:
        \\  "myhost":
        \\    +s: xonsh
    ;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "config.zzhc", .data = config_content });

    var path_buf: [1024]u8 = undefined;
    const absolute_path = try tmp_dir.dir.realpath("config.zzhc", &path_buf);

    var args_list = std.ArrayList([]const u8).init(testing.allocator);
    defer {
        for (args_list.items) |arg| testing.allocator.free(arg);
        args_list.deinit();
    }

    try readAndParseConfigurationFile(testing.allocator, absolute_path, "myhost", &args_list);

    // Should include settings keys/values flat-mapped + host keys/values
    try testing.expect(args_list.items.len == 8);
    try testing.expectEqualStrings("+lh", args_list.items[0]);
    try testing.expectEqualStrings("~/.myzzh", args_list.items[1]);
    try testing.expectEqualStrings("+hh", args_list.items[2]);
    try testing.expectEqualStrings("/custom/home", args_list.items[3]);
    try testing.expectEqualStrings("+xc", args_list.items[4]);
    try testing.expectEqualStrings("/custom/config.zzhc", args_list.items[5]);
    try testing.expectEqualStrings("+s", args_list.items[6]);
    try testing.expectEqualStrings("xonsh", args_list.items[7]);

    // Test binary default url enabled check
    try testing.expect(try isBinaryDefaultUrlEnabled(absolute_path, "BurntSushi/ripgrep"));
    try testing.expect(try isBinaryDefaultUrlEnabled(absolute_path, "ripgrep"));
    try testing.expect(try isBinaryDefaultUrlEnabled(absolute_path, "rg"));
    try testing.expect(try isBinaryDefaultUrlEnabled(absolute_path, "sharkdp/fd"));
    try testing.expect(try isBinaryDefaultUrlEnabled(absolute_path, "fd"));
    try testing.expect(try isBinaryDefaultUrlEnabled(absolute_path, "some/other-tool"));
    try testing.expect(!try isBinaryDefaultUrlEnabled(absolute_path, "missing"));

    // Test custom URL lookup with {arch} substitution
    const arch_str = switch (@import("builtin").cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => "x86_64",
    };

    const lookup_url = try lookupBinaryUrlInConfig(testing.allocator, absolute_path, "BurntSushi/ripgrep", arch_str);
    try testing.expect(lookup_url != null);
    const expected_rg_url = try std.fmt.allocPrint(testing.allocator, "https://example.com/ripgrep-{s}.tar.gz", .{arch_str});
    defer testing.allocator.free(expected_rg_url);
    try testing.expectEqualStrings(expected_rg_url, lookup_url.?);
    testing.allocator.free(lookup_url.?);

    const lookup_fd = try lookupBinaryUrlInConfig(testing.allocator, absolute_path, "sharkdp/fd", arch_str);
    try testing.expect(lookup_fd != null);
    const expected_fd_url = try std.fmt.allocPrint(testing.allocator, "https://example.com/fd-{s}.tar.gz", .{arch_str});
    defer testing.allocator.free(expected_fd_url);
    try testing.expectEqualStrings(expected_fd_url, lookup_fd.?);
    testing.allocator.free(lookup_fd.?);
}

test "initializeDefaultConfigurationFile Test" {
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [1024]u8 = undefined;
    const absolute_tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    // Run the initialization with a custom directory under our temp dir
    const config_dir_path = try std.fs.path.join(testing.allocator, &.{ absolute_tmp_path, ".config", "zzh" });
    defer testing.allocator.free(config_dir_path);

    try initializeDefaultConfigurationFile(testing.allocator, config_dir_path);

    // Verify it created the config file
    const expected_path = try std.fs.path.join(testing.allocator, &.{ config_dir_path, "config.zzhc" });
    defer testing.allocator.free(expected_path);

    try std.fs.accessAbsolute(expected_path, .{});

    // Verify calling it again does not overwrite it
    try initializeDefaultConfigurationFile(testing.allocator, config_dir_path);
}

test "stripCommentsFromLine Test" {
    const testing = std.testing;
    
    // Simple comment
    try testing.expectEqualStrings("abc", stripCommentsFromLine("abc#comment"));
    // Comment with spaces
    try testing.expectEqualStrings("abc ", stripCommentsFromLine("abc # comment"));
    // No comment
    try testing.expectEqualStrings("abc", stripCommentsFromLine("abc"));
    // Comment inside double quotes
    try testing.expectEqualStrings("abc \"d#e\"", stripCommentsFromLine("abc \"d#e\""));
    // Comment inside single quotes
    try testing.expectEqualStrings("abc 'd#e'", stripCommentsFromLine("abc 'd#e'"));
    // Comment after quotes
    try testing.expectEqualStrings("abc \"d\" ", stripCommentsFromLine("abc \"d\" #comment"));
    // Double quote inside single quote comment
    try testing.expectEqualStrings("abc '\"' ", stripCommentsFromLine("abc '\"' # comment"));
}

test "Config Parsing Test - Inline Comments" {
    const testing = std.testing;
    const config_content =
        \\hosts:
        \\  ".*":
        \\    +s: zsh # Default shell to install
        \\    +hhh: "~" # Base dir
        \\  "myhost":
        \\    -p: 2222 # Port for testing
        \\    +if: # Reinstall flag
        \\    +e:
        \\      - OSH_THEME="powerlevel10k" # comment inside list
        \\      - TEST_VAR="hello # world" # comment with hash inside string
    ;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "config.zzhc", .data = config_content });

    var path_buf: [1024]u8 = undefined;
    const absolute_path = try tmp_dir.dir.realpath("config.zzhc", &path_buf);

    var args_list = std.ArrayList([]const u8).init(testing.allocator);
    defer {
        for (args_list.items) |arg| testing.allocator.free(arg);
        args_list.deinit();
    }

    try readAndParseConfigurationFile(testing.allocator, absolute_path, "myhost", &args_list);

    try testing.expectEqual(args_list.items.len, 11);
    try testing.expectEqualStrings("+s", args_list.items[0]);
    try testing.expectEqualStrings("zsh", args_list.items[1]);
    try testing.expectEqualStrings("+hhh", args_list.items[2]);
    try testing.expectEqualStrings("~", args_list.items[3]);
    try testing.expectEqualStrings("-p", args_list.items[4]);
    try testing.expectEqualStrings("2222", args_list.items[5]);
    try testing.expectEqualStrings("+if", args_list.items[6]);
    try testing.expectEqualStrings("+e", args_list.items[7]);
    try testing.expectEqualStrings("OSH_THEME=\"powerlevel10k\"", args_list.items[8]);
    try testing.expectEqualStrings("+e", args_list.items[9]);
    try testing.expectEqualStrings("TEST_VAR=\"hello # world\"", args_list.items[10]);
}

test "Config Parsing Test - Boolean Options" {
    const testing = std.testing;
    const config_content =
        \\hosts:
        \\  "myhost":
        \\    ++tmux: true
        \\    +if: false
        \\    +hhr: true
        \\    +s: bash
    ;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "config.zzhc", .data = config_content });

    var path_buf: [1024]u8 = undefined;
    const absolute_path = try tmp_dir.dir.realpath("config.zzhc", &path_buf);

    var args_list = std.ArrayList([]const u8).init(testing.allocator);
    defer {
        for (args_list.items) |arg| testing.allocator.free(arg);
        args_list.deinit();
    }

    try readAndParseConfigurationFile(testing.allocator, absolute_path, "myhost", &args_list);

    try testing.expectEqual(args_list.items.len, 4);
    try testing.expectEqualStrings("++tmux", args_list.items[0]);
    try testing.expectEqualStrings("+hhr", args_list.items[1]);
    try testing.expectEqualStrings("+s", args_list.items[2]);
    try testing.expectEqualStrings("bash", args_list.items[3]);
}



