const std = @import("std");
const cli = @import("cli.zig");
const bundler = @import("bundler.zig");
const package = @import("package.zig");
const config = @import("config.zig");

fn pathDeleteFileAbsolute(allocator: std.mem.Allocator, path: []const u8) !void {
    var temp_io = std.Io.Threaded.init(allocator, .{});
    defer temp_io.deinit();
    try std.Io.Dir.deleteFileAbsolute(temp_io.io(), path);
}
fn pathDeleteTreeAbsolute(allocator: std.mem.Allocator, path: []const u8) !void {
    var temp_io = std.Io.Threaded.init(allocator, .{});
    defer temp_io.deinit();
    try std.Io.Dir.cwd().deleteTree(temp_io.io(), path);
}

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

// In POSIX shells, we cannot put a literal single quote inside a single-quoted string.
// Instead, we must close the quote, write an escaped quote (\'), and reopen the quote.
// E.g., session name "foo'bar" is escaped to "foo'\''bar".
fn escapeSingleQuotesForShell(allocator: std.mem.Allocator, input_string: []const u8) ![]const u8 {
    var escaped_builder = std.ArrayList(u8).empty;
    errdefer escaped_builder.deinit(allocator);
    for (input_string) |char| {
        if (char == '\'') {
            try escaped_builder.appendSlice(allocator, "'\\''");
        } else {
            try escaped_builder.append(allocator, char);
        }
    }
    return escaped_builder.toOwnedSlice(allocator);
}

// Shell paths starting with ~ (like ~/.zzh) won't have ~ expanded by the remote shell
// if we wrap it entirely in single quotes. To bypass this restriction, we leave the ~
// unquoted and single-quote the rest of the path. E.g., "~/my dir" -> ~'/my dir'.
fn escapePathForShell(allocator: std.mem.Allocator, raw_path: []const u8) ![]const u8 {
    var escaped_builder = std.ArrayList(u8).empty;
    errdefer escaped_builder.deinit(allocator);

    var unquoted_part = raw_path;
    if (std.mem.startsWith(u8, raw_path, "~")) {
        if (std.mem.indexOfScalar(u8, raw_path, '/')) |slash_idx| {
            try escaped_builder.appendSlice(allocator, raw_path[0 .. slash_idx + 1]);
            unquoted_part = raw_path[slash_idx + 1 ..];
        } else {
            try escaped_builder.appendSlice(allocator, raw_path);
            unquoted_part = "";
        }
    }

    if (unquoted_part.len > 0) {
        try escaped_builder.append(allocator, '\'');
        for (unquoted_part) |char| {
            if (char == '\'') {
                try escaped_builder.appendSlice(allocator, "'\\''");
            } else {
                try escaped_builder.append(allocator, char);
            }
        }
        try escaped_builder.append(allocator, '\'');
    }

    return escaped_builder.toOwnedSlice(allocator);
}

pub const StagedScript = struct {
    bootstrap_script: []const u8,
    session_script: []const u8,

    pub fn deinit(self: StagedScript, allocator: std.mem.Allocator) void {
        allocator.free(self.bootstrap_script);
        allocator.free(self.session_script);
    }
};

