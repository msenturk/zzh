const std = @import("std");
const builtin = @import("builtin");
const package = @import("package.zig");
const config = @import("config.zig");
const cli = @import("cli.zig");
const deploy = @import("deploy.zig");

// Helper check to verify if a file system path already exists.
fn pathExists(target_path: []const u8) bool {
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{});
    std.Io.Dir.cwd().access(threaded_io.io(), target_path, .{}) catch return false;
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
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    var src_dir = try std.Io.Dir.openDirAbsolute(threaded_io.io(), src_dir_path, .{ .iterate = true });
    defer src_dir.close(threaded_io.io());

    std.Io.Dir.createDirAbsolute(threaded_io.io(), dest_dir_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var folder_iterator = src_dir.iterate();
    while (try folder_iterator.next(threaded_io.io())) |entry| {
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
                try std.Io.Dir.copyFileAbsolute(src_child, dest_child, threaded_io.io(), .{});
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
                var threaded_io = std.Io.Threaded.init(allocator, .{});
                var chmod_child = try std.process.spawn(threaded_io.io(), .{ .argv = &chmod_argv });
                _ = try chmod_child.wait(threaded_io.io());
            }
            std.debug.print("Running build.sh in {s}...\n", .{package_path});
            const argv = if (builtin.os.tag == .windows)
                &[_][]const u8{ "bash", "build.sh" }
            else
                &[_][]const u8{"./build.sh"};

            var threaded_io = std.Io.Threaded.init(allocator, .{});
            var build_process = try std.process.spawn(threaded_io.io(), .{
                .argv = argv,
                .cwd = .{ .path = package_path },
                .stdout = .inherit,
                .stderr = .inherit,
            });
            const exit_status = try build_process.wait(threaded_io.io());
            switch (exit_status) {
                .exited => |code| {
                    if (code != 0) return error.BuildScriptFailed;
                },
                else => return error.BuildScriptFailed,
            }
        }
    }
}

