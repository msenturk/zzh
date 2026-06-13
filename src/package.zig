const std = @import("std");
const config = @import("config.zig");

/// Metadata defining a remote shell or plugin repository/url to download.
pub const DownloaderManifest = struct {
    name: []const u8,
    git_url: []const u8,
    clean_name: []const u8,
};

/// Releases all dynamically allocated strings in the downloader manifest.
pub fn releasePackageVitals(allocator: std.mem.Allocator, manifest: DownloaderManifest) void {
    allocator.free(manifest.name);
    allocator.free(manifest.git_url);
    allocator.free(manifest.clean_name);
}

/// Normalizes user-specified package identifiers into uniform naming schemas.
/// This guarantees shells are prefixed with 'xxh-shell-' and plugins with 'xxh-plugin-',
/// resolving short names like 'nushell' to standard package formats.
pub noinline fn normalizePackageIdentifier(allocator: std.mem.Allocator, name: []const u8, is_shell: bool) ![]const u8 {
    if (is_shell) {
        var mapped_name = name;
        if (std.mem.eql(u8, name, "nushell")) {
            mapped_name = "nu";
        } else if (std.mem.eql(u8, name, "xxh-shell-nushell")) {
            mapped_name = "xxh-shell-nu";
        } else if (std.mem.startsWith(u8, name, "nushell+git+")) {
            const rest = name["nushell".len..];
            return std.fmt.allocPrint(allocator, "xxh-shell-nu{s}", .{rest});
        } else if (std.mem.startsWith(u8, name, "xxh-shell-nushell+git+")) {
            const rest = name["xxh-shell-nushell".len..];
            return std.fmt.allocPrint(allocator, "xxh-shell-nu{s}", .{rest});
        }

        if (!std.mem.startsWith(u8, mapped_name, "xxh-shell-")) {
            if (std.mem.indexOf(u8, mapped_name, "+git+")) |idx| {
                const shell_short = mapped_name[0..idx];
                const rest = mapped_name[idx..];
                var clean_short = shell_short;
                if (std.mem.eql(u8, clean_short, "nushell")) {
                    clean_short = "nu";
                }
                if (!std.mem.startsWith(u8, clean_short, "xxh-shell-")) {
                    return std.fmt.allocPrint(allocator, "xxh-shell-{s}{s}", .{ clean_short, rest });
                }
            } else {
                return std.fmt.allocPrint(allocator, "xxh-shell-{s}", .{mapped_name});
            }
        }
        return allocator.dupe(u8, mapped_name);
    } else {
        if (!std.mem.startsWith(u8, name, "xxh-plugin-")) {
            if (std.mem.indexOf(u8, name, "+git+")) |idx| {
                const plugin_short = name[0..idx];
                const rest = name[idx..];
                if (!std.mem.startsWith(u8, plugin_short, "xxh-plugin-")) {
                    return std.fmt.allocPrint(allocator, "xxh-plugin-{s}{s}", .{ plugin_short, rest });
                } else {
                    // This is unreachable by design because plugin_short is a prefix of name,
                    // and name does not start with "xxh-plugin-".
                    @panic("plugin_short prefix invariant violated");
                }
            } else {
                return std.fmt.allocPrint(allocator, "xxh-plugin-{s}", .{name});
            }
        }
    }
    return allocator.dupe(u8, name);
}

/// Constructs a download manifest from a raw package specification.
/// If a Git URL is specified via the '+git+' infix, we parse it directly;
/// otherwise, we fall back to official XXH GitHub repositories.
pub noinline fn fetchPackageVitals(allocator: std.mem.Allocator, raw_name: []const u8, is_shell: bool) !DownloaderManifest {
    const resolved_name = try normalizePackageIdentifier(allocator, raw_name, is_shell);
    errdefer allocator.free(resolved_name);

    if (std.mem.indexOf(u8, resolved_name, "+git+")) |idx| {
        const clean_name = try allocator.dupe(u8, resolved_name[0..idx]);
        errdefer allocator.free(clean_name);
        const git_url = try allocator.dupe(u8, resolved_name[idx + 5 ..]);
        return .{
            .name = resolved_name,
            .git_url = git_url,
            .clean_name = clean_name,
        };
    } else {
        const clean_name = try allocator.dupe(u8, resolved_name);
        errdefer allocator.free(clean_name);
        
        // Nushell's shell wrapper is hosted inside the zzh repository itself.
        const git_url = if (std.mem.eql(u8, resolved_name, "xxh-shell-nu"))
            try allocator.dupe(u8, "https://github.com/msenturk/zzh/tree/main/shells/xxh-shell-nu")
        else
            try std.fmt.allocPrint(allocator, "https://github.com/xxh/{s}", .{resolved_name});
        
        return .{
            .name = resolved_name,
            .git_url = git_url,
            .clean_name = clean_name,
        };
    }
}

