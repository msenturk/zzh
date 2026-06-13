import sys

with open('src/cli.zig', 'r') as f:
    content = f.read()

new_content = content.replace(
    'token_idx += 1;\n            if (token_idx < tokens.len) {',
    'token_idx += 1;\n            if (token_idx >= tokens.len) {\n                std.debug.print("Error: Missing argument for \'{s}\'\\n", .{token});\n                std.process.exit(1);\n            }\n            if (true) {'
)

with open('src/cli.zig', 'w') as f:
    f.write(new_content)

print('Done')
