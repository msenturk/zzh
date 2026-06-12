const std = @import("std");

fn runZzh(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    var out_buf = std.ArrayList(u8).init(allocator);
    errdefer out_buf.deinit();

    var stdout_reader = child.stdout.?.reader();
    while (true) {
        var buf: [1024]u8 = undefined;
        const amt = try stdout_reader.read(&buf);
        if (amt == 0) break;
        try out_buf.appendSlice(buf[0..amt]);
    }

    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("Command failed: ", .{});
        for (args) |arg| {
            std.debug.print("{s} ", .{arg});
        }
        std.debug.print("\n", .{});
        return error.CommandFailed;
    }

    return out_buf.toOwnedSlice();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Running E2E tests...\n", .{});

    // Start docker container
    const docker_run = [_][]const u8{
        "docker", "run", "-d", "--rm", "--name", "zzh-e2e-test",
        "-p", "2222:2222",
        "-e", "USER_NAME=testuser",
        "-e", "USER_PASSWORD=testpass",
        "-e", "PASSWORD_ACCESS=true",
        "linuxserver/openssh-server"
    };

    std.debug.print("Starting docker container...\n", .{});
    var child = std.process.Child.init(&docker_run, allocator);
    child.spawn() catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Docker not found. Skipping E2E test.\n", .{});
            return;
        }
        return err;
    };
    _ = try child.wait();

    defer {
        const docker_rm = [_][]const u8{ "docker", "rm", "-f", "zzh-e2e-test" };
        var rm_child = std.process.Child.init(&docker_rm, allocator);
        rm_child.spawn() catch {};
        _ = rm_child.wait() catch {};
    }

    // Wait for SSH to become available
    std.debug.print("Waiting for SSH to become available...\n", .{});
    std.time.sleep(8 * std.time.ns_per_s);

    const zzh_exe = if (@import("builtin").os.tag == .windows) "zig-out/bin/zzh.exe" else "zig-out/bin/zzh";

    // Test 1: Basic Connection E2E
    std.debug.print("Running Test 1 (Basic Connection)...\n", .{});
    const args1 = [_][]const u8{
        zzh_exe,
        "testuser@127.0.0.1",
        "-p", "2222",
        "++password", "testpass",
        "+s", "zsh",
        "+hc", "echo E2E_SUCCESS"
    };
    const out1 = try runZzh(allocator, &args1);
    defer allocator.free(out1);
    if (std.mem.indexOf(u8, out1, "E2E_SUCCESS") == null) {
        std.debug.print("Test 1 Failed: {s}\n", .{out1});
        std.process.exit(1);
    }
    std.debug.print("Test 1 (Basic Connection) Passed!\n", .{});

    // Test 2: Tmux Deployment and Session Wrapping E2E
    std.debug.print("Running Test 2 (Tmux Deployment & Wrapping)...\n", .{});
    const args2 = [_][]const u8{
        zzh_exe,
        "testuser@127.0.0.1",
        "-p", "2222",
        "++password", "testpass",
        "+s", "zsh",
        "++tmux",
        "+hc", "tmux -V"
    };
    const out2 = try runZzh(allocator, &args2);
    defer allocator.free(out2);
    if (std.mem.indexOf(u8, out2, "tmux") == null) {
        std.debug.print("Test 2 Failed: {s}\n", .{out2});
        std.process.exit(1);
    }
    std.debug.print("Test 2 (Tmux Deployment & Execution) Passed!\n", .{});

    // Test 3: Static Binary Provisioning E2E (+b)
    std.debug.print("Running Test 3 (Static Binary Provisioning - ripgrep)...\n", .{});
    const args3 = [_][]const u8{
        zzh_exe,
        "testuser@127.0.0.1",
        "-p", "2222",
        "++password", "testpass",
        "+s", "zsh",
        "+b", "BurntSushi/ripgrep",
        "+hc", "rg --version"
    };
    const out3 = try runZzh(allocator, &args3);
    defer allocator.free(out3);
    if (std.mem.indexOf(u8, out3, "ripgrep") == null) {
        std.debug.print("Test 3 Failed: {s}\n", .{out3});
        std.process.exit(1);
    }
    std.debug.print("Test 3 (Static Binary Provisioning - ripgrep) Passed!\n", .{});

    std.debug.print("All E2E Tests Passed successfully!\n", .{});
}
