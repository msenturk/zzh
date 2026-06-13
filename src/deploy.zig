const std = @import("std");
const cli = @import("cli.zig");

fn b64Encode(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const size = encoder.calcSize(raw.len);
    const buf = try allocator.alloc(u8, size);
    _ = encoder.encode(buf, raw);
    return buf;
}

fn formatEnvVar(allocator: std.mem.Allocator, env_var: []const u8, to_base64: bool) ![]const u8 {
    if (std.mem.indexOfScalar(u8, env_var, '=')) |eq_idx| {
        const key = env_var[0..eq_idx];
        var val = env_var[eq_idx + 1 ..];
        // trim quotes if present
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        } else if (val.len >= 2 and val[0] == '\'' and val[val.len - 1] == '\'') {
            val = val[1 .. val.len - 1];
        }

        if (to_base64) {
            const b64_val = try b64Encode(allocator, val);
            defer allocator.free(b64_val);
            return std.fmt.allocPrint(allocator, "{s}={s}", .{ key, b64_val });
        } else {
            return std.fmt.allocPrint(allocator, "{s}={s}", .{ key, val });
        }
    } else {
        return allocator.dupe(u8, env_var);
    }
}

// In POSIX shells, we cannot put a literal single quote inside a single-quoted string.
// Instead, we must close the quote, write an escaped quote (\'), and reopen the quote.
// E.g., session name "foo'bar" is escaped to "foo'\''bar".
fn escapeSingleQuotesForShell(allocator: std.mem.Allocator, input_string: []const u8) ![]const u8 {
    var escaped_builder = std.ArrayList(u8).init(allocator);
    errdefer escaped_builder.deinit();
    for (input_string) |char| {
        if (char == '\'') {
            try escaped_builder.appendSlice("'\\''");
        } else {
            try escaped_builder.append(char);
        }
    }
    return escaped_builder.toOwnedSlice();
}

// Shell paths starting with ~ (like ~/.zzh) won't have ~ expanded by the remote shell
// if we wrap it entirely in single quotes. To bypass this restriction, we leave the ~
// unquoted and single-quote the rest of the path. E.g., "~/my dir" -> ~'/my dir'.
fn escapePathForShell(allocator: std.mem.Allocator, raw_path: []const u8) ![]const u8 {
    var escaped_builder = std.ArrayList(u8).init(allocator);
    errdefer escaped_builder.deinit();

    var unquoted_part = raw_path;
    if (std.mem.startsWith(u8, raw_path, "~")) {
        if (std.mem.indexOfScalar(u8, raw_path, '/')) |slash_idx| {
            try escaped_builder.appendSlice(raw_path[0 .. slash_idx + 1]);
            unquoted_part = raw_path[slash_idx + 1 ..];
        } else {
            try escaped_builder.appendSlice(raw_path);
            unquoted_part = "";
        }
    }

    if (unquoted_part.len > 0) {
        try escaped_builder.append('\'');
        for (unquoted_part) |char| {
            if (char == '\'') {
                try escaped_builder.appendSlice("'\\''");
            } else {
                try escaped_builder.append(char);
            }
        }
        try escaped_builder.append('\'');
    }

    return escaped_builder.toOwnedSlice();
}

pub const StagedScript = struct {
    bootstrap_script: []const u8,
    session_script: []const u8,

    pub fn deinit(self: StagedScript, allocator: std.mem.Allocator) void {
        allocator.free(self.bootstrap_script);
        allocator.free(self.session_script);
    }
};

