const std = @import("std");
const config = @import("config.zig");

fn pathCopyFileAbsolute(allocator: std.mem.Allocator, source_path: []const u8, dest_path: []const u8) !void {
    var temp_io = std.Io.Threaded.init(allocator, .{});
    defer temp_io.deinit();
    try std.Io.Dir.copyFileAbsolute(source_path, dest_path, temp_io.io(), .{});
}

var _temp_counter: u64 = 0;
fn getNextTempCounter() u64 {
    _temp_counter += 1;
    return _temp_counter;
}

fn pathDeleteFileAbsolute(allocator: std.mem.Allocator, path: []const u8) !void {
    var temp_io = std.Io.Threaded.init(allocator, .{});
    defer temp_io.deinit();
    try std.Io.Dir.deleteFileAbsolute(temp_io.io(), path);
}
fn pathDeleteTreeAbsolute(allocator: std.mem.Allocator, path: []const u8) !void {
    var temp_io = std.Io.Threaded.init(allocator, .{});
    defer temp_io.deinit();
    try std.Io.Dir.cwd().deleteTree(temp_io.io(), path);
}

fn pathExistsAbsolute(allocator: std.mem.Allocator, path: []const u8) bool {
    var temp_io = std.Io.Threaded.init(allocator, .{});
    defer temp_io.deinit();
    std.Io.Dir.accessAbsolute(temp_io.io(), path, .{}) catch return false;
    return true;
}
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

        const sub_dir = if (is_shell) "shells" else "plugins";
        
        var is_local = false;
        var local_pkg_path: []u8 = "";
        
        // Check if the package exists in the current working directory (e.g., during development)
        var temp_io = std.Io.Threaded.init(allocator, .{});
        defer temp_io.deinit();
        if (std.Io.Dir.cwd().realPathFileAlloc(temp_io.io(), ".", allocator)) |cwd_path| {
            defer allocator.free(cwd_path);
            if (std.fs.path.join(allocator, &.{ cwd_path, sub_dir, resolved_name })) |joined| {
                var threaded_io = std.Io.Threaded.init(allocator, .{});
                defer threaded_io.deinit();
                if (std.Io.Dir.cwd().access(threaded_io.io(), joined, .{})) |_| {
                    is_local = true;
                    local_pkg_path = joined;
                } else |_| {
                    allocator.free(joined);
                }
            } else |_| {}
        } else |_| {}

        const git_url = if (is_local) local_pkg_path else try std.fmt.allocPrint(allocator, "https://github.com/msenturk/zzh/releases/latest/download/{s}.tar.gz", .{resolved_name});

        return .{
            .name = resolved_name,
            .git_url = git_url,
            .clean_name = clean_name,
        };
    }
}

