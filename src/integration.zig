const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const package = @import("package.zig");
const bundler = @import("bundler.zig");
const deploy = @import("deploy.zig");

test "Integration: CLI Overrides Config" {
    const testing = std.testing;

    // 1. Create a mock config file
    const config_content =
        \\hosts:
        \\  ".*":
        \\    +s: zsh
        \\    +hhh: "~"
        \\  "test-host":
        \\    -p: 2222
        \\    +e:
        \\      - OSH_THEME="simple"
    ;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "config.zzhc", .data = config_content });

    var path_buf: [1024]u8 = undefined;
    const absolute_config_path = try tmp_dir.dir.realpath("config.zzhc", &path_buf);

    // 2. Mock parsed CLI arguments that override the config file (e.g. port 3333 and shell fish)
    const cli_args = [_][]const u8{
        "-p", "3333", "test-host", "+s", "fish",
    };

    // 3. Initialize final merged arguments struct
    var final_args = cli.XxhArgs.init(testing.allocator);
    defer final_args.deinit();

    // 4. Step A: Parse config file args first
    var config_args_list = std.ArrayList([]const u8).init(testing.allocator);
    defer {
        for (config_args_list.items) |item| testing.allocator.free(item);
        config_args_list.deinit();
    }
    try config.parseConfig(testing.allocator, absolute_config_path, "test-host", &config_args_list);
    try cli.parseFromSlice(testing.allocator, config_args_list.items, &final_args);

    // 5. Step B: Parse CLI args on top to override
    try cli.parseFromSlice(testing.allocator, &cli_args, &final_args);

    // 6. Assertions
    // Default shell from config was "zsh", but CLI override should be "fish"
    try testing.expectEqualStrings("fish", final_args.shell.?);

    // Port from config was "2222", and CLI override should override to "3333"
    try testing.expectEqualStrings("3333", final_args.ssh_port.?);
    try testing.expectEqualStrings("test-host", final_args.destination.?);
    try testing.expectEqual(@as(usize, 0), final_args.ssh_args.items.len);

    // Env from config should remain as it wasn't overridden on CLI
    try testing.expectEqual(@as(usize, 1), final_args.env.items.len);
    try testing.expectEqualStrings("OSH_THEME=\"simple\"", final_args.env.items[0]);
}

test "Integration: Payload Bundler layout and file copying" {
    const testing = std.testing;

    // Create a mock shell directory with entrypoint and bin
    var tmp_shell_dir = testing.tmpDir(.{});
    defer tmp_shell_dir.cleanup();
    try tmp_shell_dir.dir.writeFile(.{ .sub_path = "entrypoint.sh", .data = "#!/bin/sh\necho shell" });
    try tmp_shell_dir.dir.makeDir("bin");
    try tmp_shell_dir.dir.writeFile(.{ .sub_path = "bin/zsh", .data = "zsh binary" });

    // Create a mock plugin directory
    var tmp_plugin_dir = testing.tmpDir(.{});
    defer tmp_plugin_dir.cleanup();
    try tmp_plugin_dir.dir.writeFile(.{ .sub_path = "init.sh", .data = "#!/bin/sh\necho plugin" });

    var shell_buf: [1024]u8 = undefined;
    const shell_path = try tmp_shell_dir.dir.realpath(".", &shell_buf);

    var plugin_buf: [1024]u8 = undefined;
    const plugin_path = try tmp_plugin_dir.dir.realpath(".", &plugin_buf);

    const plugin_paths = [_][]const u8{plugin_path};

    // Run the bundler
    const result = try bundler.buildPayload(testing.allocator, shell_path, &plugin_paths);
    defer bundler.cleanupBundle(testing.allocator, result);

    // 1. Verify target directory and tarball were generated
    try testing.expect(std.fs.path.isAbsolute(result.temp_build_dir));
    try testing.expect(std.fs.path.isAbsolute(result.archive_path));

    // 2. Open temporary build directory and verify nested structure
    const shell_pkg_name = std.fs.path.basename(shell_path);
    const plugin_folder_name = std.fs.path.basename(plugin_path);

    const check_entrypoint_path = try std.fmt.allocPrint(testing.allocator, "{s}/.zzh/shells/{s}/entrypoint.sh", .{ result.temp_build_dir, shell_pkg_name });
    defer testing.allocator.free(check_entrypoint_path);
    var ep_file = try std.fs.openFileAbsolute(check_entrypoint_path, .{});
    ep_file.close();

    const check_zsh_path = try std.fmt.allocPrint(testing.allocator, "{s}/.zzh/shells/{s}/bin/zsh", .{ result.temp_build_dir, shell_pkg_name });
    defer testing.allocator.free(check_zsh_path);
    var zsh_file = try std.fs.openFileAbsolute(check_zsh_path, .{});
    zsh_file.close();

    const check_init_path = try std.fmt.allocPrint(testing.allocator, "{s}/.zzh/plugins/{s}/init.sh", .{ result.temp_build_dir, plugin_folder_name });
    defer testing.allocator.free(check_init_path);
    var init_file = try std.fs.openFileAbsolute(check_init_path, .{});
    init_file.close();
}

test "Integration: Remote command generation and quoting" {
    const testing = std.testing;

    var args = cli.XxhArgs.init(testing.allocator);
    defer args.deinit();

    args.shell = try testing.allocator.dupe(u8, "zsh");
    try args.env.append(try testing.allocator.dupe(u8, "A=B"));
    try args.env.append(try testing.allocator.dupe(u8, "C=D E F"));
    args.verbose = true;

    const cmd = try deploy.buildRemoteCommand(testing.allocator, &args);
    defer testing.allocator.free(cmd);

    try testing.expectEqualStrings("mkdir -p ~/.zzh && tar -xf - -C ~/.zzh && ~/.zzh/.zzh/shells/xxh-shell-zsh/build/entrypoint.sh -v 1 -e A=Qg== -e C=RCBFIEY=", cmd);
}

test "Integration: Host regex pattern translation and matching" {
    const testing = std.testing;

    // Matches '.*' (all)
    try testing.expect(config.matchPattern(testing.allocator, ".*", "host-a"));
    try testing.expect(config.matchPattern(testing.allocator, "*", "host-b"));

    // Matches 'prod-server-.*'
    try testing.expect(config.matchPattern(testing.allocator, "prod-server-.*", "prod-server-01"));
    try testing.expect(!config.matchPattern(testing.allocator, "prod-server-.*", "dev-server-01"));

    // Matches exact
    try testing.expect(config.matchPattern(testing.allocator, "my-exact-host", "my-exact-host"));
    try testing.expect(!config.matchPattern(testing.allocator, "my-exact-host", "my-exact-host-2"));
}