// Generates the shell scripts used to provision the environment and launch the TTY session on the remote host.
pub fn compileStagedScript(allocator: std.mem.Allocator, zzh_args: *const cli.OperationalConfig) !StagedScript {
    const host_zzh_home = zzh_args.host_zzh_home orelse "~/.zzh";
    const escaped_home = try escapePathForShell(allocator, host_zzh_home);
    defer allocator.free(escaped_home);
    const shell = zzh_args.shell orelse "zsh";

    var bootstrap_builder = std.ArrayList(u8).init(allocator);
    errdefer bootstrap_builder.deinit();

    // install_force_full deletes the entire ~/.zzh folder. 
    // install_force only deletes the staging subdirectory (~/.zzh/.zzh) containing the staged packages, 
    // preserving other files in ~/.zzh (like static binaries in ~/.zzh/bin or user profiles).
    if (zzh_args.install_force_full) {
        try bootstrap_builder.appendSlice("rm -rf ");
        try bootstrap_builder.appendSlice(escaped_home);
        try bootstrap_builder.appendSlice(" && ");
    } else if (zzh_args.install_force) {
        try bootstrap_builder.appendSlice("rm -rf ");
        try bootstrap_builder.appendSlice(escaped_home);
        try bootstrap_builder.appendSlice("/.zzh && ");
    }

    try bootstrap_builder.appendSlice("mkdir -p ");
    try bootstrap_builder.appendSlice(escaped_home);
    try bootstrap_builder.appendSlice(" && tar -xmf - -C ");
    try bootstrap_builder.appendSlice(escaped_home);

    var session_builder = std.ArrayList(u8).init(allocator);
    errdefer session_builder.deinit();

    try session_builder.appendSlice("ln -sf .zzh ");
    try session_builder.appendSlice(escaped_home);
    try session_builder.appendSlice("/.xxh && chmod -R +x ");
    try session_builder.appendSlice(escaped_home);
    try session_builder.appendSlice(" 2>/dev/null || true && ");

    var shell_package_folder = std.ArrayList(u8).init(allocator);
    defer shell_package_folder.deinit();
    if (!std.mem.startsWith(u8, shell, "xxh-shell-")) {
        try shell_package_folder.appendSlice("xxh-shell-");
    }
    try shell_package_folder.appendSlice(shell);

    // If ++tmux, wrap the entrypoint script execution inside a persistent tmux session.
    // This allows the remote session to stay alive if the SSH connection drops.
    if (zzh_args.tmux) {
        const session_name = zzh_args.tmux_session orelse "zzh";
        const escaped_session_name = try escapeSingleQuotesForShell(allocator, session_name);
        defer allocator.free(escaped_session_name);
        try session_builder.appendSlice(escaped_home);
        try session_builder.appendSlice("/bin/tmux new-session -A -s '");
        try session_builder.appendSlice(escaped_session_name);
        try session_builder.appendSlice("' ");
    }

    // entrypoint command (quoted for tmux if needed)
    if (zzh_args.tmux) try session_builder.append('\"');
    try session_builder.appendSlice(escaped_home);
    try session_builder.appendSlice("/.zzh/shells/");
    try session_builder.appendSlice(shell_package_folder.items);
    try session_builder.appendSlice("/build/entrypoint.sh");

    if (zzh_args.host_execute_file) |f| {
        try session_builder.appendSlice(" -f \"");
        try session_builder.appendSlice(f);
        try session_builder.appendSlice("\"");
    }

    if (zzh_args.host_execute_command) |hc| {
        const hc_b64 = try b64Encode(allocator, hc);
        defer allocator.free(hc_b64);
        try session_builder.appendSlice(" -C ");
        try session_builder.appendSlice(hc_b64);
    }

    if (zzh_args.vverbose) {
        try session_builder.appendSlice(" -v 2");
    } else if (zzh_args.verbose) {
        try session_builder.appendSlice(" -v 1");
    }

    // prepend zzh's bin directory and common system paths to the remote PATH 
    // so our static binaries (like tmux/rg) take precedence while keeping standard tools available.
    {
        const cmd = "export PATH=\"$XXH_HOME/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH\"";
        const cmd_b64 = try b64Encode(allocator, cmd);
        defer allocator.free(cmd_b64);
        try session_builder.appendSlice(" -b ");
        try session_builder.appendSlice(cmd_b64);
    }

    for (zzh_args.env.items) |e| {
        const formatted = try formatEnvVar(allocator, e, true);
        defer allocator.free(formatted);
        try session_builder.appendSlice(" -e ");
        try session_builder.appendSlice(formatted);
    }
    for (zzh_args.envb.items) |e| {
        const formatted = try formatEnvVar(allocator, e, false);
        defer allocator.free(formatted);
        try session_builder.appendSlice(" -e ");
        try session_builder.appendSlice(formatted);
    }

    if (zzh_args.host_home) |h| {
        try session_builder.appendSlice(" -H ");
        try session_builder.appendSlice(h);
    } else {
        try session_builder.appendSlice(" -H ~");
    }

    if (zzh_args.host_home_xdg) |hx| {
        try session_builder.appendSlice(" -X ");
        try session_builder.appendSlice(hx);
    }

    for (zzh_args.host_execute_bash.items) |b| {
        const b_b64 = try b64Encode(allocator, b);
        defer allocator.free(b_b64);
        try session_builder.appendSlice(" -b ");
        try session_builder.appendSlice(b_b64);
    }

    if (zzh_args.dotfiles.items.len > 0) {
        var basenames = std.ArrayList([]const u8).init(allocator);
        defer basenames.deinit();
        var remote_names = std.ArrayList([]const u8).init(allocator);
        defer remote_names.deinit();

        for (zzh_args.dotfiles.items) |d| {
            if (std.mem.indexOfScalar(u8, d, ':')) |colon_idx| {
                try basenames.append(try allocator.dupe(u8, std.fs.path.basename(d[0..colon_idx])));
                try remote_names.append(try allocator.dupe(u8, d[colon_idx + 1 ..]));
            } else {
                const base = std.fs.path.basename(d);
                try basenames.append(try allocator.dupe(u8, base));
                try remote_names.append(try allocator.dupe(u8, base));
            }
        }
        defer {
            for (basenames.items) |b| allocator.free(b);
            for (remote_names.items) |r| allocator.free(r);
        }

        const joined_basenames = try std.mem.join(allocator, " ", basenames.items);
        defer allocator.free(joined_basenames);
        const joined_remotes = try std.mem.join(allocator, " ", remote_names.items);
        defer allocator.free(joined_remotes);

        // This bash script synchronizes dotfiles by setting up symlinks on the remote.
        // It's base64 encoded so it transmits cleanly as a command argument without shell escaping issues.
        const script = try std.fmt.allocPrint(allocator,
            \\if diff -y /dev/null /dev/null >/dev/null 2>&1; then _zzh_has_y=1; else _zzh_has_y=0; fi;
            \\if diff -u /dev/null /dev/null >/dev/null 2>&1; then _zzh_has_u=1; else _zzh_has_u=0; fi;
            \\_zzh_current_src="{s}";
            \\_zzh_current_dst="{s}";
            \\set -- $_zzh_current_dst;
            \\for src_base in $_zzh_current_src; do
            \\  basename=$1;
            \\  shift;
            \\  _zzh_src="$XXH_HOME/.zzh/dotfiles/$src_base";
            \\  _zzh_dst="~/$basename";
            \\  _zzh_dst=$(eval echo "$_zzh_dst");
            \\  if [ -L "$_zzh_dst" ]; then
            \\    target=$(readlink "$_zzh_dst");
            \\    if [ "$target" != "$_zzh_src" ]; then
            \\      rm -f "$_zzh_dst";
            \\      ln -sf "$_zzh_src" "$_zzh_dst";
            \\    fi;
            \\  elif [ -e "$_zzh_dst" ]; then
            \\    differ=0;
            \\    if [ -f "$_zzh_dst" ] && [ -f "$_zzh_src" ]; then
            \\      if ! cmp -s "$_zzh_dst" "$_zzh_src"; then
            \\        differ=1;
            \\        echo "--- Diff for $basename (Remote vs Local) ---";
            \\        if [ "$_zzh_has_y" -eq 1 ]; then
            \\          diff -y "$_zzh_dst" "$_zzh_src";
            \\        elif [ "$_zzh_has_u" -eq 1 ]; then
            \\          diff -u "$_zzh_dst" "$_zzh_src";
            \\        else
            \\          diff "$_zzh_dst" "$_zzh_src";
            \\        fi;
            \\        echo "--------------------------------------------";
            \\      fi;
            \\    elif [ -d "$_zzh_dst" ] && [ -d "$_zzh_src" ]; then
            \\      if ! diff -r "$_zzh_dst" "$_zzh_src" >/dev/null 2>&1; then
            \\        differ=1;
            \\        echo "--- Diff for $basename (Remote vs Local) ---";
            \\        if [ "$_zzh_has_y" -eq 1 ]; then
            \\          diff -ry "$_zzh_dst" "$_zzh_src";
            \\        elif [ "$_zzh_has_u" -eq 1 ]; then
            \\          diff -ru "$_zzh_dst" "$_zzh_src";
            \\        else
            \\          diff -r "$_zzh_dst" "$_zzh_src";
            \\        fi;
            \\        echo "--------------------------------------------";
            \\      fi;
            \\    else
            \\      differ=1;
            \\    fi;
            \\    if [ "$differ" -eq 1 ]; then
            \\      _zzh_overwrite="y";
            \\      if [ -c /dev/tty ] && [ -t 0 ]; then
            \\        printf "Remote file/directory %s differs from local. Overwrite on remote? [y/N]: " "$basename";
            \\        read _zzh_ans < /dev/tty;
            \\        case "$_zzh_ans" in
            \\          [yY]|[yY][eE][sS]) _zzh_overwrite="y" ;;
            \\          *) _zzh_overwrite="n" ;;
            \\        esac;
            \\      fi;
            \\      if [ "$_zzh_overwrite" = "y" ]; then
            \\        mv "$_zzh_dst" "$_zzh_dst.zzh-bak";
            \\        ln -sf "$_zzh_src" "$_zzh_dst";
            \\        echo "Updated symlink for $basename (old backed up as $basename.zzh-bak).";
            \\      else
            \\        echo "Skipping update for $basename, keeping remote as is.";
            \\      fi;
            \\    else
            \\      rm -rf "$_zzh_dst";
            \\      ln -sf "$_zzh_src" "$_zzh_dst";
            \\    fi;
            \\  else
            \\    ln -sf "$_zzh_src" "$_zzh_dst";
            \\  fi;
            \\done;
        , .{ joined_basenames, joined_remotes });
        defer allocator.free(script);
        const b_b64 = try b64Encode(allocator, script);
        defer allocator.free(b_b64);
        try session_builder.appendSlice(" -b ");
        try session_builder.appendSlice(b_b64);
    }

    if (zzh_args.tmux) {
        try session_builder.append('\"');
    }

    return StagedScript{
        .bootstrap_script = try bootstrap_builder.toOwnedSlice(),
        .session_script = try session_builder.toOwnedSlice(),
    };
}


