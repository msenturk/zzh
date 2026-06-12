const std = @import("std");

pub const DestinationInfo = struct {
    user: ?[]const u8 = null,
    host: []const u8,
    port: ?[]const u8 = null,
};

pub fn parseDestination(dest: []const u8) DestinationInfo {
    var raw = dest;
    if (std.mem.indexOf(u8, raw, "://")) |idx| {
        raw = raw[idx + 3 ..];
    }

    var user: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, raw, '@')) |idx| {
        user = raw[0..idx];
        raw = raw[idx + 1 ..];
    }

    var host: []const u8 = undefined;
    var port: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, raw, ':')) |idx| {
        host = raw[0..idx];
        port = raw[idx + 1 ..];
    } else {
        host = raw;
    }

    return .{
        .user = user,
        .host = host,
        .port = port,
    };
}

pub const ZzhArgs = struct {
    // xxh shell & plugins
    shell: ?[]const u8 = null,
    plugins: std.ArrayList([]const u8), // +I, ++install-plugin, ++install-zzh-packages
    env: std.ArrayList([]const u8), // +e, ++env
    envb: std.ArrayList([]const u8), // +eb, ++envb
    
    // config & home paths
    config_path: ?[]const u8 = null, // +xc, ++zzh-config, ++config
    local_zzh_home: ?[]const u8 = null, // +lh, ++local-zzh-home
    host_zzh_home: ?[]const u8 = null, // +hh, ++host-zzh-home
    host_zzh_home_remove: bool = false, // +hhr, ++host-zzh-home-remove
    host_home: ?[]const u8 = null, // +hhh, ++host-home
    host_home_xdg: ?[]const u8 = null, // +hhx, ++host-home-xdg
    
    // installation control
    install: bool = false, // +i, ++install
    install_force: bool = false, // +if, ++install-force
    install_force_full: bool = false, // +iff, ++install-force-full
    
    // execution command control
    host_execute_file: ?[]const u8 = null, // +hf, ++host-execute-file
    host_execute_command: ?[]const u8 = null, // +hc, ++host-execute-command
    host_execute_bash: std.ArrayList([]const u8), // +heb, ++host-execute-bash
    
    // logging & verbosity
    verbose: bool = false, // +v, ++verbose
    vverbose: bool = false, // +vv, ++vverbose
    quiet: bool = false, // +q, ++quiet
    
    // package operations
    install_zzh_packages: std.ArrayList([]const u8), // +I, ++install-zzh-packages
    list_zzh_packages: std.ArrayList([]const u8), // +L, ++list-zzh-packages
    has_list_zzh_packages: bool = false, // True if +L/++list-zzh-packages is specified
    reinstall_zzh_packages: std.ArrayList([]const u8), // +RI, ++reinstall-zzh-packages
    remove_zzh_packages: std.ArrayList([]const u8), // +R, ++remove-zzh-packages
    list_shells: bool = false, // +LS, +list-shells
    list_plugins: bool = false, // +LP, +list-plugins
    extract_sourcing_files: bool = false, // +ES, ++extract-sourcing-files
    
    // ssh & connection params
    ssh_port: ?[]const u8 = null, // -p
    ssh_login: ?[]const u8 = null, // -l
    ssh_private_key: ?[]const u8 = null, // -i
    ssh_jump_host: ?[]const u8 = null, // -J
    ssh_options: std.ArrayList([]const u8), // -o
    ssh_command: ?[]const u8 = null, // +c, ++ssh-command
    password: ?[]const u8 = null, // +P, ++password
    password_prompt: bool = false, // +PP, ++password-prompt
    
    // tuning
    pexpect_timeout: ?[]const u8 = null, // ++pexpect-timeout
    copy_method: ?[]const u8 = null, // ++copy-method
    scp_command: ?[]const u8 = null, // ++scp-command
    pexpect_disable: bool = false, // ++pexpect-disable
    
    // raw target & arguments pass-through
    destination: ?[]const u8 = null,
    ssh_args: std.ArrayList([]const u8), // other unparsed ssh args
    help: bool = false, // -h, --help
    debug: bool = false, // ++debug
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ZzhArgs {
        return .{
            .plugins = std.ArrayList([]const u8).init(allocator),
            .env = std.ArrayList([]const u8).init(allocator),
            .envb = std.ArrayList([]const u8).init(allocator),
            .host_execute_bash = std.ArrayList([]const u8).init(allocator),
            .install_zzh_packages = std.ArrayList([]const u8).init(allocator),
            .list_zzh_packages = std.ArrayList([]const u8).init(allocator),
            .reinstall_zzh_packages = std.ArrayList([]const u8).init(allocator),
            .remove_zzh_packages = std.ArrayList([]const u8).init(allocator),
            .ssh_options = std.ArrayList([]const u8).init(allocator),
            .ssh_args = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ZzhArgs) void {
        if (self.shell) |s| self.allocator.free(s);
        if (self.config_path) |c| self.allocator.free(c);
        if (self.local_zzh_home) |lh| self.allocator.free(lh);
        if (self.host_zzh_home) |hh| self.allocator.free(hh);
        if (self.host_home) |h| self.allocator.free(h);
        if (self.host_home_xdg) |hx| self.allocator.free(hx);
        if (self.host_execute_file) |f| self.allocator.free(f);
        if (self.host_execute_command) |c| self.allocator.free(c);
        if (self.ssh_port) |p| self.allocator.free(p);
        if (self.ssh_login) |l| self.allocator.free(l);
        if (self.ssh_private_key) |k| self.allocator.free(k);
        if (self.ssh_jump_host) |j| self.allocator.free(j);
        if (self.ssh_command) |c| self.allocator.free(c);
        if (self.password) |p| self.allocator.free(p);
        if (self.pexpect_timeout) |t| self.allocator.free(t);
        if (self.copy_method) |m| self.allocator.free(m);
        if (self.scp_command) |c| self.allocator.free(c);
        if (self.destination) |d| self.allocator.free(d);

        for (self.plugins.items) |p| self.allocator.free(p);
        self.plugins.deinit();
        for (self.env.items) |e| self.allocator.free(e);
        self.env.deinit();
        for (self.envb.items) |e| self.allocator.free(e);
        self.envb.deinit();
        for (self.host_execute_bash.items) |b| self.allocator.free(b);
        self.host_execute_bash.deinit();
        for (self.install_zzh_packages.items) |p| self.allocator.free(p);
        self.install_zzh_packages.deinit();
        for (self.list_zzh_packages.items) |p| self.allocator.free(p);
        self.list_zzh_packages.deinit();
        for (self.reinstall_zzh_packages.items) |p| self.allocator.free(p);
        self.reinstall_zzh_packages.deinit();
        for (self.remove_zzh_packages.items) |p| self.allocator.free(p);
        self.remove_zzh_packages.deinit();
        for (self.ssh_options.items) |o| self.allocator.free(o);
        self.ssh_options.deinit();
        for (self.ssh_args.items) |s| self.allocator.free(s);
        self.ssh_args.deinit();
    }
};

pub fn parseFromSlice(allocator: std.mem.Allocator, args: []const []const u8, zzh_args: *ZzhArgs) !void {
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            zzh_args.help = true;
        } else if (std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.ssh_port) |v| allocator.free(v);
                zzh_args.ssh_port = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "-l")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.ssh_login) |v| allocator.free(v);
                zzh_args.ssh_login = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "-i")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.ssh_private_key) |v| allocator.free(v);
                zzh_args.ssh_private_key = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "-J")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.ssh_jump_host) |v| allocator.free(v);
                zzh_args.ssh_jump_host = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i < args.len) {
                try zzh_args.ssh_options.append(try allocator.dupe(u8, args[i]));
            }
        } else if (std.mem.eql(u8, arg, "+c") or std.mem.eql(u8, arg, "++ssh-command")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.ssh_command) |v| allocator.free(v);
                zzh_args.ssh_command = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "+P") or std.mem.eql(u8, arg, "++password")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.password) |v| allocator.free(v);
                zzh_args.password = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "+PP") or std.mem.eql(u8, arg, "++password-prompt")) {
            zzh_args.password_prompt = true;
        } else if (std.mem.eql(u8, arg, "+i") or std.mem.eql(u8, arg, "++install")) {
            zzh_args.install = true;
        } else if (std.mem.eql(u8, arg, "+if") or std.mem.eql(u8, arg, "++install-force")) {
            zzh_args.install_force = true;
        } else if (std.mem.eql(u8, arg, "+iff") or std.mem.eql(u8, arg, "++install-force-full")) {
            zzh_args.install_force_full = true;
        } else if (std.mem.eql(u8, arg, "+xc") or std.mem.eql(u8, arg, "++zzh-config") or std.mem.eql(u8, arg, "++config")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.config_path) |v| allocator.free(v);
                zzh_args.config_path = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "+e") or std.mem.eql(u8, arg, "++env")) {
            i += 1;
            if (i < args.len) {
                try zzh_args.env.append(try allocator.dupe(u8, args[i]));
            }
        } else if (std.mem.eql(u8, arg, "+eb") or std.mem.eql(u8, arg, "++envb")) {
            i += 1;
            if (i < args.len) {
                try zzh_args.envb.append(try allocator.dupe(u8, args[i]));
            }
        } else if (std.mem.eql(u8, arg, "+lh") or std.mem.eql(u8, arg, "++local-zzh-home")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.local_zzh_home) |v| allocator.free(v);
                zzh_args.local_zzh_home = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "+hh") or std.mem.eql(u8, arg, "++host-zzh-home")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.host_zzh_home) |v| allocator.free(v);
                zzh_args.host_zzh_home = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "+hhr") or std.mem.eql(u8, arg, "++host-zzh-home-remove")) {
            zzh_args.host_zzh_home_remove = true;
        } else if (std.mem.eql(u8, arg, "+hhh") or std.mem.eql(u8, arg, "++host-home")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.host_home) |v| allocator.free(v);
                zzh_args.host_home = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "+hhx") or std.mem.eql(u8, arg, "++host-home-xdg")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.host_home_xdg) |v| allocator.free(v);
                zzh_args.host_home_xdg = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "+hf") or std.mem.eql(u8, arg, "++host-execute-file")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.host_execute_file) |v| allocator.free(v);
                zzh_args.host_execute_file = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "+hc") or std.mem.eql(u8, arg, "++host-execute-command")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.host_execute_command) |v| allocator.free(v);
                zzh_args.host_execute_command = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "+heb") or std.mem.eql(u8, arg, "++host-execute-bash")) {
            i += 1;
            if (i < args.len) {
                try zzh_args.host_execute_bash.append(try allocator.dupe(u8, args[i]));
            }
        } else if (std.mem.eql(u8, arg, "+s") or std.mem.eql(u8, arg, "++shell") or std.mem.eql(u8, arg, "+shell")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.shell) |v| allocator.free(v);
                zzh_args.shell = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "+v") or std.mem.eql(u8, arg, "++verbose")) {
            zzh_args.verbose = true;
        } else if (std.mem.eql(u8, arg, "+vv") or std.mem.eql(u8, arg, "++vverbose")) {
            zzh_args.vverbose = true;
        } else if (std.mem.eql(u8, arg, "+q") or std.mem.eql(u8, arg, "++quiet") or std.mem.eql(u8, arg, "+quiet")) {
            zzh_args.quiet = true;
        } else if (std.mem.eql(u8, arg, "+I") or std.mem.eql(u8, arg, "++install-zzh-packages") or std.mem.eql(u8, arg, "++install-plugin") or std.mem.eql(u8, arg, "+install-plugin")) {
            i += 1;
            if (i < args.len) {
                try zzh_args.install_zzh_packages.append(try allocator.dupe(u8, args[i]));
                try zzh_args.plugins.append(try allocator.dupe(u8, args[i]));
            }
        } else if (std.mem.eql(u8, arg, "+L") or std.mem.eql(u8, arg, "++list-zzh-packages")) {
            zzh_args.has_list_zzh_packages = true;
            while (i + 1 < args.len) {
                const next_arg = args[i + 1];
                if (std.mem.startsWith(u8, next_arg, "+") or std.mem.startsWith(u8, next_arg, "-")) {
                    break;
                }
                i += 1;
                try zzh_args.list_zzh_packages.append(try allocator.dupe(u8, args[i]));
            }
        } else if (std.mem.eql(u8, arg, "+RI") or std.mem.eql(u8, arg, "++reinstall-zzh-packages")) {
            i += 1;
            if (i < args.len) {
                try zzh_args.reinstall_zzh_packages.append(try allocator.dupe(u8, args[i]));
            }
        } else if (std.mem.eql(u8, arg, "+R") or std.mem.eql(u8, arg, "++remove-zzh-packages")) {
            i += 1;
            if (i < args.len) {
                try zzh_args.remove_zzh_packages.append(try allocator.dupe(u8, args[i]));
            }
        } else if (std.mem.eql(u8, arg, "+LS") or std.mem.eql(u8, arg, "++list-shells") or std.mem.eql(u8, arg, "+list-shells")) {
            zzh_args.list_shells = true;
        } else if (std.mem.eql(u8, arg, "+LP") or std.mem.eql(u8, arg, "++list-plugins") or std.mem.eql(u8, arg, "+list-plugins")) {
            zzh_args.list_plugins = true;
        } else if (std.mem.eql(u8, arg, "+ES") or std.mem.eql(u8, arg, "++extract-sourcing-files")) {
            zzh_args.extract_sourcing_files = true;
        } else if (std.mem.eql(u8, arg, "++pexpect-timeout")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.pexpect_timeout) |v| allocator.free(v);
                zzh_args.pexpect_timeout = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "++copy-method")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.copy_method) |v| allocator.free(v);
                zzh_args.copy_method = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "++scp-command")) {
            i += 1;
            if (i < args.len) {
                if (zzh_args.scp_command) |v| allocator.free(v);
                zzh_args.scp_command = try allocator.dupe(u8, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "++debug") or std.mem.eql(u8, arg, "--debug")) {
            zzh_args.debug = true;
        } else if (std.mem.eql(u8, arg, "++pexpect-disable")) {
            zzh_args.pexpect_disable = true;
        } else if (std.mem.startsWith(u8, arg, "+")) {
            // Unrecognized + argument, ignore
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // Unrecognized ssh option or flag.
            // Check if this option takes an argument and consume it as well.
            try zzh_args.ssh_args.append(try allocator.dupe(u8, arg));
            if (arg.len == 2) {
                const opt = arg[1];
                switch (opt) {
                    'b', 'c', 'D', 'E', 'e', 'F', 'i', 'J', 'L', 'l', 'm', 'O', 'o', 'p', 'Q', 'R', 'S', 'W', 'w' => {
                        i += 1;
                        if (i < args.len) {
                            try zzh_args.ssh_args.append(try allocator.dupe(u8, args[i]));
                        }
                    },
                    else => {},
                }
            }
        } else {
            // Positional argument
            if (zzh_args.destination == null) {
                zzh_args.destination = try allocator.dupe(u8, arg);
            } else {
                try zzh_args.ssh_args.append(try allocator.dupe(u8, arg));
            }
        }
        i += 1;
    }
}

