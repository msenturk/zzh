const std = @import("std");

/// The target destination parsed into user connection credentials, host address, and target port.
pub const ConnectionEndpoint = struct {
    user: ?[]const u8 = null,
    host: []const u8,
    port: ?[]const u8 = null,
};

/// Parses a connection endpoint string (e.g., 'ssh://user@host:port' or 'user@host:port') 
/// into its structural parts.
pub fn parseConnectionEndpoint(destination_uri: []const u8) ConnectionEndpoint {
    var raw_uri = destination_uri;
    // Strip standard SSH scheme prefix if present.
    if (std.mem.indexOf(u8, raw_uri, "://")) |scheme_idx| {
        raw_uri = raw_uri[scheme_idx + 3 ..];
    }

    var connection_user: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, raw_uri, '@')) |at_idx| {
        connection_user = raw_uri[0..at_idx];
        raw_uri = raw_uri[at_idx + 1 ..];
    }

    var connection_host: []const u8 = undefined;
    var connection_port: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, raw_uri, ':')) |colon_idx| {
        connection_host = raw_uri[0..colon_idx];
        connection_port = raw_uri[colon_idx + 1 ..];
    } else {
        connection_host = raw_uri;
    }

    return .{
        .user = connection_user,
        .host = connection_host,
        .port = connection_port,
    };
}

