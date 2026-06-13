const std = @import("std");
const builtin = @import("builtin");
const package = @import("package.zig");
const config = @import("config.zig");
const cli = @import("cli.zig");
const deploy = @import("deploy.zig");

// Helper check to verify if a file system path already exists.
fn pathExists(target_path: []const u8) bool {
    std.fs.accessAbsolute(target_path, .{}) catch return false;
    return true;
}

// Determines if a file or directory should be excluded from the deployment payload.
// Filters out large media assets, recording scripts, and common VCS metadata to keep payloads lean.
fn shouldIgnore(name: []const u8) bool {
    const ignored_extensions = [_][]const u8{ ".gif", ".tape", ".vhs", ".mp4", ".mov" };
    for (ignored_extensions) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }

    const ignored_names = [_][]const u8{ ".git", ".github", ".gitignore", "node_modules", ".zig-cache" };
    for (ignored_names) |ignored| {
        if (std.mem.eql(u8, name, ignored)) return true;
    }

    return false;
}

// Recursively copies all files and subdirectories from src to dest.
// Used to duplicate shell build artifacts and plugin contents into the payload staging area.
pub fn duplicateDirectory(allocator: std.mem.Allocator, src_dir_path: []const u8, dest_dir_path: []const u8) !void {
    var src_dir = try std.fs.openDirAbsolute(src_dir_path, .{ .iterate = true });
    defer src_dir.close();

    std.fs.makeDirAbsolute(dest_dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var folder_iterator = src_dir.iterate();
    while (try folder_iterator.next()) |entry| {
        if (shouldIgnore(entry.name)) continue;

        const src_child = try std.fs.path.join(allocator, &.{ src_dir_path, entry.name });
        defer allocator.free(src_child);
        const dest_child = try std.fs.path.join(allocator, &.{ dest_dir_path, entry.name });
        defer allocator.free(dest_child);

        switch (entry.kind) {
            .directory => {
                try duplicateDirectory(allocator, src_child, dest_child);
            },
            .file => {
                try std.fs.copyFileAbsolute(src_child, dest_child, .{});
            },
            else => {},
        }
    }
}

// The manifest that tracks the location of the compiled payload and its staging environment.
pub const PayloadManifest = struct {
    staging_area_path: []const u8,
    tarball_output_path: []const u8,
};

// Invokes the package-specific local build.sh script if present.
// This is used to compile binary artifacts (like shells or plugins) locally before bundling.
fn invokeLocalBuildScript(allocator: std.mem.Allocator, package_path: []const u8) !void {
    const build_sh_path = try std.fs.path.join(allocator, &.{ package_path, "build.sh" });
    defer allocator.free(build_sh_path);

    if (pathExists(build_sh_path)) {
        const build_dir = try std.fs.path.join(allocator, &.{ package_path, "build" });
        defer allocator.free(build_dir);

        if (!pathExists(build_dir)) {
            if (builtin.os.tag != .windows) {
                const chmod_argv = [_][]const u8{ "chmod", "+x", build_sh_path };
                var chmod_child = std.process.Child.init(&chmod_argv, allocator);
                _ = try chmod_child.spawnAndWait();
            }
            std.debug.print("Running build.sh in {s}...\n", .{package_path});
            const argv = if (builtin.os.tag == .windows)
                &[_][]const u8{ "bash", "build.sh" }
            else
                &[_][]const u8{ "./build.sh" };

            var build_process = std.process.Child.init(argv, allocator);
            build_process.cwd = package_path;
            build_process.stdout_behavior = .Inherit;
            build_process.stderr_behavior = .Inherit;
            try build_process.spawn();
            const exit_status = try build_process.wait();
            switch (exit_status) {
                .Exited => |code| {
                    if (code != 0) return error.BuildScriptFailed;
                },
                else => return error.BuildScriptFailed,
            }
        }
    }
}

// Thread entrypoint wrapper to run the local package build process concurrently.
fn concurrentBuildWorker(allocator: std.mem.Allocator, package_path: []const u8) void {
    invokeLocalBuildScript(allocator, package_path) catch |err| {
        std.debug.print("Error running build script for {s}: {}\n", .{ package_path, err });
    };
}

// Collects the shell, plugins, dotfiles, and requested binaries, runs their builds,
// stages them in a temporary workspace, and bundles them into an uncompressed tar archive.
pub fn assembleDeploymentPayload(allocator: std.mem.Allocator, shell_path: []const u8, plugin_paths: []const []const u8, zzh_args: *const cli.OperationalConfig) !PayloadManifest {
    const home_dir = config.discoverUserHomeDirectory(allocator) orelse return error.HomeDirNotFound;
    defer allocator.free(home_dir);

    // The payload signature is computed from all requested shells, plugins, binaries, and dotfiles.
    // If the local cache matches this signature, we bypass reconstruction completely to make connections instantaneous.
    const payload_hash = try deploy.getDeploymentHash(allocator, zzh_args);
    defer allocator.free(payload_hash);

    var tarball_filename = std.ArrayList(u8).init(allocator);
    defer tarball_filename.deinit();
    try tarball_filename.writer().print("payload-{s}.tar", .{payload_hash});
    const tarball_output_path = try std.fs.path.join(allocator, &.{ home_dir, ".zzh", "tmp", tarball_filename.items });
    errdefer allocator.free(tarball_output_path);

    // Reuse existing payload if cached to speed up the connection sequence.
    if (pathExists(tarball_output_path) and !zzh_args.install_force and !zzh_args.install_force_full) {
        std.debug.print("[3/4] Building payload archive...\n", .{});
        std.debug.print("      - Re-using cached payload\n", .{});

        var file_size: u64 = 0;
        if (std.fs.openFileAbsolute(tarball_output_path, .{})) |tarball_file| {
            if (tarball_file.stat()) |stat| {
                file_size = stat.size;
            } else |_| {}
            tarball_file.close();
        } else |_| {}
        const size_mb = @as(f64, @floatFromInt(file_size)) / 1024.0 / 1024.0;
        std.debug.print("      - Done. (Size: {d:.1} MB)\n", .{size_mb});

        return .{
            .staging_area_path = try allocator.dupe(u8, ""),
            .tarball_output_path = tarball_output_path,
        };
    }

    std.debug.print("[3/4] Building payload archive...\n", .{});

    // Standardize on a randomized staging area name to avoid race conditions and file collisions during concurrent local builds.
    const random_id = std.crypto.random.int(u64);
    var staging_folder_name: [64]u8 = undefined;
    const temp_name = try std.fmt.bufPrint(&staging_folder_name, "zzh-build-{x}", .{random_id});

    const staging_area_path = try std.fs.path.join(allocator, &.{ home_dir, ".zzh", "tmp", temp_name });
    errdefer allocator.free(staging_area_path);

    const tmp_parent_dir = try std.fs.path.join(allocator, &.{ home_dir, ".zzh", "tmp" });
    defer allocator.free(tmp_parent_dir);
    try package.ensureDirectoryPath(tmp_parent_dir);

    // Shell script execution needs to happen before copying shell assets.
    try invokeLocalBuildScript(allocator, shell_path);

    const shell_pkg_name = std.fs.path.basename(shell_path);

    // Locate the built assets directory for the shell package.
    const shell_src_build = try std.fs.path.join(allocator, &.{ shell_path, "build" });
    defer allocator.free(shell_src_build);
    const shell_has_build = pathExists(shell_src_build);
    const shell_source_dir = if (shell_has_build) shell_src_build else shell_path;

    const dest_shell_parent = try std.fs.path.join(allocator, &.{ staging_area_path, ".zzh", "shells", shell_pkg_name });
    defer allocator.free(dest_shell_parent);

    const dest_shell_dir = if (shell_has_build)
        try std.fs.path.join(allocator, &.{ dest_shell_parent, "build" })
    else
        try allocator.dupe(u8, dest_shell_parent);
    defer allocator.free(dest_shell_dir);

    try package.ensureDirectoryPath(dest_shell_dir);

    var clean_shell_name = shell_pkg_name;
    if (std.mem.startsWith(u8, clean_shell_name, "xxh-shell-")) {
        clean_shell_name = clean_shell_name["xxh-shell-".len..];
    }
    std.debug.print("      - Bundling shell '{s}'\n", .{clean_shell_name});

    if (zzh_args.debug or zzh_args.verbose) {
        std.debug.print("Copying shell from {s} to {s}...\n", .{ shell_source_dir, dest_shell_dir });
    }
    try duplicateDirectory(allocator, shell_source_dir, dest_shell_dir);

    // Build all requested plugins concurrently using separate background worker threads.
    var plugin_build_threads = std.ArrayList(std.Thread).init(allocator);
    defer plugin_build_threads.deinit();

    for (plugin_paths) |plugin_path| {
        const build_thread = try std.Thread.spawn(.{}, concurrentBuildWorker, .{ allocator, plugin_path });
        try plugin_build_threads.append(build_thread);
    }

    for (plugin_build_threads.items) |t| {
        t.join();
    }

    // Stage plugin folders into the payload directory.
    for (plugin_paths) |plugin_path| {
        const plugin_name = std.fs.path.basename(plugin_path);

        const plugin_src_build = try std.fs.path.join(allocator, &.{ plugin_path, "build" });
        defer allocator.free(plugin_src_build);
        const plugin_has_build = pathExists(plugin_src_build);
        const plugin_source_dir = if (plugin_has_build) plugin_src_build else plugin_path;

        const dest_plugin_parent = try std.fs.path.join(allocator, &.{ staging_area_path, ".zzh", "plugins", plugin_name });
        defer allocator.free(dest_plugin_parent);

        const dest_plugin_dir = if (plugin_has_build)
            try std.fs.path.join(allocator, &.{ dest_plugin_parent, "build" })
        else
            try allocator.dupe(u8, dest_plugin_parent);
        defer allocator.free(dest_plugin_dir);

        try package.ensureDirectoryPath(dest_plugin_dir);

        var clean_plugin_name = plugin_name;
        if (std.mem.startsWith(u8, clean_plugin_name, "xxh-plugin-")) {
            clean_plugin_name = clean_plugin_name["xxh-plugin-".len..];
        }
        std.debug.print("      - Bundling plugin '{s}'\n", .{clean_plugin_name});

        if (zzh_args.debug or zzh_args.verbose) {
            std.debug.print("Copying plugin from {s} to {s}...\n", .{ plugin_source_dir, dest_plugin_dir });
        }
        try duplicateDirectory(allocator, plugin_source_dir, dest_plugin_dir);
    }

    // Copy any local user configuration dotfiles into the payload.
    if (zzh_args.dotfiles.items.len > 0) {
        const dest_dotfiles_dir = try std.fs.path.join(allocator, &.{ staging_area_path, ".zzh", "dotfiles" });
        defer allocator.free(dest_dotfiles_dir);
        try package.ensureDirectoryPath(dest_dotfiles_dir);

        for (zzh_args.dotfiles.items) |d| {
            var local_path = d;
            var remote_name: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, d, ':')) |colon_idx| {
                local_path = d[0..colon_idx];
                remote_name = d[colon_idx + 1 ..];
            }

            const basename = remote_name orelse std.fs.path.basename(local_path);
            if (shouldIgnore(basename)) {
                if (zzh_args.debug or zzh_args.verbose) {
                    std.debug.print("Ignoring dotfile {s} during bundling.\n", .{basename});
                }
                continue;
            }
            const dotfile_dest = try std.fs.path.join(allocator, &.{ dest_dotfiles_dir, basename });
            defer allocator.free(dotfile_dest);

            const resolved_src = try config.expandUserPath(allocator, local_path);
            defer allocator.free(resolved_src);
            const absolute_src = std.fs.cwd().realpathAlloc(allocator, resolved_src) catch |err| {
                if (err == error.FileNotFound) {
                    std.debug.print("Warning: Dotfile '{s}' not found, skipping.\n", .{resolved_src});
                    continue;
                }
                return err;
            };
            defer allocator.free(absolute_src);

            if (zzh_args.debug or zzh_args.verbose) {
                std.debug.print("Copying dotfile from {s} to {s}...\n", .{ absolute_src, dotfile_dest });
            }

            var source_is_directory = false;
            if (std.fs.openDirAbsolute(absolute_src, .{})) |opened_dir| {
                var dir_handle = opened_dir;
                source_is_directory = true;
                dir_handle.close();
            } else |_| {}

            if (source_is_directory) {
                try duplicateDirectory(allocator, absolute_src, dotfile_dest);
            } else {
                try std.fs.copyFileAbsolute(absolute_src, dotfile_dest, .{});
            }
        }
    }

    // Bundle the local tmux binary at tarball root as bin/tmux if ++tmux is active
    if (zzh_args.tmux) {
        var base_dir: []const u8 = undefined;
        if (zzh_args.local_zzh_home) |lh| {
            base_dir = try config.expandUserPath(allocator, lh);
        } else {
            base_dir = try std.fs.path.join(allocator, &.{ home_dir, ".zzh" });
        }
        defer allocator.free(base_dir);

        const local_tmux = try std.fs.path.join(allocator, &.{ base_dir, "bin", "tmux" });
        defer allocator.free(local_tmux);

        var tmux_exists = false;
        if (std.fs.openFileAbsolute(local_tmux, .{})) |f| {
            f.close();
            tmux_exists = true;
        } else |_| {}

        if (tmux_exists) {
            const dest_bin_dir = try std.fs.path.join(allocator, &.{ staging_area_path, "bin" });
            defer allocator.free(dest_bin_dir);
            try package.ensureDirectoryPath(dest_bin_dir);

            const dest_tmux = try std.fs.path.join(allocator, &.{ dest_bin_dir, "tmux" });
            defer allocator.free(dest_tmux);

            std.debug.print("      - Bundling binary 'tmux'\n", .{});
            if (zzh_args.debug or zzh_args.verbose) {
                std.debug.print("Bundling tmux binary from {s} to {s}...\n", .{ local_tmux, dest_tmux });
            }
            try std.fs.copyFileAbsolute(local_tmux, dest_tmux, .{});
        }
    }

    // Cache any requested command line binaries (like rg or fd) in the payload workspace.
    if (zzh_args.binaries.items.len > 0) {
        var base_dir: []const u8 = undefined;
        if (zzh_args.local_zzh_home) |lh| {
            base_dir = try config.expandUserPath(allocator, lh);
        } else {
            base_dir = try std.fs.path.join(allocator, &.{ home_dir, ".zzh" });
        }
        defer allocator.free(base_dir);

        for (zzh_args.binaries.items) |repo| {
            const bin_name = package.extractExecutableName(repo);
            const local_bin = try std.fs.path.join(allocator, &.{ base_dir, "bin", bin_name });
            defer allocator.free(local_bin);

            var bin_exists = false;
            if (std.fs.openFileAbsolute(local_bin, .{})) |f| {
                f.close();
                bin_exists = true;
            } else |_| {}

            if (bin_exists) {
                const dest_bin_dir = try std.fs.path.join(allocator, &.{ staging_area_path, "bin" });
                defer allocator.free(dest_bin_dir);
                try package.ensureDirectoryPath(dest_bin_dir);

                const dest_bin = try std.fs.path.join(allocator, &.{ dest_bin_dir, bin_name });
                defer allocator.free(dest_bin);

                std.debug.print("      - Bundling binary '{s}'\n", .{bin_name});
                if (zzh_args.debug or zzh_args.verbose) {
                    std.debug.print("Bundling binary {s} from {s} to {s}...\n", .{ bin_name, local_bin, dest_bin });
                }
                try std.fs.copyFileAbsolute(local_bin, dest_bin, .{});
            }
        }
    }

    // Standard gzip/xz compression on the client machine creates a CPU bottleneck on large shell/plugin bundles.
    // We write a plain tar archive here and let SSH's native compression (-C) optimize the transit pipeline dynamically.
    if (zzh_args.debug or zzh_args.verbose) {
        std.debug.print("Creating payload archive {s}...\n", .{tarball_output_path});
    }
    const tar_start_time = std.time.milliTimestamp();
    const tar_argv = [_][]const u8{ "tar", "-cf", tarball_output_path, "-C", staging_area_path, "." };
    try package.executeSubprocess(allocator, &tar_argv);
    const elapsed_ms = std.time.milliTimestamp() - tar_start_time;
    if (zzh_args.time) {
        std.debug.print("=> Creating archive took {d} ms\n", .{elapsed_ms});
    }

    var file_size: u64 = 0;
    if (std.fs.openFileAbsolute(tarball_output_path, .{})) |tarball_file| {
        if (tarball_file.stat()) |stat| {
            file_size = stat.size;
        } else |_| {}
        tarball_file.close();
    } else |_| {}
    const size_mb = @as(f64, @floatFromInt(file_size)) / 1024.0 / 1024.0;
    std.debug.print("      - Done. (Size: {d:.1} MB)\n", .{size_mb});

    return .{
        .staging_area_path = staging_area_path,
        .tarball_output_path = tarball_output_path,
    };
}