pub fn getDeploymentHash(allocator: std.mem.Allocator, zzh_args: *const cli.OperationalConfig) ![]const u8 {
    // Environment variables (zzh_args.env / envb) are intentionally excluded from the deployment 
    // payload signature hash because they are injected dynamically at runtime during the connection 
    // step, and do not change the static payload content of the compiled archive tarball.
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    if (zzh_args.shell) |s| {
        hasher.update(s);
    }
    for (zzh_args.plugins.items) |p| {
        hasher.update("|");
        hasher.update(p);
    }
    for (zzh_args.dotfiles.items) |d| {
        hasher.update("|D|");
        hasher.update(d);
    }
    for (zzh_args.binaries.items) |b| {
        hasher.update("|B|");
        hasher.update(b);
    }
    if (zzh_args.tmux) {
        hasher.update("|tmux|");
        if (zzh_args.tmux_session) |s| hasher.update(s);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
}

pub fn checkPasswordless(allocator: std.mem.Allocator, zzh_args: *const cli.OperationalConfig) !bool {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer {
        for (argv.items) |item| {
            allocator.free(item);
        }
        argv.deinit();
    }

    try argv.append(try allocator.dupe(u8, zzh_args.ssh_command orelse "ssh"));
    try argv.append(try allocator.dupe(u8, "-o"));
    try argv.append(try allocator.dupe(u8, "BatchMode=yes"));
    try argv.append(try allocator.dupe(u8, "-o"));
    try argv.append(try allocator.dupe(u8, "StrictHostKeyChecking=accept-new"));
    try argv.append(try allocator.dupe(u8, "-o"));
    try argv.append(try allocator.dupe(u8, "ConnectTimeout=5"));

    if (zzh_args.ssh_port) |p| {
        try argv.append(try allocator.dupe(u8, "-p"));
        try argv.append(try allocator.dupe(u8, p));
    }
    if (zzh_args.ssh_private_key) |k| {
        try argv.append(try allocator.dupe(u8, "-i"));
        try argv.append(try allocator.dupe(u8, k));
    }
    if (zzh_args.ssh_login) |l| {
        try argv.append(try allocator.dupe(u8, "-l"));
        try argv.append(try allocator.dupe(u8, l));
    }
    if (zzh_args.ssh_jump_host) |j| {
        try argv.append(try allocator.dupe(u8, "-J"));
        try argv.append(try allocator.dupe(u8, j));
    }

    for (zzh_args.ssh_options.items) |opt| {
        try argv.append(try allocator.dupe(u8, "-o"));
        try argv.append(try allocator.dupe(u8, opt));
    }

    if (zzh_args.destination) |dest| {
        const dest_info = cli.parseConnectionEndpoint(dest);
        try argv.append(try allocator.dupe(u8, dest_info.host));
    } else {
        return false;
    }
    try argv.append(try allocator.dupe(u8, "exit"));
    try argv.append(try allocator.dupe(u8, "0"));

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |exit_code| exit_code == 0,
        else => false,
    };
}

pub fn buildSshBoilerplate(allocator: std.mem.Allocator, zzh_args: *const cli.OperationalConfig) !std.ArrayList([]const u8) {
    var ssh_boilerplate = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (ssh_boilerplate.items) |item| {
            allocator.free(item);
        }
        ssh_boilerplate.deinit();
    }

    const ssh_cmd = zzh_args.ssh_command orelse "ssh";
    try ssh_boilerplate.append(try allocator.dupe(u8, ssh_cmd));

    try ssh_boilerplate.append(try allocator.dupe(u8, "-C")); // Enable SSH native compression to speed up transfer without local CPU bottleneck
    try ssh_boilerplate.append(try allocator.dupe(u8, "-o"));
    try ssh_boilerplate.append(try allocator.dupe(u8, "StrictHostKeyChecking=accept-new"));

    // Prevent 20-30s delay on Windows due to GSSAPI timeout
    try ssh_boilerplate.append(try allocator.dupe(u8, "-o"));
    try ssh_boilerplate.append(try allocator.dupe(u8, "GSSAPIAuthentication=no"));

    if (!zzh_args.verbose and !zzh_args.vverbose) {
        try ssh_boilerplate.append(try allocator.dupe(u8, "-o"));
        try ssh_boilerplate.append(try allocator.dupe(u8, "LogLevel=QUIET"));
    }

    if (zzh_args.ssh_port) |p| {
        try ssh_boilerplate.append(try allocator.dupe(u8, "-o"));
        const opt = try std.fmt.allocPrint(allocator, "Port={s}", .{p});
        try ssh_boilerplate.append(opt);
    }

    if (zzh_args.ssh_private_key) |k| {
        try ssh_boilerplate.append(try allocator.dupe(u8, "-o"));
        const opt = try std.fmt.allocPrint(allocator, "IdentityFile={s}", .{k});
        try ssh_boilerplate.append(opt);
    }

    if (zzh_args.ssh_login) |l| {
        try ssh_boilerplate.append(try allocator.dupe(u8, "-o"));
        const opt = try std.fmt.allocPrint(allocator, "User={s}", .{l});
        try ssh_boilerplate.append(opt);
    } else if (zzh_args.destination) |dest| {
        const dest_info = cli.parseConnectionEndpoint(dest);
        if (dest_info.user) |u| {
            try ssh_boilerplate.append(try allocator.dupe(u8, "-o"));
            const opt = try std.fmt.allocPrint(allocator, "User={s}", .{u});
            try ssh_boilerplate.append(opt);
        }
    }

    if (zzh_args.ssh_jump_host) |j| {
        try ssh_boilerplate.append(try allocator.dupe(u8, "-o"));
        const opt = try std.fmt.allocPrint(allocator, "ProxyJump={s}", .{j});
        try ssh_boilerplate.append(opt);
    }

    for (zzh_args.ssh_options.items) |o| {
        try ssh_boilerplate.append(try allocator.dupe(u8, "-o"));
        try ssh_boilerplate.append(try allocator.dupe(u8, o));
    }

    // Reuse existing SSH multiplexed connection to avoid doing authentication handshake twice (which can take 1-2s).
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) {
        try ssh_boilerplate.append(try allocator.dupe(u8, "-o"));
        try ssh_boilerplate.append(try allocator.dupe(u8, "ControlMaster=auto"));
        try ssh_boilerplate.append(try allocator.dupe(u8, "-o"));
        try ssh_boilerplate.append(try allocator.dupe(u8, "ControlPath=/tmp/zzh_mux_%h_%p_%r"));
        try ssh_boilerplate.append(try allocator.dupe(u8, "-o"));
        try ssh_boilerplate.append(try allocator.dupe(u8, "ControlPersist=5m"));
    }

    for (zzh_args.ssh_args.items) |arg| {
        try ssh_boilerplate.append(try allocator.dupe(u8, arg));
    }

    return ssh_boilerplate;
}

