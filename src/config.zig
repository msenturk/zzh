const std = @import("std");

pub fn getHomeDir(allocator: std.mem.Allocator) ?[]const u8 {
    var env_map = std.process.getEnvMap(allocator) catch return null;
    defer env_map.deinit();

    if (env_map.get("USERPROFILE")) |val| {
        return allocator.dupe(u8, val) catch null;
    }
    if (env_map.get("HOME")) |val| {
        return allocator.dupe(u8, val) catch null;
    }
    if (env_map.get("HOMEDRIVE")) |drive| {
        if (env_map.get("HOMEPATH")) |path| {
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ drive, path }) catch null;
        }
    }
    return null;
}

pub fn resolvePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "~")) {
        if (getHomeDir(allocator)) |home| {
            defer allocator.free(home);
            var rest = path[1..];
            if (std.mem.startsWith(u8, rest, "/") or std.mem.startsWith(u8, rest, "\\")) {
                rest = rest[1..];
            }
            return std.fs.path.join(allocator, &.{ home, rest });
        }
    }
    return allocator.dupe(u8, path);
}

fn globMatch(pattern: []const u8, input: []const u8) bool {
    if (pattern.len == 0) return input.len == 0;
    if (std.mem.eql(u8, pattern, "*")) return true;

    if (pattern[0] == '*') {
        var i: usize = 0;
        while (i <= input.len) : (i += 1) {
            if (globMatch(pattern[1..], input[i..])) return true;
        }
        return false;
    }

    if (input.len == 0) return false;

    if (pattern[0] == '?' or pattern[0] == input[0]) {
        return globMatch(pattern[1..], input[1..]);
    }

    return false;
}