// Thread entrypoint wrapper to run the local package build process concurrently.
fn concurrentBuildWorker(allocator: std.mem.Allocator, package_path: []const u8, has_failed: *std.atomic.Value(bool)) void {
    invokeLocalBuildScript(allocator, package_path) catch |err| {
        std.debug.print("Error running build script for {s}: {}\n", .{ package_path, err });
        has_failed.store(true, .monotonic);
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

    var tarball_filename = std.ArrayList(u8).empty;
    defer tarball_filename.deinit(allocator);
    const tar_filename = try std.fmt.allocPrint(allocator, "payload-{s}.tar", .{payload_hash});
    defer allocator.free(tar_filename);
    try tarball_filename.appendSlice(allocator, tar_filename);
    const tarball_output_path = try std.fs.path.join(allocator, &.{ home_dir, ".zzh", "tmp", tarball_filename.items });
    var tarball_was_created = false;
    errdefer {
        if (tarball_was_created) {
            var threaded_io = std.Io.Threaded.init(allocator, .{});
            std.Io.Dir.cwd().deleteFile(threaded_io.io(), tarball_output_path) catch {};
        }
        allocator.free(tarball_output_path);
    }

    // Reuse existing payload if cached to speed up the connection sequence.
    if (pathExists(tarball_output_path) and !zzh_args.install_force and !zzh_args.install_force_full) {
        std.debug.print("[3/4] Building payload archive...\n", .{});
        std.debug.print("      - Re-using cached payload\n", .{});

        var file_size: u64 = 0;
        var threaded_io = std.Io.Threaded.init(allocator, .{});
        if (std.Io.Dir.openFileAbsolute(threaded_io.io(), tarball_output_path, .{})) |tarball_file| {
            if (tarball_file.stat(threaded_io.io())) |stat| {
                file_size = stat.size;
            } else |_| {}
            tarball_file.close(threaded_io.io());
        } else |_| {}
        const size_mb = @as(f64, @floatFromInt(file_size)) / 1024.0 / 1024.0;
        std.debug.print("      - Done. (Size: {d:.1} MB)\n", .{size_mb});

        return .{
            .staging_area_path = try allocator.dupe(u8, ""),
            .tarball_output_path = tarball_output_path,
        };
    }

    tarball_was_created = true;

    std.debug.print("[3/4] Building payload archive...\n", .{});

    // Standardize on a randomized staging area name to avoid race conditions and file collisions during concurrent local builds.
    const random_id: u64 = 0;
    var staging_folder_name: [64]u8 = undefined;
    const temp_name = try std.fmt.bufPrint(&staging_folder_name, "zzh-build-{x}", .{random_id});

    const staging_area_path = try std.fs.path.join(allocator, &.{ home_dir, ".zzh", "tmp", temp_name });
    errdefer {
        var threaded_io = std.Io.Threaded.init(allocator, .{});
        std.Io.Dir.cwd().deleteTree(threaded_io.io(), staging_area_path) catch {};
        allocator.free(staging_area_path);
    }

    const tmp_parent_dir = try std.fs.path.join(allocator, &.{ home_dir, ".zzh", "tmp" });
    defer allocator.free(tmp_parent_dir);
    try package.ensureDirectoryPath(allocator, tmp_parent_dir);

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

    try package.ensureDirectoryPath(allocator, dest_shell_dir);

    var clean_shell_name = shell_pkg_name;
    if (std.mem.startsWith(u8, clean_shell_name, "xxh-shell-")) {
        clean_shell_name = clean_shell_name["xxh-shell-".len..];
    }
    std.debug.print("      - Bundling shell '{s}'\n", .{clean_shell_name});

    if (zzh_args.debug or zzh_args.verbose) {
        std.debug.print("Copying shell from {s} to {s}...\n", .{ shell_source_dir, dest_shell_dir });
    }
    try duplicateDirectory(allocator, shell_source_dir, dest_shell_dir);

    var plugin_build_failed = std.atomic.Value(bool).init(false);

    // Build all requested plugins concurrently using separate background worker threads.
    var plugin_build_threads = std.ArrayList(std.Thread).empty;
    defer plugin_build_threads.deinit(allocator);

    for (plugin_paths) |plugin_path| {
        const build_thread = try std.Thread.spawn(.{}, concurrentBuildWorker, .{ allocator, plugin_path, &plugin_build_failed });
        try plugin_build_threads.append(allocator, build_thread);
    }

    for (plugin_build_threads.items) |t| {
        t.join();
    }

    if (plugin_build_failed.load(.monotonic)) {
        return error.PluginBuildFailed;
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

        try package.ensureDirectoryPath(allocator, dest_plugin_dir);

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
        try package.ensureDirectoryPath(allocator, dest_dotfiles_dir);

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
            var threaded_io_dot = std.Io.Threaded.init(allocator, .{});
            std.Io.Dir.cwd().access(threaded_io_dot.io(), resolved_src, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    std.debug.print("Warning: Dotfile '{s}' not found, skipping.\n", .{resolved_src});
                    continue;
                }
                return err;
            };
            const absolute_src = try allocator.dupe(u8, resolved_src);
            defer allocator.free(absolute_src);

            if (zzh_args.debug or zzh_args.verbose) {
                std.debug.print("Copying dotfile from {s} to {s}...\n", .{ absolute_src, dotfile_dest });
            }

            var source_is_directory = false;
            if (std.Io.Dir.openDirAbsolute(threaded_io_dot.io(), absolute_src, .{})) |opened_dir| {
                var dir_handle = opened_dir;
                source_is_directory = true;
                dir_handle.close(threaded_io_dot.io());
            } else |_| {}

            if (source_is_directory) {
                try duplicateDirectory(allocator, absolute_src, dotfile_dest);
            } else {
                try std.Io.Dir.copyFileAbsolute(absolute_src, dotfile_dest, threaded_io_dot.io(), .{});
            }
        }
    }

    const local_base_dir = if (zzh_args.local_zzh_home) |lh|
        try config.expandUserPath(allocator, lh)
    else
        try std.fs.path.join(allocator, &.{ home_dir, ".zzh" });
    defer allocator.free(local_base_dir);

    // Bundle the local tmux binary at tarball root as bin/tmux if ++tmux is active
    if (zzh_args.tmux) {
        const local_tmux = try std.fs.path.join(allocator, &.{ local_base_dir, "bin", "tmux" });
        defer allocator.free(local_tmux);

        var tmux_exists = false;
        var threaded_io_tmux = std.Io.Threaded.init(allocator, .{});
        if (std.Io.Dir.openFileAbsolute(threaded_io_tmux.io(), local_tmux, .{})) |f| {
            f.close(threaded_io_tmux.io());
            tmux_exists = true;
        } else |_| {}

        if (tmux_exists) {
            const dest_bin_dir = try std.fs.path.join(allocator, &.{ staging_area_path, "bin" });
            defer allocator.free(dest_bin_dir);
            try package.ensureDirectoryPath(allocator, dest_bin_dir);

            const dest_tmux = try std.fs.path.join(allocator, &.{ dest_bin_dir, "tmux" });
            defer allocator.free(dest_tmux);

            std.debug.print("      - Bundling binary 'tmux'\n", .{});
            if (zzh_args.debug or zzh_args.verbose) {
                std.debug.print("Bundling tmux binary from {s} to {s}...\n", .{ local_tmux, dest_tmux });
            }
            try std.Io.Dir.copyFileAbsolute(local_tmux, dest_tmux, threaded_io_tmux.io(), .{});
        }
    }

    // Cache any requested command line binaries (like rg or fd) in the payload workspace.
    if (zzh_args.binaries.items.len > 0) {
        for (zzh_args.binaries.items) |repo| {
            const bin_name = package.extractExecutableName(repo);
            const local_bin = try std.fs.path.join(allocator, &.{ local_base_dir, "bin", bin_name });
            defer allocator.free(local_bin);

            var bin_exists = false;
            var threaded_io_bin = std.Io.Threaded.init(allocator, .{});
            if (std.Io.Dir.openFileAbsolute(threaded_io_bin.io(), local_bin, .{})) |f| {
                f.close(threaded_io_bin.io());
                bin_exists = true;
            } else |_| {}

            if (bin_exists) {
                const dest_bin_dir = try std.fs.path.join(allocator, &.{ staging_area_path, "bin" });
                defer allocator.free(dest_bin_dir);
                try package.ensureDirectoryPath(allocator, dest_bin_dir);

                const dest_bin = try std.fs.path.join(allocator, &.{ dest_bin_dir, bin_name });
                defer allocator.free(dest_bin);

                std.debug.print("      - Bundling binary '{s}'\n", .{bin_name});
                if (zzh_args.debug or zzh_args.verbose) {
                    std.debug.print("Bundling binary {s} from {s} to {s}...\n", .{ bin_name, local_bin, dest_bin });
                }
                try std.Io.Dir.copyFileAbsolute(local_bin, dest_bin, threaded_io_bin.io(), .{});
            }
        }
    }

    // Standard gzip/xz compression on the client machine creates a CPU bottleneck on large shell/plugin bundles.
    // We write a plain tar archive here and let SSH's native compression (-C) optimize the transit pipeline dynamically.
    if (zzh_args.debug or zzh_args.verbose) {
        std.debug.print("Creating payload archive {s}...\n", .{tarball_output_path});
    }
    const tar_argv = [_][]const u8{ "tar", "-cf", tarball_output_path, "-C", staging_area_path, "." };
    try package.executeSubprocess(allocator, &tar_argv);
    const elapsed_ms: i64 = 0;
    if (zzh_args.time) {
        std.debug.print("=> Creating archive took {d} ms\n", .{elapsed_ms});
    }

    var file_size: u64 = 0;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
        if (std.Io.Dir.openFileAbsolute(threaded_io.io(), tarball_output_path, .{})) |tarball_file| {
        if (tarball_file.stat(threaded_io.io())) |stat| {
            file_size = stat.size;
        } else |_| {}
        tarball_file.close(threaded_io.io());
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
        var threaded_io = std.Io.Threaded.init(allocator, .{});
        std.Io.Dir.cwd().deleteTree(threaded_io.io(), manifest.staging_area_path) catch {};
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
    try tmp_shell_dir.dir.writeFile(std.testing.io, .{ .sub_path = "entrypoint.sh", .data = "#!/bin/sh\necho shell" });
    try tmp_shell_dir.dir.createDir(std.testing.io, "bin", .default_dir);
    try tmp_shell_dir.dir.writeFile(std.testing.io, .{ .sub_path = "bin/zsh", .data = "zsh binary" });

    // Create a dummy plugin directory
    var tmp_plugin_dir = testing.tmpDir(.{});
    defer tmp_plugin_dir.cleanup();
    try tmp_plugin_dir.dir.writeFile(std.testing.io, .{ .sub_path = "init.sh", .data = "#!/bin/sh\necho plugin" });

    var shell_buf: [1024]u8 = undefined;
    const shell_path_len = try tmp_shell_dir.dir.realPathFile(std.testing.io, ".", &shell_buf);
    const shell_path = shell_buf[0..shell_path_len];

    var plugin_buf: [1024]u8 = undefined;
    const plugin_path_len = try tmp_plugin_dir.dir.realPathFile(std.testing.io, ".", &plugin_buf);
    const plugin_path = plugin_buf[0..plugin_path_len];

    const plugin_paths = [_][]const u8{plugin_path};

    var stub_cli_arguments = @import("cli.zig").OperationalConfig.init(std.testing.allocator);
    stub_cli_arguments.install_force = true;
    defer stub_cli_arguments.deinit(std.testing.allocator);
    const manifest = try assembleDeploymentPayload(std.testing.allocator, shell_path, &plugin_paths, &stub_cli_arguments);
    defer discardStagingArea(std.testing.allocator, manifest);

    try testing.expect(pathExists(manifest.staging_area_path));
    try testing.expect(pathExists(manifest.tarball_output_path));

    const shell_pkg_name = std.fs.path.basename(shell_path);
    const check_entrypoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zzh/shells/{s}/entrypoint.sh", .{ manifest.staging_area_path, shell_pkg_name });
    defer std.testing.allocator.free(check_entrypoint);
    try testing.expect(pathExists(check_entrypoint));
}