pub const RemoteTarget = struct {
    os: []const u8,
    arch: []const u8,
};

fn normalizeArch(allocator: std.mem.Allocator, raw_arch: []const u8) ![]const u8 {
    const lower = try allocator.alloc(u8, raw_arch.len);
    defer allocator.free(lower);
    _ = std.ascii.lowerString(lower, raw_arch);

    if (std.mem.indexOf(u8, lower, "x86_64") != null or std.mem.indexOf(u8, lower, "amd64") != null) {
        return try allocator.dupe(u8, "x86_64");
    } else if (std.mem.indexOf(u8, lower, "aarch64") != null or std.mem.indexOf(u8, lower, "arm64") != null) {
        return try allocator.dupe(u8, "aarch64");
    } else {
        // Fallback to x86_64
        return try allocator.dupe(u8, "x86_64");
    }
}

pub fn detectRemoteTarget(allocator: std.mem.Allocator, zzh_args: *const cli.OperationalConfig) !RemoteTarget {
    var ssh_boilerplate = try buildSshBoilerplate(allocator, zzh_args);
    defer {
        for (ssh_boilerplate.items) |item| {
            allocator.free(item);
        }
        ssh_boilerplate.deinit();
    }

    var runner_args = std.ArrayList([]const u8).init(allocator);
    defer runner_args.deinit();

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var exe_path: ?[]const u8 = null;
    defer {
        if (exe_path) |p| allocator.free(p);
    }

    if (zzh_args.password) |pwd| {
        exe_path = std.fs.selfExePathAlloc(allocator) catch null;
        if (exe_path) |p| {
            try env_map.put("SSH_ASKPASS", p);
            try env_map.put("SSH_ASKPASS_REQUIRE", "force");
            try env_map.put("DISPLAY", "dummy:0");
            try env_map.put("ZZH_INTERNAL_ASKPASS", "1");
            try env_map.put("ZZH_INTERNAL_PASSWORD", pwd);
        }
    }

    const builtin = @import("builtin");
    if (zzh_args.password != null and exe_path != null and builtin.os.tag != .windows) {
        try runner_args.append(exe_path.?);
        try runner_args.append("--internal-setsid");
    }

    for (ssh_boilerplate.items) |arg| {
        try runner_args.append(arg);
    }

    if (zzh_args.destination) |dest| {
        const dest_info = cli.parseConnectionEndpoint(dest);
        try runner_args.append(dest_info.host);
    }

    try runner_args.append("echo ZZH_TARGET_START && uname -s && uname -m && echo ZZH_TARGET_END");

    if (zzh_args.verbose or zzh_args.vverbose) {
        std.debug.print("Detecting remote target with command:", .{});
        for (runner_args.items) |arg| {
            std.debug.print(" {s}", .{arg});
        }
        std.debug.print("\n", .{});
    }

    var child = std.process.Child.init(runner_args.items, allocator);
    child.env_map = &env_map;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    var out_buf = std.ArrayList(u8).init(allocator);
    defer out_buf.deinit();

    var stdout_reader = child.stdout.?.reader();
    while (true) {
        var buf: [1024]u8 = undefined;
        const amt = try stdout_reader.read(&buf);
        if (amt == 0) break;
        try out_buf.appendSlice(buf[0..amt]);
    }

    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        if (zzh_args.verbose or zzh_args.vverbose) {
            std.debug.print("Remote target detection failed with exit code or signal. Output: {s}\n", .{out_buf.items});
        }
        return error.RemoteTargetDetectionFailed;
    }

    var lines_it = std.mem.tokenizeAny(u8, out_buf.items, "\r\n");
    
    var os_line: ?[]const u8 = null;
    var arch_line: ?[]const u8 = null;
    var inside_target_block = false;

    while (lines_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.eql(u8, trimmed, "ZZH_TARGET_START")) {
            inside_target_block = true;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "ZZH_TARGET_END")) {
            break;
        }
        if (inside_target_block) {
            if (os_line == null) {
                os_line = trimmed;
            } else if (arch_line == null) {
                arch_line = trimmed;
            }
        }
    }

    if (os_line == null or arch_line == null) {
        return error.RemoteTargetDetectionFailed;
    }

    const os = try allocator.alloc(u8, os_line.?.len);
    errdefer allocator.free(os);
    _ = std.ascii.lowerString(os, os_line.?);

    const arch = try normalizeArch(allocator, arch_line.?);

    return RemoteTarget{
        .os = os,
        .arch = arch,
    };
}

