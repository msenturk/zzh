const std = @import("std");
const builtin = @import("builtin");
const package = @import("package.zig");
const config = @import("config.zig");

fn dirExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

pub fn copyDirRecursive(allocator: std.mem.Allocator, src_dir_path: []const u8, dest_dir_path: []const u8) !void {
    var src_dir = try std.fs.openDirAbsolute(src_dir_path, .{ .iterate = true });
    defer src_dir.close();

    std.fs.makeDirAbsolute(dest_dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        const src_child = try std.fs.path.join(allocator, &.{ src_dir_path, entry.name });
        defer allocator.free(src_child);
        const dest_child = try std.fs.path.join(allocator, &.{ dest_dir_path, entry.name });
        defer allocator.free(dest_child);

        switch (entry.kind) {
            .directory => {
                try copyDirRecursive(allocator, src_child, dest_child);
            },
            .file => {
                try std.fs.copyFileAbsolute(src_child, dest_child, .{});
            },
            else => {},
        }
    }
}

pub const BundleResult = struct {
    temp_build_dir: []const u8,
    archive_path: []const u8,
};

fn runBuildScriptIfPresent(allocator: std.mem.Allocator, pkg_path: []const u8) !void {
    const build_sh_path = try std.fs.path.join(allocator, &.{ pkg_path, "build.sh" });
    defer allocator.free(build_sh_path);

    if (dirExists(build_sh_path)) {
        const build_dir = try std.fs.path.join(allocator, &.{ pkg_path, "build" });
        defer allocator.free(build_dir);

        if (!dirExists(build_dir)) {
            std.debug.print("Running build.sh in {s}...\n", .{pkg_path});
            const argv = if (builtin.os.tag == .windows)
                &[_][]const u8{ "bash", "build.sh" }
            else
                &[_][]const u8{ "./build.sh" };

            var child = std.process.Child.init(argv, allocator);
            child.cwd = pkg_path;
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;
            try child.spawn();
            const term = try child.wait();
            switch (term) {
                .Exited => |code| {
                    if (code != 0) return error.BuildScriptFailed;
                },
                else => return error.BuildScriptFailed,
            }
        }
    }
}

