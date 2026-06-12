const std = @import("std");
const config = @import("config.zig");

pub const ResolvedPackage = struct {
    name: []const u8,
    git_url: []const u8,
    clean_name: []const u8,
};

pub fn freeResolvedPackage(allocator: std.mem.Allocator, pkg: ResolvedPackage) void {
    allocator.free(pkg.name);
    allocator.free(pkg.git_url);
    allocator.free(pkg.clean_name);
}

pub noinline fn resolvePackageName(allocator: std.mem.Allocator, name: []const u8, is_shell: bool) ![]const u8 {
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
                }
            } else {
                return std.fmt.allocPrint(allocator, "xxh-plugin-{s}", .{name});
            }
        }
    }
    return allocator.dupe(u8, name);
}

pub noinline fn resolvePackage(allocator: std.mem.Allocator, raw_name: []const u8, is_shell: bool) !ResolvedPackage {
    const resolved_name = try resolvePackageName(allocator, raw_name, is_shell);
    errdefer allocator.free(resolved_name);

    if (std.mem.indexOf(u8, resolved_name, "+git+")) |idx| {
        const clean_name = try allocator.dupe(u8, resolved_name[0..idx]);
        const git_url = try allocator.dupe(u8, resolved_name[idx + 5 ..]);
        return .{
            .name = resolved_name,
            .git_url = git_url,
            .clean_name = clean_name,
        };
    } else {
        const clean_name = try allocator.dupe(u8, resolved_name);
        
        var git_url: []const u8 = undefined;
        if (std.mem.eql(u8, resolved_name, "xxh-shell-nu")) {
            git_url = try allocator.dupe(u8, "https://github.com/msenturk/zzh/tree/main/shells/xxh-shell-nu");
        } else {
            git_url = try std.fmt.allocPrint(allocator, "https://github.com/xxh/{s}", .{resolved_name});
        }
        
        return .{
            .name = resolved_name,
            .git_url = git_url,
            .clean_name = clean_name,
        };
    }
}

pub fn makeDirRecursive(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/' or path[i] == '\\') {
            if (i == 0) continue;
            if (i == 2 and path[1] == ':') continue;

            const sub_path = path[0..i];
            std.fs.makeDirAbsolute(sub_path) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }
    }
    std.fs.makeDirAbsolute(path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

pub fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
}

fn downloadOfficialNuPlugin(allocator: std.mem.Allocator, plugin_name: []const u8, target_dir: []const u8) !void {
    const NU_VERSION = "0.94.2";
    const tarball_name = "nu_plugin_download.tar.gz";

    const temp_tarball = try std.fs.path.join(allocator, &.{ target_dir, tarball_name });
    defer allocator.free(temp_tarball);

    // Create target directory first
    try makeDirRecursive(allocator, target_dir);

    // 1. Download Nushell tarball using curl
    const download_url = try std.fmt.allocPrint(allocator, "https://github.com/nushell/nushell/releases/download/{s}/nu-{s}-x86_64-unknown-linux-musl.tar.gz", .{ NU_VERSION, NU_VERSION });
    defer allocator.free(download_url);

    const curl_argv = [_][]const u8{ "curl", "-L", "-o", temp_tarball, download_url };
    try runCommand(allocator, &curl_argv);

    // 2. Extract using tar
    const tar_argv = [_][]const u8{ "tar", "-xzf", temp_tarball, "-C", target_dir };
    try runCommand(allocator, &tar_argv);

    // 3. Move the plugin binary to the root of target_dir
    const extracted_folder_name = try std.fmt.allocPrint(allocator, "nu-{s}-x86_64-unknown-linux-musl", .{NU_VERSION});
    defer allocator.free(extracted_folder_name);

    const bin_filename = try std.fmt.allocPrint(allocator, "nu_plugin_{s}", .{plugin_name});
    defer allocator.free(bin_filename);

    const src_path = try std.fs.path.join(allocator, &.{ target_dir, extracted_folder_name, bin_filename });
    defer allocator.free(src_path);

    const dest_path = try std.fs.path.join(allocator, &.{ target_dir, bin_filename });
    defer allocator.free(dest_path);

    // Rename (move) file
    try std.fs.renameAbsolute(src_path, dest_path);

    // 4. Clean up the extracted directory and temporary tarball
    const extracted_dir_path = try std.fs.path.join(allocator, &.{ target_dir, extracted_folder_name });
    defer allocator.free(extracted_dir_path);
    try std.fs.deleteTreeAbsolute(extracted_dir_path);
    try std.fs.deleteFileAbsolute(temp_tarball);
}