// Generates the shell scripts used to provision the environment and launch the TTY session on the remote host.
pub fn compileStagedScript(allocator: std.mem.Allocator, zzh_args: *const cli.OperationalConfig) !StagedScript {
    const host_zzh_home = zzh_args.host_zzh_home orelse "~/.zzh";
    const escaped_home = try escapePathForShell(allocator, host_zzh_home);
    defer allocator.free(escaped_home);
    const shell = zzh_args.shell orelse "zsh";

    var bootstrap_builder = std.ArrayList(u8).empty;
    errdefer bootstrap_builder.deinit(allocator);

    // install_force_full deletes the entire ~/.zzh folder.
    // install_force only deletes the staging subdirectory (~/.zzh/.zzh) containing the staged packages,
    // preserving other files in ~/.zzh (like static binaries in ~/.zzh/bin or user profiles).
    if (zzh_args.install_force_full) {
        try bootstrap_builder.appendSlice(allocator, "rm -rf ");
        try bootstrap_builder.appendSlice(allocator, escaped_home);
        try bootstrap_builder.appendSlice(allocator, " && ");
    } else if (zzh_args.install_force) {
        try bootstrap_builder.appendSlice(allocator, "rm -rf ");
        try bootstrap_builder.appendSlice(allocator, escaped_home);
        try bootstrap_builder.appendSlice(allocator, "/.zzh && ");
    }

    try bootstrap_builder.appendSlice(allocator, "mkdir -p ");
    try bootstrap_builder.appendSlice(allocator, escaped_home);
    try bootstrap_builder.appendSlice(allocator, " && tar -xmf - -C ");
    try bootstrap_builder.appendSlice(allocator, escaped_home);

    var session_builder = std.ArrayList(u8).empty;
    errdefer session_builder.deinit(allocator);

    try session_builder.appendSlice(allocator, "ln -sf .zzh ");
    try session_builder.appendSlice(allocator, escaped_home);
    try session_builder.appendSlice(allocator, "/.xxh && chmod -R +x ");
    try session_builder.appendSlice(allocator, escaped_home);
    try session_builder.appendSlice(allocator, " 2>/dev/null || true && ");

    var shell_package_folder = std.ArrayList(u8).empty;
    defer shell_package_folder.deinit(allocator);
    if (!std.mem.startsWith(u8, shell, "xxh-shell-")) {
        try shell_package_folder.appendSlice(allocator, "xxh-shell-");
    }
    try shell_package_folder.appendSlice(allocator, shell);

    // If ++tmux, wrap the entrypoint script execution inside a persistent tmux session.
    // This allows the remote session to stay alive if the SSH connection drops.
    if (zzh_args.tmux) {
        const session_name = zzh_args.tmux_session orelse "zzh";
        const escaped_session_name = try escapeSingleQuotesForShell(allocator, session_name);
        defer allocator.free(escaped_session_name);
        try session_builder.appendSlice(allocator, escaped_home);
        try session_builder.appendSlice(allocator, "/bin/tmux new-session -A -s '");
        try session_builder.appendSlice(allocator, escaped_session_name);
        try session_builder.appendSlice(allocator, "' ");
    }

    // entrypoint command (quoted for tmux if needed)
    if (zzh_args.tmux) try session_builder.append(allocator, '\"');
    try session_builder.appendSlice(allocator, escaped_home);
    try session_builder.appendSlice(allocator, "/.zzh/shells/");
    try session_builder.appendSlice(allocator, shell_package_folder.items);
    try session_builder.appendSlice(allocator, "/build/entrypoint.sh");

    if (zzh_args.host_execute_file) |f| {
        try session_builder.appendSlice(allocator, " -f \"");
        try session_builder.appendSlice(allocator, f);
        try session_builder.appendSlice(allocator, "\"");
    }

    if (zzh_args.host_execute_command) |hc| {
        const hc_b64 = try b64Encode(allocator, hc);
        defer allocator.free(hc_b64);
        try session_builder.appendSlice(allocator, " -C ");
        try session_builder.appendSlice(allocator, hc_b64);
    }

    if (zzh_args.vverbose) {
        try session_builder.appendSlice(allocator, " -v 2");
    } else if (zzh_args.verbose) {
        try session_builder.appendSlice(allocator, " -v 1");
    }

    // prepend zzh's bin directory and common system paths to the remote PATH
    // so our static binaries (like tmux/rg) take precedence while keeping standard tools available.
    {
        const cmd = try std.fmt.allocPrint(allocator, "export ZZH_HOME='{s}'; export XXH_HOME='{s}'; export PATH=\"{s}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH\"", .{ host_zzh_home, host_zzh_home, host_zzh_home });
        defer allocator.free(cmd);
        const cmd_b64 = try b64Encode(allocator, cmd);
        defer allocator.free(cmd_b64);
        try session_builder.appendSlice(allocator, " -b ");
        try session_builder.appendSlice(allocator, cmd_b64);
    }

    for (zzh_args.env.items) |e| {
        const formatted = try formatEnvVar(allocator, e, true);
        defer allocator.free(formatted);
        try session_builder.appendSlice(allocator, " -e ");
        try session_builder.appendSlice(allocator, formatted);
    }
    for (zzh_args.envb.items) |e| {
        const formatted = try formatEnvVar(allocator, e, false);
        defer allocator.free(formatted);
        try session_builder.appendSlice(allocator, " -e ");
        try session_builder.appendSlice(allocator, formatted);
    }

    if (zzh_args.host_home) |h| {
        try session_builder.appendSlice(allocator, " -H ");
        try session_builder.appendSlice(allocator, h);
    } else {
        try session_builder.appendSlice(allocator, " -H ~");
    }

    if (zzh_args.host_home_xdg) |hx| {
        try session_builder.appendSlice(allocator, " -X ");
        try session_builder.appendSlice(allocator, hx);
    }

    for (zzh_args.host_execute_bash.items) |b| {
        const b_b64 = try b64Encode(allocator, b);
        defer allocator.free(b_b64);
        try session_builder.appendSlice(allocator, " -b ");
        try session_builder.appendSlice(allocator, b_b64);
    }

    if (zzh_args.dotfiles.items.len > 0) {
        var basenames = std.ArrayList([]const u8).empty;
        defer basenames.deinit(allocator);
        var remote_names = std.ArrayList([]const u8).empty;
        defer remote_names.deinit(allocator);

        for (zzh_args.dotfiles.items) |d| {
            if (std.mem.indexOfScalar(u8, d, ':')) |colon_idx| {
                try basenames.append(allocator, try allocator.dupe(u8, std.fs.path.basename(d[0..colon_idx])));
                try remote_names.append(allocator, try allocator.dupe(u8, d[colon_idx + 1 ..]));
            } else {
                const base = std.fs.path.basename(d);
                try basenames.append(allocator, try allocator.dupe(u8, base));
                try remote_names.append(allocator, try allocator.dupe(u8, base));
            }
        }
        defer {
            for (basenames.items) |b| allocator.free(b);
            for (remote_names.items) |r| allocator.free(r);
        }

        const joined_basenames = try std.mem.join(allocator, " ", basenames.items);
        defer allocator.free(joined_basenames);
        const joined_remotes = try std.mem.join(allocator, " ", remote_names.items);
        defer allocator.free(joined_remotes);

        // This bash script synchronizes dotfiles by setting up symlinks on the remote.
        // It's base64 encoded so it transmits cleanly as a command argument without shell escaping issues.
        const script = try std.fmt.allocPrint(allocator,
            \\if diff -y /dev/null /dev/null >/dev/null 2>&1; then _zzh_has_y=1; else _zzh_has_y=0; fi;
            \\if diff -u /dev/null /dev/null >/dev/null 2>&1; then _zzh_has_u=1; else _zzh_has_u=0; fi;
            \\_zzh_current_src="{s}";
            \\_zzh_current_dst="{s}";
            \\set -- $_zzh_current_dst;
            \\for src_base in $_zzh_current_src; do
            \\  basename=$1;
            \\  shift;
            \\  _zzh_src="{s}/.zzh/dotfiles/$src_base";
            \\  _zzh_src=$(eval echo "$_zzh_src");
            \\  for dst_dir in "~" "{s}"; do
            \\    _zzh_dst="$dst_dir/$basename";
            \\    _zzh_dst=$(eval echo "$_zzh_dst");
            \\    if [ -L "$_zzh_dst" ]; then
            \\      target=$(readlink "$_zzh_dst");
            \\      if [ "$target" != "$_zzh_src" ]; then
            \\        rm -f "$_zzh_dst";
            \\        ln -sf "$_zzh_src" "$_zzh_dst";
            \\      fi;
            \\    elif [ -e "$_zzh_dst" ]; then
            \\      differ=0;
            \\      if [ -f "$_zzh_dst" ] && [ -f "$_zzh_src" ]; then
            \\        if ! cmp -s "$_zzh_dst" "$_zzh_src"; then
            \\          differ=1;
            \\          echo "--- Diff for $basename (Remote vs Local) ---";
            \\          if [ "$_zzh_has_y" -eq 1 ]; then
            \\            diff -y "$_zzh_dst" "$_zzh_src";
            \\          elif [ "$_zzh_has_u" -eq 1 ]; then
            \\            diff -u "$_zzh_dst" "$_zzh_src";
            \\          else
            \\            diff "$_zzh_dst" "$_zzh_src";
            \\          fi;
            \\          echo "--------------------------------------------";
            \\        fi;
            \\      elif [ -d "$_zzh_dst" ] && [ -d "$_zzh_src" ]; then
            \\        if ! diff -r "$_zzh_dst" "$_zzh_src" >/dev/null 2>&1; then
            \\          differ=1;
            \\          echo "--- Diff for $basename (Remote vs Local) ---";
            \\          if [ "$_zzh_has_y" -eq 1 ]; then
            \\            diff -ry "$_zzh_dst" "$_zzh_src";
            \\          elif [ "$_zzh_has_u" -eq 1 ]; then
            \\            diff -ru "$_zzh_dst" "$_zzh_src";
            \\          else
            \\            diff -r "$_zzh_dst" "$_zzh_src";
            \\          fi;
            \\          echo "--------------------------------------------";
            \\        fi;
            \\      else
            \\        differ=1;
            \\      fi;
            \\      if [ "$differ" -eq 1 ]; then
            \\        _zzh_overwrite="y";
            \\        if [ -c /dev/tty ] && [ -t 0 ]; then
            \\          printf "Remote file/directory %s differs from local. Overwrite on remote? [y/N]: " "$basename";
            \\          read _zzh_ans < /dev/tty;
            \\          case "$_zzh_ans" in
            \\            [yY]|[yY][eE][sS]) _zzh_overwrite="y" ;;
            \\            *) _zzh_overwrite="n" ;;
            \\          esac;
            \\        fi;
            \\        if [ "$_zzh_overwrite" = "y" ]; then
            \\          mv "$_zzh_dst" "$_zzh_dst.zzh-bak";
            \\          ln -sf "$_zzh_src" "$_zzh_dst";
            \\          echo "Updated symlink for $basename (old backed up as $basename.zzh-bak).";
            \\        else
            \\          echo "Skipping update for $basename, keeping remote as is.";
            \\        fi;
            \\      else
            \\        rm -rf "$_zzh_dst";
            \\        ln -sf "$_zzh_src" "$_zzh_dst";
            \\      fi;
            \\    else
            \\      ln -sf "$_zzh_src" "$_zzh_dst";
            \\    fi;
            \\  done;
            \\done;
        , .{ joined_basenames, joined_remotes, escaped_home, escaped_home });
        const dotfiles_export = try std.fmt.allocPrint(allocator, "export ZZH_DOTFILES_DIR=\"{s}/.zzh/dotfiles\";", .{host_zzh_home});
        defer allocator.free(dotfiles_export);
        const dotfiles_b64 = try b64Encode(allocator, dotfiles_export);
        defer allocator.free(dotfiles_b64);
        try session_builder.appendSlice(allocator, " -b ");
        try session_builder.appendSlice(allocator, dotfiles_b64);

        defer allocator.free(script);
        const b_b64 = try b64Encode(allocator, script);
        defer allocator.free(b_b64);
        try session_builder.appendSlice(allocator, " -b ");
        try session_builder.appendSlice(allocator, b_b64);

        const is_bash = std.mem.eql(u8, shell, "bash") or std.mem.eql(u8, shell, "xxh-shell-bash");
        const is_zsh = std.mem.eql(u8, shell, "zsh") or std.mem.eql(u8, shell, "xxh-shell-zsh");
        const is_fish = std.mem.eql(u8, shell, "fish") or std.mem.eql(u8, shell, "xxh-shell-fish");
        const is_xonsh = std.mem.eql(u8, shell, "xonsh") or std.mem.eql(u8, shell, "xxh-shell-xonsh");
        const is_nu = std.mem.eql(u8, shell, "nu") or std.mem.eql(u8, shell, "nushell") or std.mem.eql(u8, shell, "xxh-shell-nu");

        if (is_bash or is_zsh or is_fish or is_xonsh or is_nu) {
            const rc_files = if (is_bash)
                &[_][]const u8{ ".bashrc", ".bash_aliases", ".bash_profile" }
            else if (is_zsh)
                &[_][]const u8{ ".zshrc", ".zprofile", ".profile" }
            else if (is_fish)
                &[_][]const u8{"config.fish"}
            else if (is_xonsh)
                &[_][]const u8{ "xonshrc", ".xonshrc" }
            else
                &[_][]const u8{"config.nu"};

            const target_rc_rel = if (is_bash)
                "shells/xxh-shell-bash/build/bashrc"
            else if (is_zsh)
                "shells/xxh-shell-zsh/build/.zshrc"
            else if (is_fish)
                "shells/xxh-shell-fish/build/config/fish/config.fish"
            else if (is_xonsh)
                "shells/xxh-shell-xonsh/build/xonshrc"
            else
                "shells/xxh-shell-nu/build/config.nu";

            var source_lines = std.ArrayList(u8).empty;
            defer source_lines.deinit(allocator);

            var nu_basename: ?[]const u8 = null;
            defer {
                if (nu_basename) |nb| allocator.free(nb);
            }

            for (zzh_args.dotfiles.items) |d| {
                var local_path = d;
                var remote_name: ?[]const u8 = null;
                if (std.mem.indexOfScalar(u8, d, ':')) |colon_idx| {
                    local_path = d[0..colon_idx];
                    remote_name = d[colon_idx + 1 ..];
                }
                const basename = remote_name orelse std.fs.path.basename(local_path);
                const file_only = std.fs.path.basename(basename);

                for (rc_files) |rc| {
                    if (std.mem.eql(u8, file_only, rc)) {
                        if (is_bash or is_zsh) {
                            const formatted = try std.fmt.allocPrint(allocator, "[ -f ~/{s} ] && . ~/{s}\n", .{ basename, basename });
                            defer allocator.free(formatted);
                            try source_lines.appendSlice(allocator, formatted);
                        } else if (is_fish) {
                            const formatted = try std.fmt.allocPrint(allocator, "if test -f ~/{s}; source ~/{s}; end\n", .{ basename, basename });
                            defer allocator.free(formatted);
                            try source_lines.appendSlice(allocator, formatted);
                        } else if (is_xonsh) {
                            const formatted = try std.fmt.allocPrint(allocator, "import os; _rc = os.path.expanduser('~/{s}'); os.path.exists(_rc) and exec(open(_rc).read())\n", .{basename});
                            defer allocator.free(formatted);
                            try source_lines.appendSlice(allocator, formatted);
                        } else if (is_nu) {
                            const formatted = try std.fmt.allocPrint(allocator, "source \"~/{s}\"\n", .{basename});
                            defer allocator.free(formatted);
                            try source_lines.appendSlice(allocator, formatted);
                            if (nu_basename == null) {
                                nu_basename = try allocator.dupe(u8, basename);
                            }
                        }
                        break;
                    }
                }
            }

            if (source_lines.items.len > 0) {
                var inject: []const u8 = undefined;
                if (is_nu and nu_basename != null) {
                    inject = try std.fmt.allocPrint(allocator,
                        \\_dir=$(dirname ~/{s}); mkdir -p "$_dir" && touch ~/{s};
                        \\_zzh_rc="{s}/.zzh/{s}";
                        \\if [ -f "$_zzh_rc" ]; then
                        \\  if ! grep -qF "# zzh-user-dotfiles" "$_zzh_rc" 2>/dev/null; then
                        \\    printf '\n# zzh-user-dotfiles\n{s}' >> "$_zzh_rc";
                        \\  fi;
                        \\fi;
                        \\unset _zzh_rc;
                    , .{ nu_basename.?, nu_basename.?, host_zzh_home, target_rc_rel, source_lines.items });
                } else {
                    inject = try std.fmt.allocPrint(allocator,
                        \\_zzh_rc="{s}/.zzh/{s}";
                        \\if [ -f "$_zzh_rc" ]; then
                        \\  if ! grep -qF "# zzh-user-dotfiles" "$_zzh_rc" 2>/dev/null; then
                        \\    printf '\n# zzh-user-dotfiles\n{s}' >> "$_zzh_rc";
                        \\  fi;
                        \\fi;
                        \\unset _zzh_rc;
                    , .{ host_zzh_home, target_rc_rel, source_lines.items });
                }
                defer allocator.free(inject);
                const inject_b64 = try b64Encode(allocator, inject);
                defer allocator.free(inject_b64);
                try session_builder.appendSlice(allocator, " -b ");
                try session_builder.appendSlice(allocator, inject_b64);
            }
        }
    }

    if (zzh_args.tmux) {
        try session_builder.append(allocator, '\"');
    }

    return StagedScript{
        .bootstrap_script = try bootstrap_builder.toOwnedSlice(allocator),
        .session_script = try session_builder.toOwnedSlice(allocator),
    };
}