pub fn deployAndConnect(allocator: std.mem.Allocator, zzh_args: *const cli.OperationalConfig, archive_path: []const u8, temp_build_dir: []const u8) !void {
    const builtin = @import("builtin");
    const staged_script = try compileStagedScript(allocator, zzh_args);
    defer staged_script.deinit(allocator);

    // Some mock command wrappers (e.g. for testing) don't support env variables directly on command line
    const is_mock_cmd = if (zzh_args.ssh_command) |cmd|
        std.mem.indexOf(u8, cmd, "cmd") != null
    else
        false;
    const env_prefix = if (is_mock_cmd) "" else "export APPIMAGE_EXTRACT_AND_RUN=1 && ";

    const bootstrap_cmd = blk: {
        const raw_bootstrap = staged_script.bootstrap_script;
        if (zzh_args.install_force or zzh_args.install_force_full) {
            break :blk try std.fmt.allocPrint(allocator, "{s}echo \"ZZH_PAYLOAD_REQ\" && {s}", .{ env_prefix, raw_bootstrap });
        } else {
            const hash = try getDeploymentHash(allocator, zzh_args);
            defer allocator.free(hash);
            const target_dir = zzh_args.host_zzh_home orelse "~/.zzh";
            const escaped_target_dir = try escapePathForShell(allocator, target_dir);
            defer allocator.free(escaped_target_dir);

            // To save bandwidth and speed up connections, we only deploy the payload if the remote hash doesn't match our local one.
            break :blk try std.fmt.allocPrint(allocator, "{s}if [ \"$(cat {s}/.payload_hash 2>/dev/null)\" != \"{s}\" ]; then echo \"ZZH_PAYLOAD_REQ\" && {s} && echo \"{s}\" > {s}/.payload_hash; else echo \"ZZH_PAYLOAD_SKIP\"; fi", .{ env_prefix, escaped_target_dir, hash, raw_bootstrap, hash, escaped_target_dir });
        }
    };
    defer allocator.free(bootstrap_cmd);

    const session_cmd = try std.fmt.allocPrint(allocator, "{s}{s}", .{ env_prefix, staged_script.session_script });
    defer allocator.free(session_cmd);

    var ssh_boilerplate = try buildSshBoilerplate(allocator, zzh_args);
    defer {
        for (ssh_boilerplate.items) |item| {
            allocator.free(item);
        }
        ssh_boilerplate.deinit();
    }

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var exe_path: ?[]const u8 = null;
    defer {
        if (exe_path) |p| allocator.free(p);
    }

    if (zzh_args.password) |pwd| {
        exe_path = std.fs.selfExePathAlloc(allocator) catch null;
        if (exe_path) |p| {
            try env_map.put("SSH_ASKPASS", p);
            try env_map.put("SSH_ASKPASS_REQUIRE", "force");
            try env_map.put("DISPLAY", "dummy:0");
            try env_map.put("ZZH_INTERNAL_ASKPASS", "1");
            try env_map.put("ZZH_INTERNAL_PASSWORD", pwd);
        } else {
            std.debug.print("Warning: Could not get self executable path for SSH_ASKPASS.\n", .{});
        }
    }

    // Run the bootstrap script first to upload/extract the payload tarball if needed.
    if (bootstrap_cmd.len > 0) {
        const d_cmd = bootstrap_cmd;
        // NOTE: bootstrap_runner_args intentionally aliases string slices owned by ssh_boilerplate,
        // static string literals, and exe_path (which is cleaned up at function end).
        // Therefore, we must NOT free the individual items in bootstrap_runner_args on deinit.
        var bootstrap_runner_args = std.ArrayList([]const u8).init(allocator);
        defer bootstrap_runner_args.deinit();

        if (zzh_args.password != null and exe_path != null and builtin.os.tag != .windows) {
            try bootstrap_runner_args.append(exe_path.?);
            try bootstrap_runner_args.append("--internal-setsid");
        }

        for (ssh_boilerplate.items) |arg| {
            try bootstrap_runner_args.append(arg);
        }
        if (zzh_args.destination) |dest| {
            const dest_info = cli.parseConnectionEndpoint(dest);
        try bootstrap_runner_args.append(dest_info.host);
        }
        try bootstrap_runner_args.append(d_cmd);

        if (zzh_args.verbose or zzh_args.vverbose) {
            std.debug.print("Deploying payload with command:", .{});
            for (bootstrap_runner_args.items) |arg| {
                std.debug.print(" {s}", .{arg});
            }
            std.debug.print("\n", .{});
        } else {
            std.debug.print("[4/4] Deploying to remote...\n", .{});
        }

        var child = std.process.Child.init(bootstrap_runner_args.items, allocator);
        child.env_map = &env_map;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;

        const deploy_start_time = std.time.milliTimestamp();
        try child.spawn();

        const PayloadThread = struct {
            fn run(path: []const u8, stdin_file: std.fs.File) void {
                defer stdin_file.close();
                var archive_file = std.fs.openFileAbsolute(path, .{}) catch return;
                defer archive_file.close();

                const file_stat = archive_file.stat() catch return;
                const total_size = file_stat.size;
                var uploaded_size: u64 = 0;
                var last_percent: u64 = 200;
                var printed_header = false;

                var buf: [32768]u8 = undefined;
                while (true) {
                    const amt = archive_file.read(&buf) catch break;
                    if (amt == 0) break;
                    stdin_file.writeAll(buf[0..amt]) catch break;
                    uploaded_size += amt;

                    if (uploaded_size > 128 * 1024 or uploaded_size == total_size) {
                        printed_header = true;
                        if (total_size > 0) {
                            const percent = (uploaded_size * 100) / total_size;
                            if (percent != last_percent or uploaded_size == total_size) {
                                last_percent = percent;
                                const mb_uploaded = uploaded_size / (1024 * 1024);
                                const mb_total = total_size / (1024 * 1024);
                                std.debug.print("\r      - Uploading payload... {d:>3}% ({d} MB / {d} MB)", .{ percent, mb_uploaded, mb_total });
                            }
                        }
                    }
                }
                if (printed_header) {
                    std.debug.print("\n", .{});
                }
            }
        };

        var send_payload = false;
        var got_response = false;
        var stdout_reader = child.stdout.?.reader();
        while (true) {
            var line_buf: [1024]u8 = undefined;
            const line = stdout_reader.readUntilDelimiterOrEof(&line_buf, '\n') catch break;
            if (line) |l| {
                if (std.mem.indexOf(u8, l, "ZZH_PAYLOAD_REQ") != null) {
                    send_payload = true;
                    got_response = true;
                    break;
                } else if (std.mem.indexOf(u8, l, "ZZH_PAYLOAD_SKIP") != null) {
                    send_payload = false;
                    got_response = true;
                    break;
                } else {
                    std.io.getStdOut().writer().print("{s}\n", .{l}) catch {};
                }
            } else {
                break;
            }
        }

        if (!zzh_args.verbose and !zzh_args.vverbose) {
            if (got_response) {
                if (send_payload) {
                    std.debug.print("      - Uploading payload to {s}...\n", .{zzh_args.destination.?});
                } else {
                    std.debug.print("      - Remote payload already cached (skipping upload)\n", .{});
                }
            }
        }

        var thread: ?std.Thread = null;
        if (send_payload) {
            thread = try std.Thread.spawn(.{}, PayloadThread.run, .{ archive_path, child.stdin.? });
        } else {
            child.stdin.?.close();
        }
        child.stdin = null;

        while (true) {
            var line_buf: [1024]u8 = undefined;
            const line = stdout_reader.readUntilDelimiterOrEof(&line_buf, '\n') catch break;
            if (line) |l| {
                std.io.getStdOut().writer().print("{s}\n", .{l}) catch {};
            } else {
                break;
            }
        }

        if (thread) |t| {
            t.join();
            if (!zzh_args.verbose and !zzh_args.vverbose) {
                std.debug.print("      - Unpacking archive...\n", .{});
            }
        }

        const term = try child.wait();

        if (!got_response and (term != .Exited or term.Exited != 0)) {
            std.debug.print("Error: SSH connection failed to establish or authenticate.\n", .{});
            std.debug.print("Underlying command run was:", .{});
            for (bootstrap_runner_args.items) |arg| {
                std.debug.print(" {s}", .{arg});
            }
            std.debug.print("\n", .{});
            if (zzh_args.password != null) {
                std.debug.print("Note: If you entered a password, please verify it is correct.\n", .{});
            }
            if (temp_build_dir.len > 0) {
                std.fs.deleteTreeAbsolute(temp_build_dir) catch {};
            }
            std.fs.deleteTreeAbsolute(archive_path) catch {};
            return error.DeploymentFailed;
        }

        const elapsed_deploy = std.time.milliTimestamp() - deploy_start_time;
        if (zzh_args.time) {
            std.debug.print("=> SSH deployment finished in {d} ms\n", .{elapsed_deploy});
        }

        // Clean up temporary local workspace directory early since connection might last a long time.
        if (temp_build_dir.len > 0) {
            std.fs.deleteTreeAbsolute(temp_build_dir) catch {};
        }

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    // On Windows, ssh.exe sometimes exits with 255 when stdin is closed even if the remote command succeeded.
                    // If we got ZZH_PAYLOAD_SKIP, the payload is already cached on remote, so we can ignore exit code 255.
                    if (send_payload or code != 255) {
                        std.debug.print("Payload deployment failed with exit code: {}\n", .{code});
                        return error.DeploymentFailed;
                    }
                }
            },
            else => {
                std.debug.print("Payload deployment terminated unexpectedly\n", .{});
                return error.DeploymentTerminated;
            },
        }
    }

    // Launch the interactive session over SSH.
    var interactive_session_args = std.ArrayList([]const u8).init(allocator);
    defer interactive_session_args.deinit();
    for (ssh_boilerplate.items) |arg| {
        try interactive_session_args.append(arg);
    }
    // -t is required to allocate a pseudo-terminal for interactive shells
    if (zzh_args.tmux) {
        try interactive_session_args.append("-tt");
    } else if (zzh_args.host_execute_command == null and zzh_args.host_execute_file == null) {
        try interactive_session_args.append("-t");
    }
    if (zzh_args.destination) |dest| {
        const dest_info = cli.parseConnectionEndpoint(dest);
        try interactive_session_args.append(dest_info.host);
    }
    try interactive_session_args.append(session_cmd);

    if (zzh_args.verbose or zzh_args.vverbose) {
        std.debug.print("Connecting with command:", .{});
        for (interactive_session_args.items) |arg| {
            std.debug.print(" {s}", .{arg});
        }
        std.debug.print("\n", .{});
    }

    if (!zzh_args.verbose and !zzh_args.vverbose) {
        std.debug.print("Connecting to target host via SSH...\n", .{});
        if (zzh_args.tmux) {
            std.debug.print("Entering remote tmux session...\n", .{});
        }
    }

    var child = std.process.Child.init(interactive_session_args.items, allocator);
    child.env_map = &env_map;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    const term = try child.wait();

    // Perform client-side remote directory cleanup if requested by the user.
    if (zzh_args.host_zzh_home_remove) {
        const host_zzh_home = zzh_args.host_zzh_home orelse "~/.zzh";
        const escaped_home = try escapePathForShell(allocator, host_zzh_home);
        defer allocator.free(escaped_home);
        const clean_cmd = try std.fmt.allocPrint(allocator, "rm -rf {s}", .{escaped_home});
        defer allocator.free(clean_cmd);

        var cleanup_runner_args = std.ArrayList([]const u8).init(allocator);
        defer cleanup_runner_args.deinit();

        if (zzh_args.password != null and exe_path != null and builtin.os.tag != .windows) {
            try cleanup_runner_args.append(exe_path.?);
            try cleanup_runner_args.append("--internal-setsid");
        }

        for (ssh_boilerplate.items) |arg| {
            try cleanup_runner_args.append(arg);
        }
        if (zzh_args.destination) |dest| {
            const dest_info = cli.parseConnectionEndpoint(dest);
            try cleanup_runner_args.append(dest_info.host);
        }
        try cleanup_runner_args.append(clean_cmd);

        if (zzh_args.verbose or zzh_args.vverbose) {
            std.debug.print("Cleaning up remote home directory with command:", .{});
            for (cleanup_runner_args.items) |arg| {
                std.debug.print(" {s}", .{arg});
            }
            std.debug.print("\n", .{});
        }

        var clean_child = std.process.Child.init(cleanup_runner_args.items, allocator);
        clean_child.env_map = &env_map;
        clean_child.stdin_behavior = .Ignore;
        clean_child.stdout_behavior = .Ignore;
        clean_child.stderr_behavior = .Ignore;

        _ = clean_child.spawnAndWait() catch {};
    }

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("SSH exited with code: {}\n", .{code});
            }
        },
        else => {
            std.debug.print("SSH session terminated unexpectedly\n", .{});
        },
    }
}