/// Recursively creates a local directory path if it does not already exist.
pub fn ensureDirectoryPath(target_directory: []const u8) !void {
    var char_idx: usize = 0;
    while (char_idx < target_directory.len) : (char_idx += 1) {
        if (target_directory[char_idx] == '/' or target_directory[char_idx] == '\\') {
            if (char_idx == 0) continue;
            // Ignore Windows drive letter prefixes (e.g. C:)
            if (char_idx == 2 and target_directory[1] == ':') continue;

            const sub_path = target_directory[0..char_idx];
            std.fs.makeDirAbsolute(sub_path) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }
    }
    std.fs.makeDirAbsolute(target_directory) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

/// Spawns a subprocess and blocks until it exits. Returns error if command returns non-zero.
pub fn executeSubprocess(allocator: std.mem.Allocator, command_argv: []const []const u8) !void {
    var child_process = std.process.Child.init(command_argv, allocator);
    child_process.stdout_behavior = .Inherit;
    child_process.stderr_behavior = .Inherit;
    try child_process.spawn();
    const exit_status = try child_process.wait();
    switch (exit_status) {
        .Exited => |code| {
            if (code != 0) return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
}

/// Downloads and extracts the official statically compiled Nushell plugins.
/// We target musl releases because Nushell plugins compiled with musl run seamlessly on almost
/// all Linux distros, including minimal environments (like Alpine) that lack glibc out of the box.
fn fetchStaticallyCompiledNushellPlugin(allocator: std.mem.Allocator, plugin_name: []const u8, target_dir: []const u8) !void {
    const NU_VERSION = "0.94.2";
    const tarball_name = "nu_plugin_download.tar.gz";

    const temp_tarball = try std.fs.path.join(allocator, &.{ target_dir, tarball_name });
    defer allocator.free(temp_tarball);

    try ensureDirectoryPath(target_dir);

    const arch_str = switch (@import("builtin").cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return error.UnsupportedArchitecture,
    };

    const download_url = try std.fmt.allocPrint(allocator, "https://github.com/nushell/nushell/releases/download/{s}/nu-{s}-{s}-unknown-linux-musl.tar.gz", .{ NU_VERSION, NU_VERSION, arch_str });
    defer allocator.free(download_url);

    const curl_argv = [_][]const u8{ "curl", "-L", "-o", temp_tarball, download_url };
    try executeSubprocess(allocator, &curl_argv);

    const tar_argv = [_][]const u8{ "tar", "-xzf", temp_tarball, "-C", target_dir };
    try executeSubprocess(allocator, &tar_argv);

    const extracted_folder_name = try std.fmt.allocPrint(allocator, "nu-{s}-{s}-unknown-linux-musl", .{ NU_VERSION, arch_str });
    defer allocator.free(extracted_folder_name);

    const bin_filename = try std.fmt.allocPrint(allocator, "nu_plugin_{s}", .{plugin_name});
    defer allocator.free(bin_filename);

    const src_path = try std.fs.path.join(allocator, &.{ target_dir, extracted_folder_name, bin_filename });
    defer allocator.free(src_path);

    const dest_path = try std.fs.path.join(allocator, &.{ target_dir, bin_filename });
    defer allocator.free(dest_path);

    try std.fs.renameAbsolute(src_path, dest_path);

    const extracted_dir_path = try std.fs.path.join(allocator, &.{ target_dir, extracted_folder_name });
    defer allocator.free(extracted_dir_path);
    try std.fs.deleteTreeAbsolute(extracted_dir_path);
    try std.fs.deleteFileAbsolute(temp_tarball);
}

/// Clones only a specific subdirectory from a repository tree instead of cloning the entire project.
/// This uses sparse-checkout and depth-1 clone to save CPU cycles and network bandwidth, especially
/// when downloading our custom shells (like nushell shell) embedded inside the mono zzh repository.
fn gitCloneSubdirectoryOnly(allocator: std.mem.Allocator, package_name: []const u8, git_url: []const u8, target_dir: []const u8) !void {
    if (std.mem.indexOf(u8, git_url, "/tree/")) |tree_idx| {
        const repo_url = git_url[0..tree_idx];
        const rest = git_url[tree_idx + 6 ..];
        if (std.mem.indexOf(u8, rest, "/")) |slash_idx| {
            const branch = rest[0..slash_idx];
            const subfolder = rest[slash_idx + 1 ..];

            std.debug.print("      - Downloading {s} (fallback repository)...\n", .{package_name});
            
            const tmp_target_dir = try std.fmt.allocPrint(allocator, "{s}_tmp", .{target_dir});
            defer allocator.free(tmp_target_dir);
            std.fs.deleteTreeAbsolute(tmp_target_dir) catch {};

            // 1. Full depth-1 clone of the branch.
            const clone_argv = [_][]const u8{ "git", "clone", "--depth=1", "-b", branch, repo_url, tmp_target_dir };
            try executeSubprocess(allocator, &clone_argv);

            const extracted_folder = try std.fs.path.join(allocator, &.{ tmp_target_dir, subfolder });
            defer allocator.free(extracted_folder);

            // 2. Ensure target_dir doesn't exist before moving to avoid nesting.
            std.fs.deleteTreeAbsolute(target_dir) catch {};

            // 3. Move the subdirectory to the target location.
            const mv_argv = [_][]const u8{ "mv", extracted_folder, target_dir };
            try executeSubprocess(allocator, &mv_argv);

            std.fs.deleteTreeAbsolute(tmp_target_dir) catch {};
        } else {
            std.debug.print("Invalid tree URL format: {s}\n", .{git_url});
            return error.InvalidUrl;
        }
    } else {
        return error.InvalidUrl;
    }
}

/// Iterates through all cached packages locally and pulls the latest changes via 'git pull --rebase'.
/// This allows users to easily keep their customized shell and plugin layouts up-to-date.
pub fn refreshCachedRepositories(allocator: std.mem.Allocator, local_xxh_home: ?[]const u8) !void {
    var base_dir: []const u8 = undefined;
    if (local_xxh_home) |lh| {
        base_dir = try config.expandUserPath(allocator, lh);
    } else {
        const home = config.discoverUserHomeDirectory(allocator) orelse return error.HomeDirNotFound;
        defer allocator.free(home);
        base_dir = try std.fs.path.join(allocator, &.{ home, ".zzh" });
    }
    defer allocator.free(base_dir);

    const sub_dirs = [_][]const u8{ "shells", "plugins" };
    for (sub_dirs) |sub_dir| {
        // Note: The double ".zzh" path construction is intentional.
        // On the target remote host, the user's payloads and configurations are deployed 
        // into ~/.zzh/.zzh/ (e.g. ~/.zzh/.zzh/shells/...). Storing cached packages locally 
        // in ~/.zzh/.zzh/ mirrors the target structure and ensures relative path lookups are consistent.
        const dir_path = try std.fs.path.join(allocator, &.{ base_dir, ".zzh", sub_dir });
        defer allocator.free(dir_path);

        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .directory) {
                const pkg_dir = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(pkg_dir);

                const git_dir = try std.fs.path.join(allocator, &.{ pkg_dir, ".git" });
                defer allocator.free(git_dir);

                std.fs.accessAbsolute(git_dir, .{}) catch continue;

                std.debug.print("Updating {s}...\n", .{entry.name});
                const argv = [_][]const u8{ "git", "pull", "--rebase" };
                var child = std.process.Child.init(&argv, allocator);
                child.cwd = pkg_dir;
                child.stdout_behavior = .Inherit;
                child.stderr_behavior = .Inherit;
                child.spawn() catch {
                    std.debug.print("Failed to spawn git pull for {s}\n", .{entry.name});
                    continue;
                };
                _ = child.wait() catch continue;
            }
        }
    }
}

/// Provisions the portable static tmux binary, saving it to ~/.zzh/bin/tmux.
/// Relies on tmux/tmux-builds static releases. Static compilation ensures we do not have glibc
/// or dynamic linker compatibility issues when executing on minimal target architectures.
pub fn provisionStaticallyCompiledTmux(allocator: std.mem.Allocator, install_force: bool, local_xxh_home: ?[]const u8, target_arch: []const u8) ![]const u8 {
    var base_dir: []const u8 = undefined;
    if (local_xxh_home) |lh| {
        base_dir = try config.expandUserPath(allocator, lh);
    } else {
        const home = config.discoverUserHomeDirectory(allocator) orelse return error.HomeDirNotFound;
        defer allocator.free(home);
        base_dir = try std.fs.path.join(allocator, &.{ home, ".zzh" });
    }
    defer allocator.free(base_dir);

    const bin_dir = try std.fs.path.join(allocator, &.{ base_dir, "bin" });
    defer allocator.free(bin_dir);
    try ensureDirectoryPath(bin_dir);

    const tmux_path = try std.fs.path.join(allocator, &.{ bin_dir, "tmux" });
    errdefer allocator.free(tmux_path);

    const exists = blk: {
        std.fs.accessAbsolute(tmux_path, .{}) catch { break :blk false; };
        break :blk true;
    };

    if (exists and !install_force) {
        return tmux_path;
    }

    const TMUX_VERSION = "v3.6a";
    const url = try std.fmt.allocPrint(allocator, "https://github.com/tmux/tmux-builds/releases/download/{s}/tmux-3.6a-linux-{s}.tar.gz", .{ TMUX_VERSION, target_arch });
    defer allocator.free(url);
    std.debug.print("      - Downloading portable static tmux {s}...\n", .{TMUX_VERSION});
    
    const archive_path = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{tmux_path});
    defer {
        std.fs.deleteFileAbsolute(archive_path) catch {};
        allocator.free(archive_path);
    }

    const builtin = @import("builtin");
    const curl_cmd = if (builtin.os.tag == .windows) "curl.exe" else "curl";
    const curl_argv = [_][]const u8{ curl_cmd, "-fsSL", "-o", archive_path, url };
    try executeSubprocess(allocator, &curl_argv);

    std.debug.print("      - Extracting tmux binary...\n", .{});
    const tar_cmd = if (builtin.os.tag == .windows) "tar.exe" else "tar";
    const tar_argv = [_][]const u8{ tar_cmd, "-xf", archive_path, "-C", bin_dir };
    try executeSubprocess(allocator, &tar_argv);

    if (builtin.os.tag != .windows) {
        const chmod_argv = [_][]const u8{ "chmod", "+x", tmux_path };
        try executeSubprocess(allocator, &chmod_argv);
    }
    std.debug.print("      - Caching tmux binary to ~/.zzh/bin/tmux...\n", .{});

    return tmux_path;
}

