const std = @import("std");
const config = @import("config.zig");

pub const ResolvedPackage = struct {
    name: []const u8,
    git_url: []const u8,
    clean_name: []const u8,
};

pub fn freeResolvedPackage(allocator: std.mem.Allocator, pkg: ResolvedPackage) void {
    allocator.free(pkg.name);
    allocator.free(pkg.git_url);
    allocator.free(pkg.clean_name);
}

pub fn resolvePackageName(allocator: std.mem.Allocator, name: []const u8, is_shell: bool) ![]const u8 {
    if (is_shell) {
        if (!std.mem.startsWith(u8, name, "xxh-shell-")) {
            if (std.mem.indexOf(u8, name, "+git+")) |idx| {
                const shell_short = name[0..idx];
                const rest = name[idx..];
                if (!std.mem.startsWith(u8, shell_short, "xxh-shell-")) {
                    return std.fmt.allocPrint(allocator, "xxh-shell-{s}{s}", .{ shell_short, rest });
                }
            } else {
                return std.fmt.allocPrint(allocator, "xxh-shell-{s}", .{name});
            }
        }
    } else {
        if (!std.mem.startsWith(u8, name, "xxh-plugin-")) {
            if (std.mem.indexOf(u8, name, "+git+")) |idx| {
                const plugin_short = name[0..idx];
                const rest = name[idx..];
                if (!std.mem.startsWith(u8, plugin_short, "xxh-plugin-")) {
                    return std.fmt.allocPrint(allocator, "xxh-plugin-{s}{s}", .{ plugin_short, rest });
                }
            } else {
                return std.fmt.allocPrint(allocator, "xxh-plugin-{s}", .{name});
            }
        }
    }
    return allocator.dupe(u8, name);
}

pub fn resolvePackage(allocator: std.mem.Allocator, raw_name: []const u8, is_shell: bool) !ResolvedPackage {
    const resolved_name = try resolvePackageName(allocator, raw_name, is_shell);
    errdefer allocator.free(resolved_name);

    if (std.mem.indexOf(u8, resolved_name, "+git+")) |idx| {
        const clean_name = try allocator.dupe(u8, resolved_name[0..idx]);
        const git_url = try allocator.dupe(u8, resolved_name[idx + 5 ..]);
        return .{
            .name = resolved_name,
            .git_url = git_url,
            .clean_name = clean_name,
        };
    } else {
        const clean_name = try allocator.dupe(u8, resolved_name);
        const git_url = try std.fmt.allocPrint(allocator, "https://github.com/xxh/{s}", .{resolved_name});
        return .{
            .name = resolved_name,
            .git_url = git_url,
            .clean_name = clean_name,
        };
    }
}

pub fn makeDirRecursive(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/' or path[i] == '\\') {
            if (i == 0) continue;
            if (i == 2 and path[1] == ':') continue;

            const sub_path = path[0..i];
            std.fs.makeDirAbsolute(sub_path) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }
    }
    std.fs.makeDirAbsolute(path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

pub fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
}

pub fn downloadAndCachePackage(allocator: std.mem.Allocator, pkg: ResolvedPackage, is_shell: bool, install_force: bool, local_xxh_home: ?[]const u8) ![]const u8 {
    var base_dir: []const u8 = undefined;
    if (local_xxh_home) |lh| {
        base_dir = try config.resolvePath(allocator, lh);
    } else {
        const home = config.getHomeDir(allocator) orelse return error.HomeDirNotFound;
        defer allocator.free(home);
        base_dir = try std.fs.path.join(allocator, &.{ home, ".zzh" });
    }
    defer allocator.free(base_dir);

    const sub_dir = if (is_shell) "shells" else "plugins";
    const target_dir = try std.fs.path.join(allocator, &.{ base_dir, ".zzh", sub_dir, pkg.clean_name });
    errdefer allocator.free(target_dir);

    var exists = true;
    std.fs.accessAbsolute(target_dir, .{}) catch |err| {
        if (err == error.FileNotFound) {
            exists = false;
        } else {
            return err;
        }
    };

    if (exists and install_force) {
        std.fs.deleteTreeAbsolute(target_dir) catch {};
        exists = false;
    }

    if (!exists) {
        const parent_dir = try std.fs.path.join(allocator, &.{ base_dir, ".zzh", sub_dir });
        defer allocator.free(parent_dir);
        try makeDirRecursive(allocator, parent_dir);

        // Run git clone --depth=1 <git_url> <target_dir>
        std.debug.print("Downloading {s} from {s}...\n", .{ pkg.clean_name, pkg.git_url });
        const argv = [_][]const u8{ "git", "clone", "--depth=1", pkg.git_url, target_dir };
        try runCommand(allocator, &argv);
    }

    return target_dir;
}

test "resolvePackage Test" {
    const testing = std.testing;

    const p1 = try resolvePackage(testing.allocator, "zsh", true);
    defer freeResolvedPackage(testing.allocator, p1);
    try testing.expectEqualStrings("xxh-shell-zsh", p1.clean_name);
    try testing.expectEqualStrings("https://github.com/xxh/xxh-shell-zsh", p1.git_url);

    const p2 = try resolvePackage(testing.allocator, "myplugin+git+https://github.com/user/myplugin", false);
    defer freeResolvedPackage(testing.allocator, p2);
    try testing.expectEqualStrings("xxh-plugin-myplugin", p2.clean_name);
    try testing.expectEqualStrings("https://github.com/user/myplugin", p2.git_url);
}