pub fn getDeploymentHash(allocator: std.mem.Allocator, zzh_args: *const cli.OperationalConfig) ![]const u8 {
    // Environment variables (zzh_args.env / envb) are intentionally excluded from the deployment
    // payload signature hash because they are injected dynamically at runtime during the connection
    // step, and do not change the static payload content of the compiled archive tarball.
    //
    // NOTE: This hash is also used as a cache key for the payload tarball filename.
    // Only package names/identifiers and file paths are hashed, NOT the actual file contents of dotfiles
    // or plugins. If you modify the contents of a dotfile or a plugin locally on disk without changing
    // its path/identifier, the hash key will remain identical, and zzh will reuse the cached tarball
    // instead of rebuilding it. To force reconstruction and upload in this scenario, run with
    // ++install-force (or +if).
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
    for (zzh_args.binaries.items) |b| {
        hasher.update("|B|");
        hasher.update(b);
    }
    if (zzh_args.tmux) {
        hasher.update("|tmux|");
        if (zzh_args.tmux_session) |s| hasher.update(s);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(digest, .lower)});
}

pub fn checkPasswordless(allocator: std.mem.Allocator, zzh_args: *const cli.OperationalConfig, io: std.Io) !bool {
    var argv = std.ArrayList([]const u8).empty;
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

    if (zzh_args.destination) |dest| {
        const dest_info = cli.parseConnectionEndpoint(dest);
        try argv.append(try allocator.dupe(u8, dest_info.host));
    } else {
        return false;
    }
    try argv.append(try allocator.dupe(u8, "exit"));
    try argv.append(try allocator.dupe(u8, "0"));

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |exit_code| exit_code == 0,
        else => false,
    };
}