pub fn parseArgs(allocator: std.mem.Allocator) !ZzhArgs {
    var zzh_args = ZzhArgs.init(allocator);
    errdefer zzh_args.deinit();

    var args_it = try std.process.argsWithAllocator(allocator);
    defer args_it.deinit();

    // Skip program name
    _ = args_it.next();

    var list = std.ArrayList([]const u8).init(allocator);
    defer list.deinit();

    while (args_it.next()) |arg| {
        try list.append(arg);
    }

    try parseFromSlice(allocator, list.items, &zzh_args);
    return zzh_args;
}

test "CLI Parsing Test - Short Forms and Core SSH Options" {
    const testing = std.testing;
    var args = ZzhArgs.init(testing.allocator);
    defer args.deinit();

    const cli_args = [_][]const u8{
        "-p", "2222",
        "-l", "myuser",
        "-i", "id_rsa",
        "-J", "jump_host",
        "-o", "Option1=Val1",
        "-o", "Option2=Val2",
        "+c", "et",
        "+P", "secretpass",
        "+PP",
        "+i",
        "+if",
        "+iff",
        "+xc", "config_file.yml",
        "+e", "ENV_VAR1=val1",
        "+eb", "ENV_VAR2=val2_b64",
        "+lh", "/local/home",
        "+hh", "/host/home",
        "+hhr",
        "+hhh", "/user/home",
        "+hhx", "/xdg/config",
        "+hf", "script.sh",
        "+hc", "echo hello",
        "+heb", "echo before",
        "+s", "zsh",
        "+v",
        "+vv",
        "+q",
        "+I", "pkg_a",
        "+RI", "pkg_b",
        "+R", "pkg_c",
        "+LS",
        "+LP",
        "+ES",
        "user@myhost",
        "-extra-ssh-arg",
    };

    try parseFromSlice(testing.allocator, &cli_args, &args);

    try testing.expectEqualStrings("2222", args.ssh_port.?);
    try testing.expectEqualStrings("myuser", args.ssh_login.?);
    try testing.expectEqualStrings("id_rsa", args.ssh_private_key.?);
    try testing.expectEqualStrings("jump_host", args.ssh_jump_host.?);
    try testing.expectEqual(@as(usize, 2), args.ssh_options.items.len);
    try testing.expectEqualStrings("Option1=Val1", args.ssh_options.items[0]);
    try testing.expectEqualStrings("Option2=Val2", args.ssh_options.items[1]);
    try testing.expectEqualStrings("et", args.ssh_command.?);
    try testing.expectEqualStrings("secretpass", args.password.?);
    try testing.expect(args.password_prompt);
    try testing.expect(args.install);
    try testing.expect(args.install_force);
    try testing.expect(args.install_force_full);
    try testing.expectEqualStrings("config_file.yml", args.config_path.?);
    try testing.expectEqual(@as(usize, 1), args.env.items.len);
    try testing.expectEqualStrings("ENV_VAR1=val1", args.env.items[0]);
    try testing.expectEqual(@as(usize, 1), args.envb.items.len);
    try testing.expectEqualStrings("ENV_VAR2=val2_b64", args.envb.items[0]);
    try testing.expectEqualStrings("/local/home", args.local_zzh_home.?);
    try testing.expectEqualStrings("/host/home", args.host_zzh_home.?);
    try testing.expect(args.host_zzh_home_remove);
    try testing.expectEqualStrings("/user/home", args.host_home.?);
    try testing.expectEqualStrings("/xdg/config", args.host_home_xdg.?);
    try testing.expectEqualStrings("script.sh", args.host_execute_file.?);
    try testing.expectEqualStrings("echo hello", args.host_execute_command.?);
    try testing.expectEqual(@as(usize, 1), args.host_execute_bash.items.len);
    try testing.expectEqualStrings("echo before", args.host_execute_bash.items[0]);
    try testing.expectEqualStrings("zsh", args.shell.?);
    try testing.expect(args.verbose);
    try testing.expect(args.vverbose);
    try testing.expect(args.quiet);
    try testing.expectEqual(@as(usize, 1), args.install_zzh_packages.items.len);
    try testing.expectEqualStrings("pkg_a", args.install_zzh_packages.items[0]);
    try testing.expectEqual(@as(usize, 1), args.reinstall_zzh_packages.items.len);
    try testing.expectEqualStrings("pkg_b", args.reinstall_zzh_packages.items[0]);
    try testing.expectEqual(@as(usize, 1), args.remove_zzh_packages.items.len);
    try testing.expectEqualStrings("pkg_c", args.remove_zzh_packages.items[0]);
    try testing.expect(args.list_shells);
    try testing.expect(args.list_plugins);
    try testing.expect(args.extract_sourcing_files);
    try testing.expectEqualStrings("user@myhost", args.destination.?);
    try testing.expectEqual(@as(usize, 1), args.ssh_args.items.len);
    try testing.expectEqualStrings("-extra-ssh-arg", args.ssh_args.items[0]);
}