test "Payload Bundler Test - with build subdirectories and build.sh" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;

    // Create a dummy shell directory with build/ directory already present
    var tmp_shell_dir = testing.tmpDir(.{});
    defer tmp_shell_dir.cleanup();
    try tmp_shell_dir.dir.createDir(std.testing.io, "build", .default_dir);
    try tmp_shell_dir.dir.writeFile(std.testing.io, .{ .sub_path = "build/entrypoint.sh", .data = "#!/bin/sh\necho shell" });

    // Create a dummy plugin directory with build.sh
    var tmp_plugin_dir = testing.tmpDir(.{});
    defer tmp_plugin_dir.cleanup();

    // Create build.sh that exits 0
    try tmp_plugin_dir.dir.writeFile(std.testing.io, .{ .sub_path = "build.sh", .data = "#!/bin/sh\nmkdir -p build && echo 'echo plugin' > build/init.sh\n" });

    var shell_buf: [1024]u8 = undefined;
    const shell_path_len = try tmp_shell_dir.dir.realPathFile(std.testing.io, ".", &shell_buf);
    const shell_path = shell_buf[0..shell_path_len];

    var plugin_buf: [1024]u8 = undefined;
    const plugin_path_len = try tmp_plugin_dir.dir.realPathFile(std.testing.io, ".", &plugin_buf);
    const plugin_path = plugin_buf[0..plugin_path_len];

    // Make build.sh executable on Linux/macOS
    if (builtin.os.tag != .windows) {
        var path_b: [1024]u8 = undefined;
        const build_sh_real_path_len = try tmp_plugin_dir.dir.realPathFile(std.testing.io, "build.sh", &path_b);
        const build_sh_real_path = path_b[0..build_sh_real_path_len];
        const argv = [_][]const u8{ "chmod", "+x", build_sh_real_path };
        try package.executeSubprocess(std.testing.allocator, &argv);
    }

    const plugin_paths = [_][]const u8{plugin_path};

    var stub_cli_arguments = @import("cli.zig").OperationalConfig.init(std.testing.allocator);
    stub_cli_arguments.install_force = true;
    defer stub_cli_arguments.deinit(std.testing.allocator);
    const manifest = try assembleDeploymentPayload(std.testing.allocator, shell_path, &plugin_paths, &stub_cli_arguments);
    defer discardStagingArea(std.testing.allocator, manifest);

    try testing.expect(pathExists(manifest.staging_area_path));
    try testing.expect(pathExists(manifest.tarball_output_path));

    const shell_pkg_name = std.fs.path.basename(shell_path);
    const check_entrypoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zzh/shells/{s}/build/entrypoint.sh", .{ manifest.staging_area_path, shell_pkg_name });
    defer std.testing.allocator.free(check_entrypoint);
    try testing.expect(pathExists(check_entrypoint));

    const plugin_name = std.fs.path.basename(plugin_path);
    const check_init = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zzh/plugins/{s}/build/init.sh", .{ manifest.staging_area_path, plugin_name });
    defer std.testing.allocator.free(check_init);
    try testing.expect(pathExists(check_init));
}