pub fn buildSshBoilerplate(allocator: std.mem.Allocator, zzh_args: *const cli.OperationalConfig) !std.ArrayList([]const u8) {
    var ssh_boilerplate = std.ArrayList([]const u8).empty;
    errdefer {
        for (ssh_boilerplate.items) |item| {
            allocator.free(item);
        }
        ssh_boilerplate.deinit(allocator);
    }

    const ssh_cmd = zzh_args.ssh_command orelse "ssh";
    try ssh_boilerplate.append(allocator, try allocator.dupe(u8, ssh_cmd));

    try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "-C")); // Enable SSH native compression to speed up transfer without local CPU bottleneck
    try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "-o"));
    try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "StrictHostKeyChecking=accept-new"));

    // Prevent 20-30s delay on Windows due to GSSAPI timeout
    try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "-o"));
    try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "GSSAPIAuthentication=no"));

    if (!zzh_args.verbose and !zzh_args.vverbose) {
        try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "-o"));
        try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "LogLevel=QUIET"));
    }

    if (zzh_args.ssh_port) |p| {
        try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "-o"));
        const opt = try std.fmt.allocPrint(allocator, "Port={s}", .{p});
        try ssh_boilerplate.append(allocator, opt);
    }

    if (zzh_args.ssh_private_key) |k| {
        try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "-o"));
        const opt = try std.fmt.allocPrint(allocator, "IdentityFile={s}", .{k});
        try ssh_boilerplate.append(allocator, opt);
    }

    if (zzh_args.ssh_login) |l| {
        try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "-o"));
        const opt = try std.fmt.allocPrint(allocator, "User={s}", .{l});
        try ssh_boilerplate.append(allocator, opt);
    } else if (zzh_args.destination) |dest| {
        const dest_info = cli.parseConnectionEndpoint(dest);
        if (dest_info.user) |u| {
            try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "-o"));
            const opt = try std.fmt.allocPrint(allocator, "User={s}", .{u});
            try ssh_boilerplate.append(allocator, opt);
        }
    }

    if (zzh_args.ssh_jump_host) |j| {
        try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "-o"));
        const opt = try std.fmt.allocPrint(allocator, "ProxyJump={s}", .{j});
        try ssh_boilerplate.append(allocator, opt);
    }

    for (zzh_args.ssh_options.items) |o| {
        try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "-o"));
        try ssh_boilerplate.append(allocator, try allocator.dupe(u8, o));
    }

    // Reuse existing SSH multiplexed connection to avoid doing authentication handshake twice (which can take 1-2s).
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) {
        try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "-o"));
        try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "ControlMaster=auto"));
        try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "-o"));
        try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "ControlPath=/tmp/zzh_mux_%h_%p_%r"));
        try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "-o"));
        try ssh_boilerplate.append(allocator, try allocator.dupe(u8, "ControlPersist=5m"));
    }

    for (zzh_args.ssh_args.items) |arg| {
        try ssh_boilerplate.append(allocator, try allocator.dupe(u8, arg));
    }

    return ssh_boilerplate;
}

fn normalizeOs(allocator: std.mem.Allocator, raw_os: []const u8) ![]const u8 {
    const lower = try allocator.alloc(u8, raw_os.len);
    defer allocator.free(lower);
    _ = std.ascii.lowerString(lower, raw_os);

    if (std.mem.indexOf(u8, lower, "linux") != null) {
        return try allocator.dupe(u8, "linux");
    } else if (std.mem.indexOf(u8, lower, "darwin") != null) {
        return try allocator.dupe(u8, "darwin");
    } else if (std.mem.indexOf(u8, lower, "freebsd") != null) {
        return try allocator.dupe(u8, "freebsd");
    } else {
        return try allocator.dupe(u8, "linux"); // safe fallback
    }
}

fn normalizeArch(allocator: std.mem.Allocator, raw_arch: []const u8) ![]const u8 {
    const lower = try allocator.alloc(u8, raw_arch.len);
    defer allocator.free(lower);
    _ = std.ascii.lowerString(lower, raw_arch);

    if (std.mem.indexOf(u8, lower, "x86_64") != null or std.mem.indexOf(u8, lower, "amd64") != null) {
        return try allocator.dupe(u8, "x86_64");
    } else if (std.mem.indexOf(u8, lower, "aarch64") != null or std.mem.indexOf(u8, lower, "arm64") != null) {
        return try allocator.dupe(u8, "aarch64");
    } else {
        std.debug.print("Warning: Unrecognized remote architecture '{s}', falling back to x86_64\n", .{raw_arch});
        return try allocator.dupe(u8, "x86_64");
    }
}