test "CLI Parsing Test - Long Forms and Other Options" {
    const testing = std.testing;
    var args = ZzhArgs.init(testing.allocator);
    defer args.deinit();

    const cli_args = [_][]const u8{
        "++ssh-command", "et_long",
        "++password", "secretpass_long",
        "++password-prompt",
        "++install",
        "++install-force",
        "++install-force-full",
        "++zzh-config", "config_file_long.yml",
        "++env", "ENV_VAR1=val1_long",
        "++envb", "ENV_VAR2=val2_b64_long",
        "++local-zzh-home", "/local/home/long",
        "++host-zzh-home", "/host/home/long",
        "++host-zzh-home-remove",
        "++host-home", "/user/home/long",
        "++host-home-xdg", "/xdg/config/long",
        "++host-execute-file", "script_long.sh",
        "++host-execute-command", "echo hello long",
        "++host-execute-bash", "echo before long",
        "++shell", "fish",
        "++verbose",
        "++vverbose",
        "++quiet",
        "++install-zzh-packages", "pkg_a_long",
        "++list-zzh-packages", "pkg_list_a", "pkg_list_b",
        "++reinstall-zzh-packages", "pkg_b_long",
        "++remove-zzh-packages", "pkg_c_long",
        "++list-shells",
        "++list-plugins",
        "++extract-sourcing-files",
        "++pexpect-timeout", "10",
        "++copy-method", "rsync",
        "++scp-command", "scp_custom",
        "++pexpect-disable",
        "user@host_long",
    };

    try parseFromSlice(testing.allocator, &cli_args, &args);

    try testing.expectEqualStrings("et_long", args.ssh_command.?);
    try testing.expectEqualStrings("secretpass_long", args.password.?);
    try testing.expect(args.password_prompt);
    try testing.expect(args.install);
    try testing.expect(args.install_force);
    try testing.expect(args.install_force_full);
    try testing.expectEqualStrings("config_file_long.yml", args.config_path.?);
    try testing.expectEqual(@as(usize, 1), args.env.items.len);
    try testing.expectEqualStrings("ENV_VAR1=val1_long", args.env.items[0]);
    try testing.expectEqual(@as(usize, 1), args.envb.items.len);
    try testing.expectEqualStrings("ENV_VAR2=val2_b64_long", args.envb.items[0]);
    try testing.expectEqualStrings("/local/home/long", args.local_zzh_home.?);
    try testing.expectEqualStrings("/host/home/long", args.host_zzh_home.?);
    try testing.expect(args.host_zzh_home_remove);
    try testing.expectEqualStrings("/user/home/long", args.host_home.?);
    try testing.expectEqualStrings("/xdg/config/long", args.host_home_xdg.?);
    try testing.expectEqualStrings("script_long.sh", args.host_execute_file.?);
    try testing.expectEqualStrings("echo hello long", args.host_execute_command.?);
    try testing.expectEqual(@as(usize, 1), args.host_execute_bash.items.len);
    try testing.expectEqualStrings("echo before long", args.host_execute_bash.items[0]);
    try testing.expectEqualStrings("fish", args.shell.?);
    try testing.expect(args.verbose);
    try testing.expect(args.vverbose);
    try testing.expect(args.quiet);
    try testing.expectEqual(@as(usize, 1), args.install_zzh_packages.items.len);
    try testing.expectEqualStrings("pkg_a_long", args.install_zzh_packages.items[0]);
    try testing.expect(args.has_list_zzh_packages);
    try testing.expectEqual(@as(usize, 2), args.list_zzh_packages.items.len);
    try testing.expectEqualStrings("pkg_list_a", args.list_zzh_packages.items[0]);
    try testing.expectEqualStrings("pkg_list_b", args.list_zzh_packages.items[1]);
    try testing.expectEqual(@as(usize, 1), args.reinstall_zzh_packages.items.len);
    try testing.expectEqualStrings("pkg_b_long", args.reinstall_zzh_packages.items[0]);
    try testing.expectEqual(@as(usize, 1), args.remove_zzh_packages.items.len);
    try testing.expectEqualStrings("pkg_c_long", args.remove_zzh_packages.items[0]);
    try testing.expect(args.list_shells);
    try testing.expect(args.list_plugins);
    try testing.expect(args.extract_sourcing_files);
    try testing.expectEqualStrings("10", args.pexpect_timeout.?);
    try testing.expectEqualStrings("rsync", args.copy_method.?);
    try testing.expectEqualStrings("scp_custom", args.scp_command.?);
    try testing.expect(args.pexpect_disable);
    try testing.expectEqualStrings("user@host_long", args.destination.?);
}

