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

pub noinline fn buildRemoteCommand(allocator: std.mem.Allocator, zzh_args: *const cli.ZzhArgs) ![]const u8 {
    var cmd_buf = std.ArrayList(u8).init(allocator);
    errdefer cmd_buf.deinit();

    const host_zzh_home = zzh_args.host_zzh_home orelse "~/.zzh";
    const shell = zzh_args.shell orelse "zsh";

    if (zzh_args.install_force_full) {
        try cmd_buf.appendSlice("rm -rf ");
        try cmd_buf.appendSlice(host_zzh_home);
        try cmd_buf.appendSlice(" && ");
    } else if (zzh_args.install_force) {
        try cmd_buf.appendSlice("rm -rf ");
        try cmd_buf.appendSlice(host_zzh_home);
        try cmd_buf.appendSlice("/.zzh && ");
    }

    try cmd_buf.appendSlice("mkdir -p ");
    try cmd_buf.appendSlice(host_zzh_home);
    try cmd_buf.appendSlice(" && tar -xmf - -C ");
    try cmd_buf.appendSlice(host_zzh_home);
    try cmd_buf.appendSlice(" && ln -sf .zzh ");
    try cmd_buf.appendSlice(host_zzh_home);
    try cmd_buf.appendSlice("/.xxh && chmod -R +x ");
    try cmd_buf.appendSlice(host_zzh_home);
    try cmd_buf.appendSlice("/.zzh 2>/dev/null || true && ");

    var shell_pkg_name = std.ArrayList(u8).init(allocator);
    defer shell_pkg_name.deinit();
    if (!std.mem.startsWith(u8, shell, "xxh-shell-")) {
        try shell_pkg_name.appendSlice("xxh-shell-");
    }
    try shell_pkg_name.appendSlice(shell);

    // If ++tmux, wrap the entrypoint in the persistent tmux binary at ~/.zzh/bin/tmux
    // The entrypoint.sh + all its args become the tmux window-command string.
    // We build: ~/.zzh/bin/tmux new-session -A -s <session> 'ENTRYPOINT [args]'
    if (zzh_args.tmux) {
        const session = zzh_args.tmux_session orelse "zzh";
        try cmd_buf.appendSlice(host_zzh_home);
        try cmd_buf.appendSlice("/bin/tmux new-session -A -s '");
        try cmd_buf.appendSlice(session);
        try cmd_buf.appendSlice("' ");
    }

    // entrypoint command (quoted for tmux if needed)
    const ep_start = cmd_buf.items.len;
    _ = ep_start;
    if (zzh_args.tmux) try cmd_buf.append('\"');
    try cmd_buf.appendSlice(host_zzh_home);
    try cmd_buf.appendSlice("/.zzh/shells/");
    try cmd_buf.appendSlice(shell_pkg_name.items);
    try cmd_buf.appendSlice("/build/entrypoint.sh");

    if (zzh_args.host_execute_file) |f| {
        try cmd_buf.appendSlice(" -f \"");
        try cmd_buf.appendSlice(f);
        try cmd_buf.appendSlice("\"");
    }

    if (zzh_args.host_execute_command) |hc| {
        const hc_b64 = try b64Encode(allocator, hc);
        defer allocator.free(hc_b64);
        try cmd_buf.appendSlice(" -C ");
        try cmd_buf.appendSlice(hc_b64);
    }

    if (zzh_args.vverbose) {
        try cmd_buf.appendSlice(" -v 2");
    } else if (zzh_args.verbose) {
        try cmd_buf.appendSlice(" -v 1");
    }

    for (zzh_args.env.items) |e| {
        const formatted = try formatEnvVar(allocator, e, true);
        defer allocator.free(formatted);
        try cmd_buf.appendSlice(" -e ");
        try cmd_buf.appendSlice(formatted);
    }
    for (zzh_args.envb.items) |e| {
        const formatted = try formatEnvVar(allocator, e, false);
        defer allocator.free(formatted);
        try cmd_buf.appendSlice(" -e ");
        try cmd_buf.appendSlice(formatted);
    }

    if (zzh_args.host_home) |h| {
        try cmd_buf.appendSlice(" -H ");
        try cmd_buf.appendSlice(h);
    }

    if (zzh_args.host_home_xdg) |hx| {
        try cmd_buf.appendSlice(" -X ");
        try cmd_buf.appendSlice(hx);
    }

    for (zzh_args.host_execute_bash.items) |b| {
        const b_b64 = try b64Encode(allocator, b);
        defer allocator.free(b_b64);
        try cmd_buf.appendSlice(" -b ");
        try cmd_buf.appendSlice(b_b64);
    }

    for (zzh_args.dotfiles.items) |d| {
        const basename = std.fs.path.basename(d);
        // Safe symlink:
        // - If already correctly symlinked: no-op
        // - If real file or dir: back up as <name>.zzh-bak, then symlink
        // - If broken/wrong symlink: replace
        const ln_cmd = try std.fmt.allocPrint(allocator,
            \\_zzh_src="$XXH_HOME/.zzh/dotfiles/{s}"; _zzh_dst=~/{s}; if [ -L "$_zzh_dst" ] && [ "$(readlink "$_zzh_dst")" = "$_zzh_src" ]; then : ; elif [ -e "$_zzh_dst" ] && [ ! -L "$_zzh_dst" ]; then mv "$_zzh_dst" "$_zzh_dst.zzh-bak" && ln -sf "$_zzh_src" "$_zzh_dst"; else ln -sf "$_zzh_src" "$_zzh_dst"; fi
        , .{ basename, basename });
        defer allocator.free(ln_cmd);
        const b_b64 = try b64Encode(allocator, ln_cmd);
        defer allocator.free(b_b64);
        try cmd_buf.appendSlice(" -b ");
        try cmd_buf.appendSlice(b_b64);
    }

    if (zzh_args.host_zzh_home_remove) {
        if (zzh_args.tmux) try cmd_buf.append('\"');
        try cmd_buf.appendSlice(" && rm -rf ");
        try cmd_buf.appendSlice(host_zzh_home);
    } else if (zzh_args.tmux) {
        try cmd_buf.append('\"');
    }

    return cmd_buf.toOwnedSlice();
}