/// Checks if a package is cached locally; if not, git clones/downloads it from remote.
pub fn obtainAndCachePackage(allocator: std.mem.Allocator, pkg: DownloaderManifest, is_shell: bool, install_force: bool, local_xxh_home: ?[]const u8) ![]const u8 {
    var base_dir: []const u8 = undefined;
    if (local_xxh_home) |lh| {
        base_dir = try config.expandUserPath(allocator, lh);
    } else {
        const home = config.discoverUserHomeDirectory(allocator) orelse return error.HomeDirNotFound;
        defer allocator.free(home);
        base_dir = try std.fs.path.join(allocator, &.{ home, ".zzh" });
    }
    defer allocator.free(base_dir);

    const sub_dir = if (is_shell) "shells" else "plugins";
    // Mirrors the target host directory layout ~/.zzh/.zzh/ to ensure consistency.
    const target_dir = try std.fs.path.join(allocator, &.{ base_dir, ".zzh", sub_dir, pkg.clean_name });
    errdefer allocator.free(target_dir);

    var exists = true;
    std.fs.accessAbsolute(target_dir, .{}) catch |err| {
        if (err == error.FileNotFound) {
            exists = false;
        } else {
            return err;
        }
    };

    if (exists and install_force) {
        std.fs.deleteTreeAbsolute(target_dir) catch {};
        exists = false;
    }

    if (!exists) {
        const parent_dir = try std.fs.path.join(allocator, &.{ base_dir, ".zzh", sub_dir });
        defer allocator.free(parent_dir);
        try ensureDirectoryPath(parent_dir);

        if (!is_shell and std.mem.startsWith(u8, pkg.clean_name, "xxh-plugin-nu-")) {
            const plugin_suffix = pkg.clean_name["xxh-plugin-nu-".len..];
            std.debug.print("      - Downloading official Nushell plugin '{s}'...\n", .{plugin_suffix});
            try fetchStaticallyCompiledNushellPlugin(allocator, plugin_suffix, target_dir);
        } else {
            if (std.mem.indexOf(u8, pkg.git_url, "/tree/") != null) {
                try gitCloneSubdirectoryOnly(allocator, pkg.clean_name, pkg.git_url, target_dir);
            } else {
                std.debug.print("      - Downloading {s}...\n", .{ pkg.clean_name });
                const argv = [_][]const u8{ "git", "clone", "--depth=1", pkg.git_url, target_dir };
                executeSubprocess(allocator, &argv) catch |err| {
                    if (err == error.CommandFailed) {
                        std.debug.print("      - Failed to download from git. Trying fallback repository...\n", .{});
                        const fallback_url = try std.fmt.allocPrint(allocator, "https://github.com/msenturk/zzh/tree/main/{s}/{s}", .{sub_dir, pkg.clean_name});
                        defer allocator.free(fallback_url);
                        try gitCloneSubdirectoryOnly(allocator, pkg.clean_name, fallback_url, target_dir);
                    } else {
                        return err;
                    }
                };
            }
        }
    }

    return target_dir;
}