pub fn buildPayload(allocator: std.mem.Allocator, shell_path: []const u8, plugin_paths: []const []const u8) !BundleResult {
    const home = config.getHomeDir(allocator) orelse return error.HomeDirNotFound;
    defer allocator.free(home);

    // Create unique random names for temp dir and archive
    const random_val = std.crypto.random.int(u64);
    var name_buf: [64]u8 = undefined;
    const temp_name = try std.fmt.bufPrint(&name_buf, "xxh-build-{x}", .{random_val});

    const temp_build_dir = try std.fs.path.join(allocator, &.{ home, ".zzh", "tmp", temp_name });
    errdefer allocator.free(temp_build_dir);

    var archive_buf: [64]u8 = undefined;
    const archive_name = try std.fmt.bufPrint(&archive_buf, "payload-{x}.tar.gz", .{random_val});
    const archive_path = try std.fs.path.join(allocator, &.{ home, ".zzh", "tmp", archive_name });
    errdefer allocator.free(archive_path);

    // Make sure tmp directory exists
    const tmp_parent = try std.fs.path.join(allocator, &.{ home, ".zzh", "tmp" });
    defer allocator.free(tmp_parent);
    try package.makeDirRecursive(allocator, tmp_parent);

    // Ensure build is present for shell
    try runBuildScriptIfPresent(allocator, shell_path);

    const shell_pkg_name = std.fs.path.basename(shell_path);

    // Copy shell files to .zzh/shells/xxh-shell-<name>/[build]
    const shell_src_build = try std.fs.path.join(allocator, &.{ shell_path, "build" });
    defer allocator.free(shell_src_build);
    const has_build = dirExists(shell_src_build);
    const shell_src = if (has_build) shell_src_build else shell_path;

    const dest_shell_parent = try std.fs.path.join(allocator, &.{ temp_build_dir, ".zzh", "shells", shell_pkg_name });
    defer allocator.free(dest_shell_parent);

    const dest_shell_dir = if (has_build)
        try std.fs.path.join(allocator, &.{ dest_shell_parent, "build" })
    else
        try allocator.dupe(u8, dest_shell_parent);
    defer allocator.free(dest_shell_dir);

    try package.makeDirRecursive(allocator, dest_shell_dir);

    std.debug.print("Copying shell from {s} to {s}...\n", .{ shell_src, dest_shell_dir });
    try copyDirRecursive(allocator, shell_src, dest_shell_dir);

    // Copy plugins if any
    for (plugin_paths) |plugin_path| {
        // Ensure build is present for plugin
        try runBuildScriptIfPresent(allocator, plugin_path);

        const plugin_name = std.fs.path.basename(plugin_path);

        const plugin_src_build = try std.fs.path.join(allocator, &.{ plugin_path, "build" });
        defer allocator.free(plugin_src_build);
        const plugin_has_build = dirExists(plugin_src_build);
        const plugin_src = if (plugin_has_build) plugin_src_build else plugin_path;

        const dest_plugin_parent = try std.fs.path.join(allocator, &.{ temp_build_dir, ".zzh", "plugins", plugin_name });
        defer allocator.free(dest_plugin_parent);

        const dest_plugin_dir = if (plugin_has_build)
            try std.fs.path.join(allocator, &.{ dest_plugin_parent, "build" })
        else
            try allocator.dupe(u8, dest_plugin_parent);
        defer allocator.free(dest_plugin_dir);

        try package.makeDirRecursive(allocator, dest_plugin_dir);

        std.debug.print("Copying plugin from {s} to {s}...\n", .{ plugin_src, dest_plugin_dir });
        try copyDirRecursive(allocator, plugin_src, dest_plugin_dir);
    }

    // Run system tar command with gzip compression
    std.debug.print("Creating compressed payload archive {s}...\n", .{ archive_path });
    const argv = [_][]const u8{ "tar", "-czf", archive_path, "-C", temp_build_dir, "." };
    try package.runCommand(allocator, &argv);

    return .{
        .temp_build_dir = temp_build_dir,
        .archive_path = archive_path,
    };
}

pub fn cleanupBundle(allocator: std.mem.Allocator, result: BundleResult) void {
    std.fs.deleteTreeAbsolute(result.temp_build_dir) catch {};
    std.fs.deleteTreeAbsolute(result.archive_path) catch {};
    allocator.free(result.temp_build_dir);
    allocator.free(result.archive_path);
}

test "Payload Bundler Test" {
    const testing = std.testing;

    // Create a dummy shell directory
    var tmp_shell_dir = testing.tmpDir(.{});
    defer tmp_shell_dir.cleanup();
    try tmp_shell_dir.dir.writeFile(.{ .sub_path = "entrypoint.sh", .data = "#!/bin/sh\necho shell" });
    try tmp_shell_dir.dir.makeDir("bin");
    try tmp_shell_dir.dir.writeFile(.{ .sub_path = "bin/zsh", .data = "zsh binary" });

    // Create a dummy plugin directory
    var tmp_plugin_dir = testing.tmpDir(.{});
    defer tmp_plugin_dir.cleanup();
    try tmp_plugin_dir.dir.writeFile(.{ .sub_path = "init.sh", .data = "#!/bin/sh\necho plugin" });

    var shell_buf: [1024]u8 = undefined;
    const shell_path = try tmp_shell_dir.dir.realpath(".", &shell_buf);

    var plugin_buf: [1024]u8 = undefined;
    const plugin_path = try tmp_plugin_dir.dir.realpath(".", &plugin_buf);

    const plugin_paths = [_][]const u8{plugin_path};

    const result = try buildPayload(testing.allocator, shell_path, &plugin_paths);
    defer cleanupBundle(testing.allocator, result);

    // Verify temp_build_dir contains copy of shell and plugins
    try testing.expect(dirExists(result.temp_build_dir));
    try testing.expect(dirExists(result.archive_path));

    const shell_pkg_name = std.fs.path.basename(shell_path);
    const check_entrypoint = try std.fmt.allocPrint(testing.allocator, "{s}/.zzh/shells/{s}/entrypoint.sh", .{ result.temp_build_dir, shell_pkg_name });
    defer testing.allocator.free(check_entrypoint);
    try testing.expect(dirExists(check_entrypoint));
}