fn downloadFromTree(allocator: std.mem.Allocator, name: []const u8, git_url: []const u8, target_dir: []const u8) !void {
    if (std.mem.indexOf(u8, git_url, "/tree/")) |tree_idx| {
        const repo_url = git_url[0..tree_idx];
        const rest = git_url[tree_idx + 6 ..];
        if (std.mem.indexOf(u8, rest, "/")) |slash_idx| {
            const branch = rest[0..slash_idx];
            const subfolder = rest[slash_idx + 1 ..];

            std.debug.print("Downloading {s} from {s} (branch: {s}, folder: {s})...\n", .{ name, repo_url, branch, subfolder });
            
            const tmp_target_dir = try std.fmt.allocPrint(allocator, "{s}_tmp", .{target_dir});
            defer allocator.free(tmp_target_dir);

            // 1. Partial clone
            const argv1 = [_][]const u8{ "git", "clone", "--no-checkout", "--depth=1", "--filter=tree:0", "-b", branch, repo_url, tmp_target_dir };
            try runCommand(allocator, &argv1);

            // 2. Sparse checkout
            const argv2 = [_][]const u8{ "git", "-C", tmp_target_dir, "sparse-checkout", "set", "--no-cone", subfolder };
            try runCommand(allocator, &argv2);

            // 3. Checkout
            const argv3 = [_][]const u8{ "git", "-C", tmp_target_dir, "checkout" };
            try runCommand(allocator, &argv3);

            // 4. Move subfolder to actual target_dir
            const extracted_folder = try std.fs.path.join(allocator, &.{ tmp_target_dir, subfolder });
            defer allocator.free(extracted_folder);

            try std.fs.renameAbsolute(extracted_folder, target_dir);

            // 5. Cleanup
            std.fs.deleteTreeAbsolute(tmp_target_dir) catch {};
        } else {
            std.debug.print("Invalid tree URL format: {s}\n", .{git_url});
            return error.InvalidUrl;
        }
    } else {
        return error.InvalidUrl;
    }
}