/// Formats the final executable file name from a repository URL.
pub fn extractExecutableName(repository_url: []const u8) []const u8 {
    var name = repository_url;
    if (std.mem.lastIndexOfScalar(u8, repository_url, '/')) |idx| {
        name = repository_url[idx + 1 ..];
    }
    if (std.mem.indexOfScalar(u8, name, '@')) |idx| {
        name = name[0..idx];
    }
    // Handle specific aliases for GitHub short repositories (e.g. "BurntSushi/ripgrep" -> "rg").
    // Direct URLs (e.g. tar.gz release assets) retain their filename and are mapped post-extraction.
    if (std.mem.eql(u8, name, "ripgrep")) {
        return "rg";
    }
    return name;
}

/// Normalizes GitHub URLs to paths (like 'owner/repo').
fn normalizeGitHubRepoPath(allocator: std.mem.Allocator, raw_url: []const u8) ![]const u8 {
    var clean_path = raw_url;
    if (std.mem.startsWith(u8, clean_path, "https://github.com/")) {
        clean_path = clean_path["https://github.com/".len..];
    } else if (std.mem.startsWith(u8, clean_path, "http://github.com/")) {
        clean_path = clean_path["http://github.com/".len..];
    }
    while (clean_path.len > 0 and clean_path[clean_path.len - 1] == '/') {
        clean_path = clean_path[0 .. clean_path.len - 1];
    }
    return allocator.dupe(u8, clean_path);
}

/// Performs a depth-first search for a file matching target_name inside a directory tree.
fn searchDirectoryForFile(allocator: std.mem.Allocator, dir_path: []const u8, target_name: []const u8) !?[]const u8 {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            const sub_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(sub_path);
            if (try searchDirectoryForFile(allocator, sub_path, target_name)) |found| {
                return found;
            }
        } else if (entry.kind == .file or entry.kind == .sym_link) {
            if (std.mem.eql(u8, entry.name, target_name)) {
                return try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            }
        }
    }
    return null;
}

const RepoSearchItem = struct {
    full_name: []const u8,
    stargazers_count: u32,
    description: ?[]const u8,
};
const RepoSearchResponse = struct {
    items: []RepoSearchItem,
};

const ReleaseAsset = struct {
    name: []const u8,
    browser_download_url: []const u8,
};

fn searchGitHubForRepo(allocator: std.mem.Allocator, query: []const u8, curl_cmd: []const u8) ![]const u8 {
    const api_url = try std.fmt.allocPrint(allocator, "https://api.github.com/search/repositories?q={s}&per_page=3", .{query});
    defer allocator.free(api_url);

    const api_argv = [_][]const u8{ curl_cmd, "-fsSL", "-H", "User-Agent: zzh-client", api_url };
    return try executeSubprocessAndCaptureOutput(allocator, &api_argv);
}