test "Remote Command Builder Test" {
    const testing = std.testing;

    var args = cli.OperationalConfig.init(testing.allocator);
    defer args.deinit();

    args.shell = try testing.allocator.dupe(u8, "zsh");
    try args.env.append(try testing.allocator.dupe(u8, "VAR1=VAL1"));
    args.verbose = true;

    // Test OOM path to cover errdefer
    _ = compileStagedScript(testing.failing_allocator, &args) catch |err| {
        try testing.expect(err == error.OutOfMemory);
    };

    const staged_script = try compileStagedScript(testing.allocator, &args);
    defer staged_script.deinit(testing.allocator);
    const cmd = try std.mem.join(testing.allocator, " && ", &.{ staged_script.bootstrap_script, staged_script.session_script });
    defer testing.allocator.free(cmd);

    try testing.expectEqualStrings("mkdir -p ~/'.zzh' && tar -xmf - -C ~/'.zzh' && ln -sf .zzh ~/'.zzh'/.xxh && chmod -R +x ~/'.zzh' 2>/dev/null || true && ~/'.zzh'/.zzh/shells/xxh-shell-zsh/build/entrypoint.sh -v 1 -b ZXhwb3J0IFBBVEg9IiRYWEhfSE9NRS9iaW46L3Vzci9sb2NhbC9zYmluOi91c3IvbG9jYWwvYmluOi91c3Ivc2JpbjovdXNyL2Jpbjovc2JpbjovYmluOiRQQVRIIg== -e VAR1=VkFMMQ== -H ~", cmd);
}