/// The settings required to configure, stage, and establish the zzh session.
pub const OperationalConfig = struct {
    // xxh shell & plugins configurations
    shell: ?[]const u8 = null,
    plugins: std.ArrayList([]const u8),
    env: std.ArrayList([]const u8),
    envb: std.ArrayList([]const u8),
    dotfiles: std.ArrayList([]const u8),
    binaries: std.ArrayList([]const u8),
    
    // config & home paths
    config_path: ?[]const u8 = null,
    local_zzh_home: ?[]const u8 = null,
    host_zzh_home: ?[]const u8 = null,
    host_zzh_home_remove: bool = false,
    host_home: ?[]const u8 = null,
    host_home_xdg: ?[]const u8 = null,
    
    // installation control flags
    install: bool = false,
    install_force: bool = false,
    install_force_full: bool = false,
    
    // execution command control properties
    host_execute_file: ?[]const u8 = null,
    host_execute_command: ?[]const u8 = null,
    host_execute_bash: std.ArrayList([]const u8),
    
    // logging & verbosity settings
    verbose: bool = false,
    vverbose: bool = false,
    quiet: bool = false,
    
    // package caching and removal operations
    install_zzh_packages: std.ArrayList([]const u8),
    list_zzh_packages: std.ArrayList([]const u8),
    has_list_zzh_packages: bool = false,
    reinstall_zzh_packages: std.ArrayList([]const u8),
    remove_zzh_packages: std.ArrayList([]const u8),
    list_shells: bool = false,
    list_plugins: bool = false,
    list_binaries: bool = false,
    extract_sourcing_files: bool = false,
    update_packages: bool = false,
    
    // SSH connection configurations
    ssh_port: ?[]const u8 = null,
    ssh_login: ?[]const u8 = null,
    ssh_private_key: ?[]const u8 = null,
    ssh_jump_host: ?[]const u8 = null,
    ssh_options: std.ArrayList([]const u8),
    ssh_command: ?[]const u8 = null,
    password: ?[]const u8 = null,
    password_prompt: bool = false,
    
    // subprocess tuning settings
    pexpect_timeout: ?[]const u8 = null,
    copy_method: ?[]const u8 = null,
    scp_command: ?[]const u8 = null,
    pexpect_disable: bool = false,
    config_init: bool = false,
    
    // target and pass-through arguments
    destination: ?[]const u8 = null,
    ssh_args: std.ArrayList([]const u8),
    help: bool = false,
    debug: bool = false,
    time: bool = false,
    tmux: bool = false,
    tmux_session: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OperationalConfig {
        return .{
            .plugins = std.ArrayList([]const u8).init(allocator),
            .env = std.ArrayList([]const u8).init(allocator),
            .envb = std.ArrayList([]const u8).init(allocator),
            .dotfiles = std.ArrayList([]const u8).init(allocator),
            .binaries = std.ArrayList([]const u8).init(allocator),
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

    pub fn deinit(self: *OperationalConfig) void {
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
        if (self.tmux_session) |s| self.allocator.free(s);

        for (self.plugins.items) |p| self.allocator.free(p);
        self.plugins.deinit();
        for (self.env.items) |e| self.allocator.free(e);
        self.env.deinit();
        for (self.envb.items) |e| self.allocator.free(e);
        self.envb.deinit();
        for (self.dotfiles.items) |d| self.allocator.free(d);
        self.dotfiles.deinit();
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
        for (self.binaries.items) |b| self.allocator.free(b);
        self.binaries.deinit();
        for (self.ssh_options.items) |o| self.allocator.free(o);
        self.ssh_options.deinit();
        for (self.ssh_args.items) |s| self.allocator.free(s);
        self.ssh_args.deinit();
    }
};

/// Populates operational settings by matching recognized CLI token strings.
pub fn populateConfigFromTokens(allocator: std.mem.Allocator, tokens: []const []const u8, settings: *OperationalConfig) !void {
    var token_idx: usize = 0;
    while (token_idx < tokens.len) {
        const token = tokens[token_idx];
        if (settings.verbose or settings.vverbose) {
            std.debug.print("Processing CLI token: '{s}' (index: {d})\n", .{token, token_idx});
        }
        if (std.mem.eql(u8, token, "+h") or std.mem.eql(u8, token, "++help")) {
            settings.help = true;
        } else if (std.mem.eql(u8, token, "-p")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.ssh_port) |v| allocator.free(v);
                settings.ssh_port = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "-l")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.ssh_login) |v| allocator.free(v);
                settings.ssh_login = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "-i")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.ssh_private_key) |v| allocator.free(v);
                settings.ssh_private_key = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "-J")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.ssh_jump_host) |v| allocator.free(v);
                settings.ssh_jump_host = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "-o")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                try settings.ssh_options.append(try allocator.dupe(u8, tokens[token_idx]));
            }
        } else if (std.mem.eql(u8, token, "+c") or std.mem.eql(u8, token, "++ssh-command")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.ssh_command) |v| allocator.free(v);
                settings.ssh_command = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "+P") or std.mem.eql(u8, token, "++password")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.password) |v| allocator.free(v);
                settings.password = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "+PP") or std.mem.eql(u8, token, "++password-prompt")) {
            settings.password_prompt = true;
        } else if (std.mem.eql(u8, token, "+i") or std.mem.eql(u8, token, "++install")) {
            settings.install = true;
        } else if (std.mem.eql(u8, token, "+if") or std.mem.eql(u8, token, "++install-force")) {
            settings.install_force = true;
        } else if (std.mem.eql(u8, token, "+iff") or std.mem.eql(u8, token, "++install-force-full")) {
            settings.install_force_full = true;
        } else if (std.mem.eql(u8, token, "+xc") or std.mem.eql(u8, token, "++zzh-config") or std.mem.eql(u8, token, "++config")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.config_path) |v| allocator.free(v);
                settings.config_path = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "++config-init") or std.mem.eql(u8, token, "+config-init")) {
            settings.config_init = true;
        } else if (std.mem.eql(u8, token, "+e") or std.mem.eql(u8, token, "++env")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                try settings.env.append(try allocator.dupe(u8, tokens[token_idx]));
            }
        } else if (std.mem.eql(u8, token, "+eb") or std.mem.eql(u8, token, "++envb")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                try settings.envb.append(try allocator.dupe(u8, tokens[token_idx]));
            }
        } else if (std.mem.eql(u8, token, "+d") or std.mem.eql(u8, token, "++dotfile")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                try settings.dotfiles.append(try allocator.dupe(u8, tokens[token_idx]));
            }
        } else if (std.mem.eql(u8, token, "++update")) {
            settings.update_packages = true;
        } else if (std.mem.eql(u8, token, "++tmux")) {
            settings.tmux = true;
        } else if (std.mem.eql(u8, token, "++no-tmux")) {
            settings.tmux = false;
        } else if (std.mem.eql(u8, token, "++tmux-session")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.tmux_session) |v| allocator.free(v);
                settings.tmux_session = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "+lh") or std.mem.eql(u8, token, "++local-zzh-home")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.local_zzh_home) |v| allocator.free(v);
                settings.local_zzh_home = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "+hh") or std.mem.eql(u8, token, "++host-zzh-home")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.host_zzh_home) |v| allocator.free(v);
                settings.host_zzh_home = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "+hhr") or std.mem.eql(u8, token, "++host-zzh-home-remove")) {
            settings.host_zzh_home_remove = true;
        } else if (std.mem.eql(u8, token, "+hhh") or std.mem.eql(u8, token, "++host-home")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.host_home) |v| allocator.free(v);
                settings.host_home = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "+hhx") or std.mem.eql(u8, token, "++host-home-xdg")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.host_home_xdg) |v| allocator.free(v);
                settings.host_home_xdg = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "+hf") or std.mem.eql(u8, token, "++host-execute-file")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.host_execute_file) |v| allocator.free(v);
                settings.host_execute_file = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "+hc") or std.mem.eql(u8, token, "++host-execute-command")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.host_execute_command) |v| allocator.free(v);
                settings.host_execute_command = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "+heb") or std.mem.eql(u8, token, "++host-execute-bash")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                try settings.host_execute_bash.append(try allocator.dupe(u8, tokens[token_idx]));
            }
        } else if (std.mem.eql(u8, token, "+s") or std.mem.eql(u8, token, "++shell") or std.mem.eql(u8, token, "+shell")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.shell) |v| allocator.free(v);
                settings.shell = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "+v") or std.mem.eql(u8, token, "++verbose")) {
            settings.verbose = true;
        } else if (std.mem.eql(u8, token, "+vv") or std.mem.eql(u8, token, "++vverbose")) {
            settings.vverbose = true;
        } else if (std.mem.eql(u8, token, "+q") or std.mem.eql(u8, token, "++quiet") or std.mem.eql(u8, token, "+quiet")) {
            settings.quiet = true;
        } else if (std.mem.eql(u8, token, "+I") or std.mem.eql(u8, token, "++install-zzh-packages") or std.mem.eql(u8, token, "++install-plugin") or std.mem.eql(u8, token, "+install-plugin") or std.mem.eql(u8, token, "+p")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                try settings.install_zzh_packages.append(try allocator.dupe(u8, tokens[token_idx]));
                try settings.plugins.append(try allocator.dupe(u8, tokens[token_idx]));
            }
        } else if (std.mem.eql(u8, token, "+L") or std.mem.eql(u8, token, "++list-zzh-packages")) {
            settings.has_list_zzh_packages = true;
            while (token_idx + 1 < tokens.len) {
                const next_token = tokens[token_idx + 1];
                if (std.mem.startsWith(u8, next_token, "+") or std.mem.startsWith(u8, next_token, "-")) {
                    break;
                }
                token_idx += 1;
                try settings.list_zzh_packages.append(try allocator.dupe(u8, tokens[token_idx]));
            }
        } else if (std.mem.eql(u8, token, "+RI") or std.mem.eql(u8, token, "++reinstall-zzh-packages")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                try settings.reinstall_zzh_packages.append(try allocator.dupe(u8, tokens[token_idx]));
            }
        } else if (std.mem.eql(u8, token, "+R") or std.mem.eql(u8, token, "++remove-zzh-packages")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                try settings.remove_zzh_packages.append(try allocator.dupe(u8, tokens[token_idx]));
            }
        } else if (std.mem.eql(u8, token, "+b") or std.mem.eql(u8, token, "++binary")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                try settings.binaries.append(try allocator.dupe(u8, tokens[token_idx]));
            }
        } else if (std.mem.eql(u8, token, "+LS") or std.mem.eql(u8, token, "++list-shells") or std.mem.eql(u8, token, "+list-shells")) {
            settings.list_shells = true;
        } else if (std.mem.eql(u8, token, "+LP") or std.mem.eql(u8, token, "++list-plugins") or std.mem.eql(u8, token, "+list-plugins")) {
            settings.list_plugins = true;
        } else if (std.mem.eql(u8, token, "+LB") or std.mem.eql(u8, token, "++list-binaries") or std.mem.eql(u8, token, "+list-binaries")) {
            settings.list_binaries = true;
        } else if (std.mem.eql(u8, token, "+ES") or std.mem.eql(u8, token, "++extract-sourcing-files")) {
            settings.extract_sourcing_files = true;
        } else if (std.mem.eql(u8, token, "++pexpect-timeout")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.pexpect_timeout) |v| allocator.free(v);
                settings.pexpect_timeout = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "++copy-method")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.copy_method) |v| allocator.free(v);
                settings.copy_method = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "++scp-command")) {
            token_idx += 1;
            if (token_idx >= tokens.len) {
                std.debug.print("Error: Missing argument for '{s}'\n", .{token});
                std.process.exit(1);
            }
            if (true) {
                if (settings.scp_command) |v| allocator.free(v);
                settings.scp_command = try allocator.dupe(u8, tokens[token_idx]);
            }
        } else if (std.mem.eql(u8, token, "++debug") or std.mem.eql(u8, token, "--debug")) {
            settings.debug = true;
            settings.verbose = true;
        } else if (std.mem.eql(u8, token, "++time") or std.mem.eql(u8, token, "--time")) {
            settings.time = true;
        } else if (std.mem.eql(u8, token, "++pexpect-disable")) {
            settings.pexpect_disable = true;
        } else if (std.mem.startsWith(u8, token, "+")) {
            // Unrecognized custom command parameter, skip.
        } else if (std.mem.startsWith(u8, token, "-")) {
            // Pass standard and unrecognized options down to SSH execution.
            try settings.ssh_args.append(try allocator.dupe(u8, token));
            if (token.len == 2) {
                const opt = token[1];
                // Consume the next token if this SSH option takes an argument.
                switch (opt) {
                    'b', 'c', 'D', 'E', 'e', 'F', 'i', 'J', 'L', 'l', 'm', 'O', 'o', 'p', 'Q', 'R', 'S', 'W', 'w' => {
                        token_idx += 1;
                        if (token_idx < tokens.len) {
                            try settings.ssh_args.append(try allocator.dupe(u8, tokens[token_idx]));
                        }
                    },
                    else => {},
                }
            }
        } else {
            // Set first non-parameter positional argument as connection endpoint.
            if (settings.destination == null) {
                settings.destination = try allocator.dupe(u8, token);
            } else {
                try settings.ssh_args.append(try allocator.dupe(u8, token));
            }
        }
        token_idx += 1;
    }
}