/// Recursively creates a local directory path if it does not already exist.
pub fn ensureDirectoryPath(allocator: std.mem.Allocator, target_directory: []const u8) !void {
    var char_idx: usize = 0;
    while (char_idx < target_directory.len) : (char_idx += 1) {
        if (target_directory[char_idx] == '/' or target_directory[char_idx] == '\\') {
            if (char_idx == 0) continue;
            // Ignore Windows drive letter prefixes (e.g. C:)
            if (char_idx == 2 and target_directory[1] == ':') continue;

            const sub_path = target_directory[0..char_idx];
            var threaded_io = std.Io.Threaded.init(allocator, .{});
            std.Io.Dir.createDirAbsolute(threaded_io.io(), sub_path, .default_dir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }
    }
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{});
    std.Io.Dir.createDirAbsolute(threaded_io.io(), target_directory, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

/// Spawns a subprocess and blocks until it exits. Returns error if command returns non-zero.
pub fn executeSubprocess(allocator: std.mem.Allocator, command_argv: []const []const u8) !void {
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    var child_process = try std.process.spawn(threaded_io.io(), .{
        .argv = command_argv,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const exit_status = try child_process.wait(threaded_io.io());
    switch (exit_status) {
        .exited => |code| {
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

    try ensureDirectoryPath(allocator, target_dir);

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

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    try std.Io.Dir.renameAbsolute(src_path, dest_path, threaded_io.io());

    const extracted_dir_path = try std.fs.path.join(allocator, &.{ target_dir, extracted_folder_name });
    defer allocator.free(extracted_dir_path);
    try pathDeleteTreeAbsolute(allocator, extracted_dir_path);
    try pathDeleteFileAbsolute(allocator, temp_tarball);
}

fn downloadAndExtractTarball(allocator: std.mem.Allocator, package_name: []const u8, download_url: []const u8, target_dir: []const u8) !void {
    std.debug.print("      - Downloading {s} (tarball)...\n", .{package_name});
    
    var temp_io = std.Io.Threaded.init(allocator, .{});
    defer temp_io.deinit();
    var client = std.http.Client{ .allocator = allocator, .io = temp_io.io() };
    defer client.deinit();

    var current_url = try allocator.dupe(u8, download_url);
    defer allocator.free(current_url);

    var header_buf: [16384]u8 = undefined;
    var redirects: usize = 0;
    
    var file_stream: std.Io.File = undefined;
    const temp_tarball = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{target_dir});
    defer allocator.free(temp_tarball);

    while (redirects < 5) : (redirects += 1) {
        const uri = try std.Uri.parse(current_url);
        var req = try client.request(.GET, uri, .{ 
            .headers = .{ .accept_encoding = .{ .override = "gzip, deflate" } },
            .redirect_behavior = .unhandled,
        });
        defer req.deinit();

        try req.sendBodiless();
        var response = try req.receiveHead(&header_buf);

        if (response.head.status == .found or response.head.status == .moved_permanently) {
            if (response.head.location) |loc| {
                allocator.free(current_url);
                current_url = try allocator.dupe(u8, loc);
                continue;
            } else {
                return error.HttpRedirectMissingLocation;
            }
        } else if (response.head.status == .ok) {
            file_stream = try std.Io.Dir.cwd().createFile(temp_io.io(), temp_tarball, .{});
            defer file_stream.close(temp_io.io());

            var transfer_buf: [4096]u8 = undefined;
            var req_reader = response.reader(&transfer_buf);
            var buf: [16384]u8 = undefined;
            while (true) {
                const amt = try req_reader.readSliceShort(&buf);
                if (amt == 0) break;
                try file_stream.writeStreamingAll(temp_io.io(), buf[0..amt]);
            }
            break;
        } else {
            std.debug.print("      - HTTP Error: {d}\n", .{response.head.status});
            return error.HttpDownloadFailed;
        }
    }

    if (redirects >= 5) return error.HttpTooManyRedirects;

    // Ensure the target_dir exists
    pathDeleteTreeAbsolute(allocator, target_dir) catch {};
    try ensureDirectoryPath(allocator, target_dir);

    // Extract tarball natively via `tar` CLI to perfectly preserve file permissions
    const tar_argv = [_][]const u8{ "tar", "-xzf", temp_tarball, "-C", target_dir, "--strip-components=1" };
    try executeSubprocess(allocator, &tar_argv);

    try pathDeleteFileAbsolute(allocator, temp_tarball);
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

        var temp_io1 = std.Io.Threaded.init(allocator, .{});
        defer temp_io1.deinit();
        var dir = std.Io.Dir.openDirAbsolute(temp_io1.io(), dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(temp_io1.io());

        var it = dir.iterate();
        while (try it.next(temp_io1.io())) |entry| {
            if (entry.kind == .directory) {
                const pkg_dir = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(pkg_dir);

                const git_dir = try std.fs.path.join(allocator, &.{ pkg_dir, ".git" });
                defer allocator.free(git_dir);

                if (!pathExistsAbsolute(allocator, git_dir)) continue;

                std.debug.print("Updating {s}...\n", .{entry.name});
                const argv = [_][]const u8{ "git", "pull", "--rebase" };
                var threaded_io = std.Io.Threaded.init(allocator, .{});
                defer threaded_io.deinit();
                var child = std.process.spawn(threaded_io.io(), .{
                    .argv = &argv,
                    .cwd = .{ .path = pkg_dir },
                    .stdout = .inherit,
                    .stderr = .inherit,
                }) catch {
                    std.debug.print("Failed to spawn git pull for {s}\n", .{entry.name});
                    continue;
                };
                _ = child.wait(threaded_io.io()) catch continue;
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
    try ensureDirectoryPath(allocator, bin_dir);

    const tmux_path = try std.fs.path.join(allocator, &.{ bin_dir, "tmux" });
    errdefer allocator.free(tmux_path);

    const exists = blk: {
        if (!pathExistsAbsolute(allocator, tmux_path)) {
            break :blk false;
        }
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
        pathDeleteFileAbsolute(allocator, archive_path) catch {};
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
    if (!pathExistsAbsolute(allocator, target_dir)) {
        exists = false;
    }

    if (exists and install_force) {
        pathDeleteTreeAbsolute(allocator, target_dir) catch {};
        exists = false;
    }

    if (!exists) {
        const parent_dir = try std.fs.path.join(allocator, &.{ base_dir, ".zzh", sub_dir });
        defer allocator.free(parent_dir);
        try ensureDirectoryPath(allocator, parent_dir);

        if (!is_shell and std.mem.startsWith(u8, pkg.clean_name, "xxh-plugin-nu-")) {
            const plugin_suffix = pkg.clean_name["xxh-plugin-nu-".len..];
            std.debug.print("      - Downloading official Nushell plugin '{s}'...\n", .{plugin_suffix});
            try fetchStaticallyCompiledNushellPlugin(allocator, plugin_suffix, target_dir);
        } else {
            if (std.mem.endsWith(u8, pkg.git_url, ".tar.gz")) {
                downloadAndExtractTarball(allocator, pkg.clean_name, pkg.git_url, target_dir) catch |err| {
                    if (err == error.HttpDownloadFailed) {
                        std.debug.print("      - Failed to download tarball. Trying official xxh fallback repository...\n", .{});
                        const fallback_url = try std.fmt.allocPrint(allocator, "https://github.com/xxh/{s}/releases/latest/download/{s}.tar.gz", .{ pkg.clean_name, pkg.clean_name });
                        defer allocator.free(fallback_url);
                        try downloadAndExtractTarball(allocator, pkg.clean_name, fallback_url, target_dir);
                    } else {
                        return err;
                    }
                };
            } else {
                std.debug.print("      - Downloading {s} (git)...\n", .{pkg.clean_name});
                const argv = [_][]const u8{ "git", "clone", "--depth=1", pkg.git_url, target_dir };
                executeSubprocess(allocator, &argv) catch |err| {
                    if (err == error.CommandFailed) {
                        std.debug.print("      - Failed to download from git. Trying official xxh fallback repository...\n", .{});
                        const fallback_url = try std.fmt.allocPrint(allocator, "https://github.com/xxh/{s}", .{pkg.clean_name});
                        defer allocator.free(fallback_url);
                        const fallback_argv = [_][]const u8{ "git", "clone", "--depth=1", fallback_url, target_dir };
                        try executeSubprocess(allocator, &fallback_argv);
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
/// Limits depth to 8 to avoid stack overflow on malicious/corrupt archives.
fn searchDirectoryForFile(allocator: std.mem.Allocator, dir_path: []const u8, target_name: []const u8, depth: u8) !?[]const u8 {
    if (depth > 8) return null;

    var temp_io2 = std.Io.Threaded.init(allocator, .{});
    defer temp_io2.deinit();
    var dir = std.Io.Dir.openDirAbsolute(temp_io2.io(), dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer dir.close(temp_io2.io());

    var it = dir.iterate();
    while (try it.next(temp_io2.io())) |entry| {
        if (entry.kind == .directory) {
            const sub_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(sub_path);
            if (try searchDirectoryForFile(allocator, sub_path, target_name, depth + 1)) |found| {
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

    try stdout.print("\nMultiple GitHub repositories found for search. Please select one:\n");
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
                try stdout.print("Input too long. Please try again.\n");
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

    try stdout.print("\nCompatible release assets found. Please select one to download:\n");
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
                try stdout.print("Input too long. Please try again.\n");
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

    var filtered = std.ArrayList(ReleaseAsset).empty;
    defer filtered.deinit(allocator);

    // Filter stage 1: OS and Architecture matching
    for (assets) |asset| {
        const name = asset.name;
        if (std.mem.indexOf(u8, name, target_os) != null or
            (std.mem.eql(u8, target_os, "linux") and std.mem.indexOf(u8, name, "unknown-linux") != null))
        {
            const has_arch_match = if (is_x64)
                (std.mem.indexOf(u8, name, "x86_64") != null or std.mem.indexOf(u8, name, "amd64") != null)
            else
                (std.mem.indexOf(u8, name, "aarch64") != null or std.mem.indexOf(u8, name, "arm64") != null);

            if (has_arch_match) {
                if (std.mem.endsWith(u8, name, ".deb") or std.mem.endsWith(u8, name, ".rpm") or std.mem.endsWith(u8, name, ".apk")) {
                    continue;
                }
                try filtered.append(allocator, asset);
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
                    try filtered.append(allocator, asset);
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

            if (false) {
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
    var temp_io = std.Io.Threaded.init(allocator, .{});
    defer temp_io.deinit();

    const result = try std.process.run(allocator, temp_io.io(), .{
        .argv = command_argv,
    });
    
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        return error.CommandFailed;
    }
    allocator.free(result.stderr);
    return result.stdout;
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
    try ensureDirectoryPath(allocator, bin_dir);

    const dest_bin_path = try std.fs.path.join(allocator, &.{ bin_dir, bin_name });
    defer allocator.free(dest_bin_path);

    const exists = blk: {
        if (!pathExistsAbsolute(allocator, dest_bin_path)) {
            break :blk false;
        }
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
        // Direct URLs bypass target_os/target_arch verification since the user has explicitly
        // specified the exact file/archive URL to download and provision.
        std.debug.print("      - Downloading direct file/archive from {s}...\n", .{resolved_repo_input});
        const is_archive = std.mem.endsWith(u8, resolved_repo_input, ".tar.gz") or
            std.mem.endsWith(u8, resolved_repo_input, ".tgz") or
            std.mem.endsWith(u8, resolved_repo_input, ".zip");

        if (is_archive) {
            const rand = getNextTempCounter();
            var archive_name_buf: [64]u8 = undefined;
            const archive_name = try std.fmt.bufPrint(&archive_name_buf, "tmp_bin_{x}", .{rand});
            const archive_path = try std.fs.path.join(allocator, &.{ bin_dir, archive_name });
            defer {
                pathDeleteFileAbsolute(allocator, archive_path) catch {};
                allocator.free(archive_path);
            }

            var temp_extract_name_buf: [64]u8 = undefined;
            const temp_extract_name = try std.fmt.bufPrint(&temp_extract_name_buf, "tmp_extract_{x}", .{rand});
            const temp_extract_path = try std.fs.path.join(allocator, &.{ bin_dir, temp_extract_name });
            defer {
                pathDeleteTreeAbsolute(allocator, temp_extract_path) catch {};
                allocator.free(temp_extract_path);
            }

            const download_argv = [_][]const u8{ curl_cmd, "-fsSL", "--connect-timeout", "2", "--max-time", "120", "-o", archive_path, resolved_repo_input };
            try executeSubprocess(allocator, &download_argv);

            try ensureDirectoryPath(allocator, temp_extract_path);

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
            const found_bin_path = try searchDirectoryForFile(allocator, temp_extract_path, search_name, 0);

            if (found_bin_path) |fbp| {
                defer allocator.free(fbp);
                try pathCopyFileAbsolute(allocator, fbp, dest_bin_path);
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
        !std.mem.startsWith(u8, resolved_repo_input, "https://"))
    {
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
                if (false) {
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

    const rand = getNextTempCounter();
    var archive_name_buf: [64]u8 = undefined;
    const archive_name = try std.fmt.bufPrint(&archive_name_buf, "tmp_bin_{x}", .{rand});
    const archive_path = try std.fs.path.join(allocator, &.{ bin_dir, archive_name });
    defer {
        pathDeleteFileAbsolute(allocator, archive_path) catch {};
        allocator.free(archive_path);
    }

    var temp_extract_name_buf: [64]u8 = undefined;
    const temp_extract_name = try std.fmt.bufPrint(&temp_extract_name_buf, "tmp_extract_{x}", .{rand});
    const temp_extract_path = try std.fs.path.join(allocator, &.{ bin_dir, temp_extract_name });
    defer {
        pathDeleteTreeAbsolute(allocator, temp_extract_path) catch {};
        allocator.free(temp_extract_path);
    }

    std.debug.print("      - Downloading {s}...\n", .{asset.name});
    const download_argv = [_][]const u8{ curl_cmd, "-fsSL", "--connect-timeout", "2", "--max-time", "120", "-o", archive_path, asset.browser_download_url };
    try executeSubprocess(allocator, &download_argv);

    const is_tarball = std.mem.endsWith(u8, asset.browser_download_url, ".tar.gz") or std.mem.endsWith(u8, asset.browser_download_url, ".tgz") or std.mem.endsWith(u8, asset.browser_download_url, ".tar") or std.mem.endsWith(u8, asset.name, ".tar.gz") or std.mem.endsWith(u8, asset.name, ".tgz") or std.mem.endsWith(u8, asset.name, ".tar");

    if (is_tarball) {
        try ensureDirectoryPath(allocator, temp_extract_path);
        std.debug.print("      - Extracting archive...\n", .{});
        const tar_cmd = if (builtin.os.tag == .windows) "tar.exe" else "tar";
        const tar_argv = [_][]const u8{ tar_cmd, "-xf", archive_path, "-C", temp_extract_path };
        try executeSubprocess(allocator, &tar_argv);

        std.debug.print("      - Locating binary file '{s}'...\n", .{bin_name});
        const found_bin_path = try searchDirectoryForFile(allocator, temp_extract_path, bin_name, 0);
        if (found_bin_path) |fbp| {
            defer allocator.free(fbp);
            try pathCopyFileAbsolute(allocator, fbp, dest_bin_path);
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
        try pathCopyFileAbsolute(allocator, archive_path, dest_bin_path);
        if (builtin.os.tag != .windows) {
            const chmod_argv = [_][]const u8{ "chmod", "+x", dest_bin_path };
            try executeSubprocess(allocator, &chmod_argv);
        }
    }
}

test "resolvePackage Test" {
    const testing = std.testing;

    const s1 = try normalizePackageIdentifier(std.testing.allocator, "zsh+git+https://github.com/user/zsh", true);
    defer std.testing.allocator.free(s1);
    try testing.expectEqualStrings("xxh-shell-zsh+git+https://github.com/user/zsh", s1);

    const s2 = try normalizePackageIdentifier(std.testing.allocator, "myplugin+git+https://github.com/user/myplugin", false);
    defer std.testing.allocator.free(s2);
    try testing.expectEqualStrings("xxh-plugin-myplugin+git+https://github.com/user/myplugin", s2);

    _ = fetchPackageVitals(testing.failing_allocator, "zsh", true) catch |err| {
        try testing.expect(err == error.OutOfMemory);
    };

    var failable = FailableAllocator.init(std.testing.allocator, 1);
    const failable_allocator = failable.getAllocator();
    _ = fetchPackageVitals(failable_allocator, "zsh", true) catch |err| {
        try testing.expect(err == error.OutOfMemory);
    };

    const p1 = try fetchPackageVitals(std.testing.allocator, "zsh", true);
    defer releasePackageVitals(std.testing.allocator, p1);
    try testing.expectEqualStrings("xxh-shell-zsh", p1.clean_name);
    try testing.expect(std.mem.indexOf(u8, p1.git_url, "xxh-shell-zsh") != null);

    const p2 = try fetchPackageVitals(std.testing.allocator, "myplugin+git+https://github.com/user/myplugin", false);
    defer releasePackageVitals(std.testing.allocator, p2);
    try testing.expectEqualStrings("xxh-plugin-myplugin", p2.clean_name);
    try testing.expectEqualStrings("https://github.com/user/myplugin", p2.git_url);

    const p3 = try fetchPackageVitals(std.testing.allocator, "xxh-shell-zsh", true);
    defer releasePackageVitals(std.testing.allocator, p3);
    try testing.expectEqualStrings("xxh-shell-zsh", p3.clean_name);

    const p4 = try fetchPackageVitals(std.testing.allocator, "zsh+git+https://github.com/user/zsh", true);
    defer releasePackageVitals(std.testing.allocator, p4);
    try testing.expectEqualStrings("xxh-shell-zsh", p4.clean_name);
    try testing.expectEqualStrings("https://github.com/user/zsh", p4.git_url);

    const p5 = try fetchPackageVitals(std.testing.allocator, "xxh-shell-zsh+git+https://github.com/user/zsh", true);
    defer releasePackageVitals(std.testing.allocator, p5);
    try testing.expectEqualStrings("xxh-shell-zsh", p5.clean_name);

    const p6 = try fetchPackageVitals(std.testing.allocator, "myplugin", false);
    defer releasePackageVitals(std.testing.allocator, p6);
    try testing.expectEqualStrings("xxh-plugin-myplugin", p6.clean_name);
    try testing.expect(std.mem.indexOf(u8, p6.git_url, "xxh-plugin-myplugin") != null);

    const p7 = try fetchPackageVitals(std.testing.allocator, "xxh-plugin-myplugin+git+https://github.com/user/myplugin", false);
    defer releasePackageVitals(std.testing.allocator, p7);
    try testing.expectEqualStrings("xxh-plugin-myplugin", p7.clean_name);

    const nu1 = try normalizePackageIdentifier(std.testing.allocator, "nushell", true);
    defer std.testing.allocator.free(nu1);
    try testing.expectEqualStrings("xxh-shell-nu", nu1);

    const nu2 = try normalizePackageIdentifier(std.testing.allocator, "nushell+git+https://github.com/msenturk/xxh-shell-nu", true);
    defer std.testing.allocator.free(nu2);
    try testing.expectEqualStrings("xxh-shell-nu+git+https://github.com/msenturk/xxh-shell-nu", nu2);

    const nu3 = try normalizePackageIdentifier(std.testing.allocator, "xxh-shell-nushell", true);
    defer std.testing.allocator.free(nu3);
    try testing.expectEqualStrings("xxh-shell-nu", nu3);

    const nu4 = try normalizePackageIdentifier(std.testing.allocator, "xxh-shell-nushell+git+https://github.com/msenturk/xxh-shell-nu", true);
    defer std.testing.allocator.free(nu4);
    try testing.expectEqualStrings("xxh-shell-nu+git+https://github.com/msenturk/xxh-shell-nu", nu4);

    const nu5 = try fetchPackageVitals(std.testing.allocator, "nushell", true);
    defer releasePackageVitals(std.testing.allocator, nu5);
    try testing.expectEqualStrings("xxh-shell-nu", nu5.clean_name);
    try testing.expect(std.mem.indexOf(u8, nu5.git_url, "xxh-shell-nu") != null);

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
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @alignCast(@ptrCast(ctx));
        self.alloc_count += 1;
        if (self.alloc_count > self.fail_index) {
            return null;
        }
        return self.allocator.rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @alignCast(@ptrCast(ctx));
        return self.allocator.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Self = @alignCast(@ptrCast(ctx));
        return self.allocator.rawRemap(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @alignCast(@ptrCast(ctx));
        self.allocator.rawFree(buf, buf_align, ret_addr);
    }
};