fn forwardStdin(child_stdin: std.fs.File, parent_stdin: std.fs.File) void {
    var buf: [1024]u8 = undefined;
    while (true) {
        const amt = parent_stdin.read(&buf) catch break;
        if (amt == 0) break;
        child_stdin.writeAll(buf[0..amt]) catch break;
    }
}

pub fn getDeploymentHash(allocator: std.mem.Allocator, zzh_args: *const cli.ZzhArgs) ![]const u8 {
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
    if (zzh_args.tmux) {
        hasher.update("|tmux|");
        if (zzh_args.tmux_session) |s| hasher.update(s);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
}

pub fn checkPasswordless(allocator: std.mem.Allocator, zzh_args: *const cli.ZzhArgs) !bool {
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

    try argv.append(try allocator.dupe(u8, zzh_args.destination.?));
    try argv.append(try allocator.dupe(u8, "exit"));
    try argv.append(try allocator.dupe(u8, "0"));

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    
    const term = try child.spawnAndWait();
    if (term == .Exited) {
        return term.Exited == 0;
    }
    return false;
}

pub noinline fn deployAndConnect(allocator: std.mem.Allocator, zzh_args: *const cli.ZzhArgs, archive_path: []const u8, temp_build_dir: []const u8) !void {
    const remote_cmd = try buildRemoteCommand(allocator, zzh_args);
    defer allocator.free(remote_cmd);

    // Split remote_cmd into deploy_cmd and run_cmd
    var deploy_cmd_parts = std.ArrayList([]const u8).init(allocator);
    defer deploy_cmd_parts.deinit();
    var run_cmd_parts = std.ArrayList([]const u8).init(allocator);
    defer run_cmd_parts.deinit();

    var it = std.mem.splitSequence(u8, remote_cmd, " && ");
    var found_tar = false;
    while (it.next()) |part| {
        if (!found_tar) {
            try deploy_cmd_parts.append(part);
            if (std.mem.startsWith(u8, part, "tar -xmf ")) {
                found_tar = true;
            }
        } else {
            try run_cmd_parts.append(part);
        }
    }

    const deploy_cmd = if (found_tar) blk: {
        const db = try std.mem.join(allocator, " && ", deploy_cmd_parts.items);
        defer allocator.free(db);
        if (zzh_args.install_force or zzh_args.install_force_full) {
             break :blk try std.fmt.allocPrint(allocator, 
                 "echo \"ZZH_PAYLOAD_REQ\" && {s}",
                 .{ db }
             );
        } else {
             const hash = try getDeploymentHash(allocator, zzh_args);
             defer allocator.free(hash);
             const target_dir = zzh_args.host_zzh_home orelse "~/.zzh";
             break :blk try std.fmt.allocPrint(allocator, 
                 "if [ \"$(cat {s}/.payload_hash 2>/dev/null)\" != \"{s}\" ]; then echo \"ZZH_PAYLOAD_REQ\" && {s} && echo \"{s}\" > {s}/.payload_hash; else echo \"ZZH_PAYLOAD_SKIP\"; fi",
                 .{ target_dir, hash, db, hash, target_dir }
             );
        }
    } else null;
    defer if (deploy_cmd) |d| allocator.free(d);

    const run_cmd = if (found_tar) try std.mem.join(allocator, " && ", run_cmd_parts.items) else remote_cmd;
    defer if (found_tar) allocator.free(run_cmd);

    // Build common SSH argv prefix (everything except the command and -t flag)
    var common_argv = std.ArrayList([]const u8).init(allocator);
    defer {
        for (common_argv.items) |item| {
            allocator.free(item);
        }
        common_argv.deinit();
    }

    const ssh_cmd = zzh_args.ssh_command orelse "ssh";
    try common_argv.append(try allocator.dupe(u8, ssh_cmd));

    try common_argv.append(try allocator.dupe(u8, "-C")); // Enable SSH native compression to speed up transfer without local CPU bottleneck
    try common_argv.append(try allocator.dupe(u8, "-o"));
    try common_argv.append(try allocator.dupe(u8, "StrictHostKeyChecking=accept-new"));
    
    // Prevent 20-30s delay on Windows due to GSSAPI timeout
    try common_argv.append(try allocator.dupe(u8, "-o"));
    try common_argv.append(try allocator.dupe(u8, "GSSAPIAuthentication=no"));

    if (!zzh_args.verbose and !zzh_args.vverbose) {
        try common_argv.append(try allocator.dupe(u8, "-o"));
        try common_argv.append(try allocator.dupe(u8, "LogLevel=QUIET"));
    }

    if (zzh_args.ssh_port) |p| {
        try common_argv.append(try allocator.dupe(u8, "-o"));
        const opt = try std.fmt.allocPrint(allocator, "Port={s}", .{p});
        defer allocator.free(opt);
        try common_argv.append(try allocator.dupe(u8, opt));
    }

    if (zzh_args.ssh_private_key) |k| {
        try common_argv.append(try allocator.dupe(u8, "-o"));
        const opt = try std.fmt.allocPrint(allocator, "IdentityFile={s}", .{k});
        defer allocator.free(opt);
        try common_argv.append(try allocator.dupe(u8, opt));
    }

    if (zzh_args.ssh_login) |l| {
        try common_argv.append(try allocator.dupe(u8, "-o"));
        const opt = try std.fmt.allocPrint(allocator, "User={s}", .{l});
        defer allocator.free(opt);
        try common_argv.append(try allocator.dupe(u8, opt));
    }

    if (zzh_args.ssh_jump_host) |j| {
        try common_argv.append(try allocator.dupe(u8, "-o"));
        const opt = try std.fmt.allocPrint(allocator, "ProxyJump={s}", .{j});
        defer allocator.free(opt);
        try common_argv.append(try allocator.dupe(u8, opt));
    }

    for (zzh_args.ssh_options.items) |o| {
        try common_argv.append(try allocator.dupe(u8, "-o"));
        try common_argv.append(try allocator.dupe(u8, o));
    }

    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) {
        try common_argv.append(try allocator.dupe(u8, "-o"));
        try common_argv.append(try allocator.dupe(u8, "ControlMaster=auto"));
        try common_argv.append(try allocator.dupe(u8, "-o"));
        try common_argv.append(try allocator.dupe(u8, "ControlPath=/tmp/zzh_mux_%h_%p_%r"));
        try common_argv.append(try allocator.dupe(u8, "-o"));
        try common_argv.append(try allocator.dupe(u8, "ControlPersist=5m"));
    }

    for (zzh_args.ssh_args.items) |arg| {
        try common_argv.append(try allocator.dupe(u8, arg));
    }

    if (zzh_args.destination) |dest| {
        const dest_info = cli.parseDestination(dest);
        try common_argv.append(try allocator.dupe(u8, dest_info.host));
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

    // Step 1: Deploy the payload if deployment is needed
    if (deploy_cmd) |d_cmd| {
        var deploy_argv = std.ArrayList([]const u8).init(allocator);
        defer deploy_argv.deinit();

        if (zzh_args.password != null and exe_path != null and builtin.os.tag != .windows) {
            try deploy_argv.append(try allocator.dupe(u8, exe_path.?));
            try deploy_argv.append(try allocator.dupe(u8, "--internal-setsid"));
        }

        for (common_argv.items) |arg| {
            try deploy_argv.append(arg);
        }
        try deploy_argv.append(d_cmd);

        if (zzh_args.verbose or zzh_args.vverbose) {
            std.debug.print("Deploying payload with command:", .{});
            for (deploy_argv.items) |arg| {
                std.debug.print(" {s}", .{arg});
            }
            std.debug.print("\n", .{});
        } else {
            std.debug.print("Connecting to target host via SSH...\n", .{});
        }

        var child = std.process.Child.init(deploy_argv.items, allocator);
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
                        if (!printed_header) {
                            std.debug.print("\nUploading payload to target host...\n", .{});
                            printed_header = true;
                        }

                        if (total_size > 0) {
                            const percent = (uploaded_size * 100) / total_size;
                            if (percent != last_percent or uploaded_size == total_size) {
                                last_percent = percent;
                                const bar_width = 40;
                                const filled = (uploaded_size * bar_width) / total_size;
                                
                                var bar_chars: [40]u8 = undefined;
                                for (&bar_chars, 0..) |*c, i| {
                                    if (i < filled) {
                                        c.* = '=';
                                    } else if (i == filled and i < bar_width - 1) {
                                        c.* = '>';
                                    } else {
                                        c.* = ' ';
                                    }
                                }
                                const mb_uploaded = uploaded_size / (1024 * 1024);
                                const mb_total = total_size / (1024 * 1024);
                                std.debug.print("\r[{s}] {d:>3}% ({d} MB / {d} MB)", .{ bar_chars, percent, mb_uploaded, mb_total });
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
        var stdout_reader = child.stdout.?.reader();
        while (true) {
            var line_buf: [1024]u8 = undefined;
            const line = stdout_reader.readUntilDelimiterOrEof(&line_buf, '\n') catch break;
            if (line) |l| {
                if (std.mem.indexOf(u8, l, "ZZH_PAYLOAD_REQ") != null) {
                    send_payload = true;
                    break;
                } else if (std.mem.indexOf(u8, l, "ZZH_PAYLOAD_SKIP") != null) {
                    send_payload = false;
                    break;
                } else {
                    std.io.getStdOut().writer().print("{s}\n", .{l}) catch {};
                }
            } else {
                break;
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
        }

        const term = try child.wait();
        const elapsed_deploy = std.time.milliTimestamp() - deploy_start_time;
        if (zzh_args.time) {
            std.debug.print("=> SSH deployment finished in {d} ms\n", .{ elapsed_deploy });
        }

        // Clean up payload early to prevent leftover files if the interactive session is killed
        std.fs.deleteTreeAbsolute(temp_build_dir) catch {};
        std.fs.deleteTreeAbsolute(archive_path) catch {};
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    std.debug.print("Payload deployment failed with exit code: {}\n", .{code});
                    return error.DeploymentFailed;
                }
            },
            else => {
                std.debug.print("Payload deployment terminated unexpectedly\n", .{});
                return error.DeploymentTerminated;
            },
        }
    }

    // Step 2: Connect to remote host and execute the entrypoint
    var run_argv = std.ArrayList([]const u8).init(allocator);
    defer run_argv.deinit();
    for (common_argv.items) |arg| {
        try run_argv.append(arg);
    }
    // Allocate pseudo-terminal (-t) for the shell connection
    try run_argv.append("-t");
    try run_argv.append(run_cmd);

    if (zzh_args.verbose or zzh_args.vverbose) {
        std.debug.print("Connecting with command:", .{});
        for (run_argv.items) |arg| {
            std.debug.print(" {s}", .{arg});
        }
        std.debug.print("\n", .{});
    }

    var child = std.process.Child.init(run_argv.items, allocator);
    child.env_map = &env_map;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    // Wait for SSH to complete
    const term = try child.wait();
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

    var args = cli.ZzhArgs.init(testing.allocator);
    defer args.deinit();

    args.shell = try testing.allocator.dupe(u8, "zsh");
    try args.env.append(try testing.allocator.dupe(u8, "VAR1=VAL1"));
    args.verbose = true;

    // Test OOM path to cover errdefer cmd_buf.deinit()
    _ = buildRemoteCommand(testing.failing_allocator, &args) catch |err| {
        try testing.expect(err == error.OutOfMemory);
    };

    const cmd = try buildRemoteCommand(testing.allocator, &args);
    defer testing.allocator.free(cmd);

    try testing.expectEqualStrings("mkdir -p ~/.zzh && tar -xmf - -C ~/.zzh && ln -sf .zzh ~/.zzh/.xxh && chmod -R +x ~/.zzh/.zzh 2>/dev/null || true && ~/.zzh/.zzh/shells/xxh-shell-zsh/build/entrypoint.sh -v 1 -e VAR1=VkFMMQ==", cmd);
}

test "Remote Command Builder Test - Comprehensive" {
    const testing = std.testing;

    var args = cli.ZzhArgs.init(testing.allocator);
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

    const cmd = try buildRemoteCommand(testing.allocator, &args);
    defer testing.allocator.free(cmd);

    // Verify commands inside cmd
    try testing.expect(std.mem.indexOf(u8, cmd, "rm -rf /custom/home &&") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "mkdir -p /custom/home && tar -xmf - -C /custom/home && ln -sf .zzh /custom/home/.xxh && chmod -R +x /custom/home/.zzh") != null);
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
    try testing.expect(std.mem.indexOf(u8, cmd, " && rm -rf /custom/home") != null);
}

