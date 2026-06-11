const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const package = @import("package.zig");
const bundler = @import("bundler.zig");
const deploy = @import("deploy.zig");

fn listPackages(allocator: std.mem.Allocator, local_xxh_home: ?[]const u8, filter_packages: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();
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
    for (sub_dirs) |sub| {
        const path = try std.fs.path.join(allocator, &.{ base_dir, ".zzh", sub });
        defer allocator.free(path);

        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "xxh-")) {
                if (filter_packages.len > 0) {
                    var found = false;
                    for (filter_packages) |fp| {
                        if (std.mem.eql(u8, entry.name, fp)) {
                            found = true;
                            break;
                        }
                    }
                    if (found) {
                        try stdout.print("{s}\n", .{entry.name});
                    }
                } else {
                    try stdout.print("{s}\n", .{entry.name});
                }
            }
        }
    }
}

fn listShellsOrPlugins(allocator: std.mem.Allocator, local_xxh_home: ?[]const u8, sub: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    var base_dir: []const u8 = undefined;
    if (local_xxh_home) |lh| {
        base_dir = try config.resolvePath(allocator, lh);
    } else {
        const home = config.getHomeDir(allocator) orelse return error.HomeDirNotFound;
        defer allocator.free(home);
        base_dir = try std.fs.path.join(allocator, &.{ home, ".zzh" });
    }
    defer allocator.free(base_dir);

    const path = try std.fs.path.join(allocator, &.{ base_dir, ".zzh", sub });
    defer allocator.free(path);

    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "xxh-")) {
            try stdout.print("{s}\n", .{entry.name});
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Parse CLI arguments first to locate the target host and config path
    var cli_args_only = try cli.parseArgs(allocator);
    defer cli_args_only.deinit();

    // Check if we are performing a local packages operation
    const has_local_ops_only = cli_args_only.destination == null and (
        cli_args_only.has_list_xxh_packages or
        cli_args_only.list_shells or
        cli_args_only.list_plugins or
        cli_args_only.install_xxh_packages.items.len > 0 or
        cli_args_only.reinstall_xxh_packages.items.len > 0 or
        cli_args_only.remove_xxh_packages.items.len > 0
    );

    if (cli_args_only.destination == null and !has_local_ops_only) {
        std.debug.print("Usage: zzh [ssh arguments] [user@]host[:port] [zzh arguments]\n", .{});
        std.debug.print("Example: zzh user@host +s zsh\n", .{});
        std.process.exit(1);
    }

    // 2. Resolve and parse config.zzhc path if destination is present
    var config_args_list = std.ArrayList([]const u8).init(allocator);
    defer {
        for (config_args_list.items) |item| allocator.free(item);
        config_args_list.deinit();
    }

    if (cli_args_only.destination) |dest| {
        const dest_info = cli.parseDestination(dest);
        const config_path_raw = cli_args_only.config_path orelse "~/.config/zzh/config.zzhc";
        const config_path = try config.resolvePath(allocator, config_path_raw);
        defer allocator.free(config_path);

        config.parseConfig(allocator, config_path, dest_info.host, &config_args_list) catch |err| {
            std.debug.print("Warning: Failed to parse config file: {}\n", .{err});
        };
    }

    // 3. Merge arguments: Config file arguments first, then CLI arguments
    var merged_args = cli.XxhArgs.init(allocator);
    defer merged_args.deinit();

    try cli.parseFromSlice(allocator, config_args_list.items, &merged_args);

    // Re-read process arguments to get fresh CLI args list
    var args_it = try std.process.argsWithAllocator(allocator);
    defer args_it.deinit();
    _ = args_it.next(); // Skip program name
    var cli_args_list = std.ArrayList([]const u8).init(allocator);
    defer {
        for (cli_args_list.items) |item| allocator.free(item);
        cli_args_list.deinit();
    }
    while (args_it.next()) |arg| {
        try cli_args_list.append(try allocator.dupe(u8, arg));
    }
    try cli.parseFromSlice(allocator, cli_args_list.items, &merged_args);

    // 4. Perform package operations if requested
    var package_op_performed = false;
    if (merged_args.install_xxh_packages.items.len > 0) {
        for (merged_args.install_xxh_packages.items) |pkg_name| {
            const is_shell = std.mem.indexOf(u8, pkg_name, "-shell-") != null;
            const resolved = try package.resolvePackage(allocator, pkg_name, is_shell);
            defer package.freeResolvedPackage(allocator, resolved);
            const path = try package.downloadAndCachePackage(allocator, resolved, is_shell, merged_args.install_force, merged_args.local_xxh_home);
            allocator.free(path);
        }
        package_op_performed = true;
    }

    if (merged_args.reinstall_xxh_packages.items.len > 0) {
        for (merged_args.reinstall_xxh_packages.items) |pkg_name| {
            const is_shell = std.mem.indexOf(u8, pkg_name, "-shell-") != null;
            const resolved = try package.resolvePackage(allocator, pkg_name, is_shell);
            defer package.freeResolvedPackage(allocator, resolved);
            const path = try package.downloadAndCachePackage(allocator, resolved, is_shell, true, merged_args.local_xxh_home);
            allocator.free(path);
        }
        package_op_performed = true;
    }

    if (merged_args.remove_xxh_packages.items.len > 0) {
        var base_dir: []const u8 = undefined;
        if (merged_args.local_xxh_home) |lh| {
            base_dir = try config.resolvePath(allocator, lh);
        } else {
            const home = config.getHomeDir(allocator) orelse return error.HomeDirNotFound;
            defer allocator.free(home);
            base_dir = try std.fs.path.join(allocator, &.{ home, ".zzh" });
        }
        defer allocator.free(base_dir);

        for (merged_args.remove_xxh_packages.items) |pkg_name| {
            const is_shell = std.mem.indexOf(u8, pkg_name, "-shell-") != null;
            const sub_dir = if (is_shell) "shells" else "plugins";
            const resolved = try package.resolvePackage(allocator, pkg_name, is_shell);
            defer package.freeResolvedPackage(allocator, resolved);

            const target_dir = try std.fs.path.join(allocator, &.{ base_dir, ".zzh", sub_dir, resolved.clean_name });
            defer allocator.free(target_dir);

            std.fs.deleteTreeAbsolute(target_dir) catch {};
            std.debug.print("Removed {s}\n", .{resolved.clean_name});
        }
        package_op_performed = true;
    }

    if (merged_args.has_list_xxh_packages) {
        try listPackages(allocator, merged_args.local_xxh_home, merged_args.list_xxh_packages.items);
        return;
    }

    if (merged_args.list_shells) {
        try listShellsOrPlugins(allocator, merged_args.local_xxh_home, "shells");
        return;
    }

    if (merged_args.list_plugins) {
        try listShellsOrPlugins(allocator, merged_args.local_xxh_home, "plugins");
        return;
    }

    if (merged_args.destination == null) {
        if (package_op_performed) {
            return;
        } else {
            std.debug.print("Usage: zzh [ssh arguments] [user@]host[:port] [zzh arguments]\n", .{});
            std.process.exit(1);
        }
    }

    // 5. Override ssh User (-l) or Port (-p) from the destination URL if specified
    const dest_info = cli.parseDestination(merged_args.destination.?);
    if (dest_info.user) |u| {
        if (merged_args.ssh_login) |old| allocator.free(old);
        merged_args.ssh_login = try allocator.dupe(u8, u);
    }
    if (dest_info.port) |p| {
        if (merged_args.ssh_port) |old| allocator.free(old);
        merged_args.ssh_port = try allocator.dupe(u8, p);
    }

    // 6. Resolve and download shell package
    const shell_name = merged_args.shell orelse "zsh";
    const resolved_shell = try package.resolvePackage(allocator, shell_name, true);
    defer package.freeResolvedPackage(allocator, resolved_shell);

    const shell_path = try package.downloadAndCachePackage(allocator, resolved_shell, true, merged_args.install_force, merged_args.local_xxh_home);
    defer allocator.free(shell_path);

    // 7. Resolve and download plugin packages
    var plugin_paths = std.ArrayList([]const u8).init(allocator);
    defer {
        for (plugin_paths.items) |p| allocator.free(p);
        plugin_paths.deinit();
    }

    for (merged_args.plugins.items) |plugin_name| {
        const resolved_plugin = try package.resolvePackage(allocator, plugin_name, false);
        defer package.freeResolvedPackage(allocator, resolved_plugin);

        const plugin_path = try package.downloadAndCachePackage(allocator, resolved_plugin, false, merged_args.install_force, merged_args.local_xxh_home);
        try plugin_paths.append(plugin_path);
    }

    // 8. Bundle payload
    const bundle = try bundler.buildPayload(allocator, shell_path, plugin_paths.items);
    defer bundler.cleanupBundle(allocator, bundle);

    // 9. Deploy and connect
    try deploy.deployAndConnect(allocator, &merged_args, bundle.archive_path);
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test {
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = @import("package.zig");
    _ = @import("bundler.zig");
    _ = @import("deploy.zig");
    _ = @import("integration.zig");
}