fn translateRegexToGlob(allocator: std.mem.Allocator, regex: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < regex.len) {
        if (i + 1 < regex.len and regex[i] == '.' and regex[i + 1] == '*') {
            try result.append('*');
            i += 2;
        } else {
            try result.append(regex[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice();
}

pub fn matchPattern(allocator: std.mem.Allocator, pattern: []const u8, host: []const u8) bool {
    var pat = pattern;
    if (pat.len >= 2 and pat[0] == '"' and pat[pat.len - 1] == '"') {
        pat = pat[1 .. pat.len - 1];
    } else if (pat.len >= 2 and pat[0] == '\'' and pat[pat.len - 1] == '\'') {
        pat = pat[1 .. pat.len - 1];
    }

    if (std.mem.eql(u8, pat, ".*") or std.mem.eql(u8, pat, "*")) {
        return true;
    }

    const glob = translateRegexToGlob(allocator, pat) catch return false;
    defer allocator.free(glob);

    return globMatch(glob, host);
}

fn trimQuotes(val: []const u8) []const u8 {
    var v = val;
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') {
        v = v[1 .. v.len - 1];
    } else if (v.len >= 2 and v[0] == '\'' and v[v.len - 1] == '\'') {
        v = v[1 .. v.len - 1];
    }
    return v;
}

pub fn parseConfig(allocator: std.mem.Allocator, file_path: []const u8, host: []const u8, args_list: *std.ArrayList([]const u8)) !void {
    const file = std.fs.openFileAbsolute(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    var buf: [4096]u8 = undefined;
    var in_hosts = false;
    var is_matching_host = false;
    var current_key: ?[]const u8 = null;
    var list_item_added = false;
    defer {
        if (current_key) |k| allocator.free(k);
    }

    while (try in_stream.readUntilDelimiterOrEof(&buf, '\n')) |raw_line| {
        // Strip carriage return if Windows line ending
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        // Count leading spaces
        var indent: usize = 0;
        for (line) |char| {
            if (char == ' ') {
                indent += 1;
            } else if (char == '\t') {
                indent += 4;
            } else {
                break;
            }
        }

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            continue;
        }

        if (indent <= 4) {
            if (current_key) |k| {
                if (is_matching_host and !list_item_added) {
                    try args_list.append(k);
                } else {
                    allocator.free(k);
                }
                current_key = null;
            }
        }

        if (indent == 0) {
            if (std.mem.startsWith(u8, trimmed, "hosts:")) {
                in_hosts = true;
            } else {
                in_hosts = false;
            }
            is_matching_host = false;
            continue;
        }

        if (!in_hosts) continue;

        if (indent == 2) {
            // This is a host pattern, e.g., "myhost": or ".*":
            is_matching_host = false;
            if (std.mem.endsWith(u8, trimmed, ":")) {
                const pattern = trimmed[0 .. trimmed.len - 1];
                if (matchPattern(allocator, pattern, host)) {
                    is_matching_host = true;
                }
            }
            continue;
        }

        if (!is_matching_host) continue;

        if (indent == 4) {
            // Parse a key-value or key-list declaration, e.g., "+s: zsh" or "-p: 2222" or "+e:"
            if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_idx| {
                const key = std.mem.trim(u8, trimmed[0..colon_idx], " \t");
                const val = trimQuotes(std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t"));
                if (val.len > 0) {
                    // key-value pair
                    try args_list.append(try allocator.dupe(u8, key));
                    try args_list.append(try allocator.dupe(u8, val));
                } else {
                    // key-list start or boolean flag
                    current_key = try allocator.dupe(u8, key);
                    list_item_added = false;
                }
            }
        } else if (indent > 4) {
            // A list item, e.g., "- OSH_THEME="simple""
            if (current_key) |k| {
                if (std.mem.startsWith(u8, trimmed, "- ")) {
                    const item_val = trimQuotes(std.mem.trim(u8, trimmed[2..], " \t"));
                    try args_list.append(try allocator.dupe(u8, k));
                    try args_list.append(try allocator.dupe(u8, item_val));
                    list_item_added = true;
                }
            }
        }
    }

    if (current_key) |k| {
        if (is_matching_host and !list_item_added) {
            try args_list.append(k);
        } else {
            allocator.free(k);
        }
        current_key = null;
    }
}


test "Config Parsing Test" {
    const testing = std.testing;
    const config_content =
        \\hosts:
        \\  ".*":
        \\    +s: xonsh
        \\    +hhh: "~"
        \\  "myhost":
        \\    -p: 2222
        \\    +if:
        \\    +e:
        \\      - OSH_THEME="simple"
        \\      - MY_VAR="val"
        \\  "otherhost":
        \\    -p: 3333
    ;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "config.zzhc", .data = config_content });

    var path_buf: [1024]u8 = undefined;
    const absolute_path = try tmp_dir.dir.realpath("config.zzhc", &path_buf);

    var args_list = std.ArrayList([]const u8).init(testing.allocator);
    defer {
        for (args_list.items) |arg| testing.allocator.free(arg);
        args_list.deinit();
    }

    try parseConfig(testing.allocator, absolute_path, "myhost", &args_list);

    // Should match both ".*" and "myhost"
    // Expected arguments from ".*":
    // +s, xonsh, +hhh, "~"
    // Expected arguments from "myhost":
    // -p, 2222, +if, +e, OSH_THEME="simple", +e, MY_VAR="val"
    // Total 11 elements

    try testing.expect(args_list.items.len == 11);
    try testing.expectEqualStrings("+s", args_list.items[0]);
    try testing.expectEqualStrings("xonsh", args_list.items[1]);
    try testing.expectEqualStrings("+hhh", args_list.items[2]);
    try testing.expectEqualStrings("~", args_list.items[3]);
    try testing.expectEqualStrings("-p", args_list.items[4]);
    try testing.expectEqualStrings("2222", args_list.items[5]);
    try testing.expectEqualStrings("+if", args_list.items[6]);
    try testing.expectEqualStrings("+e", args_list.items[7]);
    try testing.expectEqualStrings("OSH_THEME=\"simple\"", args_list.items[8]);
}
