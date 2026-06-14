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

    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "config.zzhc", .data = config_content });

    var path_buf: [1024]u8 = undefined;
    const absolute_config_path_len = try tmp_dir.dir.realPathFile(std.testing.io, "config.zzhc", &path_buf);
    const absolute_config_path = path_buf[0..absolute_config_path_len];

    // We verify that CLI arguments take precedence over matched file configurations
    // so that users can dynamically override standard defaults per-invocation.
    const cli_args = [_][]const u8{
        "-p", "3333", "test-host", "+s", "fish",
    };

    var final_settings = cli.OperationalConfig.init(std.testing.allocator);
    defer final_settings.deinit(testing.allocator);

    var config_args_list = std.ArrayList([]const u8).empty;
    defer {
        for (config_args_list.items) |item| std.testing.allocator.free(item);
        config_args_list.deinit(std.testing.allocator);
    }
    try config.readAndParseConfigurationFile(std.testing.allocator, absolute_config_path, "test-host", &config_args_list);
    try cli.populateConfigFromTokens(std.testing.allocator, config_args_list.items, &final_settings);

    try cli.populateConfigFromTokens(std.testing.allocator, &cli_args, &final_settings);

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
    try tmp_shell_dir.dir.writeFile(std.testing.io, .{ .sub_path = "entrypoint.sh", .data = "#!/bin/sh\necho shell" });
    try tmp_shell_dir.dir.createDir(std.testing.io, "bin", .default_dir);
    try tmp_shell_dir.dir.writeFile(std.testing.io, .{ .sub_path = "bin/zsh", .data = "zsh binary" });

    var tmp_plugin_dir = testing.tmpDir(.{});
    defer tmp_plugin_dir.cleanup();
    try tmp_plugin_dir.dir.writeFile(std.testing.io, .{ .sub_path = "init.sh", .data = "#!/bin/sh\necho plugin" });

    var shell_buf: [1024]u8 = undefined;
    const shell_path_len = try tmp_shell_dir.dir.realPathFile(std.testing.io, ".", &shell_buf);
    const shell_path = shell_buf[0..shell_path_len];

    var plugin_buf: [1024]u8 = undefined;
    const plugin_path_len = try tmp_plugin_dir.dir.realPathFile(std.testing.io, ".", &plugin_buf);
    const plugin_path = plugin_buf[0..plugin_path_len];

    const plugin_paths = [_][]const u8{plugin_path};

    var dummy_args = @import("cli.zig").OperationalConfig.init(std.testing.allocator);
    dummy_args.install_force = true;
    defer dummy_args.deinit(std.testing.allocator);

    // We execute the payload builder to verify that shell assets, plugin initializers,
    // and directories are placed in their correct relative structures inside the archive.
    const result = try bundler.assembleDeploymentPayload(std.testing.allocator, shell_path, &plugin_paths, &dummy_args);
    defer bundler.discardStagingArea(std.testing.allocator, result);

    try testing.expect(std.fs.path.isAbsolute(result.staging_area_path));
    try testing.expect(std.fs.path.isAbsolute(result.tarball_output_path));

    const shell_pkg_name = std.fs.path.basename(shell_path);
    const plugin_folder_name = std.fs.path.basename(plugin_path);

    const check_entrypoint_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zzh/shells/{s}/entrypoint.sh", .{ result.staging_area_path, shell_pkg_name });
    defer std.testing.allocator.free(check_entrypoint_path);
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    var ep_file = try std.Io.Dir.openFileAbsolute(threaded_io.io(), check_entrypoint_path, .{});
    ep_file.close(threaded_io.io());

    const check_zsh_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zzh/shells/{s}/bin/zsh", .{ result.staging_area_path, shell_pkg_name });
    defer std.testing.allocator.free(check_zsh_path);
    var zsh_file = try std.Io.Dir.openFileAbsolute(threaded_io.io(), check_zsh_path, .{});
    zsh_file.close(threaded_io.io());

    const check_init_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zzh/plugins/{s}/init.sh", .{ result.staging_area_path, plugin_folder_name });
    defer std.testing.allocator.free(check_init_path);
    var init_file = try std.Io.Dir.openFileAbsolute(threaded_io.io(), check_init_path, .{});
    init_file.close(threaded_io.io());
}

test "Integration: Remote command generation and quoting" {
    const testing = std.testing;

    var args = cli.OperationalConfig.init(std.testing.allocator);
    defer args.deinit(std.testing.allocator);

    args.shell = try std.testing.allocator.dupe(u8, "zsh");
    try args.env.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "A=B"));
    try args.env.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "C=D E F"));
    args.verbose = true;

    // Verifies that environmental configurations and payload expansion parameters
    // are correctly compiled and escaped into safe SSH deployment commands.
    const staged_script = try deploy.compileStagedScript(std.testing.allocator, &args);
    defer staged_script.deinit(std.testing.allocator);
    const cmd = try std.mem.join(std.testing.allocator, " && ", &.{ staged_script.bootstrap_script, staged_script.session_script });
    defer std.testing.allocator.free(cmd);

    try testing.expectEqualStrings("mkdir -p ~/'.zzh' && tar -xmf - -C ~/'.zzh' && ln -sf .zzh ~/'.zzh'/.xxh && chmod -R +x ~/'.zzh' 2>/dev/null || true && ~/'.zzh'/.zzh/shells/xxh-shell-zsh/build/entrypoint.sh -v 1 -b ZXhwb3J0IFpaSF9IT01FPSd+Ly56emgnOyBleHBvcnQgWFhIX0hPTUU9J34vLnp6aCc7IGV4cG9ydCBQQVRIPSJ+Ly56emgvYmluOi91c3IvbG9jYWwvc2JpbjovdXNyL2xvY2FsL2JpbjovdXNyL3NiaW46L3Vzci9iaW46L3NiaW46L2JpbjokUEFUSCI= -e A=Qg== -e C=RCBFIEY= -H ~", cmd);
}

test "Integration: Host regex pattern translation and matching" {
    const testing = std.testing;

    // Matches '.*' (all)
    try testing.expect(config.hostMatchesPattern(std.testing.allocator, ".*", "host-a"));
    try testing.expect(config.hostMatchesPattern(std.testing.allocator, "*", "host-b"));

    // Matches 'prod-server-.*'
    try testing.expect(config.hostMatchesPattern(std.testing.allocator, "prod-server-.*", "prod-server-01"));
    try testing.expect(!config.hostMatchesPattern(std.testing.allocator, "prod-server-.*", "dev-server-01"));

    // Matches exact
    try testing.expect(config.hostMatchesPattern(std.testing.allocator, "my-exact-host", "my-exact-host"));
    try testing.expect(!config.hostMatchesPattern(std.testing.allocator, "my-exact-host", "my-exact-host-2"));
}