/// Parses local process command line arguments into our structured operational configuration.
pub fn parseCommandLineArguments(allocator: std.mem.Allocator) !OperationalConfig {
    var operational_settings = OperationalConfig.init(allocator);
    errdefer operational_settings.deinit();

    var argument_iterator = try std.process.argsWithAllocator(allocator);
    defer argument_iterator.deinit();

    // Skip program execution path
    _ = argument_iterator.next();

    var token_buffer = std.ArrayList([]const u8).init(allocator);
    defer token_buffer.deinit();

    while (argument_iterator.next()) |token| {
        try token_buffer.append(token);
    }

    try populateConfigFromTokens(allocator, token_buffer.items, &operational_settings);
    return operational_settings;
}

/// Prompts the user and reads their password securely by disabling terminal character echo.
/// Echo disabling prevents leaking passwords to anyone looking over the shoulder or logging output.
pub fn readMaskedPasswordFromTerminal(allocator: std.mem.Allocator, user_prompt: []const u8) ![]u8 {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}", .{user_prompt});

    const stdin = std.io.getStdIn();
    const builtin = @import("builtin");

    if (builtin.os.tag == .windows) {
        // Query console mode, disable ENABLE_ECHO_INPUT bit, and restore console state afterwards.
        const windows = std.os.windows;
        var console_mode: windows.DWORD = 0;
        if (windows.kernel32.GetConsoleMode(stdin.handle, &console_mode) == windows.FALSE) {
            return error.GetConsoleModeFailed;
        }
        const ENABLE_ECHO_INPUT = 0x0004;
        const hidden_mode = console_mode & ~@as(windows.DWORD, ENABLE_ECHO_INPUT);
        if (windows.kernel32.SetConsoleMode(stdin.handle, hidden_mode) == windows.FALSE) {
            return error.SetConsoleModeFailed;
        }
        defer _ = windows.kernel32.SetConsoleMode(stdin.handle, console_mode);

        var password_buffer: [1024]u8 = undefined;
        const input_line = try stdin.reader().readUntilDelimiterOrEof(&password_buffer, '\n');
        try stdout.print("\n", .{});
        if (input_line) |line| {
            var line_length = line.len;
            if (line_length > 0 and line[line_length - 1] == '\r') line_length -= 1;
            return allocator.dupe(u8, line[0..line_length]);
        }
        return error.EndOfStream;
    } else {
        // POSIX terminal attributes handling.
        const posix = std.posix;
        var tty_settings = try posix.tcgetattr(stdin.handle);
        const original_tty_settings = tty_settings;
        tty_settings.lflag.ECHO = false;
        try posix.tcsetattr(stdin.handle, .FLUSH, tty_settings);
        defer posix.tcsetattr(stdin.handle, .FLUSH, original_tty_settings) catch {};

        var password_buffer: [1024]u8 = undefined;
        const input_line = try stdin.reader().readUntilDelimiterOrEof(&password_buffer, '\n');
        try stdout.print("\n", .{});
        if (input_line) |line| {
            var line_length = line.len;
            if (line_length > 0 and line[line_length - 1] == '\r') line_length -= 1;
            return allocator.dupe(u8, line[0..line_length]);
        }
        return error.EndOfStream;
    }
}