pub fn deployAndConnect(
    allocator: std.mem.Allocator,
    zzh_args: *const cli.OperationalConfig,
    shell_path: []const u8,
    plugin_paths: []const []const u8,
    io: std.Io,
) !void {
    const builtin = @import("builtin");
    const staged_script = try compileStagedScript(allocator, zzh_args);
    defer staged_script.deinit(allocator);

    // Some mock command wrappers (e.g. for testing) don't support env variables directly on command line
    const is_mock_cmd = if (zzh_args.ssh_command) |cmd|
        std.mem.indexOf(u8, cmd, "cmd") != null
    else
        false;
    const env_prefix = if (is_mock_cmd) "" else "export APPIMAGE_EXTRACT_AND_RUN=1 && ";

    const session_cmd = try std.fmt.allocPrint(allocator, "{s}{s}", .{ env_prefix, staged_script.session_script });
    defer allocator.free(session_cmd);

    var ssh_boilerplate = try buildSshBoilerplate(allocator, zzh_args);
    defer {
        for (ssh_boilerplate.items) |item| {
            allocator.free(item);
        }
        ssh_boilerplate.deinit(allocator);
    }

    var env_map = try config.global_environ.createMap(allocator);
    defer env_map.deinit();

    var exe_path: ?[]const u8 = null;
    defer {
        if (exe_path) |p| allocator.free(p);
    }

    if (zzh_args.password) |pwd| {
        exe_path = std.process.executablePathAlloc(io, allocator) catch null;
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

    const local_hash = try getDeploymentHash(allocator, zzh_args);
    defer allocator.free(local_hash);

    var target_os: ?[]const u8 = null;
    var target_arch: ?[]const u8 = null;
    var remote_hash: ?[]const u8 = null;
    defer {
        if (target_os) |o| allocator.free(o);
        if (target_arch) |a| allocator.free(a);
        if (remote_hash) |h| allocator.free(h);
    }

    {
        var check_runner_args = std.ArrayList([]const u8).empty;
        defer {
            for (check_runner_args.items) |arg| {
                allocator.free(arg);
            }
            check_runner_args.deinit(allocator);
        }

        if (zzh_args.password != null and exe_path != null and builtin.os.tag != .windows) {
            try check_runner_args.append(allocator, try allocator.dupe(u8, exe_path.?));
            try check_runner_args.append(allocator, try allocator.dupe(u8, "--internal-setsid"));
        }

        for (ssh_boilerplate.items) |arg| {
            try check_runner_args.append(allocator, try allocator.dupe(u8, arg));
        }

        if (zzh_args.destination) |dest| {
            const dest_info = cli.parseConnectionEndpoint(dest);
            try check_runner_args.append(allocator, try allocator.dupe(u8, dest_info.host));
        }

        const detect_cmd = "echo ZZH_TARGET_START && uname -s && uname -m && echo ZZH_TARGET_END || echo ZZH_TARGET_END";
        const check_cmd = try std.fmt.allocPrint(allocator, "{s}; cat ~/.zzh/.payload_hash 2>/dev/null || echo ZZH_NO_HASH", .{detect_cmd});
        defer allocator.free(check_cmd);
        try check_runner_args.append(allocator, try allocator.dupe(u8, check_cmd));

        if (zzh_args.verbose or zzh_args.vverbose) {
            std.debug.print("Checking remote target and payload hash with command:", .{});
            for (check_runner_args.items) |arg| {
                std.debug.print(" {s}", .{arg});
            }
            std.debug.print("\n", .{});
        } else {
            std.debug.print("      - Detecting remote host system architecture...\n", .{});
        }

        var child = try std.process.spawn(io, .{
            .argv = check_runner_args.items,
            .environ_map = &env_map,
            .stdout = .pipe,
            .stderr = .inherit,
        });

        var out_buf = std.ArrayList(u8).empty;
        defer out_buf.deinit(allocator);

        while (true) {
            var buf: [1024]u8 = undefined;
            const amt = child.stdout.?.readStreaming(io, &.{&buf}) catch |err| switch(err) { error.EndOfStream => break, else => return err };
            if (amt == 0) break;
            try out_buf.appendSlice(allocator, buf[0..amt]);
        }

        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) {
            if (zzh_args.verbose or zzh_args.vverbose) {
                std.debug.print("Remote target check failed with exit code or signal. Output: {s}\n", .{out_buf.items});
            }
            return error.RemoteTargetDetectionFailed;
        }

        var lines_it = std.mem.tokenizeAny(u8, out_buf.items, "\r\n");
        var inside_target_block = false;
        var os_line: ?[]const u8 = null;
        var arch_line: ?[]const u8 = null;

        while (lines_it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (std.mem.eql(u8, trimmed, "ZZH_TARGET_START")) {
                inside_target_block = true;
                continue;
            }
            if (std.mem.eql(u8, trimmed, "ZZH_TARGET_END")) {
                inside_target_block = false;
                continue;
            }
            if (inside_target_block) {
                if (os_line == null) {
                    os_line = trimmed;
                } else if (arch_line == null) {
                    arch_line = trimmed;
                }
                continue;
            }
            // First line after target block is the hash
            if (remote_hash == null) {
                remote_hash = try allocator.dupe(u8, trimmed);
            }
        }

        target_os = try normalizeOs(allocator, os_line orelse "linux");
        target_arch = try normalizeArch(allocator, arch_line orelse "x86_64");

        try package.provisionNushellPlugins(
            allocator,
            zzh_args.plugins.items,
            zzh_args.install_force,
            zzh_args.local_zzh_home,
            target_os.?,
            target_arch.?,
        );
    }

    var send_payload = false;
    if (zzh_args.install_force or zzh_args.install_force_full) {
        send_payload = true;
    } else if (remote_hash) |rh| {
        if (std.mem.eql(u8, rh, "ZZH_NO_HASH") or !std.mem.eql(u8, rh, local_hash)) {
            send_payload = true;
        }
    }

    var opt_bundle: ?bundler.PayloadManifest = null;
    defer {
        if (opt_bundle) |bundle| {
            bundler.discardStagingArea(allocator, bundle);
        }
    }

    if (send_payload) {
        if (zzh_args.tmux) {
            const cached_tmux_path = try package.provisionStaticallyCompiledTmux(
                allocator,
                zzh_args.install_force,
                zzh_args.local_zzh_home,
                target_arch.?,
            );
            allocator.free(cached_tmux_path);
        }

        for (zzh_args.binaries.items) |repo| {
            try package.provisionStaticallyCompiledBinary(
                allocator,
                repo,
                zzh_args.install_force,
                zzh_args.local_zzh_home,
                target_os.?,
                target_arch.?,
            );
        }

        opt_bundle = try bundler.assembleDeploymentPayload(
            allocator,
            shell_path,
            plugin_paths,
            zzh_args,
        );

        if (!zzh_args.verbose and !zzh_args.vverbose) {
            std.debug.print("      - Uploading payload to {s}...\n", .{zzh_args.destination.?});
        }

        const target_dir = zzh_args.host_zzh_home orelse "~/.zzh";
        const escaped_target_dir = try escapePathForShell(allocator, target_dir);
        defer allocator.free(escaped_target_dir);

        const bootstrap_cmd = try std.fmt.allocPrint(allocator, "{s}{s} && echo \"{s}\" > {s}/.payload_hash", .{ env_prefix, staged_script.bootstrap_script, local_hash, escaped_target_dir });
        defer allocator.free(bootstrap_cmd);

        var bootstrap_runner_args = std.ArrayList([]const u8).empty;
        defer {
            for (bootstrap_runner_args.items) |arg| {
                allocator.free(arg);
            }
            bootstrap_runner_args.deinit(allocator);
        }

        if (zzh_args.password != null and exe_path != null and builtin.os.tag != .windows) {
            try bootstrap_runner_args.append(allocator, try allocator.dupe(u8, exe_path.?));
            try bootstrap_runner_args.append(allocator, try allocator.dupe(u8, "--internal-setsid"));
        }

        for (ssh_boilerplate.items) |arg| {
            try bootstrap_runner_args.append(allocator, try allocator.dupe(u8, arg));
        }
        if (zzh_args.destination) |dest| {
            const dest_info = cli.parseConnectionEndpoint(dest);
            try bootstrap_runner_args.append(allocator, try allocator.dupe(u8, dest_info.host));
        }
        try bootstrap_runner_args.append(allocator, try allocator.dupe(u8, bootstrap_cmd));

        if (zzh_args.verbose or zzh_args.vverbose) {
            std.debug.print("Deploying payload with command:", .{});
            for (bootstrap_runner_args.items) |arg| {
                std.debug.print(" {s}", .{arg});
            }
            std.debug.print("\n", .{});
        } else {
            std.debug.print("[4/4] Deploying to remote...\n", .{});
        }

        var temp_io_deploy = std.Io.Threaded.init(allocator, .{});
        defer temp_io_deploy.deinit();

        
        var child = try std.process.spawn(temp_io_deploy.io(), .{
            .argv = bootstrap_runner_args.items,
            .environ_map = &env_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });

        const PayloadThread = struct {
            fn run(path: []const u8, stdin_file: std.Io.File) void {
                var th_io = std.Io.Threaded.init(std.heap.page_allocator, .{});
                defer th_io.deinit();
                defer stdin_file.close(th_io.io());
                var archive_file = std.Io.Dir.openFileAbsolute(th_io.io(), path, .{}) catch return;
                defer archive_file.close(th_io.io());

                const file_stat = archive_file.stat(th_io.io()) catch return;
                const total_size = file_stat.size;
                var uploaded_size: u64 = 0;
                var last_percent: u64 = 200;
                var printed_header = false;

                var buf: [32768]u8 = undefined;
                while (true) {
                    const amt = archive_file.readStreaming(th_io.io(), &.{&buf}) catch break;
                    if (amt == 0) break;
                    stdin_file.writeStreamingAll(th_io.io(), buf[0..amt]) catch break;
                    uploaded_size += amt;

                    if (uploaded_size > 128 * 1024 or uploaded_size == total_size) {
                        printed_header = true;
                        if (total_size > 0) {
                            const percent = (uploaded_size * 100) / total_size;
                            if (percent != last_percent or uploaded_size == total_size) {
                                last_percent = percent;
                                const mb_uploaded = uploaded_size / (1024 * 1024);
                                const mb_total = total_size / (1024 * 1024);
                                std.debug.print("\r      - Uploading payload... {d:>3}% ({d} MB / {d} MB)", .{ percent, mb_uploaded, mb_total });
                            }
                        }
                    }
                }
                if (printed_header) {
                    std.debug.print("\n", .{});
                }
            }
        };

        var thread = try std.Thread.spawn(.{}, PayloadThread.run, .{ opt_bundle.?.tarball_output_path, child.stdin.? });

        // Forward stdout from remote
        var buf_out: [65536]u8 = undefined;
        while (true) {
            const amt = child.stdout.?.readStreaming(temp_io_deploy.io(), &.{&buf_out}) catch |err| switch(err) { error.EndOfStream => break, else => break };
            if (amt == 0) break;
            std.debug.print("{s}", .{buf_out[0..amt]});
        }

        thread.join();
        if (!zzh_args.verbose and !zzh_args.vverbose) {
            std.debug.print("      - Unpacking archive...\n", .{});
        }

        const term = try std.process.Child.wait(&child, temp_io_deploy.io());

        if (zzh_args.time) {
            std.debug.print("=> SSH deployment finished\n", .{});
        }

        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    if (code != 255) {
                        std.debug.print("Payload deployment failed with exit code: {}\n", .{code});
                        pathDeleteFileAbsolute(allocator, opt_bundle.?.tarball_output_path) catch {};
                        return error.DeploymentFailed;
                    }
                }
            },
            else => {
                std.debug.print("Payload deployment terminated unexpectedly\n", .{});
                pathDeleteFileAbsolute(allocator, opt_bundle.?.tarball_output_path) catch {};
                return error.DeploymentTerminated;
            },
        }
    } else {
        if (!zzh_args.verbose and !zzh_args.vverbose) {
            std.debug.print("      - Remote payload already cached (skipping upload)\n", .{});
        }
    }

    // Launch the interactive session over SSH.
    var interactive_session_args = std.ArrayList([]const u8).empty;
    defer interactive_session_args.deinit(allocator);
    for (ssh_boilerplate.items) |arg| {
        try interactive_session_args.append(allocator, arg);
    }
    // -t is required to allocate a pseudo-terminal for interactive shells
    if (zzh_args.tmux) {
        try interactive_session_args.append(allocator, "-tt");
    } else if (zzh_args.host_execute_command == null and zzh_args.host_execute_file == null) {
        try interactive_session_args.append(allocator, "-t");
    }
    if (zzh_args.destination) |dest| {
        const dest_info = cli.parseConnectionEndpoint(dest);
        try interactive_session_args.append(allocator, dest_info.host);
    }
    try interactive_session_args.append(allocator, session_cmd);

    if (zzh_args.verbose or zzh_args.vverbose) {
        std.debug.print("Connecting with command:", .{});
        for (interactive_session_args.items) |arg| {
            std.debug.print(" {s}", .{arg});
        }
        std.debug.print("\n", .{});
    }

    if (!zzh_args.verbose and !zzh_args.vverbose) {
        std.debug.print("Connecting to target host via SSH...\n", .{});
        if (zzh_args.tmux) {
            std.debug.print("Entering remote tmux session...\n", .{});
        }
    }

    var child = try std.process.spawn(io, .{
        .argv = interactive_session_args.items,
        .environ_map = &env_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    const term = try child.wait(io);

    // Perform client-side remote directory cleanup if requested by the user.
    if (zzh_args.host_zzh_home_remove) {
        const host_zzh_home = zzh_args.host_zzh_home orelse "~/.zzh";
        const escaped_home = try escapePathForShell(allocator, host_zzh_home);
        defer allocator.free(escaped_home);
        const clean_cmd = try std.fmt.allocPrint(allocator, "rm -rf {s}", .{escaped_home});
        defer allocator.free(clean_cmd);

        var cleanup_runner_args = std.ArrayList([]const u8).empty;
        defer cleanup_runner_args.deinit(allocator);

        if (zzh_args.password != null and exe_path != null and builtin.os.tag != .windows) {
            try cleanup_runner_args.append(allocator, exe_path.?);
            try cleanup_runner_args.append(allocator, "--internal-setsid");
        }

        for (ssh_boilerplate.items) |arg| {
            try cleanup_runner_args.append(allocator, arg);
        }
        if (zzh_args.destination) |dest| {
            const dest_info = cli.parseConnectionEndpoint(dest);
            try cleanup_runner_args.append(allocator, dest_info.host);
        }
        try cleanup_runner_args.append(allocator, clean_cmd);

        if (zzh_args.verbose or zzh_args.vverbose) {
            std.debug.print("Cleaning up remote home directory with command:", .{});
            for (cleanup_runner_args.items) |arg| {
                std.debug.print(" {s}", .{arg});
            }
            std.debug.print("\n", .{});
        }

        if (std.process.spawn(io, .{
            .argv = cleanup_runner_args.items,
            .environ_map = &env_map,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        })) |spawned_cc| {
            var cc = spawned_cc;
            _ = std.process.Child.wait(&cc, io) catch {};
        } else |_| {}
    }

    switch (term) {
        .exited => |code| {
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
    

    var args = cli.OperationalConfig.init(std.testing.allocator);
    defer args.deinit(std.testing.allocator);

    args.shell = try std.testing.allocator.dupe(u8, "zsh");
    try args.env.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "VAR1=VAL1"));
    args.verbose = true;

    // Test OOM path to cover errdefer
    _ = compileStagedScript(std.testing.failing_allocator, &args) catch |err| {
        try std.testing.expect(err == error.OutOfMemory);
    };

    const staged_script = try compileStagedScript(std.testing.allocator, &args);
    defer staged_script.deinit(std.testing.allocator);
    const cmd = try std.mem.join(std.testing.allocator, " && ", &.{ staged_script.bootstrap_script, staged_script.session_script });
    defer std.testing.allocator.free(cmd);

    try std.testing.expectEqualStrings("mkdir -p ~/'.zzh' && tar -xmf - -C ~/'.zzh' && ln -sf .zzh ~/'.zzh'/.xxh && chmod -R +x ~/'.zzh' 2>/dev/null || true && ~/'.zzh'/.zzh/shells/xxh-shell-zsh/build/entrypoint.sh -v 1 -b ZXhwb3J0IFpaSF9IT01FPSd+Ly56emgnOyBleHBvcnQgWFhIX0hPTUU9J34vLnp6aCc7IGV4cG9ydCBQQVRIPSJ+Ly56emgvYmluOi91c3IvbG9jYWwvc2JpbjovdXNyL2xvY2FsL2JpbjovdXNyL3NiaW46L3Vzci9iaW46L3NiaW46L2JpbjokUEFUSCI= -e VAR1=VkFMMQ== -H ~", cmd);
}

test "Remote Command Builder Test - Comprehensive" {
    

    var args = cli.OperationalConfig.init(std.testing.allocator);
    defer args.deinit(std.testing.allocator);

    args.shell = try std.testing.allocator.dupe(u8, "bash");
    args.host_zzh_home = try std.testing.allocator.dupe(u8, "/custom/home");

    // Flags
    args.install_force_full = true;
    args.host_zzh_home_remove = true;
    args.vverbose = true;

    // Command and File execution
    args.host_execute_file = try std.testing.allocator.dupe(u8, "script.sh");
    args.host_execute_command = try std.testing.allocator.dupe(u8, "echo hello");

    // Env vars with and without quotes, and without =
    try args.env.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "VAR1=\"VAL1\""));
    try args.env.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "VAR2='VAL2'"));
    try args.env.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "VAR_NO_VAL"));

    // Raw envb (to_base64 is false)
    try args.envb.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "B64VAR1=VAL1"));
    try args.envb.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "B64VAR_NO_VAL"));

    // Host homes
    args.host_home = try std.testing.allocator.dupe(u8, "/host/home");
    args.host_home_xdg = try std.testing.allocator.dupe(u8, "/xdg/config");

    // Execute bash
    try args.host_execute_bash.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "bash_cmd"));

    // Dotfiles (one to source, one not to source)
    try args.dotfiles.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "~/.bashrc"));
    try args.dotfiles.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "~/.tmux.conf"));

    const staged_script = try compileStagedScript(std.testing.allocator, &args);
    defer staged_script.deinit(std.testing.allocator);
    const cmd = try std.mem.join(std.testing.allocator, " && ", &.{ staged_script.bootstrap_script, staged_script.session_script });
    defer std.testing.allocator.free(cmd);

    // Verify commands inside cmd
    try std.testing.expect(std.mem.indexOf(u8, cmd, "rm -rf '/custom/home' &&") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "mkdir -p '/custom/home' && tar -xmf - -C '/custom/home' && ln -sf .zzh '/custom/home'/.xxh && chmod -R +x '/custom/home'") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, " -b ZXhwb3J0IFpaSF9IT01F") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, " -f \"script.sh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, " -C ZWNobyBoZWxsbw==") != null); // base64 of "echo hello"
    try std.testing.expect(std.mem.indexOf(u8, cmd, " -v 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, " -e VAR1=VkFMMQ==") != null); // base64 of "VAL1" (quotes trimmed)
    try std.testing.expect(std.mem.indexOf(u8, cmd, " -e VAR2=VkFMMg==") != null); // base64 of "VAL2" (quotes trimmed)
    try std.testing.expect(std.mem.indexOf(u8, cmd, " -e VAR_NO_VAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, " -e B64VAR1=VAL1") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, " -e B64VAR_NO_VAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, " -H /host/home") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, " -X /xdg/config") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, " -b YmFzaF9jbWQ=") != null); // base64 of "bash_cmd"

    // Verify dotfiles directory export
    const expected_export = "export ZZH_DOTFILES_DIR=\"/custom/home/.zzh/dotfiles\";";
    const expected_export_b64 = try b64Encode(std.testing.allocator, expected_export);
    defer std.testing.allocator.free(expected_export_b64);
    var expected_buf = std.ArrayList(u8).empty;
    defer expected_buf.deinit(std.testing.allocator);
    const f_buf = try std.fmt.allocPrint(std.testing.allocator, " -b {s}", .{expected_export_b64});
    defer std.testing.allocator.free(f_buf);
    try expected_buf.appendSlice(std.testing.allocator, f_buf);
    try std.testing.expect(std.mem.indexOf(u8, cmd, expected_buf.items) != null);

    // Verify dotfiles sourcing (bash-specific injection)
    const expected_source =
        \\_zzh_rc="/custom/home/.zzh/shells/xxh-shell-bash/build/bashrc";
        \\if [ -f "$_zzh_rc" ]; then
        \\  if ! grep -qF "# zzh-user-dotfiles" "$_zzh_rc" 2>/dev/null; then
        \\    printf '\n# zzh-user-dotfiles\n[ -f ~/.bashrc ] && . ~/.bashrc
        \\' >> "$_zzh_rc";
        \\  fi;
        \\fi;
        \\unset _zzh_rc;
    ;
    const expected_source_b64 = try b64Encode(std.testing.allocator, expected_source);
    defer std.testing.allocator.free(expected_source_b64);
    var expected_source_buf = std.ArrayList(u8).empty;
    defer expected_source_buf.deinit(std.testing.allocator);
    const f_buf2 = try std.fmt.allocPrint(std.testing.allocator, " -b {s}", .{expected_source_b64});
    defer std.testing.allocator.free(f_buf2);
    try expected_source_buf.appendSlice(std.testing.allocator, f_buf2);
    try std.testing.expect(std.mem.indexOf(u8, cmd, expected_source_buf.items) != null);

    try std.testing.expect(std.mem.indexOf(u8, cmd, " && rm -rf '/custom/home'") == null);
}

