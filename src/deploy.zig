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

pub fn buildRemoteCommand(allocator: std.mem.Allocator, xxh_args: *const cli.XxhArgs) ![]const u8 {
    var cmd_buf = std.ArrayList(u8).init(allocator);
    errdefer cmd_buf.deinit();

    const host_xxh_home = xxh_args.host_xxh_home orelse "~/.zzh";
    const shell = xxh_args.shell orelse "zsh";

    if (xxh_args.install_force_full) {
        try cmd_buf.appendSlice("rm -rf ");
        try cmd_buf.appendSlice(host_xxh_home);
        try cmd_buf.appendSlice(" && ");
    } else if (xxh_args.install_force) {
        try cmd_buf.appendSlice("rm -rf ");
        try cmd_buf.appendSlice(host_xxh_home);
        try cmd_buf.appendSlice("/.zzh && ");
    }

    try cmd_buf.appendSlice("mkdir -p ");
    try cmd_buf.appendSlice(host_xxh_home);
    try cmd_buf.appendSlice(" && tar -xf - -C ");
    try cmd_buf.appendSlice(host_xxh_home);
    try cmd_buf.appendSlice(" && ");

    var shell_pkg_name = std.ArrayList(u8).init(allocator);
    defer shell_pkg_name.deinit();
    if (!std.mem.startsWith(u8, shell, "xxh-shell-")) {
        try shell_pkg_name.appendSlice("xxh-shell-");
    }
    try shell_pkg_name.appendSlice(shell);

    try cmd_buf.appendSlice(host_xxh_home);
    try cmd_buf.appendSlice("/.zzh/shells/");
    try cmd_buf.appendSlice(shell_pkg_name.items);
    try cmd_buf.appendSlice("/build/entrypoint.sh");

    if (xxh_args.host_execute_file) |f| {
        try cmd_buf.appendSlice(" -f \"");
        try cmd_buf.appendSlice(f);
        try cmd_buf.appendSlice("\"");
    }

    if (xxh_args.host_execute_command) |hc| {
        const hc_b64 = try b64Encode(allocator, hc);
        defer allocator.free(hc_b64);
        try cmd_buf.appendSlice(" -C ");
        try cmd_buf.appendSlice(hc_b64);
    }

    if (xxh_args.vverbose) {
        try cmd_buf.appendSlice(" -v 2");
    } else if (xxh_args.verbose) {
        try cmd_buf.appendSlice(" -v 1");
    }

    for (xxh_args.env.items) |e| {
        const formatted = try formatEnvVar(allocator, e, true);
        defer allocator.free(formatted);
        try cmd_buf.appendSlice(" -e ");
        try cmd_buf.appendSlice(formatted);
    }
    for (xxh_args.envb.items) |e| {
        const formatted = try formatEnvVar(allocator, e, false);
        defer allocator.free(formatted);
        try cmd_buf.appendSlice(" -e ");
        try cmd_buf.appendSlice(formatted);
    }

    if (xxh_args.host_home) |h| {
        try cmd_buf.appendSlice(" -H ");
        try cmd_buf.appendSlice(h);
    }

    if (xxh_args.host_home_xdg) |hx| {
        try cmd_buf.appendSlice(" -X ");
        try cmd_buf.appendSlice(hx);
    }

    for (xxh_args.host_execute_bash.items) |b| {
        const b_b64 = try b64Encode(allocator, b);
        defer allocator.free(b_b64);
        try cmd_buf.appendSlice(" -b ");
        try cmd_buf.appendSlice(b_b64);
    }

    if (xxh_args.host_xxh_home_remove) {
        try cmd_buf.appendSlice(" && rm -rf ");
        try cmd_buf.appendSlice(host_xxh_home);
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

pub fn deployAndConnect(allocator: std.mem.Allocator, xxh_args: *const cli.XxhArgs, archive_path: []const u8) !void {
    const remote_cmd = try buildRemoteCommand(allocator, xxh_args);
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
            if (std.mem.startsWith(u8, part, "tar -xf ")) {
                found_tar = true;
            }
        } else {
            try run_cmd_parts.append(part);
        }
    }

    const deploy_cmd = if (found_tar) try std.mem.join(allocator, " && ", deploy_cmd_parts.items) else null;
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

    const ssh_cmd = xxh_args.ssh_command orelse "ssh";
    try common_argv.append(try allocator.dupe(u8, ssh_cmd));

    try common_argv.append(try allocator.dupe(u8, "-o"));
    try common_argv.append(try allocator.dupe(u8, "StrictHostKeyChecking=accept-new"));

    if (!xxh_args.verbose and !xxh_args.vverbose) {
        try common_argv.append(try allocator.dupe(u8, "-o"));
        try common_argv.append(try allocator.dupe(u8, "LogLevel=QUIET"));
    }

    if (xxh_args.ssh_port) |p| {
        try common_argv.append(try allocator.dupe(u8, "-o"));
        const opt = try std.fmt.allocPrint(allocator, "Port={s}", .{p});
        defer allocator.free(opt);
        try common_argv.append(try allocator.dupe(u8, opt));
    }

    if (xxh_args.ssh_private_key) |k| {
        try common_argv.append(try allocator.dupe(u8, "-o"));
        const opt = try std.fmt.allocPrint(allocator, "IdentityFile={s}", .{k});
        defer allocator.free(opt);
        try common_argv.append(try allocator.dupe(u8, opt));
    }

    if (xxh_args.ssh_login) |l| {
        try common_argv.append(try allocator.dupe(u8, "-o"));
        const opt = try std.fmt.allocPrint(allocator, "User={s}", .{l});
        defer allocator.free(opt);
        try common_argv.append(try allocator.dupe(u8, opt));
    }

    if (xxh_args.ssh_jump_host) |j| {
        try common_argv.append(try allocator.dupe(u8, "-o"));
        const opt = try std.fmt.allocPrint(allocator, "ProxyJump={s}", .{j});
        defer allocator.free(opt);
        try common_argv.append(try allocator.dupe(u8, opt));
    }

    for (xxh_args.ssh_options.items) |o| {
        try common_argv.append(try allocator.dupe(u8, "-o"));
        try common_argv.append(try allocator.dupe(u8, o));
    }

    for (xxh_args.ssh_args.items) |arg| {
        try common_argv.append(try allocator.dupe(u8, arg));
    }

    if (xxh_args.destination) |dest| {
        const dest_info = cli.parseDestination(dest);
        try common_argv.append(try allocator.dupe(u8, dest_info.host));
    }

    // Step 1: Deploy the payload if deployment is needed
    if (deploy_cmd) |d_cmd| {
        var deploy_argv = std.ArrayList([]const u8).init(allocator);
        defer deploy_argv.deinit();
        for (common_argv.items) |arg| {
            try deploy_argv.append(arg);
        }
        try deploy_argv.append(d_cmd);

        if (xxh_args.verbose or xxh_args.vverbose) {
            std.debug.print("Deploying payload with command:", .{});
            for (deploy_argv.items) |arg| {
                std.debug.print(" {s}", .{arg});
            }
            std.debug.print("\n", .{});
        }

        var child = std.process.Child.init(deploy_argv.items, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        try child.spawn();

        // Write the tarball archive bytes to child's stdin
        var archive_file = try std.fs.openFileAbsolute(archive_path, .{});
        defer archive_file.close();

        var buf: [4096]u8 = undefined;
        while (true) {
            const amt = try archive_file.read(&buf);
            if (amt == 0) break;
            try child.stdin.?.writeAll(buf[0..amt]);
        }
        child.stdin.?.close();
        child.stdin = null;

        const term = try child.wait();
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

    if (xxh_args.verbose or xxh_args.vverbose) {
        std.debug.print("Connecting with command:", .{});
        for (run_argv.items) |arg| {
            std.debug.print(" {s}", .{arg});
        }
        std.debug.print("\n", .{});
    }

    var child = std.process.Child.init(run_argv.items, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    // Start stdin forwarding in background thread
    var thread = try std.Thread.spawn(.{}, forwardStdin, .{
        child.stdin.?,
        std.io.getStdIn(),
    });
    thread.detach();

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

    var args = cli.XxhArgs.init(testing.allocator);
    defer args.deinit();

    args.shell = try testing.allocator.dupe(u8, "zsh");
    try args.env.append(try testing.allocator.dupe(u8, "VAR1=VAL1"));
    args.verbose = true;

    const cmd = try buildRemoteCommand(testing.allocator, &args);
    defer testing.allocator.free(cmd);

    try testing.expectEqualStrings("mkdir -p ~/.zzh && tar -xf - -C ~/.zzh && ~/.zzh/.zzh/shells/xxh-shell-zsh/build/entrypoint.sh -v 1 -e VAR1=VkFMMQ==", cmd);
}