pub fn updatePackages(allocator: std.mem.Allocator, local_xxh_home: ?[]const u8) !void {
    var base_dir: []const u8 = undefined;
    if (local_xxh_home) |lh| {
        base_dir = try config.resolvePath(allocator, lh);
    } else {
        const home = config.getHomeDir(allocator) orelse return error.HomeDirNotFound;
        defer allocator.free(home);
        base_dir = try std.fs.path.join(allocator, &.{ home, ".zzh" });
    }
    defer allocator.free(base_dir);

    const sub_dirs = [_][]const u8{ "shells", "plugins" };
    for (sub_dirs) |sub_dir| {
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

                std.fs.accessAbsolute(git_dir, .{}) catch continue; // skip if not a git repo

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

/// Downloads a portable static `tmux` binary and installs it to `~/.zzh/bin/tmux`.
/// Currently uses `nelsonenzo/tmux-appimage` for Linux x86_64.
/// On other platforms, prints a skip message.
pub fn downloadTmux(allocator: std.mem.Allocator, install_force: bool, local_xxh_home: ?[]const u8) ![]const u8 {
    var base_dir: []const u8 = undefined;
    if (local_xxh_home) |lh| {
        base_dir = try config.resolvePath(allocator, lh);
    } else {
        const home = config.getHomeDir(allocator) orelse return error.HomeDirNotFound;
        defer allocator.free(home);
        base_dir = try std.fs.path.join(allocator, &.{ home, ".zzh" });
    }
    defer allocator.free(base_dir);

    const bin_dir = try std.fs.path.join(allocator, &.{ base_dir, "bin" });
    errdefer allocator.free(bin_dir);
    try makeDirRecursive(allocator, bin_dir);

    const tmux_path = try std.fs.path.join(allocator, &.{ bin_dir, "tmux" });
    errdefer allocator.free(tmux_path);

    // Check already installed
    const exists = blk: {
        std.fs.accessAbsolute(tmux_path, .{}) catch { break :blk false; };
        break :blk true;
    };

    if (exists and !install_force) {
        std.debug.print("tmux already installed at {s}\n", .{tmux_path});
        return tmux_path;
    }

    // AppImage is only for Linux x86_64 without musl; for musl/arm we try a different source
    const builtin = @import("builtin");
    if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        const TMUX_VERSION = "3.5a";
        const url = "https://github.com/nelsonenzo/tmux-appimage/releases/download/" ++ TMUX_VERSION ++ "/tmux.appimage";
        std.debug.print("Downloading portable tmux {s} from {s}...\n", .{ TMUX_VERSION, url });
        const curl_argv = [_][]const u8{ "curl", "-fsSL", "-o", tmux_path, url };
        try runCommand(allocator, &curl_argv);
        // Make executable
        const chmod_argv = [_][]const u8{ "chmod", "+x", tmux_path };
        try runCommand(allocator, &chmod_argv);
        std.debug.print("tmux installed to {s}\n", .{tmux_path});
    } else {
        std.debug.print("Automatic tmux download is only supported for Linux x86_64.\n", .{});
        std.debug.print("Please install tmux manually and copy the binary to {s}\n", .{tmux_path});
    }

    return tmux_path;
}

pub fn downloadAndCachePackage(allocator: std.mem.Allocator, pkg: ResolvedPackage, is_shell: bool, install_force: bool, local_xxh_home: ?[]const u8) ![]const u8 {
    var base_dir: []const u8 = undefined;
    if (local_xxh_home) |lh| {
        base_dir = try config.resolvePath(allocator, lh);
    } else {
        const home = config.getHomeDir(allocator) orelse return error.HomeDirNotFound;
        defer allocator.free(home);
        base_dir = try std.fs.path.join(allocator, &.{ home, ".zzh" });
    }
    defer allocator.free(base_dir);

    const sub_dir = if (is_shell) "shells" else "plugins";
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
        try makeDirRecursive(allocator, parent_dir);

        if (!is_shell and std.mem.startsWith(u8, pkg.clean_name, "xxh-plugin-nu-")) {
            const plugin_suffix = pkg.clean_name["xxh-plugin-nu-".len..];
            std.debug.print("Downloading official Nushell plugin '{s}' from Nushell releases...\n", .{plugin_suffix});
            try downloadOfficialNuPlugin(allocator, plugin_suffix, target_dir);
        } else {
            if (std.mem.indexOf(u8, pkg.git_url, "/tree/") != null) {
                try downloadFromTree(allocator, pkg.clean_name, pkg.git_url, target_dir);
            } else {
                // Standard git clone
                std.debug.print("Downloading {s} from {s}...\n", .{ pkg.clean_name, pkg.git_url });
                const argv = [_][]const u8{ "git", "clone", "--depth=1", pkg.git_url, target_dir };
                runCommand(allocator, &argv) catch |err| {
                    if (err == error.CommandFailed) {
                        std.debug.print("Failed to download from {s}. Trying fallback repository...\n", .{pkg.git_url});
                        const fallback_url = try std.fmt.allocPrint(allocator, "https://github.com/msenturk/zzh/tree/main/{s}/{s}", .{sub_dir, pkg.clean_name});
                        defer allocator.free(fallback_url);
                        try downloadFromTree(allocator, pkg.clean_name, fallback_url, target_dir);
                    } else {
                        return err;
                    }
                };
            }
        }
    }

    return target_dir;
}