test "Remote Command Builder Test - install_force" {
    

    var args = cli.OperationalConfig.init(std.testing.allocator);
    defer args.deinit(std.testing.allocator);

    args.shell = try std.testing.allocator.dupe(u8, "zsh");
    args.host_zzh_home = try std.testing.allocator.dupe(u8, "/custom/home");
    args.install_force = true;
    args.install_force_full = false;

    const staged_script = try compileStagedScript(std.testing.allocator, &args);
    defer staged_script.deinit(std.testing.allocator);
    const cmd = try std.mem.join(std.testing.allocator, " && ", &.{ staged_script.bootstrap_script, staged_script.session_script });
    defer std.testing.allocator.free(cmd);

    try std.testing.expect(std.mem.indexOf(u8, cmd, "rm -rf '/custom/home'/.zzh &&") != null);
}

fn getTempDir(allocator: std.mem.Allocator) ![]const u8 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        var env_map = try config.global_environ.createMap(allocator);
        defer env_map.deinit();
        if (env_map.get("TEMP")) |temp| {
            return allocator.dupe(u8, temp);
        }
        if (builtin.is_test) return allocator.dupe(u8, "C:\\Temp");
        return allocator.dupe(u8, "C:\\Temp");
    } else {
        return allocator.dupe(u8, "/tmp");
    }
}

