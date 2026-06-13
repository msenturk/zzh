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

    const rand = std.crypto.random.int(u64);
    const port_num = 40000 + (rand % 10000);
    var port_mapping_b: [64]u8 = undefined;
    const port_mapping = try std.fmt.bufPrint(&port_mapping_b, "{d}:2222", .{port_num});
    var port_str_b: [16]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_str_b, "{d}", .{port_num});

    std.debug.print("Starting podman container on port {d}...\n", .{port_num});
    const podman_run = [_][]const u8{
        "podman", "run", "-d", "--rm", "--replace", "--name", "zzh-e2e-test",
        "-p", port_mapping,
        "-e", "USER_NAME=testuser",
        "-e", "USER_PASSWORD=testpass",
        "-e", "PASSWORD_ACCESS=true",
        "lscr.io/linuxserver/openssh-server"
    };

    std.debug.print("Starting podman container...\n", .{});
    var child = std.process.Child.init(&podman_run, allocator);
    child.spawn() catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Podman not found. Skipping E2E test.\n", .{});
            return;
        }
        return err;
    };
    _ = try child.wait();

    defer {
        const podman_rm = [_][]const u8{ "podman", "rm", "-f", "zzh-e2e-test" };
        var rm_child = std.process.Child.init(&podman_rm, allocator);
        rm_child.spawn() catch {};
        _ = rm_child.wait() catch {};
    }

    // Wait for SSH to become available
    std.debug.print("Waiting for SSH to become available...\n", .{});
    std.time.sleep(8 * std.time.ns_per_s);

    // Install dependencies in container for plugin testing
    std.debug.print("Installing dependencies in test container (python3, git, curl)...\n", .{});
    const apk_args = [_][]const u8{
        "podman", "exec", "zzh-e2e-test", "apk", "add", "--no-cache", "python3", "git", "curl"
    };
    var apk_child = std.process.Child.init(&apk_args, allocator);
    _ = try apk_child.spawnAndWait();

    const zzh_exe = if (@import("builtin").os.tag == .windows) "zig-out/bin/zzh.exe" else "zig-out/bin/zzh";

    // Test 1: Basic Connection E2E
    std.debug.print("Running Test 1 (Basic Connection)...\n", .{});
    const args1 = [_][]const u8{
        zzh_exe,
        "testuser@127.0.0.1",
        "-p", port_str,
        "++password", "testpass",
        "+xc", "/dev/null",
        "+vv",
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
        "-p", port_str,
        "++password", "testpass",
        "+xc", "/dev/null",
        "+vv",
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
        "-p", port_str,
        "++password", "testpass",
        "+xc", "/dev/null",
        "+vv",
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

    // Create a local dotfile for testing
    const test_dotfile_content = "dotfile_content_test";
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "e2e_dotfile", .data = test_dotfile_content });
    var e2e_dotfile_buf: [1024]u8 = undefined;
    const e2e_dotfile_path = try tmp_dir.dir.realpath("e2e_dotfile", &e2e_dotfile_buf);

    // Test 4: Native Dotfiles (+d)
    std.debug.print("Running Test 4 (Native Dotfiles)... \n", .{});
    const args4 = [_][]const u8{
        zzh_exe,
        "testuser@127.0.0.1",
        "-p", port_str,
        "++password", "testpass",
        "+xc", "/dev/null",
        "+s", "zsh",
        "+d", e2e_dotfile_path,
        "+hc", "cat e2e_dotfile"
    };
    const out4 = try runZzh(allocator, &args4);
    defer allocator.free(out4);
    if (std.mem.indexOf(u8, out4, test_dotfile_content) == null) {
        std.debug.print("Test 4 Failed: {s}\n", .{out4});
        std.process.exit(1);
    }
    std.debug.print("Test 4 (Native Dotfiles) Passed!\n", .{});

    // Test 5: xxh-plugin-prerun-dotfiles
    std.debug.print("Running Test 5 (xxh-plugin-prerun-dotfiles)...\n", .{});
    const args5 = [_][]const u8{
        zzh_exe,
        "testuser@127.0.0.1",
        "-p", port_str,
        "++password", "testpass",
        "+xc", "/dev/null",
        "+s", "zsh",
        "+I", "xxh-plugin-prerun-dotfiles",
        "+hc", "echo PLUGIN_DOTFILES_SUCCESS"
    };
    const out5 = try runZzh(allocator, &args5);
    defer allocator.free(out5);
    if (std.mem.indexOf(u8, out5, "PLUGIN_DOTFILES_SUCCESS") == null) {
        std.debug.print("Test 5 Failed: {s}\n", .{out5});
        std.process.exit(1);
    }
    std.debug.print("Test 5 (xxh-plugin-prerun-dotfiles) Passed!\n", .{});

    // Test 6: Shell-Specific Plugin (zsh-autosuggestions)
    std.debug.print("Running Test 6 (Shell-Specific Plugin - zsh-autosuggestions)...\n", .{});
    const args6 = [_][]const u8{
        zzh_exe,
        "testuser@127.0.0.1",
        "-p", port_str,
        "++password", "testpass",
        "+xc", "/dev/null",
        "+s", "zsh",
        "+I", "xxh-plugin-zsh-autosuggestions",
        "+hc", "echo ZSH_AUTO_SUCCESS"
    };
    const out6 = try runZzh(allocator, &args6);
    defer allocator.free(out6);
    if (std.mem.indexOf(u8, out6, "ZSH_AUTO_SUCCESS") == null) {
        std.debug.print("Test 6 Failed: {s}\n", .{out6});
        std.process.exit(1);
    }
    std.debug.print("Test 6 (Shell-Specific Plugin - zsh-autosuggestions) Passed!\n", .{});

    // Test 7: Multiple Plugins
    std.debug.print("Running Test 7 (Multiple Plugins)...\n", .{});
    const args7 = [_][]const u8{
        zzh_exe,
        "testuser@127.0.0.1",
        "-p", port_str,
        "++password", "testpass",
        "+xc", "/dev/null",
        "+s", "zsh",
        "+I", "xxh-plugin-zsh-example",
        "+I", "xxh-plugin-prerun-core",
        "+hc", "echo MULTI_PLUGIN_SUCCESS"
    };
    const out7 = try runZzh(allocator, &args7);
    defer allocator.free(out7);
    if (std.mem.indexOf(u8, out7, "MULTI_PLUGIN_SUCCESS") == null) {
        std.debug.print("Test 7 Failed: {s}\n", .{out7});
        std.process.exit(1);
    }
    std.debug.print("Test 7 (Multiple Plugins) Passed!\n", .{});

    std.debug.print("All E2E Tests Passed successfully!\n", .{});
}