test "Destination Parsing Helper Test" {
    const testing = std.testing;

    {
        const d1 = parseDestination("user@host:2222");
        try testing.expectEqualStrings("user", d1.user.?);
        try testing.expectEqualStrings("host", d1.host);
        try testing.expectEqualStrings("2222", d1.port.?);
    }

    {
        const d2 = parseDestination("ssh://root@127.0.0.1");
        try testing.expectEqualStrings("root", d2.user.?);
        try testing.expectEqualStrings("127.0.0.1", d2.host);
        try testing.expect(d2.port == null);
    }

    {
        const d3 = parseDestination("host-only");
        try testing.expect(d3.user == null);
        try testing.expectEqualStrings("host-only", d3.host);
        try testing.expect(d3.port == null);
    }
}

test "CLI Parsing Test - Unrecognized options and corner cases" {
    const testing = std.testing;
    var args = ZzhArgs.init(testing.allocator);
    defer args.deinit();

    // -D is length 2 option that is not recognized but takes an argument
    // -z is unrecognized option that does NOT take an argument
    const cli_args = [_][]const u8{
        "-D", "9090",
        "-z",
        "user@host",
    };

    try parseFromSlice(testing.allocator, &cli_args, &args);

    try testing.expectEqualStrings("user@host", args.destination.?);
    try testing.expectEqual(@as(usize, 3), args.ssh_args.items.len);
    try testing.expectEqualStrings("-D", args.ssh_args.items[0]);
    try testing.expectEqualStrings("9090", args.ssh_args.items[1]);
    try testing.expectEqualStrings("-z", args.ssh_args.items[2]);
}