test "Deploy and Connect Mock Test - Success" {
    
    const builtin = @import("builtin");

    const temp_base = try getTempDir(std.testing.allocator);
    defer std.testing.allocator.free(temp_base);

    var rand: u64 = 0;
    std.testing.io.random(std.mem.asBytes(&rand));
    var sub_buf: [256]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&sub_buf, "{s}/success-{x}", .{ temp_base, rand });
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    try std.Io.Dir.createDirAbsolute(threaded_io.io(), sub_path, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, sub_path) catch {};

    var args = cli.OperationalConfig.init(std.testing.allocator);
    defer args.deinit(std.testing.allocator);

    args.shell = try std.testing.allocator.dupe(u8, "zsh");
    args.destination = try std.testing.allocator.dupe(u8, "localhost");
    args.verbose = true; // Covers verbosity print branches
    args.vverbose = true; // Covers vverbose print branches

    // Set all SSH connection options to cover their parsing and construction in deployAndConnect
    args.ssh_port = try std.testing.allocator.dupe(u8, "2222");
    args.ssh_private_key = try std.testing.allocator.dupe(u8, "dummy_key");
    args.ssh_login = try std.testing.allocator.dupe(u8, "user");
    args.ssh_jump_host = try std.testing.allocator.dupe(u8, "jump");
    try args.ssh_options.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "ForwardAgent=yes"));
    try args.ssh_args.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "-v"));

    if (builtin.os.tag == .windows) {
        args.ssh_command = try std.testing.allocator.dupe(u8, "cmd.exe");
        try args.ssh_args.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "/c"));
        try args.ssh_args.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "exit 0"));
    } else {
        args.ssh_command = try std.testing.allocator.dupe(u8, "true");
    }

    var test_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer test_io.deinit();
    try deployAndConnect(std.testing.allocator, &args, sub_path, &.{}, test_io.io());
}

