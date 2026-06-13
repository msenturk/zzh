const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const package = @import("package.zig");
const bundler = @import("bundler.zig");
const deploy = @import("deploy.zig");

// Integration tests ensure that config override hierarchies, payload staging, 
// and remote command compiling layers work in harmony without regression.

test "Integration: CLI Overrides Config" {
    const testing = std.testing;

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

    // We verify that CLI arguments take precedence over matched file configurations
    // so that users can dynamically override standard defaults per-invocation.
    const cli_args = [_][]const u8{
        "-p", "3333", "test-host", "+s", "fish",
    };

    var final_settings = cli.OperationalConfig.init(testing.allocator);
    defer final_settings.deinit();

    var config_args_list = std.ArrayList([]const u8).init(testing.allocator);
    defer {
        for (config_args_list.items) |item| testing.allocator.free(item);
        config_args_list.deinit();
    }
    try config.readAndParseConfigurationFile(testing.allocator, absolute_config_path, "test-host", &config_args_list);
    try cli.populateConfigFromTokens(testing.allocator, config_args_list.items, &final_settings);

    try cli.populateConfigFromTokens(testing.allocator, &cli_args, &final_settings);

    // Matches 'fish' override.
    try testing.expectEqualStrings("fish", final_settings.shell.?);

    // Matches '3333' override.
    try testing.expectEqualStrings("3333", final_settings.ssh_port.?);
    try testing.expectEqualStrings("test-host", final_settings.destination.?);
    try testing.expectEqual(@as(usize, 0), final_settings.ssh_args.items.len);

    // Non-overridden variables must remain unchanged.
    try testing.expectEqual(@as(usize, 1), final_settings.env.items.len);
    try testing.expectEqualStrings("OSH_THEME=\"simple\"", final_settings.env.items[0]);
}

test "Integration: Payload Bundler layout and file copying" {
    const testing = std.testing;

    var tmp_shell_dir = testing.tmpDir(.{});
    defer tmp_shell_dir.cleanup();
    try tmp_shell_dir.dir.writeFile(.{ .sub_path = "entrypoint.sh", .data = "#!/bin/sh\necho shell" });
    try tmp_shell_dir.dir.makeDir("bin");
    try tmp_shell_dir.dir.writeFile(.{ .sub_path = "bin/zsh", .data = "zsh binary" });

    var tmp_plugin_dir = testing.tmpDir(.{});
    defer tmp_plugin_dir.cleanup();
    try tmp_plugin_dir.dir.writeFile(.{ .sub_path = "init.sh", .data = "#!/bin/sh\necho plugin" });

    var shell_buf: [1024]u8 = undefined;
    const shell_path = try tmp_shell_dir.dir.realpath(".", &shell_buf);

    var plugin_buf: [1024]u8 = undefined;
    const plugin_path = try tmp_plugin_dir.dir.realpath(".", &plugin_buf);

    const plugin_paths = [_][]const u8{plugin_path};

    var dummy_args = @import("cli.zig").OperationalConfig.init(testing.allocator);
    dummy_args.install_force = true;
    defer dummy_args.deinit();
    
    // We execute the payload builder to verify that shell assets, plugin initializers,
    // and directories are placed in their correct relative structures inside the archive.
    const result = try bundler.assembleDeploymentPayload(testing.allocator, shell_path, &plugin_paths, &dummy_args);
    defer bundler.discardStagingArea(testing.allocator, result);

    try testing.expect(std.fs.path.isAbsolute(result.staging_area_path));
    try testing.expect(std.fs.path.isAbsolute(result.tarball_output_path));

    const shell_pkg_name = std.fs.path.basename(shell_path);
    const plugin_folder_name = std.fs.path.basename(plugin_path);

    const check_entrypoint_path = try std.fmt.allocPrint(testing.allocator, "{s}/.zzh/shells/{s}/entrypoint.sh", .{ result.staging_area_path, shell_pkg_name });
    defer testing.allocator.free(check_entrypoint_path);
    var ep_file = try std.fs.openFileAbsolute(check_entrypoint_path, .{});
    ep_file.close();

    const check_zsh_path = try std.fmt.allocPrint(testing.allocator, "{s}/.zzh/shells/{s}/bin/zsh", .{ result.staging_area_path, shell_pkg_name });
    defer testing.allocator.free(check_zsh_path);
    var zsh_file = try std.fs.openFileAbsolute(check_zsh_path, .{});
    zsh_file.close();

    const check_init_path = try std.fmt.allocPrint(testing.allocator, "{s}/.zzh/plugins/{s}/init.sh", .{ result.staging_area_path, plugin_folder_name });
    defer testing.allocator.free(check_init_path);
    var init_file = try std.fs.openFileAbsolute(check_init_path, .{});
    init_file.close();
}

test "Integration: Remote command generation and quoting" {
    const testing = std.testing;

    var args = cli.OperationalConfig.init(testing.allocator);
    defer args.deinit();

    args.shell = try testing.allocator.dupe(u8, "zsh");
    try args.env.append(try testing.allocator.dupe(u8, "A=B"));
    try args.env.append(try testing.allocator.dupe(u8, "C=D E F"));
    args.verbose = true;

    // Verifies that environmental configurations and payload expansion parameters 
    // are correctly compiled and escaped into safe SSH deployment commands.
    const staged_script = try deploy.compileStagedScript(testing.allocator, &args);
    defer staged_script.deinit(testing.allocator);
    const cmd = try std.mem.join(testing.allocator, " && ", &.{ staged_script.bootstrap_script, staged_script.session_script });
    defer testing.allocator.free(cmd);

    try testing.expectEqualStrings("mkdir -p ~/'.zzh' && tar -xmf - -C ~/'.zzh' && ln -sf .zzh ~/'.zzh'/.xxh && chmod -R +x ~/'.zzh' 2>/dev/null || true && ~/'.zzh'/.zzh/shells/xxh-shell-zsh/build/entrypoint.sh -v 1 -b ZXhwb3J0IFpaSF9IT01FPSd+Ly56emgnOyBleHBvcnQgWFhIX0hPTUU9J34vLnp6aCc7IGV4cG9ydCBQQVRIPSJ+Ly56emgvYmluOi91c3IvbG9jYWwvc2JpbjovdXNyL2xvY2FsL2JpbjovdXNyL3NiaW46L3Vzci9iaW46L3NiaW46L2JpbjokUEFUSCI= -e A=Qg== -e C=RCBFIEY= -H ~", cmd);
}

test "Integration: Host regex pattern translation and matching" {
    const testing = std.testing;

    // Matches '.*' (all)
    try testing.expect(config.hostMatchesPattern(testing.allocator, ".*", "host-a"));
    try testing.expect(config.hostMatchesPattern(testing.allocator, "*", "host-b"));

    // Matches 'prod-server-.*'
    try testing.expect(config.hostMatchesPattern(testing.allocator, "prod-server-.*", "prod-server-01"));
    try testing.expect(!config.hostMatchesPattern(testing.allocator, "prod-server-.*", "dev-server-01"));

    // Matches exact
    try testing.expect(config.hostMatchesPattern(testing.allocator, "my-exact-host", "my-exact-host"));
    try testing.expect(!config.hostMatchesPattern(testing.allocator, "my-exact-host", "my-exact-host-2"));
}