test "Remote Command Builder Test - Comprehensive" {
    const testing = std.testing;

    var args = cli.OperationalConfig.init(testing.allocator);
    defer args.deinit();

    args.shell = try testing.allocator.dupe(u8, "zsh");
    args.host_zzh_home = try testing.allocator.dupe(u8, "/custom/home");

    // Flags
    args.install_force_full = true;
    args.host_zzh_home_remove = true;
    args.vverbose = true;

    // Command and File execution
    args.host_execute_file = try testing.allocator.dupe(u8, "script.sh");
    args.host_execute_command = try testing.allocator.dupe(u8, "echo hello");

    // Env vars with and without quotes, and without =
    try args.env.append(try testing.allocator.dupe(u8, "VAR1=\"VAL1\""));
    try args.env.append(try testing.allocator.dupe(u8, "VAR2='VAL2'"));
    try args.env.append(try testing.allocator.dupe(u8, "VAR_NO_VAL"));

    // Raw envb (to_base64 is false)
    try args.envb.append(try testing.allocator.dupe(u8, "B64VAR1=VAL1"));
    try args.envb.append(try testing.allocator.dupe(u8, "B64VAR_NO_VAL"));

    // Host homes
    args.host_home = try testing.allocator.dupe(u8, "/host/home");
    args.host_home_xdg = try testing.allocator.dupe(u8, "/xdg/config");

    // Execute bash
    try args.host_execute_bash.append(try testing.allocator.dupe(u8, "bash_cmd"));

    const staged_script = try compileStagedScript(testing.allocator, &args);
    defer staged_script.deinit(testing.allocator);
    const cmd = try std.mem.join(testing.allocator, " && ", &.{ staged_script.bootstrap_script, staged_script.session_script });
    defer testing.allocator.free(cmd);

    // Verify commands inside cmd
    try testing.expect(std.mem.indexOf(u8, cmd, "rm -rf '/custom/home' &&") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "mkdir -p '/custom/home' && tar -xmf - -C '/custom/home' && ln -sf .zzh '/custom/home'/.xxh && chmod -R +x '/custom/home'") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, " -b ZXhwb3J0IFBBVEg") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, " -f \"script.sh\"") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, " -C ZWNobyBoZWxsbw==") != null); // base64 of "echo hello"
    try testing.expect(std.mem.indexOf(u8, cmd, " -v 2") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, " -e VAR1=VkFMMQ==") != null); // base64 of "VAL1" (quotes trimmed)
    try testing.expect(std.mem.indexOf(u8, cmd, " -e VAR2=VkFMMg==") != null); // base64 of "VAL2" (quotes trimmed)
    try testing.expect(std.mem.indexOf(u8, cmd, " -e VAR_NO_VAL") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, " -e B64VAR1=VAL1") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, " -e B64VAR_NO_VAL") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, " -H /host/home") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, " -X /xdg/config") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, " -b YmFzaF9jbWQ=") != null); // base64 of "bash_cmd"
    try testing.expect(std.mem.indexOf(u8, cmd, " && rm -rf '/custom/home'") == null);
}

test "Remote Command Builder Test - install_force" {
    const testing = std.testing;

    var args = cli.OperationalConfig.init(testing.allocator);
    defer args.deinit();

    args.shell = try testing.allocator.dupe(u8, "zsh");
    args.host_zzh_home = try testing.allocator.dupe(u8, "/custom/home");
    args.install_force = true;
    args.install_force_full = false;

    const staged_script = try compileStagedScript(testing.allocator, &args);
    defer staged_script.deinit(testing.allocator);
    const cmd = try std.mem.join(testing.allocator, " && ", &.{ staged_script.bootstrap_script, staged_script.session_script });
    defer testing.allocator.free(cmd);

    try testing.expect(std.mem.indexOf(u8, cmd, "rm -rf '/custom/home'/.zzh &&") != null);
}

fn getTempDir(allocator: std.mem.Allocator) ![]const u8 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        var env_map = try std.process.getEnvMap(allocator);
        defer env_map.deinit();
        if (env_map.get("TEMP")) |temp| {
            return allocator.dupe(u8, temp);
        }
        return allocator.dupe(u8, "C:\\Temp");
    } else {
        return allocator.dupe(u8, "/tmp");
    }
}

test "Deploy and Connect Mock Test - Success" {
    const testing = std.testing;
    const builtin = @import("builtin");

    const temp_base = try getTempDir(testing.allocator);
    defer testing.allocator.free(temp_base);

    const rand = std.crypto.random.int(u64);
    var sub_buf: [256]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&sub_buf, "{s}/success-{x}", .{ temp_base, rand });
    try std.fs.makeDirAbsolute(sub_path);
    defer std.fs.deleteTreeAbsolute(sub_path) catch {};

    var sub_dir = try std.fs.openDirAbsolute(sub_path, .{});
    defer sub_dir.close();

    try sub_dir.writeFile(.{ .sub_path = "archive.tar", .data = "dummy tar bytes" });
    var path_b: [1024]u8 = undefined;
    const archive_path = try sub_dir.realpath("archive.tar", &path_b);

    var args = cli.OperationalConfig.init(testing.allocator);
    defer args.deinit();

    args.shell = try testing.allocator.dupe(u8, "zsh");
    args.destination = try testing.allocator.dupe(u8, "localhost");
    args.verbose = true; // Covers verbosity print branches
    args.vverbose = true; // Covers vverbose print branches

    // Set all SSH connection options to cover their parsing and construction in deployAndConnect
    args.ssh_port = try testing.allocator.dupe(u8, "2222");
    args.ssh_private_key = try testing.allocator.dupe(u8, "dummy_key");
    args.ssh_login = try testing.allocator.dupe(u8, "user");
    args.ssh_jump_host = try testing.allocator.dupe(u8, "jump");
    try args.ssh_options.append(try testing.allocator.dupe(u8, "ForwardAgent=yes"));
    try args.ssh_args.append(try testing.allocator.dupe(u8, "-v"));

    if (builtin.os.tag == .windows) {
        args.ssh_command = try testing.allocator.dupe(u8, "cmd.exe");
        try args.ssh_args.append(try testing.allocator.dupe(u8, "/c"));
        try args.ssh_args.append(try testing.allocator.dupe(u8, "exit 0"));
    } else {
        args.ssh_command = try testing.allocator.dupe(u8, "true");
    }

    try deployAndConnect(testing.allocator, &args, archive_path, sub_path);
}

