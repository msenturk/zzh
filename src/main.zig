const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const package = @import("package.zig");
const bundler = @import("bundler.zig");
const deploy = @import("deploy.zig");
const builtin = @import("builtin");

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

/// Lists all custom static binaries installed locally.
fn listBinaries(allocator: std.mem.Allocator, custom_zzh_home: ?[]const u8) !void {
        var resolved_zzh_root: []const u8 = undefined;
    if (custom_zzh_home) |lh| {
        resolved_zzh_root = try config.expandUserPath(allocator, lh);
    } else {
        const home_dir = config.discoverUserHomeDirectory(allocator) orelse return error.HomeDirNotFound;
        defer allocator.free(home_dir);
        resolved_zzh_root = try std.fs.path.join(allocator, &.{ home_dir, ".zzh" });
    }
    defer allocator.free(resolved_zzh_root);

    const binary_directory_path = try std.fs.path.join(allocator, &.{ resolved_zzh_root, "bin" });
    defer allocator.free(binary_directory_path);

    var temp_io1 = std.Io.Threaded.init(allocator, .{});
    defer temp_io1.deinit();
    var binary_directory = std.Io.Dir.openDirAbsolute(temp_io1.io(), binary_directory_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer binary_directory.close(temp_io1.io());

    var directory_iterator = binary_directory.iterate();
    while (try directory_iterator.next(temp_io1.io())) |file_entry| {
        if (file_entry.kind != .directory) {
            std.debug.print("{s}\n", .{file_entry.name});
        }
    }
}

/// Lists all shells or plugins matching a filter set.
fn listPackages(allocator: std.mem.Allocator, custom_zzh_home: ?[]const u8, package_filter_list: []const []const u8) !void {
        var resolved_zzh_root: []const u8 = undefined;
    if (custom_zzh_home) |lh| {
        resolved_zzh_root = try config.expandUserPath(allocator, lh);
    } else {
        const home_dir = config.discoverUserHomeDirectory(allocator) orelse return error.HomeDirNotFound;
        defer allocator.free(home_dir);
        resolved_zzh_root = try std.fs.path.join(allocator, &.{ home_dir, ".zzh" });
    }
    defer allocator.free(resolved_zzh_root);

    const category_folders = [_][]const u8{ "shells", "plugins" };
    for (category_folders) |sub| {
        const target_category_path = try std.fs.path.join(allocator, &.{ resolved_zzh_root, ".zzh", sub });
        defer allocator.free(target_category_path);

        var temp_io2 = std.Io.Threaded.init(allocator, .{});
        defer temp_io2.deinit();
        var category_directory = std.Io.Dir.openDirAbsolute(temp_io2.io(), target_category_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
        defer category_directory.close(temp_io2.io());

        var directory_iterator = category_directory.iterate();
        while (try directory_iterator.next(temp_io2.io())) |folder_entry| {
            if (folder_entry.kind == .directory and std.mem.startsWith(u8, folder_entry.name, "xxh-")) {
                if (package_filter_list.len > 0) {
                    var matches_filter = false;
                    for (package_filter_list) |filter_item| {
                        if (std.mem.eql(u8, folder_entry.name, filter_item)) {
                            matches_filter = true;
                            break;
                        }
                    }
                    if (matches_filter) {
                        std.debug.print("{s}\n", .{folder_entry.name});
                    }
                } else {
                    std.debug.print("{s}\n", .{folder_entry.name});
                }
            }
        }
    }
}

/// Helper function to list all subfolders for a specific categories (shells or plugins).
fn listShellsOrPlugins(allocator: std.mem.Allocator, custom_zzh_home: ?[]const u8, category_name: []const u8) !void {
        var resolved_zzh_root: []const u8 = undefined;
    if (custom_zzh_home) |lh| {
        resolved_zzh_root = try config.expandUserPath(allocator, lh);
    } else {
        const home_dir = config.discoverUserHomeDirectory(allocator) orelse return error.HomeDirNotFound;
        defer allocator.free(home_dir);
        resolved_zzh_root = try std.fs.path.join(allocator, &.{ home_dir, ".zzh" });
    }
    defer allocator.free(resolved_zzh_root);

    const category_directory_path = try std.fs.path.join(allocator, &.{ resolved_zzh_root, ".zzh", category_name });
    defer allocator.free(category_directory_path);

    var temp_io3 = std.Io.Threaded.init(allocator, .{});
    defer temp_io3.deinit();
    var category_directory = std.Io.Dir.openDirAbsolute(temp_io3.io(), category_directory_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer category_directory.close(temp_io3.io());

    var directory_iterator = category_directory.iterate();
    while (try directory_iterator.next(temp_io3.io())) |folder_entry| {
        if (folder_entry.kind == .directory and std.mem.startsWith(u8, folder_entry.name, "xxh-")) {
            std.debug.print("{s}\n", .{folder_entry.name});
        }
    }
}

/// Renders the zzh usage instructions.
fn printHelp() void {
    std.debug.print(
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
        \\  +iff, ++install-force-full Force re-download and wipe existing staged home
        \\  +xc, ++zzh-config <path> Path to config.zzhc file
        \\  ++config-init            Scaffold a default config.zzhc file in ~/.config/zzh/
        \\  +e, ++env <NAME=VAL>     Set environment variable on host
        \\  +eb, ++envb <NAME=B64>   Set base64 encoded environment variable
        \\  +P, ++password <pass>    SSH password (use ++password-prompt for secure prompt)
        \\  ++debug, --debug         Show debug logs and force verbose mode
        \\  ++time, --time           Show timing breakdown for each phase
        \\
        \\Package Management:
        \\  +I, ++install-zzh-packages <pkg>   Install package locally (use 'tmux' for portable tmux)
        \\  +L, ++list-zzh-packages            List installed packages
        \\  +RI, ++reinstall-zzh-packages      Reinstall package
        \\  +R, ++remove-zzh-packages          Remove package
        \\  +b, ++binary <repo>                Install static binary from GitHub releases
        \\  +LB, ++list-binaries               List installed static binaries
        \\  +LS, ++list-shells                 List installed shells
        \\  +LP, ++list-plugins                List installed plugins
        \\  ++update                           Update all cached packages (git pull)
        \\  ++tmux                             Attach to (or create) a tmux session on remote (default)
        \\  ++no-tmux                          Disable tmux wrapping for the session
        \\  ++tmux-session <name>              Tmux session name (default: zzh)
        \\  +d, ++dotfile <file[:name]>        Sync local dotfile to remote home (supports renaming)
        \\
        \\Advanced Configuration:
        \\  +lh, ++local-zzh-home <path>       Override local zzh home directory (~/.zzh)
        \\  +hh, ++host-zzh-home <path>        Override remote zzh home directory (~/.zzh)
        \\  +hhr, ++host-zzh-home-remove       Ephemeral mode: automatically remove payload from remote after disconnect
        \\  +hhh, ++host-home <path>           Override remote user home directory (~/)
        \\  +hhx, ++host-home-xdg <path>       Override remote XDG config home directory
        \\  +ES, ++extract-sourcing-files      Extract shell-specific initialization scripts
        \\  ++pexpect-timeout <sec>            Timeout for interactive terminal automation
        \\  ++copy-method <method>             Method to copy payload (tar, rsync, scp)
        \\  ++scp-command <cmd>                Custom scp command to use
        \\  ++pexpect-disable                  Disable interactive terminal automation helper
        \\
        \\Host Execution:
        \\  +hc, ++host-execute-command <cmd>  Run a command on host and exit
        \\  +hf, ++host-execute-file <file>    Run a local file script on host and exit
        \\  +heb, ++host-execute-bash <b64>    Run base64 bash command on host
        \\
        \\For more details, visit: https://github.com/msenturk/zzh
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    config.global_environ = init.minimal.environ;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_list = std.ArrayList([]const u8).empty;
    defer {
        for (args_list.items) |arg| allocator.free(arg);
        args_list.deinit(allocator);
    }

    {
        var unfiltered_arguments = try init.minimal.args.iterateAllocator(allocator);
        defer unfiltered_arguments.deinit();
        _ = unfiltered_arguments.next(); // Skip executable path token.
        while (unfiltered_arguments.next()) |arg| {
            try args_list.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    // We intercept `--internal-setsid` calls to cleanly spawn child terminals
    // within their own session process group (preventing HUP signal propagation on Linux targets).
    if (args_list.items.len > 0 and std.mem.eql(u8, args_list.items[0], "--internal-setsid")) {
        if (builtin.os.tag == .linux) {
            _ = std.os.linux.syscall0(.setsid);
        } else if (builtin.os.tag != .windows) {
            const posix_setsid = struct {
                extern "c" fn setsid() i32;
            }.setsid;
            _ = posix_setsid();
        }

        var setsid_exec_arguments = std.ArrayList([]const u8).empty;
        defer setsid_exec_arguments.deinit(allocator);

        if (args_list.items.len > 1) {
            try setsid_exec_arguments.appendSlice(allocator, args_list.items[1..]);
            if (builtin.os.tag != .windows) {
                var th_io_exec: std.Io.Threaded = .init(allocator, .{});
                defer th_io_exec.deinit();
                return std.process.replace(th_io_exec.io(), .{ .argv = setsid_exec_arguments.items });
            } else {
                unreachable;
            }
        } else {
            std.process.exit(1);
        }
    }

    // Check if we are being invoked as an internal SSH_ASKPASS provider.
    // SSH uses this protocol to dynamically prompt for passwords when running without a control terminal.
    if (init.minimal.environ.getAlloc(allocator, "ZZH_INTERNAL_ASKPASS")) |askpass_env| {
        defer allocator.free(askpass_env);
        if (std.mem.eql(u8, askpass_env, "1")) {
            if (init.minimal.environ.getAlloc(allocator, "ZZH_INTERNAL_PASSWORD")) |stored_password| {
                defer allocator.free(stored_password);
                var temp_io = std.Io.Threaded.init(allocator, .{});
                defer temp_io.deinit();
                std.Io.File.writeStreamingAll(std.Io.File.stdout(), temp_io.io(), stored_password) catch {};
                std.Io.File.writeStreamingAll(std.Io.File.stdout(), temp_io.io(), "\n") catch {};
                std.process.exit(0);
            } else |_| {
                std.process.exit(1);
            }
        }
    } else |_| {}

    // Parse command line options to detect config paths and operational parameters.
    var preliminary_arguments = cli.OperationalConfig.init(allocator);
    defer preliminary_arguments.deinit(allocator);
    try cli.populateConfigFromTokens(allocator, args_list.items, &preliminary_arguments);

    if (preliminary_arguments.help) {
        printHelp();
        return;
    }

    if (preliminary_arguments.config_init) {
        try config.initializeDefaultConfigurationFile(allocator, null);
        return;
    }

    const is_offline_package_management = preliminary_arguments.destination == null and (preliminary_arguments.has_list_zzh_packages or
        preliminary_arguments.list_shells or
        preliminary_arguments.list_plugins or
        preliminary_arguments.list_binaries or
        preliminary_arguments.install_zzh_packages.items.len > 0 or
        preliminary_arguments.reinstall_zzh_packages.items.len > 0 or
        preliminary_arguments.remove_zzh_packages.items.len > 0 or
        preliminary_arguments.update_packages);

    if (preliminary_arguments.destination == null and !is_offline_package_management) {
        printHelp();
        std.process.exit(1);
    }

    var resolved_configuration_options = std.ArrayList([]const u8).empty;
    defer {
        for (resolved_configuration_options.items) |item| allocator.free(item);
        resolved_configuration_options.deinit(allocator);
    }

    if (preliminary_arguments.destination) |destination_uri| {
        const destination_endpoint = cli.parseConnectionEndpoint(destination_uri);
        const config_path_raw = preliminary_arguments.config_path orelse "~/.config/zzh/config.zzhc";
        const config_path = try config.expandUserPath(allocator, config_path_raw);
        defer allocator.free(config_path);

        config.readAndParseConfigurationFile(allocator, config_path, destination_endpoint.host, &resolved_configuration_options) catch |err| {
            std.debug.print("Warning: Failed to parse config file: {}\n", .{err});
        };
    }

    // Merge arguments: Config file arguments first, then command-line arguments to allow overriding.
    var operational_settings = cli.OperationalConfig.init(allocator);
    defer operational_settings.deinit(allocator);

    try cli.populateConfigFromTokens(allocator, resolved_configuration_options.items, &operational_settings);

    try cli.populateConfigFromTokens(allocator, args_list.items, &operational_settings);

    // Perform any package management requests.
    var completed_offline_action = false;
    if (operational_settings.install_zzh_packages.items.len > 0) {
        for (operational_settings.install_zzh_packages.items) |pkg_name| {
            if (std.mem.eql(u8, pkg_name, "tmux") or std.mem.eql(u8, pkg_name, "bin-tmux")) {
                const local_arch = switch (@import("builtin").cpu.arch) {
                    .x86_64 => "x86_64",
                    .aarch64 => "aarch64",
                    else => "x86_64",
                };
                const tmux_path = try package.provisionStaticallyCompiledTmux(
                    allocator,
                    operational_settings.install_force,
                    operational_settings.local_zzh_home,
                    local_arch,
                );
                allocator.free(tmux_path);
                completed_offline_action = true;
                continue;
            }
            const is_shell = std.mem.indexOf(u8, pkg_name, "-shell-") != null;
            const package_vitals = try package.fetchPackageVitals(allocator, pkg_name, is_shell);
            defer package.releasePackageVitals(allocator, package_vitals);
            const path = try package.obtainAndCachePackage(allocator, package_vitals, is_shell, operational_settings.install_force, operational_settings.local_zzh_home);
            allocator.free(path);
        }
        completed_offline_action = true;
    }

    if (operational_settings.update_packages) {
        try package.refreshCachedRepositories(allocator, operational_settings.local_zzh_home);
        completed_offline_action = true;
    }

    if (operational_settings.reinstall_zzh_packages.items.len > 0) {
        for (operational_settings.reinstall_zzh_packages.items) |pkg_name| {
            const is_shell = std.mem.indexOf(u8, pkg_name, "-shell-") != null;
            const package_vitals = try package.fetchPackageVitals(allocator, pkg_name, is_shell);
            defer package.releasePackageVitals(allocator, package_vitals);
            const path = try package.obtainAndCachePackage(allocator, package_vitals, is_shell, true, operational_settings.local_zzh_home);
            allocator.free(path);
        }
        completed_offline_action = true;
    }

    if (operational_settings.remove_zzh_packages.items.len > 0) {
        var resolved_zzh_root: []const u8 = undefined;
        if (operational_settings.local_zzh_home) |lh| {
            resolved_zzh_root = try config.expandUserPath(allocator, lh);
        } else {
            const home_dir = config.discoverUserHomeDirectory(allocator) orelse return error.HomeDirNotFound;
            defer allocator.free(home_dir);
            resolved_zzh_root = try std.fs.path.join(allocator, &.{ home_dir, ".zzh" });
        }
        defer allocator.free(resolved_zzh_root);

        for (operational_settings.remove_zzh_packages.items) |pkg_name| {
            var deleted = false;

            const is_shell = std.mem.indexOf(u8, pkg_name, "-shell-") != null;
            const category_dir = if (is_shell) "shells" else "plugins";
            const package_vitals = try package.fetchPackageVitals(allocator, pkg_name, is_shell);
            defer package.releasePackageVitals(allocator, package_vitals);

            const package_install_path = try std.fs.path.join(allocator, &.{ resolved_zzh_root, ".zzh", category_dir, package_vitals.clean_name });
            defer allocator.free(package_install_path);

            var package_directory_exists = false;
            var temp_io4 = std.Io.Threaded.init(allocator, .{});
            defer temp_io4.deinit();
            if (std.Io.Dir.openDirAbsolute(temp_io4.io(), package_install_path, .{})) |d| {
                package_directory_exists = true;
                var mutable_d = d;
                mutable_d.close(temp_io4.io());
            } else |_| {}

            if (package_directory_exists) {
                pathDeleteTreeAbsolute(allocator, package_install_path) catch {};
                std.debug.print("Removed package {s}\n", .{package_vitals.clean_name});
                deleted = true;
            }

            const binary_install_path = try std.fs.path.join(allocator, &.{ resolved_zzh_root, "bin", pkg_name });
            defer allocator.free(binary_install_path);
            var binary_file_exists = false;
            if (std.Io.Dir.accessAbsolute(temp_io4.io(), binary_install_path, .{})) |_| {
                binary_file_exists = true;
            } else |_| {}

            if (binary_file_exists) {
                pathDeleteFileAbsolute(allocator, binary_install_path) catch {};
                std.debug.print("Removed binary {s}\n", .{pkg_name});
                deleted = true;
            }

            if (!deleted) {
                std.debug.print("Package/binary '{s}' not found\n", .{pkg_name});
            }
        }
        completed_offline_action = true;
    }

    if (operational_settings.has_list_zzh_packages) {
        try listPackages(allocator, operational_settings.local_zzh_home, operational_settings.list_zzh_packages.items);
        return;
    }

    if (operational_settings.list_shells) {
        try listShellsOrPlugins(allocator, operational_settings.local_zzh_home, "shells");
        return;
    }

    if (operational_settings.list_plugins) {
        try listShellsOrPlugins(allocator, operational_settings.local_zzh_home, "plugins");
        return;
    }

    if (operational_settings.list_binaries) {
        try listBinaries(allocator, operational_settings.local_zzh_home);
        return;
    }

    if (operational_settings.destination == null) {
        if (completed_offline_action) {
            return;
        } else {
            std.debug.print("{s}", .{"Usage: zzh [ssh arguments] [user@]host[:port] [zzh arguments]\n"});
            std.process.exit(1);
        }
    }

    // Override SSH User (-l) or Port (-p) from the destination connection endpoint if specified.
    const destination_endpoint = cli.parseConnectionEndpoint(operational_settings.destination.?);
    if (destination_endpoint.user) |u| {
        if (operational_settings.ssh_login) |old| allocator.free(old);
        operational_settings.ssh_login = try allocator.dupe(u8, u);
    }
    if (destination_endpoint.port) |p| {
        if (operational_settings.ssh_port) |old| allocator.free(old);
        operational_settings.ssh_port = try allocator.dupe(u8, p);
    }

    // [1/4] Resolving packages...
    std.debug.print("{s}", .{"[1/4] Resolving packages...\n"});
    const shell_name = operational_settings.shell orelse "zsh";
    std.debug.print("      - Shell: {s} (xxh-shell-{s})\n", .{ shell_name, shell_name });
    for (operational_settings.plugins.items) |plugin_name| {
        std.debug.print("      - Plugins: {s}\n", .{plugin_name});
    }
    for (operational_settings.binaries.items) |repo| {
        std.debug.print("      - Binaries: {s}\n", .{repo});
    }
    for (operational_settings.dotfiles.items) |dotfile| {
        std.debug.print("      - Dotfile: {s}\n", .{dotfile});
    }
    if (operational_settings.dotfiles.items.len == 0 and !operational_settings.quiet) {
        std.debug.print("{s}", .{"      - Note: No dotfiles configured. " ++
            "Add '+d ~/.bashrc' or set dotfiles in config.zzhc\n"});
    }

    const resolved_shell = try package.fetchPackageVitals(allocator, shell_name, true);
    defer package.releasePackageVitals(allocator, resolved_shell);

    // [2/4] Downloading & caching...
    std.debug.print("{s}", .{"[2/4] Downloading & caching...\n"});

    const cached_shell_directory = try package.obtainAndCachePackage(allocator, resolved_shell, true, operational_settings.install_force, operational_settings.local_zzh_home);
    defer allocator.free(cached_shell_directory);

    var cached_plugin_directories = std.ArrayList([]const u8).empty;
    defer {
        for (cached_plugin_directories.items) |p| allocator.free(p);
        cached_plugin_directories.deinit(allocator);
    }

    for (operational_settings.plugins.items) |plugin_name| {
        const resolved_plugin = try package.fetchPackageVitals(allocator, plugin_name, false);
        defer package.releasePackageVitals(allocator, resolved_plugin);

        const plugin_path = try package.obtainAndCachePackage(allocator, resolved_plugin, false, operational_settings.install_force, operational_settings.local_zzh_home);
        try cached_plugin_directories.append(allocator, plugin_path);
    }

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();

    // Query for user password securely on Windows before launching connections
    // if passwordless access fails and no password was passed on the command line.
    // On Unix, SSH multiplexing is enabled, so we can let SSH prompt natively
    // once and reuse the connection, avoiding the extra check handshake latency.
    if (builtin.os.tag == .windows and operational_settings.password == null) {
        if (!try deploy.checkPasswordless(allocator, &operational_settings, threaded_io.io())) {
            var prompt_buffer: [256]u8 = undefined;
            const user_prompt = try std.fmt.bufPrint(&prompt_buffer, "{s}'s password: ", .{operational_settings.destination.?});
            const input_password = try cli.readMaskedPasswordFromTerminal(allocator, user_prompt);
            operational_settings.password = input_password;
        }
    }

    try deploy.deployAndConnect(
        allocator,
        &operational_settings,
        cached_shell_directory,
        cached_plugin_directories.items,
        threaded_io.io(),
    );
}

test "simple test" {
    var list = std.ArrayList(i32).empty;
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, 42);
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