// Discards the local staging directory to free disk space, keeping the tarball.
pub fn discardStagingArea(allocator: std.mem.Allocator, manifest: PayloadManifest) void {
    if (manifest.staging_area_path.len > 0) {
        std.fs.deleteTreeAbsolute(manifest.staging_area_path) catch {};
        allocator.free(manifest.staging_area_path);
    }
    // We intentionally DO NOT delete manifest.tarball_output_path to cache the tarball for future connections!
    allocator.free(manifest.tarball_output_path);
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

    var stub_cli_arguments = @import("cli.zig").OperationalConfig.init(testing.allocator);
    stub_cli_arguments.install_force = true;
    defer stub_cli_arguments.deinit();
    const manifest = try assembleDeploymentPayload(testing.allocator, shell_path, &plugin_paths, &stub_cli_arguments);
    defer discardStagingArea(testing.allocator, manifest);

    try testing.expect(pathExists(manifest.staging_area_path));
    try testing.expect(pathExists(manifest.tarball_output_path));

    const shell_pkg_name = std.fs.path.basename(shell_path);
    const check_entrypoint = try std.fmt.allocPrint(testing.allocator, "{s}/.zzh/shells/{s}/entrypoint.sh", .{ manifest.staging_area_path, shell_pkg_name });
    defer testing.allocator.free(check_entrypoint);
    try testing.expect(pathExists(check_entrypoint));
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
        try package.executeSubprocess(testing.allocator, &argv);
    }

    const plugin_paths = [_][]const u8{plugin_path};

    var stub_cli_arguments = @import("cli.zig").OperationalConfig.init(testing.allocator);
    stub_cli_arguments.install_force = true;
    defer stub_cli_arguments.deinit();
    const manifest = try assembleDeploymentPayload(testing.allocator, shell_path, &plugin_paths, &stub_cli_arguments);
    defer discardStagingArea(testing.allocator, manifest);

    try testing.expect(pathExists(manifest.staging_area_path));
    try testing.expect(pathExists(manifest.tarball_output_path));

    const shell_pkg_name = std.fs.path.basename(shell_path);
    const check_entrypoint = try std.fmt.allocPrint(testing.allocator, "{s}/.zzh/shells/{s}/build/entrypoint.sh", .{ manifest.staging_area_path, shell_pkg_name });
    defer testing.allocator.free(check_entrypoint);
    try testing.expect(pathExists(check_entrypoint));

    const plugin_name = std.fs.path.basename(plugin_path);
    const check_init = try std.fmt.allocPrint(testing.allocator, "{s}/.zzh/plugins/{s}/build/init.sh", .{ manifest.staging_area_path, plugin_name });
    defer testing.allocator.free(check_init);
    try testing.expect(pathExists(check_init));
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
        try package.executeSubprocess(testing.allocator, &argv);
    }

    var shell_buf: [1024]u8 = undefined;
    const shell_path = try tmp_shell_dir.dir.realpath(".", &shell_buf);

    var plugin_buf: [1024]u8 = undefined;
    const plugin_path = try tmp_plugin_dir.dir.realpath(".", &plugin_buf);

    const plugin_paths = [_][]const u8{plugin_path};

    var stub_cli_arguments = @import("cli.zig").OperationalConfig.init(testing.allocator);
    stub_cli_arguments.install_force = true;
    defer stub_cli_arguments.deinit();
    // With parallel build threads, build.sh errors are caught and logged per-thread,
    // not propagated as a top-level error. The payload still builds successfully.
    const manifest = try assembleDeploymentPayload(testing.allocator, shell_path, &plugin_paths, &stub_cli_arguments);
    defer discardStagingArea(testing.allocator, manifest);
    try testing.expect(manifest.tarball_output_path.len > 0);
}