pub fn readPassword(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}", .{prompt});

    const stdin = std.io.getStdIn();
    const builtin = @import("builtin");

    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var mode: windows.DWORD = 0;
        if (windows.kernel32.GetConsoleMode(stdin.handle, &mode) == windows.FALSE) {
            return error.GetConsoleModeFailed;
        }
        const ENABLE_ECHO_INPUT = 0x0004;
        const new_mode = mode & ~@as(windows.DWORD, ENABLE_ECHO_INPUT);
        if (windows.kernel32.SetConsoleMode(stdin.handle, new_mode) == windows.FALSE) {
            return error.SetConsoleModeFailed;
        }
        defer _ = windows.kernel32.SetConsoleMode(stdin.handle, mode);

        var buf: [1024]u8 = undefined;
        const amt = try stdin.reader().readUntilDelimiterOrEof(&buf, '\n');
        try stdout.print("\n", .{});
        if (amt) |a| {
            var len = a.len;
            if (len > 0 and a[len - 1] == '\r') len -= 1;
            return allocator.dupe(u8, a[0..len]);
        }
        return error.EndOfStream;
    } else {
        const posix = std.posix;
        var termios = try posix.tcgetattr(stdin.handle);
        const original_termios = termios;
        termios.lflag.ECHO = false;
        try posix.tcsetattr(stdin.handle, .FLUSH, termios);
        defer posix.tcsetattr(stdin.handle, .FLUSH, original_termios) catch {};

        var buf: [1024]u8 = undefined;
        const amt = try stdin.reader().readUntilDelimiterOrEof(&buf, '\n');
        try stdout.print("\n", .{});
        if (amt) |a| {
            return allocator.dupe(u8, a);
        }
        return error.EndOfStream;
    }
}



