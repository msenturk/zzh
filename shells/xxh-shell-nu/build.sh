#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"

mkdir -p build/bin

# Copy entrypoint
cp entrypoint.sh build/entrypoint.sh
chmod +x build/entrypoint.sh

NU_VERSION="0.94.2"
TARBALL="nu-${NU_VERSION}-x86_64-unknown-linux-musl.tar.gz"
URL="https://github.com/nushell/nushell/releases/download/${NU_VERSION}/${TARBALL}"

echo "Downloading Nushell v${NU_VERSION}..."
if [ ! -f "$TARBALL" ]; then
  curl -L -O "$URL"
fi

echo "Extracting Nushell..."
tar -xzf "$TARBALL"

# Find the extracted nu binary and move it to build/bin
mv "nu-${NU_VERSION}-x86_64-unknown-linux-musl/nu" build/bin/nu
chmod +x build/bin/nu

# Move all Nushell plugin binaries if they exist
if ls nu-${NU_VERSION}-x86_64-unknown-linux-musl/nu_plugin_* 1>/dev/null 2>&1; then
  mv nu-${NU_VERSION}-x86_64-unknown-linux-musl/nu_plugin_* build/bin/
  chmod +x build/bin/nu_plugin_*
fi

# Clean up extracted dir and tarball
rm -rf "nu-${NU_VERSION}-x86_64-unknown-linux-musl"
rm -f "$TARBALL"

echo "Build completed successfully. Files are in build/"