test "CLI Parsing Test - Short Forms and Core SSH Options" {
    const testing = std.testing;
    var args = OperationalConfig.init(testing.allocator);
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
        "+LB",
        "+ES",
        "user@myhost",
        "-extra-ssh-arg",
    };

    try populateConfigFromTokens(testing.allocator, &cli_args, &args);

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
    try testing.expect(args.list_binaries);
    try testing.expect(args.extract_sourcing_files);
    try testing.expectEqualStrings("user@myhost", args.destination.?);
    try testing.expectEqual(@as(usize, 1), args.ssh_args.items.len);
    try testing.expectEqualStrings("-extra-ssh-arg", args.ssh_args.items[0]);
}

test "CLI Parsing Test - Long Forms and Other Options" {
    const testing = std.testing;
    var args = OperationalConfig.init(testing.allocator);
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

    try populateConfigFromTokens(testing.allocator, &cli_args, &args);

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
        const d1 = parseConnectionEndpoint("user@host:2222");
        try testing.expectEqualStrings("user", d1.user.?);
        try testing.expectEqualStrings("host", d1.host);
        try testing.expectEqualStrings("2222", d1.port.?);
    }

    {
        const d2 = parseConnectionEndpoint("ssh://root@127.0.0.1");
        try testing.expectEqualStrings("root", d2.user.?);
        try testing.expectEqualStrings("127.0.0.1", d2.host);
        try testing.expect(d2.port == null);
    }

    {
        const d3 = parseConnectionEndpoint("host-only");
        try testing.expect(d3.user == null);
        try testing.expectEqualStrings("host-only", d3.host);
        try testing.expect(d3.port == null);
    }
}

test "CLI Parsing Test - Unrecognized options and corner cases" {
    const testing = std.testing;
    var args = OperationalConfig.init(testing.allocator);
    defer args.deinit();

    const cli_args = [_][]const u8{
        "-D", "9090",
        "-z",
        "user@host",
    };

    try populateConfigFromTokens(testing.allocator, &cli_args, &args);

    try testing.expectEqualStrings("user@host", args.destination.?);
    try testing.expectEqual(@as(usize, 3), args.ssh_args.items.len);
    try testing.expectEqualStrings("-D", args.ssh_args.items[0]);
    try testing.expectEqualStrings("9090", args.ssh_args.items[1]);
    try testing.expectEqualStrings("-z", args.ssh_args.items[2]);
}