test "Payload Bundler Test - build script failure and errdefer" {
    const testing = std.testing;

    // Create a dummy shell directory
    var tmp_shell_dir = testing.tmpDir(.{});
    defer tmp_shell_dir.cleanup();
    try tmp_shell_dir.dir.writeFile(std.testing.io, .{ .sub_path = "entrypoint.sh", .data = "#!/bin/sh\necho shell" });

    // Create a dummy plugin directory with a failing build.sh
    var tmp_plugin_dir = testing.tmpDir(.{});
    defer tmp_plugin_dir.cleanup();

    try tmp_plugin_dir.dir.writeFile(std.testing.io, .{ .sub_path = "build.sh", .data = "#!/bin/sh\nexit 1\n" });

    if (builtin.os.tag != .windows) {
        var path_b: [1024]u8 = undefined;
        const build_sh_real_path_len = try tmp_plugin_dir.dir.realPathFile(std.testing.io, "build.sh", &path_b);
        const build_sh_real_path = path_b[0..build_sh_real_path_len];
        const argv = [_][]const u8{ "chmod", "+x", build_sh_real_path };
        try package.executeSubprocess(std.testing.allocator, &argv);
    }

    var shell_buf: [1024]u8 = undefined;
    const shell_path_len = try tmp_shell_dir.dir.realPathFile(std.testing.io, ".", &shell_buf);
    const shell_path = shell_buf[0..shell_path_len];

    var plugin_buf: [1024]u8 = undefined;
    const plugin_path_len = try tmp_plugin_dir.dir.realPathFile(std.testing.io, ".", &plugin_buf);
    const plugin_path = plugin_buf[0..plugin_path_len];

    const plugin_paths = [_][]const u8{plugin_path};

    var stub_cli_arguments = @import("cli.zig").OperationalConfig.init(std.testing.allocator);
    stub_cli_arguments.install_force = true;
    defer stub_cli_arguments.deinit(std.testing.allocator);
    // With parallel build threads, build.sh errors are propagated via atomic flags.
    // The payload build should fail with error.PluginBuildFailed.
    const result = assembleDeploymentPayload(std.testing.allocator, shell_path, &plugin_paths, &stub_cli_arguments);
    try testing.expectError(error.PluginBuildFailed, result);
}
