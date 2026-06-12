const std = @import("std");

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
    std.time.sleep(5 * std.time.ns_per_s);

    const zzh_exe = if (@import("builtin").os.tag == .windows) "zig-out/bin/zzh.exe" else "zig-out/bin/zzh";

    const zzh_run = [_][]const u8{
        zzh_exe,
        "testuser@127.0.0.1",
        "-p", "2222",
        "++password", "testpass",
        "+s", "zsh",
        "+hc", "echo E2E_SUCCESS"
    };

    std.debug.print("Running zzh...\n", .{});
    var zzh_child = std.process.Child.init(&zzh_run, allocator);
    zzh_child.stdout_behavior = .Pipe;
    try zzh_child.spawn();

    var out_buf = std.ArrayList(u8).init(allocator);
    defer out_buf.deinit();

    var stdout_reader = zzh_child.stdout.?.reader();
    while (true) {
        var buf: [1024]u8 = undefined;
        const amt = stdout_reader.read(&buf) catch break;
        if (amt == 0) break;
        out_buf.appendSlice(buf[0..amt]) catch break;
    }

    const term = try zzh_child.wait();
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("zzh failed with exit code: {}\n", .{term});
        std.process.exit(1);
    }

    if (std.mem.indexOf(u8, out_buf.items, "E2E_SUCCESS") != null) {
        std.debug.print("E2E Test Passed!\n", .{});
    } else {
        std.debug.print("E2E Test Failed: Could not find E2E_SUCCESS in output.\n", .{});
        std.process.exit(1);
    }
}