test "Deploy and Connect Mock Test - Failure" {
    const testing = std.testing;
    const builtin = @import("builtin");

    const temp_base = try getTempDir(testing.allocator);
    defer testing.allocator.free(temp_base);

    const rand = std.crypto.random.int(u64);
    var sub_buf: [256]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&sub_buf, "{s}/failure-{x}", .{ temp_base, rand });
    try std.fs.makeDirAbsolute(sub_path);
    defer std.fs.deleteTreeAbsolute(sub_path) catch {};

    var sub_dir = try std.fs.openDirAbsolute(sub_path, .{});
    defer sub_dir.close();

    try sub_dir.writeFile(.{ .sub_path = "archive.tar", .data = "dummy tar bytes" });
    var path_b: [1024]u8 = undefined;
    const archive_path = try sub_dir.realpath("archive.tar", &path_b);

    var args = cli.OperationalConfig.init(testing.allocator);
    defer args.deinit();

    args.shell = try testing.allocator.dupe(u8, "zsh");
    args.destination = try testing.allocator.dupe(u8, "localhost");

    if (builtin.os.tag == .windows) {
        args.ssh_command = try testing.allocator.dupe(u8, "cmd.exe");
        try args.ssh_args.append(try testing.allocator.dupe(u8, "/c"));
        try args.ssh_args.append(try testing.allocator.dupe(u8, "exit 1"));
    } else {
        args.ssh_command = try testing.allocator.dupe(u8, "false");
    }

    deployAndConnect(testing.allocator, &args, archive_path, sub_path) catch |err| {
        try testing.expectEqual(error.DeploymentFailed, err);
    };
}


test "Deploy and Connect Mock Test - Step 1 Signal Failure" {
    const testing = std.testing;
    const builtin = @import("builtin");

    if (builtin.os.tag == .windows) return;

    const temp_base = try getTempDir(testing.allocator);
    defer testing.allocator.free(temp_base);

    const rand = std.crypto.random.int(u64);
    var sub_buf: [256]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&sub_buf, "{s}/sig1-{x}", .{ temp_base, rand });
    try std.fs.makeDirAbsolute(sub_path);
    defer std.fs.deleteTreeAbsolute(sub_path) catch {};

    var sub_dir = try std.fs.openDirAbsolute(sub_path, .{});
    defer sub_dir.close();

    try sub_dir.writeFile(.{ .sub_path = "archive.tar", .data = "dummy tar bytes" });
    var path_b1: [1024]u8 = undefined;
    const archive_path = try sub_dir.realpath("archive.tar", &path_b1);

    var args = cli.OperationalConfig.init(testing.allocator);
    defer args.deinit();

    args.shell = try testing.allocator.dupe(u8, "zsh");
    args.destination = try testing.allocator.dupe(u8, "localhost");

    // Write a script that immediately terminates with SIGKILL
    try sub_dir.writeFile(.{ .sub_path = "mock_ssh_sig1.sh", .data = "#!/bin/sh\nkill -9 $$\n" });
    var path_b2: [1024]u8 = undefined;
    const mock_ssh_path = try sub_dir.realpath("mock_ssh_sig1.sh", &path_b2);
    const chmod_argv = [_][]const u8{ "chmod", "+x", mock_ssh_path };
    try @import("package.zig").executeSubprocess(testing.allocator, &chmod_argv);

    args.ssh_command = try testing.allocator.dupe(u8, mock_ssh_path);

    const res = deployAndConnect(testing.allocator, &args, archive_path, sub_path);
    try testing.expectError(error.DeploymentTerminated, res);
}

test "Deploy and Connect Mock Test - Step 2 Signal Failure" {
    const testing = std.testing;
    const builtin = @import("builtin");

    if (builtin.os.tag == .windows) return;

    const temp_base = try getTempDir(testing.allocator);
    defer testing.allocator.free(temp_base);

    const rand = std.crypto.random.int(u64);
    var sub_buf: [256]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&sub_buf, "{s}/sig2-{x}", .{ temp_base, rand });
    try std.fs.makeDirAbsolute(sub_path);
    defer std.fs.deleteTreeAbsolute(sub_path) catch {};

    var sub_dir = try std.fs.openDirAbsolute(sub_path, .{});
    defer sub_dir.close();

    try sub_dir.writeFile(.{ .sub_path = "archive.tar", .data = "dummy tar bytes" });
    var path_b1: [1024]u8 = undefined;
    const archive_path = try sub_dir.realpath("archive.tar", &path_b1);

    var args = cli.OperationalConfig.init(testing.allocator);
    defer args.deinit();

    args.shell = try testing.allocator.dupe(u8, "zsh");
    args.destination = try testing.allocator.dupe(u8, "localhost");

    // Write a stateful script that exits 0 first time, and exits with SIGKILL second time
    const state_file_path = try std.fs.path.join(testing.allocator, &.{ archive_path, "_state" });
    defer testing.allocator.free(state_file_path);

    const script_content = try std.fmt.allocPrint(testing.allocator, "#!/bin/sh\n" ++
        "if [ -f \"{s}\" ]; then\n" ++
        "  rm -f \"{s}\"\n" ++
        "  kill -9 $$\n" ++
        "else\n" ++
        "  touch \"{s}\"\n" ++
        "  exit 0\n" ++
        "fi\n", .{ state_file_path, state_file_path, state_file_path });
    defer testing.allocator.free(script_content);

    try sub_dir.writeFile(.{ .sub_path = "mock_ssh_sig2.sh", .data = script_content });
    var path_b2: [1024]u8 = undefined;
    const mock_ssh_path = try sub_dir.realpath("mock_ssh_sig2.sh", &path_b2);
    const chmod_argv = [_][]const u8{ "chmod", "+x", mock_ssh_path };
    try @import("package.zig").executeSubprocess(testing.allocator, &chmod_argv);

    args.ssh_command = try testing.allocator.dupe(u8, mock_ssh_path);

    // Should complete without error even if step 2 gets a signal (since step 2 logs it but doesn't propagate error)
    try deployAndConnect(testing.allocator, &args, archive_path, sub_path);
}

test "escapePathForShell Test" {
    const testing = std.testing;

    const res1 = try escapePathForShell(testing.allocator, "~/.zzh");
    defer testing.allocator.free(res1);
    try testing.expectEqualStrings("~/'.zzh'", res1);

    const res2 = try escapePathForShell(testing.allocator, "~user/some dir");
    defer testing.allocator.free(res2);
    try testing.expectEqualStrings("~user/'some dir'", res2);

    const res3 = try escapePathForShell(testing.allocator, "~");
    defer testing.allocator.free(res3);
    try testing.expectEqualStrings("~", res3);

    const res4 = try escapePathForShell(testing.allocator, "/absolute/path");
    defer testing.allocator.free(res4);
    try testing.expectEqualStrings("'/absolute/path'", res4);

    const res5 = try escapePathForShell(testing.allocator, "~/path'with'quote");
    defer testing.allocator.free(res5);
    try testing.expectEqualStrings("~/'path'\\''with'\\''quote'", res5);
}