fn promptUserSelectRepo(repos: []RepoSearchItem) !usize {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    try stdout.print("\nMultiple GitHub repositories found for search. Please select one:\n", .{});
    for (repos, 0..) |repo, idx| {
        const desc = repo.description orelse "";
        try stdout.print("  [{d}] {s} ({d} stars) - {s}\n", .{ idx + 1, repo.full_name, repo.stargazers_count, desc });
    }

    var buf: [64]u8 = undefined;
    while (true) {
        try stdout.print("Enter selection [1-{d}]: ", .{repos.len});
        const line = stdin.readUntilDelimiterOrEof(&buf, '\n') catch |err| {
            if (err == error.StreamTooLong) {
                while (true) {
                    const c = stdin.readByte() catch break;
                    if (c == '\n') break;
                }
                try stdout.print("Input too long. Please try again.\n", .{});
                continue;
            }
            return err;
        };
        
        if (line == null) return error.UserInterrupted;
        
        const trimmed = std.mem.trim(u8, line.?, " \t\r");
        if (trimmed.len == 0) continue;

        if (std.fmt.parseInt(usize, trimmed, 10)) |val| {
            if (val >= 1 and val <= repos.len) {
                return val - 1;
            }
        } else |_| {}
        try stdout.print("Invalid selection '{s}'. Please try again.\n", .{trimmed});
        // Small sleep to prevent tight loop if stdin is weird
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}

fn promptUserSelectAsset(assets: []ReleaseAsset) !usize {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    try stdout.print("\nCompatible release assets found. Please select one to download:\n", .{});
    for (assets, 0..) |asset, idx| {
        try stdout.print("  [{d}] {s}\n", .{ idx + 1, asset.name });
    }

    var buf: [64]u8 = undefined;
    while (true) {
        try stdout.print("Enter selection [1-{d}]: ", .{assets.len});
        const line = stdin.readUntilDelimiterOrEof(&buf, '\n') catch |err| {
            if (err == error.StreamTooLong) {
                while (true) {
                    const c = stdin.readByte() catch break;
                    if (c == '\n') break;
                }
                try stdout.print("Input too long. Please try again.\n", .{});
                continue;
            }
            return err;
        };
        
        if (line == null) return error.UserInterrupted;
        
        const trimmed = std.mem.trim(u8, line.?, " \t\r");
        if (trimmed.len == 0) continue;

        if (std.fmt.parseInt(usize, trimmed, 10)) |val| {
            if (val >= 1 and val <= assets.len) {
                return val - 1;
            }
        } else |_| {}
        try stdout.print("Invalid selection '{s}'. Please try again.\n", .{trimmed});
        // Small sleep to prevent tight loop if stdin is weird
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}

fn findBestMatchingRepo(items: []RepoSearchItem, query: []const u8) usize {
    // Stage 1: Look for exact case-insensitive match on repo name (e.g. "fd" matches "sharkdp/fd")
    for (items, 0..) |item, idx| {
        var name = item.full_name;
        if (std.mem.lastIndexOfScalar(u8, item.full_name, '/')) |slash_idx| {
            name = item.full_name[slash_idx + 1 ..];
        }
        if (std.mem.eql(u8, name, query)) {
            return idx;
        }
    }
    // Stage 2: Fallback to the item with the highest stargazers count
    var selected_idx: usize = 0;
    var max_stars: u32 = 0;
    for (items, 0..) |repo, idx| {
        if (repo.stargazers_count > max_stars) {
            max_stars = repo.stargazers_count;
            selected_idx = idx;
        }
    }
    return selected_idx;
}

fn selectReleaseAsset(allocator: std.mem.Allocator, assets: []ReleaseAsset, target_os: []const u8, target_arch: []const u8) !ReleaseAsset {
    const is_x64 = std.mem.eql(u8, target_arch, "x86_64");

    var filtered = std.ArrayList(ReleaseAsset).init(allocator);
    defer filtered.deinit();

    // Filter stage 1: OS and Architecture matching
    for (assets) |asset| {
        const name = asset.name;
        if (std.mem.indexOf(u8, name, target_os) != null or 
            (std.mem.eql(u8, target_os, "linux") and std.mem.indexOf(u8, name, "unknown-linux") != null)) {
            const has_arch_match = if (is_x64) 
                (std.mem.indexOf(u8, name, "x86_64") != null or std.mem.indexOf(u8, name, "amd64") != null)
            else 
                (std.mem.indexOf(u8, name, "aarch64") != null or std.mem.indexOf(u8, name, "arm64") != null);

            if (has_arch_match) {
                if (std.mem.endsWith(u8, name, ".deb") or std.mem.endsWith(u8, name, ".rpm") or std.mem.endsWith(u8, name, ".apk")) {
                    continue;
                }
                try filtered.append(asset);
            }
        }
    }

    // Filter stage 2 fallback: Just Architecture matching archive formats
    if (filtered.items.len == 0) {
        for (assets) |asset| {
            const name = asset.name;
            const has_arch_match = if (is_x64) 
                (std.mem.indexOf(u8, name, "x86_64") != null or std.mem.indexOf(u8, name, "amd64") != null)
            else 
                (std.mem.indexOf(u8, name, "aarch64") != null or std.mem.indexOf(u8, name, "arm64") != null);

            if (has_arch_match) {
                if (std.mem.endsWith(u8, name, ".tar.gz") or std.mem.endsWith(u8, name, ".tgz") or std.mem.endsWith(u8, name, ".zip")) {
                    try filtered.append(asset);
                }
            }
        }
    }

    const candidates = if (filtered.items.len > 0) filtered.items else assets;

    if (candidates.len == 0) {
        return error.NoCompatibleAssetFound;
    }

    if (candidates.len == 1) {
        return candidates[0];
    }

    if (std.io.getStdIn().isTty() and std.io.getStdOut().isTty()) {
        const idx = try promptUserSelectAsset(candidates);
        return candidates[idx];
    } else {
        // Non-interactive fallback: prefer musl, then gnu, then whatever is first
        for (candidates) |asset| {
            if (std.mem.indexOf(u8, asset.name, "musl") != null) return asset;
        }
        for (candidates) |asset| {
            if (std.mem.indexOf(u8, asset.name, "gnu") != null) return asset;
        }
        return candidates[0];
    }
}

/// Spawns a child process and reads stdout into a dynamically-allocated buffer.
pub fn executeSubprocessAndCaptureOutput(allocator: std.mem.Allocator, command_argv: []const []const u8) ![]const u8 {
    var child = std.process.Child.init(command_argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    var out_buf = std.ArrayList(u8).init(allocator);
    errdefer out_buf.deinit();

    var stdout_reader = child.stdout.?.reader();
    while (true) {
        var buf: [4096]u8 = undefined;
        const amt = try stdout_reader.read(&buf);
        if (amt == 0) break;
        try out_buf.appendSlice(buf[0..amt]);
    }

    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        return error.CommandFailed;
    }

    return out_buf.toOwnedSlice();
}

/// Fetches and extracts a statically compiled target executable from GitHub Releases or direct URL.
pub fn provisionStaticallyCompiledBinary(
    allocator: std.mem.Allocator,
    repo_input: []const u8,
    install_force: bool,
    local_xxh_home: ?[]const u8,
    target_os: []const u8,
    target_arch: []const u8,
) !void {
    var base_dir: []const u8 = undefined;
    if (local_xxh_home) |lh| {
        base_dir = try config.expandUserPath(allocator, lh);
    } else {
        const home = config.discoverUserHomeDirectory(allocator) orelse return error.HomeDirNotFound;
        defer allocator.free(home);
        base_dir = try std.fs.path.join(allocator, &.{ home, ".zzh" });
    }
    defer allocator.free(base_dir);

    const bin_name = extractExecutableName(repo_input);
    const bin_dir = try std.fs.path.join(allocator, &.{ base_dir, "bin" });
    defer allocator.free(bin_dir);
    try ensureDirectoryPath(bin_dir);

    const dest_bin_path = try std.fs.path.join(allocator, &.{ bin_dir, bin_name });
    defer allocator.free(dest_bin_path);

    const exists = blk: {
        std.fs.accessAbsolute(dest_bin_path, .{}) catch { break :blk false; };
        break :blk true;
    };

    if (exists and !install_force) {
        return;
    }

    const builtin = @import("builtin");
    const curl_cmd = if (builtin.os.tag == .windows) "curl.exe" else "curl";

    const resolved_repo_input = repo_input;

    var is_direct_url = false;
    if (std.mem.startsWith(u8, resolved_repo_input, "http://") or std.mem.startsWith(u8, resolved_repo_input, "https://")) {
        var path = resolved_repo_input;
        if (std.mem.startsWith(u8, path, "https://github.com/")) {
            path = path["https://github.com/".len..];
        } else if (std.mem.startsWith(u8, path, "http://github.com/")) {
            path = path["http://github.com/".len..];
        } else {
            is_direct_url = true;
        }

        if (!is_direct_url) {
            while (path.len > 0 and path[path.len - 1] == '/') {
                path = path[0 .. path.len - 1];
            }
            var slash_count: usize = 0;
            for (path) |char| {
                if (char == '/') slash_count += 1;
            }
            if (slash_count > 1) {
                is_direct_url = true;
            }
        }
    }

    if (is_direct_url) {
        std.debug.print("      - Downloading direct file/archive from {s}...\n", .{resolved_repo_input});
        const is_archive = std.mem.endsWith(u8, resolved_repo_input, ".tar.gz") or 
                           std.mem.endsWith(u8, resolved_repo_input, ".tgz") or 
                           std.mem.endsWith(u8, resolved_repo_input, ".zip");

        if (is_archive) {
            const rand = std.crypto.random.int(u64);
            var archive_name_buf: [64]u8 = undefined;
            const archive_name = try std.fmt.bufPrint(&archive_name_buf, "tmp_bin_{x}", .{rand});
            const archive_path = try std.fs.path.join(allocator, &.{ bin_dir, archive_name });
            defer {
                std.fs.deleteFileAbsolute(archive_path) catch {};
                allocator.free(archive_path);
            }

            var temp_extract_name_buf: [64]u8 = undefined;
            const temp_extract_name = try std.fmt.bufPrint(&temp_extract_name_buf, "tmp_extract_{x}", .{rand});
            const temp_extract_path = try std.fs.path.join(allocator, &.{ bin_dir, temp_extract_name });
            defer {
                std.fs.deleteTreeAbsolute(temp_extract_path) catch {};
                allocator.free(temp_extract_path);
            }

            const download_argv = [_][]const u8{ curl_cmd, "-fsSL", "--connect-timeout", "2", "--max-time", "120", "-o", archive_path, resolved_repo_input };
            try executeSubprocess(allocator, &download_argv);

            try ensureDirectoryPath(temp_extract_path);
            
            std.debug.print("      - Extracting archive...\n", .{});
            const tar_cmd = if (builtin.os.tag == .windows) "tar.exe" else "tar";
            const tar_argv = [_][]const u8{ tar_cmd, "-xf", archive_path, "-C", temp_extract_path };
            try executeSubprocess(allocator, &tar_argv);

            var search_name = bin_name;
            if (std.mem.endsWith(u8, search_name, ".tar.gz")) {
                search_name = search_name[0 .. search_name.len - ".tar.gz".len];
            } else if (std.mem.endsWith(u8, search_name, ".tgz")) {
                search_name = search_name[0 .. search_name.len - ".tgz".len];
            } else if (std.mem.endsWith(u8, search_name, ".zip")) {
                search_name = search_name[0 .. search_name.len - ".zip".len];
            }

            std.debug.print("      - Locating binary file '{s}'...\n", .{search_name});
            const found_bin_path = try searchDirectoryForFile(allocator, temp_extract_path, search_name);

            if (found_bin_path) |fbp| {
                defer allocator.free(fbp);
                try std.fs.copyFileAbsolute(fbp, dest_bin_path, .{});
                if (builtin.os.tag != .windows) {
                    const chmod_argv = [_][]const u8{ "chmod", "+x", dest_bin_path };
                    try executeSubprocess(allocator, &chmod_argv);
                }
                std.debug.print("      - Extracting and caching to ~/.zzh/bin/{s}...\n", .{bin_name});
            } else {
                return error.BinaryNotFoundInArchive;
            }
        } else {
            const download_argv = [_][]const u8{ curl_cmd, "-fsSL", "-o", dest_bin_path, resolved_repo_input };
            try executeSubprocess(allocator, &download_argv);
            if (builtin.os.tag != .windows) {
                const chmod_argv = [_][]const u8{ "chmod", "+x", dest_bin_path };
                try executeSubprocess(allocator, &chmod_argv);
            }
            std.debug.print("      - Caching direct binary/file to ~/.zzh/bin/{s}...\n", .{bin_name});
        }
        return;
    }

    var repo_to_query: []const u8 = undefined;
    var repo_to_query_allocated = false;
    defer {
        if (repo_to_query_allocated) allocator.free(repo_to_query);
    }

    if (std.mem.indexOfScalar(u8, resolved_repo_input, '/') == null and 
        !std.mem.startsWith(u8, resolved_repo_input, "http://") and 
        !std.mem.startsWith(u8, resolved_repo_input, "https://")) {
        
        std.debug.print("      - Searching GitHub for '{s}'...\n", .{resolved_repo_input});
        const json_bytes = try searchGitHubForRepo(allocator, resolved_repo_input, curl_cmd);
        defer allocator.free(json_bytes);

        const parsed_search = try std.json.parseFromSlice(RepoSearchResponse, allocator, json_bytes, .{ .ignore_unknown_fields = true });
        defer parsed_search.deinit();

        if (parsed_search.value.items.len == 0) {
            return error.NoMatchingRepositoryFound;
        }

        var selected_idx: usize = 0;
        // If stdout/stdin is interactive, prompt the user
        if (std.io.getStdIn().isTty() and std.io.getStdOut().isTty()) {
            selected_idx = try promptUserSelectRepo(parsed_search.value.items);
        } else {
            selected_idx = findBestMatchingRepo(parsed_search.value.items, resolved_repo_input);
            std.debug.print("      - Auto-selected repo: {s}\n", .{parsed_search.value.items[selected_idx].full_name});
        }

        repo_to_query = try allocator.dupe(u8, parsed_search.value.items[selected_idx].full_name);
        repo_to_query_allocated = true;
    } else {
        repo_to_query = try normalizeGitHubRepoPath(allocator, resolved_repo_input);
        repo_to_query_allocated = true;
    }

    var tag: ?[]const u8 = null;
    var clean_repo = repo_to_query;
    if (std.mem.indexOfScalar(u8, repo_to_query, '@')) |idx| {
        clean_repo = repo_to_query[0..idx];
        tag = repo_to_query[idx + 1 ..];
    }

    const api_url = if (tag) |t|
        try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/releases/tags/{s}", .{ clean_repo, t })
    else
        try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/releases/latest", .{clean_repo});
    defer allocator.free(api_url);

    std.debug.print("      - Fetching release info from GitHub API...\n", .{});

    const api_argv = [_][]const u8{ curl_cmd, "-fsSL", "--connect-timeout", "2", "--max-time", "10", "-H", "User-Agent: zzh-client", api_url };
    
    const json_bytes = try executeSubprocessAndCaptureOutput(allocator, &api_argv);
    defer allocator.free(json_bytes);

    const ReleaseResponse = struct {
        assets: []ReleaseAsset,
    };

    const parsed = try std.json.parseFromSlice(ReleaseResponse, allocator, json_bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const asset = try selectReleaseAsset(allocator, parsed.value.assets, target_os, target_arch);

    const rand = std.crypto.random.int(u64);
    var archive_name_buf: [64]u8 = undefined;
    const archive_name = try std.fmt.bufPrint(&archive_name_buf, "tmp_bin_{x}", .{rand});
    const archive_path = try std.fs.path.join(allocator, &.{ bin_dir, archive_name });
    defer {
        std.fs.deleteFileAbsolute(archive_path) catch {};
        allocator.free(archive_path);
    }

    var temp_extract_name_buf: [64]u8 = undefined;
    const temp_extract_name = try std.fmt.bufPrint(&temp_extract_name_buf, "tmp_extract_{x}", .{rand});
    const temp_extract_path = try std.fs.path.join(allocator, &.{ bin_dir, temp_extract_name });
    defer {
        std.fs.deleteTreeAbsolute(temp_extract_path) catch {};
        allocator.free(temp_extract_path);
    }

    std.debug.print("      - Downloading {s}...\n", .{asset.name});
    const download_argv = [_][]const u8{ curl_cmd, "-fsSL", "--connect-timeout", "2", "--max-time", "120", "-o", archive_path, asset.browser_download_url };
    try executeSubprocess(allocator, &download_argv);

    const is_tarball = std.mem.endsWith(u8, asset.browser_download_url, ".tar.gz") or std.mem.endsWith(u8, asset.browser_download_url, ".tgz") or std.mem.endsWith(u8, asset.browser_download_url, ".tar") or std.mem.endsWith(u8, asset.name, ".tar.gz") or std.mem.endsWith(u8, asset.name, ".tgz") or std.mem.endsWith(u8, asset.name, ".tar");

    if (is_tarball) {
        try ensureDirectoryPath(temp_extract_path);
        std.debug.print("      - Extracting archive...\n", .{});
        const tar_cmd = if (builtin.os.tag == .windows) "tar.exe" else "tar";
        const tar_argv = [_][]const u8{ tar_cmd, "-xf", archive_path, "-C", temp_extract_path };
        try executeSubprocess(allocator, &tar_argv);

        std.debug.print("      - Locating binary file '{s}'...\n", .{bin_name});
        const found_bin_path = try searchDirectoryForFile(allocator, temp_extract_path, bin_name);
        if (found_bin_path) |fbp| {
            defer allocator.free(fbp);
            try std.fs.copyFileAbsolute(fbp, dest_bin_path, .{});
            if (builtin.os.tag != .windows) {
                const chmod_argv = [_][]const u8{ "chmod", "+x", dest_bin_path };
                try executeSubprocess(allocator, &chmod_argv);
            }
            std.debug.print("      - Extracting and caching to ~/.zzh/bin/{s}...\n", .{bin_name});
        } else {
            return error.BinaryNotFoundInArchive;
        }
    } else {
        std.debug.print("      - Using plain binary...\n", .{});
        try std.fs.copyFileAbsolute(archive_path, dest_bin_path, .{});
        if (builtin.os.tag != .windows) {
            const chmod_argv = [_][]const u8{ "chmod", "+x", dest_bin_path };
            try executeSubprocess(allocator, &chmod_argv);
        }
    }
}

test "resolvePackage Test" {
    const testing = std.testing;

    const s1 = try normalizePackageIdentifier(testing.allocator, "zsh+git+https://github.com/user/zsh", true);
    defer testing.allocator.free(s1);
    try testing.expectEqualStrings("xxh-shell-zsh+git+https://github.com/user/zsh", s1);

    const s2 = try normalizePackageIdentifier(testing.allocator, "myplugin+git+https://github.com/user/myplugin", false);
    defer testing.allocator.free(s2);
    try testing.expectEqualStrings("xxh-plugin-myplugin+git+https://github.com/user/myplugin", s2);

    _ = fetchPackageVitals(testing.failing_allocator, "zsh", true) catch |err| {
        try testing.expect(err == error.OutOfMemory);
    };

    var failable = FailableAllocator.init(testing.allocator, 1);
    const failable_allocator = failable.getAllocator();
    _ = fetchPackageVitals(failable_allocator, "zsh", true) catch |err| {
        try testing.expect(err == error.OutOfMemory);
    };

    const p1 = try fetchPackageVitals(testing.allocator, "zsh", true);
    defer releasePackageVitals(testing.allocator, p1);
    try testing.expectEqualStrings("xxh-shell-zsh", p1.clean_name);
    try testing.expectEqualStrings("https://github.com/xxh/xxh-shell-zsh", p1.git_url);

    const p2 = try fetchPackageVitals(testing.allocator, "myplugin+git+https://github.com/user/myplugin", false);
    defer releasePackageVitals(testing.allocator, p2);
    try testing.expectEqualStrings("xxh-plugin-myplugin", p2.clean_name);
    try testing.expectEqualStrings("https://github.com/user/myplugin", p2.git_url);

    const p3 = try fetchPackageVitals(testing.allocator, "xxh-shell-zsh", true);
    defer releasePackageVitals(testing.allocator, p3);
    try testing.expectEqualStrings("xxh-shell-zsh", p3.clean_name);

    const p4 = try fetchPackageVitals(testing.allocator, "zsh+git+https://github.com/user/zsh", true);
    defer releasePackageVitals(testing.allocator, p4);
    try testing.expectEqualStrings("xxh-shell-zsh", p4.clean_name);
    try testing.expectEqualStrings("https://github.com/user/zsh", p4.git_url);

    const p5 = try fetchPackageVitals(testing.allocator, "xxh-shell-zsh+git+https://github.com/user/zsh", true);
    defer releasePackageVitals(testing.allocator, p5);
    try testing.expectEqualStrings("xxh-shell-zsh", p5.clean_name);

    const p6 = try fetchPackageVitals(testing.allocator, "myplugin", false);
    defer releasePackageVitals(testing.allocator, p6);
    try testing.expectEqualStrings("xxh-plugin-myplugin", p6.clean_name);
    try testing.expectEqualStrings("https://github.com/xxh/xxh-plugin-myplugin", p6.git_url);

    const p7 = try fetchPackageVitals(testing.allocator, "xxh-plugin-myplugin+git+https://github.com/user/myplugin", false);
    defer releasePackageVitals(testing.allocator, p7);
    try testing.expectEqualStrings("xxh-plugin-myplugin", p7.clean_name);

    const nu1 = try normalizePackageIdentifier(testing.allocator, "nushell", true);
    defer testing.allocator.free(nu1);
    try testing.expectEqualStrings("xxh-shell-nu", nu1);

    const nu2 = try normalizePackageIdentifier(testing.allocator, "nushell+git+https://github.com/msenturk/xxh-shell-nu", true);
    defer testing.allocator.free(nu2);
    try testing.expectEqualStrings("xxh-shell-nu+git+https://github.com/msenturk/xxh-shell-nu", nu2);

    const nu3 = try normalizePackageIdentifier(testing.allocator, "xxh-shell-nushell", true);
    defer testing.allocator.free(nu3);
    try testing.expectEqualStrings("xxh-shell-nu", nu3);

    const nu4 = try normalizePackageIdentifier(testing.allocator, "xxh-shell-nushell+git+https://github.com/msenturk/xxh-shell-nu", true);
    defer testing.allocator.free(nu4);
    try testing.expectEqualStrings("xxh-shell-nu+git+https://github.com/msenturk/xxh-shell-nu", nu4);

    const nu5 = try fetchPackageVitals(testing.allocator, "nushell", true);
    defer releasePackageVitals(testing.allocator, nu5);
    try testing.expectEqualStrings("xxh-shell-nu", nu5.clean_name);
    try testing.expectEqualStrings("https://github.com/msenturk/zzh/tree/main/shells/xxh-shell-nu", nu5.git_url);

    const bin1 = extractExecutableName("https://raw.githubusercontent.com/xxh/static/master/xxh-demo2.gif");
    try testing.expectEqualStrings("xxh-demo2.gif", bin1);

    const bin2 = extractExecutableName("https://github.com/BurntSushi/ripgrep/releases/download/14.1.0/ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz");
    try testing.expectEqualStrings("ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz", bin2);
}

const FailableAllocator = struct {
    allocator: std.mem.Allocator,
    alloc_count: usize = 0,
    fail_index: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, fail_index: usize) Self {
        return .{
            .allocator = allocator,
            .fail_index = fail_index,
        };
    }

    pub fn getAllocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *Self = @alignCast(@ptrCast(ctx));
        self.alloc_count += 1;
        if (self.alloc_count > self.fail_index) {
            return null;
        }
        return self.allocator.rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @alignCast(@ptrCast(ctx));
        return self.allocator.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *Self = @alignCast(@ptrCast(ctx));
        self.allocator.rawFree(buf, buf_align, ret_addr);
    }
};
