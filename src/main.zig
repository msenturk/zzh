const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const package = @import("package.zig");
const bundler = @import("bundler.zig");
const deploy = @import("deploy.zig");

fn listPackages(allocator: std.mem.Allocator, local_zzh_home: ?[]const u8, filter_packages: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    var base_dir: []const u8 = undefined;
    if (local_zzh_home) |lh| {
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

fn listShellsOrPlugins(allocator: std.mem.Allocator, local_zzh_home: ?[]const u8, sub: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    var base_dir: []const u8 = undefined;
    if (local_zzh_home) |lh| {
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

fn printHelp() void {
    const stdout = std.io.getStdOut().writer();
    stdout.print(
        \\Usage: zzh [ssh arguments] [user@]host[:port] [zzh arguments]
        \\
        \\Bring your favorite shell wherever you go through the ssh.
        \\
        \\Examples:
        \\  zzh user@host +s zsh                            # Connect with zsh
        \\  zzh user@host +s nu +p nu-polars                # Connect with nushell and polars plugin
        \\  zzh -i id_rsa -p 2222 user@host +s fish         # Connect using specific key and port
        \\
        \\Arguments:
        \\  [user@]host[:port]       Destination host (e.g. root@192.168.1.5:2222)
        \\
        \\SSH Arguments:
        \\  -p, -l, -i, -J, -o       Standard SSH arguments (Port, Login, IdentityFile, ProxyJump, Options)
        \\  Any other -flag          Passed natively to the ssh command
        \\
        \\zzh Arguments:
        \\  -h, --help               Print this beautiful help message
        \\  +s, ++shell <name>       Shell to use (e.g. zsh, fish, nu, xonsh)
        \\  +p, ++plugin <name>      Plugin to install and load (e.g. zsh-autosuggestions)
        \\  +i, ++install            Force install packages without connecting
        \\  +if, ++install-force     Force re-download packages
        \\  +xc, ++zzh-config <path> Path to config.zzhc file
        \\  +e, ++env <NAME=VAL>     Set environment variable on host
        \\  +eb, ++envb <NAME=B64>   Set base64 encoded environment variable
        \\  +P, ++password <pass>    SSH password (use ++password-prompt for secure prompt)
        \\
        \\Package Management:
        \\  +I, ++install-zzh-packages <pkg>   Install package locally (use 'tmux' for portable tmux)
        \\  +L, ++list-zzh-packages            List installed packages
        \\  +RI, ++reinstall-zzh-packages      Reinstall package
        \\  +R, ++remove-zzh-packages          Remove package
        \\  +LS, ++list-shells                 List installed shells
        \\  +LP, ++list-plugins                List installed plugins
        \\  ++update                           Update all cached packages (git pull)
        \\  ++tmux                             Attach to (or create) a tmux session on remote
        \\  ++tmux-session <name>              Tmux session name (default: zzh)
        \\  +d, ++dotfile <file>               Sync dotfile to remote home
        \\
        \\Host Execution:
        \\  +hc, ++host-execute-command <cmd>  Run a command on host and exit
        \\  +hf, ++host-execute-file <file>    Run a local file script on host and exit
        \\  +heb, ++host-execute-bash <b64>    Run base64 bash command on host
        \\
        \\For more details, visit: https://github.com/msenturk/zzh
        \\
    , .{}) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_it_initial = try std.process.argsWithAllocator(allocator);
    _ = args_it_initial.next(); // skip exe name
    if (args_it_initial.next()) |first_arg| {
        if (std.mem.eql(u8, first_arg, "--internal-setsid")) {
            const builtin = @import("builtin");
            if (builtin.os.tag == .linux) {
                _ = std.os.linux.syscall0(.setsid);
            } else if (builtin.os.tag != .windows) {
                const posix_setsid = struct {
                    extern "c" fn setsid() i32;
                }.setsid;
                _ = posix_setsid();
            }

            var exec_argv = std.ArrayList([]const u8).init(allocator);
            defer exec_argv.deinit();

            while (args_it_initial.next()) |arg| {
                try exec_argv.append(try allocator.dupe(u8, arg));
            }

            if (exec_argv.items.len > 0) {
                if (builtin.os.tag != .windows) {
                    return std.process.execv(allocator, exec_argv.items);
                } else {
                    unreachable;
                }
            } else {
                std.process.exit(1);
            }
        }
    }
    args_it_initial.deinit();

    // Check if we are being invoked as an internal SSH_ASKPASS provider
    if (std.process.getEnvVarOwned(allocator, "ZZH_INTERNAL_ASKPASS")) |askpass| {
        defer allocator.free(askpass);
        if (std.mem.eql(u8, askpass, "1")) {
            if (std.process.getEnvVarOwned(allocator, "ZZH_INTERNAL_PASSWORD")) |pwd| {
                defer allocator.free(pwd);
                const stdout = std.io.getStdOut().writer();
                stdout.writeAll(pwd) catch {};
                stdout.writeAll("\n") catch {};
                std.process.exit(0);
            } else |_| {
                std.process.exit(1);
            }
        }
    } else |_| {}

    // 1. Parse CLI arguments first to locate the target host and config path
    var cli_args_only = try cli.parseArgs(allocator);
    defer cli_args_only.deinit();

    if (cli_args_only.help) {
        printHelp();
        return;
    }

    // Check if we are performing a local packages operation
    const has_local_ops_only = cli_args_only.destination == null and (
        cli_args_only.has_list_zzh_packages or
        cli_args_only.list_shells or
        cli_args_only.list_plugins or
        cli_args_only.install_zzh_packages.items.len > 0 or
        cli_args_only.reinstall_zzh_packages.items.len > 0 or
        cli_args_only.remove_zzh_packages.items.len > 0 or
        cli_args_only.update_packages
    );

    if (cli_args_only.destination == null and !has_local_ops_only) {
        printHelp();
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
    var merged_args = cli.ZzhArgs.init(allocator);
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
    if (merged_args.install_zzh_packages.items.len > 0) {
        for (merged_args.install_zzh_packages.items) |pkg_name| {
            // tmux is a special standalone binary, not a git repo
            if (std.mem.eql(u8, pkg_name, "tmux") or std.mem.eql(u8, pkg_name, "bin-tmux")) {
                const tmux_path = try package.downloadTmux(allocator, merged_args.install_force, merged_args.local_zzh_home);
                allocator.free(tmux_path);
                package_op_performed = true;
                continue;
            }
            const is_shell = std.mem.indexOf(u8, pkg_name, "-shell-") != null;
            const resolved = try package.resolvePackage(allocator, pkg_name, is_shell);
            defer package.freeResolvedPackage(allocator, resolved);
            const path = try package.downloadAndCachePackage(allocator, resolved, is_shell, merged_args.install_force, merged_args.local_zzh_home);
            allocator.free(path);
        }
        package_op_performed = true;
    }

    if (merged_args.update_packages) {
        try package.updatePackages(allocator, merged_args.local_zzh_home);
        package_op_performed = true;
    }

    if (merged_args.reinstall_zzh_packages.items.len > 0) {
        for (merged_args.reinstall_zzh_packages.items) |pkg_name| {
            const is_shell = std.mem.indexOf(u8, pkg_name, "-shell-") != null;
            const resolved = try package.resolvePackage(allocator, pkg_name, is_shell);
            defer package.freeResolvedPackage(allocator, resolved);
            const path = try package.downloadAndCachePackage(allocator, resolved, is_shell, true, merged_args.local_zzh_home);
            allocator.free(path);
        }
        package_op_performed = true;
    }

    if (merged_args.remove_zzh_packages.items.len > 0) {
        var base_dir: []const u8 = undefined;
        if (merged_args.local_zzh_home) |lh| {
            base_dir = try config.resolvePath(allocator, lh);
        } else {
            const home = config.getHomeDir(allocator) orelse return error.HomeDirNotFound;
            defer allocator.free(home);
            base_dir = try std.fs.path.join(allocator, &.{ home, ".zzh" });
        }
        defer allocator.free(base_dir);

        for (merged_args.remove_zzh_packages.items) |pkg_name| {
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

    if (merged_args.has_list_zzh_packages) {
        try listPackages(allocator, merged_args.local_zzh_home, merged_args.list_zzh_packages.items);
        return;
    }

    if (merged_args.list_shells) {
        try listShellsOrPlugins(allocator, merged_args.local_zzh_home, "shells");
        return;
    }

    if (merged_args.list_plugins) {
        try listShellsOrPlugins(allocator, merged_args.local_zzh_home, "plugins");
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

    const shell_path = try package.downloadAndCachePackage(allocator, resolved_shell, true, merged_args.install_force, merged_args.local_zzh_home);
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

        const plugin_path = try package.downloadAndCachePackage(allocator, resolved_plugin, false, merged_args.install_force, merged_args.local_zzh_home);
        try plugin_paths.append(plugin_path);
    }

    // Check if we need to prompt for a password preemptively
    if (merged_args.password == null) {
        if (!try deploy.checkPasswordless(allocator, &merged_args)) {
            var prompt_buf: [256]u8 = undefined;
            const prompt = try std.fmt.bufPrint(&prompt_buf, "{s}'s password: ", .{merged_args.destination.?});
            const pwd = try cli.readPassword(allocator, prompt);
            merged_args.password = pwd;
        }
    }

    // 8. Bundle payload
    const bundle = try bundler.buildPayload(allocator, shell_path, plugin_paths.items, &merged_args);
    defer bundler.cleanupBundle(allocator, bundle);

    // 9. Deploy and connect
    try deploy.deployAndConnect(allocator, &merged_args, bundle.archive_path, bundle.temp_build_dir);
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