test "Remote Command Builder Test - install_force" {
    const testing = std.testing;

    var args = cli.ZzhArgs.init(testing.allocator);
    defer args.deinit();

    args.shell = try testing.allocator.dupe(u8, "zsh");
    args.host_zzh_home = try testing.allocator.dupe(u8, "/custom/home");
    args.install_force = true;
    args.install_force_full = false;

    const cmd = try buildRemoteCommand(testing.allocator, &args);
    defer testing.allocator.free(cmd);

    try testing.expect(std.mem.indexOf(u8, cmd, "rm -rf /custom/home/.zzh &&") != null);
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

    var args = cli.ZzhArgs.init(testing.allocator);
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

    var args = cli.ZzhArgs.init(testing.allocator);
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

fn createPipe() !struct { read: std.fs.File, write: std.fs.File } {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var read_handle: windows.HANDLE = undefined;
        var write_handle: windows.HANDLE = undefined;
        var sa = windows.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = null,
            .bInheritHandle = windows.TRUE,
        };
        const res = windows.kernel32.CreatePipe(&read_handle, &write_handle, &sa, 0);
        if (res == 0) return error.PipeCreationFailed;
        return .{
            .read = std.fs.File{ .handle = read_handle },
            .write = std.fs.File{ .handle = write_handle },
        };
    } else {
        const pipe_fds = try std.posix.pipe();
        return .{
            .read = std.fs.File{ .handle = pipe_fds[0] },
            .write = std.fs.File{ .handle = pipe_fds[1] },
        };
    }
}