test "resolvePackage Test" {
    const testing = std.testing;

    // Direct tests for resolvePackageName branches (uncovered lines 23 and 35)
    const s1 = try resolvePackageName(testing.allocator, "zsh+git+https://github.com/user/zsh", true);
    defer testing.allocator.free(s1);
    try testing.expectEqualStrings("xxh-shell-zsh+git+https://github.com/user/zsh", s1);

    const s2 = try resolvePackageName(testing.allocator, "myplugin+git+https://github.com/user/myplugin", false);
    defer testing.allocator.free(s2);
    try testing.expectEqualStrings("xxh-plugin-myplugin+git+https://github.com/user/myplugin", s2);

    // OOM path test to cover errdefer allocator.free(resolved_name)
    _ = resolvePackage(testing.failing_allocator, "zsh", true) catch |err| {
        try testing.expect(err == error.OutOfMemory);
    };

    // Failable allocator to cover errdefer allocator.free(resolved_name) when subsequent allocation fails
    var failable = FailableAllocator.init(testing.allocator, 1);
    const failable_allocator = failable.getAllocator();
    _ = resolvePackage(failable_allocator, "zsh", true) catch |err| {
        try testing.expect(err == error.OutOfMemory);
    };

    // Case 1: Short shell name (adds prefix, default url)
    const p1 = try resolvePackage(testing.allocator, "zsh", true);
    defer freeResolvedPackage(testing.allocator, p1);
    try testing.expectEqualStrings("xxh-shell-zsh", p1.clean_name);
    try testing.expectEqualStrings("https://github.com/xxh/xxh-shell-zsh", p1.git_url);

    // Case 2: Short plugin name with +git+ url (adds prefix, clean name from +git+)
    const p2 = try resolvePackage(testing.allocator, "myplugin+git+https://github.com/user/myplugin", false);
    defer freeResolvedPackage(testing.allocator, p2);
    try testing.expectEqualStrings("xxh-plugin-myplugin", p2.clean_name);
    try testing.expectEqualStrings("https://github.com/user/myplugin", p2.git_url);

    // Case 3: Shell name already has prefix (no-op prefix, default url)
    const p3 = try resolvePackage(testing.allocator, "xxh-shell-zsh", true);
    defer freeResolvedPackage(testing.allocator, p3);
    try testing.expectEqualStrings("xxh-shell-zsh", p3.clean_name);

    // Case 4: Shell name with short form +git+ url (adds prefix, clean name from +git+)
    const p4 = try resolvePackage(testing.allocator, "zsh+git+https://github.com/user/zsh", true);
    defer freeResolvedPackage(testing.allocator, p4);
    try testing.expectEqualStrings("xxh-shell-zsh", p4.clean_name);
    try testing.expectEqualStrings("https://github.com/user/zsh", p4.git_url);

    // Case 5: Shell name with prefix +git+ url (no-op prefix, clean name from +git+)
    const p5 = try resolvePackage(testing.allocator, "xxh-shell-zsh+git+https://github.com/user/zsh", true);
    defer freeResolvedPackage(testing.allocator, p5);
    try testing.expectEqualStrings("xxh-shell-zsh", p5.clean_name);

    // Case 6: Plugin name without prefix (adds prefix, default url)
    const p6 = try resolvePackage(testing.allocator, "myplugin", false);
    defer freeResolvedPackage(testing.allocator, p6);
    try testing.expectEqualStrings("xxh-plugin-myplugin", p6.clean_name);
    try testing.expectEqualStrings("https://github.com/xxh/xxh-plugin-myplugin", p6.git_url);

    // Case 7: Plugin name with prefix +git+ url (no-op prefix, clean name from +git+)
    const p7 = try resolvePackage(testing.allocator, "xxh-plugin-myplugin+git+https://github.com/user/myplugin", false);
    defer freeResolvedPackage(testing.allocator, p7);
    try testing.expectEqualStrings("xxh-plugin-myplugin", p7.clean_name);

    // Case 8: Nushell resolution tests
    const nu1 = try resolvePackageName(testing.allocator, "nushell", true);
    defer testing.allocator.free(nu1);
    try testing.expectEqualStrings("xxh-shell-nu", nu1);

    const nu2 = try resolvePackageName(testing.allocator, "nushell+git+https://github.com/msenturk/xxh-shell-nu", true);
    defer testing.allocator.free(nu2);
    try testing.expectEqualStrings("xxh-shell-nu+git+https://github.com/msenturk/xxh-shell-nu", nu2);

    const nu3 = try resolvePackageName(testing.allocator, "xxh-shell-nushell", true);
    defer testing.allocator.free(nu3);
    try testing.expectEqualStrings("xxh-shell-nu", nu3);

    const nu4 = try resolvePackageName(testing.allocator, "xxh-shell-nushell+git+https://github.com/msenturk/xxh-shell-nu", true);
    defer testing.allocator.free(nu4);
    try testing.expectEqualStrings("xxh-shell-nu+git+https://github.com/msenturk/xxh-shell-nu", nu4);

    const nu5 = try resolvePackage(testing.allocator, "nushell", true);
    defer freeResolvedPackage(testing.allocator, nu5);
    try testing.expectEqualStrings("xxh-shell-nu", nu5.clean_name);
    try testing.expectEqualStrings("https://github.com/msenturk/zzh/tree/main/shells/xxh-shell-nu", nu5.git_url);
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