test "Payload Bundler Test - with build subdirectories and build.sh" {
    const testing = std.testing;

    // Create a dummy shell directory with build/ directory already present
    var tmp_shell_dir = testing.tmpDir(.{});
    defer tmp_shell_dir.cleanup();
    try tmp_shell_dir.dir.makeDir("build");
    try tmp_shell_dir.dir.writeFile(.{ .sub_path = "build/entrypoint.sh", .data = "#!/bin/sh\necho shell" });

    // Create a dummy plugin directory with build.sh
    var tmp_plugin_dir = testing.tmpDir(.{});
    defer tmp_plugin_dir.cleanup();
    
    // Create build.sh that exits 0
    try tmp_plugin_dir.dir.writeFile(.{ .sub_path = "build.sh", .data = "#!/bin/sh\nmkdir -p build && echo 'echo plugin' > build/init.sh\n" });
    
    var shell_buf: [1024]u8 = undefined;
    const shell_path = try tmp_shell_dir.dir.realpath(".", &shell_buf);

    var plugin_buf: [1024]u8 = undefined;
    const plugin_path = try tmp_plugin_dir.dir.realpath(".", &plugin_buf);

    // Make build.sh executable on Linux/macOS
    if (builtin.os.tag != .windows) {
        var path_b: [1024]u8 = undefined;
        const build_sh_real_path = try tmp_plugin_dir.dir.realpath("build.sh", &path_b);
        const argv = [_][]const u8{ "chmod", "+x", build_sh_real_path };
        try package.runCommand(testing.allocator, &argv);
    }

    const plugin_paths = [_][]const u8{plugin_path};

    const result = try buildPayload(testing.allocator, shell_path, &plugin_paths);
    defer cleanupBundle(testing.allocator, result);

    try testing.expect(dirExists(result.temp_build_dir));
    try testing.expect(dirExists(result.archive_path));

    const shell_pkg_name = std.fs.path.basename(shell_path);
    const check_entrypoint = try std.fmt.allocPrint(testing.allocator, "{s}/.zzh/shells/{s}/build/entrypoint.sh", .{ result.temp_build_dir, shell_pkg_name });
    defer testing.allocator.free(check_entrypoint);
    try testing.expect(dirExists(check_entrypoint));

    const plugin_name = std.fs.path.basename(plugin_path);
    const check_init = try std.fmt.allocPrint(testing.allocator, "{s}/.zzh/plugins/{s}/build/init.sh", .{ result.temp_build_dir, plugin_name });
    defer testing.allocator.free(check_init);
    try testing.expect(dirExists(check_init));
}

test "Payload Bundler Test - build script failure and errdefer" {
    const testing = std.testing;


    // Create a dummy shell directory
    var tmp_shell_dir = testing.tmpDir(.{});
    defer tmp_shell_dir.cleanup();
    try tmp_shell_dir.dir.writeFile(.{ .sub_path = "entrypoint.sh", .data = "#!/bin/sh\necho shell" });

    // Create a dummy plugin directory with a failing build.sh
    var tmp_plugin_dir = testing.tmpDir(.{});
    defer tmp_plugin_dir.cleanup();

    try tmp_plugin_dir.dir.writeFile(.{ .sub_path = "build.sh", .data = "#!/bin/sh\nexit 1\n" });

    if (builtin.os.tag != .windows) {
        var path_b: [1024]u8 = undefined;
        const build_sh_real_path = try tmp_plugin_dir.dir.realpath("build.sh", &path_b);
        const argv = [_][]const u8{ "chmod", "+x", build_sh_real_path };
        try package.runCommand(testing.allocator, &argv);
    }

    var shell_buf: [1024]u8 = undefined;
    const shell_path = try tmp_shell_dir.dir.realpath(".", &shell_buf);

    var plugin_buf: [1024]u8 = undefined;
    const plugin_path = try tmp_plugin_dir.dir.realpath(".", &plugin_buf);

    const plugin_paths = [_][]const u8{plugin_path};

    const res = buildPayload(testing.allocator, shell_path, &plugin_paths);
    try testing.expectError(error.BuildScriptFailed, res);
}