test "forwardStdin Unit Test" {
    const testing = std.testing;

    const pipe1 = try createPipe();
    const pipe2 = try createPipe();

    var thread = try std.Thread.spawn(.{}, forwardStdin, .{ pipe2.write, pipe1.read });

    const test_data = "hello world from pipe";
    try pipe1.write.writeAll(test_data);
    pipe1.write.close();

    thread.join();
    pipe2.write.close();

    var buf: [100]u8 = undefined;
    const amt = try pipe2.read.readAll(&buf);
    pipe2.read.close();

    try testing.expectEqualStrings(test_data, buf[0..amt]);
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

    var args = cli.ZzhArgs.init(testing.allocator);
    defer args.deinit();

    args.shell = try testing.allocator.dupe(u8, "zsh");
    args.destination = try testing.allocator.dupe(u8, "localhost");

    // Write a script that immediately terminates with SIGKILL
    try sub_dir.writeFile(.{ .sub_path = "mock_ssh_sig1.sh", .data = "#!/bin/sh\nkill -9 $$\n" });
    var path_b2: [1024]u8 = undefined;
    const mock_ssh_path = try sub_dir.realpath("mock_ssh_sig1.sh", &path_b2);
    const chmod_argv = [_][]const u8{ "chmod", "+x", mock_ssh_path };
    try @import("package.zig").runCommand(testing.allocator, &chmod_argv);

    args.ssh_command = try testing.allocator.dupe(u8, mock_ssh_path);

    const res = deployAndConnect(testing.allocator, &args, archive_path);
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

    var args = cli.ZzhArgs.init(testing.allocator);
    defer args.deinit();

    args.shell = try testing.allocator.dupe(u8, "zsh");
    args.destination = try testing.allocator.dupe(u8, "localhost");

    // Write a stateful script that exits 0 first time, and exits with SIGKILL second time
    const state_file_path = try std.fs.path.join(testing.allocator, &.{ archive_path, "_state" });
    defer testing.allocator.free(state_file_path);

    const script_content = try std.fmt.allocPrint(testing.allocator,
        "#!/bin/sh\n" ++
        "if [ -f \"{s}\" ]; then\n" ++
        "  rm -f \"{s}\"\n" ++
        "  kill -9 $$\n" ++
        "else\n" ++
        "  touch \"{s}\"\n" ++
        "  exit 0\n" ++
        "fi\n",
        .{ state_file_path, state_file_path, state_file_path }
    );
    defer testing.allocator.free(script_content);

    try sub_dir.writeFile(.{ .sub_path = "mock_ssh_sig2.sh", .data = script_content });
    var path_b2: [1024]u8 = undefined;
    const mock_ssh_path = try sub_dir.realpath("mock_ssh_sig2.sh", &path_b2);
    const chmod_argv = [_][]const u8{ "chmod", "+x", mock_ssh_path };
    try @import("package.zig").runCommand(testing.allocator, &chmod_argv);

    args.ssh_command = try testing.allocator.dupe(u8, mock_ssh_path);

    // Should complete without error even if step 2 gets a signal (since step 2 logs it but doesn't propagate error)
    try deployAndConnect(testing.allocator, &args, archive_path);
}
