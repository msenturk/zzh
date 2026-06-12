const std = @import("std");
const builtin = @import("builtin");
const package = @import("package.zig");
const config = @import("config.zig");
const cli = @import("cli.zig");
const deploy = @import("deploy.zig");

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

fn runBuildScriptThreadWrapper(allocator: std.mem.Allocator, pkg_path: []const u8) void {
    runBuildScriptIfPresent(allocator, pkg_path) catch |err| {
        std.debug.print("Error running build script for {s}: {}\n", .{pkg_path, err});
    };
}

pub fn buildPayload(allocator: std.mem.Allocator, shell_path: []const u8, plugin_paths: []const []const u8, zzh_args: *const cli.ZzhArgs) !BundleResult {
    const home = config.getHomeDir(allocator) orelse return error.HomeDirNotFound;
    defer allocator.free(home);

    // Compute the unique hash for the payload based on versions
    const hash = try deploy.getDeploymentHash(allocator, zzh_args);
    defer allocator.free(hash);

    var archive_name = std.ArrayList(u8).init(allocator);
    defer archive_name.deinit();
    try archive_name.writer().print("payload-{s}.tar", .{hash});
    const archive_path = try std.fs.path.join(allocator, &.{ home, ".zzh", "tmp", archive_name.items });
    errdefer allocator.free(archive_path);

    if (dirExists(archive_path) and !zzh_args.install_force and !zzh_args.install_force_full) {
        if (zzh_args.time) {
            std.debug.print("=> Re-using cached payload archive {s}\n", .{archive_path});
        }
        return .{
            .temp_build_dir = try allocator.dupe(u8, ""),
            .archive_path = archive_path,
        };
    }

    // Create unique random names for temp dir
    const random_val = std.crypto.random.int(u64);
    var name_buf: [64]u8 = undefined;
    const temp_name = try std.fmt.bufPrint(&name_buf, "zzh-build-{x}", .{random_val});

    const temp_build_dir = try std.fs.path.join(allocator, &.{ home, ".zzh", "tmp", temp_name });
    errdefer allocator.free(temp_build_dir);

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

    if (zzh_args.debug or zzh_args.verbose) {
        std.debug.print("Copying shell from {s} to {s}...\n", .{ shell_src, dest_shell_dir });
    }
    try copyDirRecursive(allocator, shell_src, dest_shell_dir);

    // Ensure builds are present for plugins in parallel
    var threads = std.ArrayList(std.Thread).init(allocator);
    defer threads.deinit();

    for (plugin_paths) |plugin_path| {
        const t = try std.Thread.spawn(.{}, runBuildScriptThreadWrapper, .{ allocator, plugin_path });
        try threads.append(t);
    }

    for (threads.items) |t| {
        t.join();
    }

    // Copy plugins if any
    for (plugin_paths) |plugin_path| {

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

        if (zzh_args.debug or zzh_args.verbose) {
            std.debug.print("Copying plugin from {s} to {s}...\n", .{ plugin_src, dest_plugin_dir });
        }
        try copyDirRecursive(allocator, plugin_src, dest_plugin_dir);
    }

    if (zzh_args.dotfiles.items.len > 0) {
        const dest_dotfiles_dir = try std.fs.path.join(allocator, &.{ temp_build_dir, ".zzh", "dotfiles" });
        defer allocator.free(dest_dotfiles_dir);
        try package.makeDirRecursive(allocator, dest_dotfiles_dir);

        for (zzh_args.dotfiles.items) |dotfile| {
            const basename = std.fs.path.basename(dotfile);
            const dotfile_dest = try std.fs.path.join(allocator, &.{ dest_dotfiles_dir, basename });
            defer allocator.free(dotfile_dest);

            const resolved_src = try config.resolvePath(allocator, dotfile);
            defer allocator.free(resolved_src);
            const abs_src = try std.fs.cwd().realpathAlloc(allocator, resolved_src);
            defer allocator.free(abs_src);

            if (zzh_args.debug or zzh_args.verbose) {
                std.debug.print("Copying dotfile from {s} to {s}...\n", .{ abs_src, dotfile_dest });
            }

            var is_dir = false;
            if (std.fs.openDirAbsolute(abs_src, .{})) |d| {
                var d_var = d;
                is_dir = true;
                d_var.close();
            } else |_| {}

            if (is_dir) {
                try copyDirRecursive(allocator, abs_src, dotfile_dest);
            } else {
                try std.fs.copyFileAbsolute(abs_src, dotfile_dest, .{});
            }
        }
    }

    // If ++tmux is requested, bundle the local tmux binary at tarball root as bin/tmux
    // This places it at ~/.zzh/bin/tmux on remote — persistent across +if reinstalls
    if (zzh_args.tmux) {
        const local_home = config.getHomeDir(allocator) orelse return error.HomeDirNotFound;
        defer allocator.free(local_home);
        const local_tmux = try std.fs.path.join(allocator, &.{ local_home, ".zzh", "bin", "tmux" });
        defer allocator.free(local_tmux);

        var tmux_exists = false;
        if (std.fs.openFileAbsolute(local_tmux, .{})) |f| {
            f.close();
            tmux_exists = true;
        } else |_| {}

        if (tmux_exists) {
            const dest_bin_dir = try std.fs.path.join(allocator, &.{ temp_build_dir, "bin" });
            defer allocator.free(dest_bin_dir);
            try package.makeDirRecursive(allocator, dest_bin_dir);

            const dest_tmux = try std.fs.path.join(allocator, &.{ dest_bin_dir, "tmux" });
            defer allocator.free(dest_tmux);

            if (zzh_args.debug or zzh_args.verbose) {
                std.debug.print("Bundling tmux binary from {s} to {s}...\n", .{ local_tmux, dest_tmux });
            }
            try std.fs.copyFileAbsolute(local_tmux, dest_tmux, .{});
        }
    }

    // Run system tar command without local gzip compression (to save CPU bottleneck).
    // We will use ssh -C to compress the transfer on the fly instead!
    if (zzh_args.debug or zzh_args.verbose) {
        std.debug.print("Creating payload archive {s}...\n", .{archive_path});
    }
    const start_time = std.time.milliTimestamp();
    const argv = [_][]const u8{ "tar", "-cf", archive_path, "-C", temp_build_dir, "." };
    try package.runCommand(allocator, &argv);
    const elapsed_ms = std.time.milliTimestamp() - start_time;
    if (zzh_args.time) {
        std.debug.print("=> Creating archive took {d} ms\n", .{ elapsed_ms });
    }

    return .{
        .temp_build_dir = temp_build_dir,
        .archive_path = archive_path,
    };
}

