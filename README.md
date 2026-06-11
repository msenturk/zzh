# zzh

[![Zig Build](https://img.shields.io/badge/Language-Zig_0.13.0-orange.svg)](https://ziglang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Fork of xhh](https://img.shields.io/badge/Fork_of-xhh-purple.svg)](https://github.com)

A zero-dependency, hyper-fast rewrite of the [xxh](https://github.com/xxh/xxh) orchestrator in Zig. 

> [!NOTE]
> This project is a fork of the original **xhh** (or `xhh-zig`) project, which ported `xxh` to Zig to eliminate local Python dependencies, reduce execution times, and provide a single, statically-linked binary.

---

## What is zzh?

`zzh` allows you to bring your favorite interactive shell (e.g., `zsh`, `fish`, `bash`) along with all your custom configurations, themes, and plugins to any remote host you connect to via SSH. It does this without requiring administrative privileges, pre-installation on the remote host, or local Python dependencies.

```mermaid
sequenceDiagram
    autonumber
    actor User as Developer
    participant ZZH as zzh CLI (Local)
    participant SSH as SSH Client
    participant Remote as Remote Host

    User->>ZZH: Run `zzh user@host +s zsh`
    Note over ZZH: 1. Parse CLI arguments<br/>2. Load & resolve config.zzhc
    ZZH->>ZZH: 3. Resolve & download shells/plugins
    ZZH->>ZZH: 4. Bundle assets into in-memory .tar
    ZZH->>SSH: 5. Spawn SSH process & pipe payload
    SSH->>Remote: 6. Extract payload to ~/.zzh/ & execute entrypoint.sh
    Remote-->>User: 7. Interactive shell session started!
```

---

## Features

- **Statically Linked Binary**: No runtime dependencies on Python or external libraries.
- **Ultra Fast Performance**: Immediate start-up times and fast execution powered by Zig's minimal, optimized runtime.
- **Piped Archiving**: Files are compressed in memory and piped directly over a single SSH connection.
- **Ecosystem Compatibility**: Works out-of-the-box with the standard `xxh` shells and plugins (e.g., `xxh-shell-zsh`, `xxh-plugin-prerun-zoxide`).

---

## Getting Started

### Prerequisites

To build `zzh` from source, you need **Zig 0.13.0**. 

If you use [mise-en-place](https://mise.jdx.dev/), the tool version is configured automatically via `mise.toml`.

### Building from Source

To compile the application:

```bash
# Debug Build
zig build

# Release Build (Optimized for Speed)
zig build -Doptimize=ReleaseSmall
```

The compiled binary will be placed in `zig-out/bin/zzh`.

### Running Tests

To run the unit tests:

```bash
zig build test
```

---

## Configuration

`zzh` looks for configuration files at `~/.config/zzh/config.zzhc`.

Here is an example `config.zzhc` file:

```yaml
# zzh Demo Configuration File (config.zzhc)
hosts:
  # Matches any host you connect to
  ".*":
    +s: zsh               # Use zsh as the default portable shell
    +hhh: "~"             # Set target home directory to "~"

  # Matches connections to localhost (e.g. root@127.0.0.1)
  "127.0.0.1":
    -p: 2222              # Use port 2222 for local test container
    +if:                  # Force reinstall xxh packages
    +e:                   # Inject environment variables
      - OSH_THEME="powerlevel10k"
```

---

## Usage

Use `zzh` exactly like you would use `ssh`. Simply prefix standard SSH commands or add `zzh`-specific arguments:

```bash
# Connect to host using zsh
zzh user@host +s zsh

# Connect to host and pre-install a plugin
zzh user@host +s zsh +I xxh-plugin-zsh-ohmyzsh
```

### Argument Syntax

Arguments starting with `+` are interpreted by `zzh` (e.g., `+s` for selecting the shell, `+I` for installing plugins). All other arguments are passed directly to the underlying `ssh` process.

---

## License

This project is licensed under the MIT License - see the LICENSE file for details.