test "escapePathForShell Test" {
    

    const res1 = try escapePathForShell(std.testing.allocator, "~/.zzh");
    defer std.testing.allocator.free(res1);
    try std.testing.expectEqualStrings("~/'.zzh'", res1);

    const res2 = try escapePathForShell(std.testing.allocator, "~user/some dir");
    defer std.testing.allocator.free(res2);
    try std.testing.expectEqualStrings("~user/'some dir'", res2);

    const res3 = try escapePathForShell(std.testing.allocator, "~");
    defer std.testing.allocator.free(res3);
    try std.testing.expectEqualStrings("~", res3);

    const res4 = try escapePathForShell(std.testing.allocator, "/absolute/path");
    defer std.testing.allocator.free(res4);
    try std.testing.expectEqualStrings("'/absolute/path'", res4);

    const res5 = try escapePathForShell(std.testing.allocator, "~/path'with'quote");
    defer std.testing.allocator.free(res5);
    try std.testing.expectEqualStrings("~/'path'\\''with'\\''quote'", res5);

    const res6 = try escapePathForShell(std.testing.allocator, "~/");
    defer std.testing.allocator.free(res6);
    try std.testing.expectEqualStrings("~/", res6);

    const res7 = try escapePathForShell(std.testing.allocator, "~user/");
    defer std.testing.allocator.free(res7);
    try std.testing.expectEqualStrings("~user/", res7);

    const res8 = try escapePathForShell(std.testing.allocator, "~user/some dir/");
    defer std.testing.allocator.free(res8);
    try std.testing.expectEqualStrings("~user/'some dir/'", res8);
}

test "normalizeOs and normalizeArch tests" {
    

    // Test normalizeOs
    const os1 = try normalizeOs(std.testing.allocator, "Linux");
    defer std.testing.allocator.free(os1);
    try std.testing.expectEqualStrings("linux", os1);

    const os2 = try normalizeOs(std.testing.allocator, "Darwin");
    defer std.testing.allocator.free(os2);
    try std.testing.expectEqualStrings("darwin", os2);

    const os3 = try normalizeOs(std.testing.allocator, "FreeBSD");
    defer std.testing.allocator.free(os3);
    try std.testing.expectEqualStrings("freebsd", os3);

    const os4 = try normalizeOs(std.testing.allocator, "MINGW64_NT-10.0");
    defer std.testing.allocator.free(os4);
    try std.testing.expectEqualStrings("linux", os4); // safe fallback

    // Test normalizeArch
    const arch1 = try normalizeArch(std.testing.allocator, "x86_64");
    defer std.testing.allocator.free(arch1);
    try std.testing.expectEqualStrings("x86_64", arch1);

    const arch2 = try normalizeArch(std.testing.allocator, "amd64");
    defer std.testing.allocator.free(arch2);
    try std.testing.expectEqualStrings("x86_64", arch2);

    const arch3 = try normalizeArch(std.testing.allocator, "aarch64");
    defer std.testing.allocator.free(arch3);
    try std.testing.expectEqualStrings("aarch64", arch3);

    const arch4 = try normalizeArch(std.testing.allocator, "arm64");
    defer std.testing.allocator.free(arch4);
    try std.testing.expectEqualStrings("aarch64", arch4);

    const arch5 = try normalizeArch(std.testing.allocator, "riscv64");
    defer std.testing.allocator.free(arch5);
    try std.testing.expectEqualStrings("x86_64", arch5); // fallback
}