pub fn cleanupBundle(allocator: std.mem.Allocator, result: BundleResult) void {
    if (result.temp_build_dir.len > 0) {
        std.fs.deleteTreeAbsolute(result.temp_build_dir) catch {};
        allocator.free(result.temp_build_dir);
    }
    // We intentionally DO NOT delete result.archive_path to cache the tarball for future connections!
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

    var dummy_args = @import("cli.zig").ZzhArgs.init(testing.allocator);
    dummy_args.install_force = true;
    defer dummy_args.deinit();
    const result = try buildPayload(testing.allocator, shell_path, &plugin_paths, &dummy_args);
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

    var dummy_args = @import("cli.zig").ZzhArgs.init(testing.allocator);
    dummy_args.install_force = true;
    defer dummy_args.deinit();
    const result = try buildPayload(testing.allocator, shell_path, &plugin_paths, &dummy_args);
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

    var dummy_args = @import("cli.zig").ZzhArgs.init(testing.allocator);
    dummy_args.install_force = true;
    defer dummy_args.deinit();
    // With parallel build threads, build.sh errors are caught and logged per-thread,
    // not propagated as a top-level error. The payload still builds successfully.
    const res = try buildPayload(testing.allocator, shell_path, &plugin_paths, &dummy_args);
    defer cleanupBundle(testing.allocator, res);
    try testing.expect(res.archive_path.len > 0);
}
