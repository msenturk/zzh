#!/bin/bash
set -e

echo "=== [1/4] Preparing Nushell shell package cache ==="
# We copy our active development copy of the Nushell shell to the local zzh cache
# so that zzh does not attempt to clone a remote git repository for it.
mkdir -p ~/.zzh/.zzh/shells/xxh-shell-nu
rm -rf ~/.zzh/.zzh/shells/xxh-shell-nu/*
cp -r shells/xxh-shell-nu/* ~/.zzh/.zzh/shells/xxh-shell-nu/

echo "=== [2/4] Setting up test SSH keys ==="
mkdir -p ~/.ssh
if [ ! -f ~/.ssh/xhh_test_key ]; then
    ssh-keygen -t ed25519 -f ~/.ssh/xhh_test_key -N "" -q
fi

# Assert helper function
function assert_contains() {
    local output="$1"
    local pattern="$2"
    local name="$3"
    if [[ "$output" == *"$pattern"* ]]; then
        echo -e "  \033[0;32m[PASS]\033[0m $name"
        return 0
    else
        echo -e "  \033[0;31m[FAIL]\033[0m $name (expected pattern '$pattern')"
        echo "  Actual Output: $output"
        exit 1
    fi
}


DISTROS=("alpine" "ubuntu" "rocky")
PORTS=(2222 2223 2224)
IMAGES=("alpine:latest" "ubuntu:latest" "rockylinux:9")

for i in "${!DISTROS[@]}"; do
    DISTRO="${DISTROS[$i]}"
    PORT="${PORTS[$i]}"
    IMAGE="${IMAGES[$i]}"

    echo "--------------------------------------------------------"
    echo "=== Running E2E tests on $DISTRO (Port $PORT) ==="
    echo "--------------------------------------------------------"

    # Clean up old container
    podman rm -f zzh-sshd-$DISTRO-run 2>/dev/null || true

    # Prepare Containerfile based on distro
    CONTAINERFILE="Containerfile.$DISTRO"
    if [ "$DISTRO" = "alpine" ]; then
        cat <<EOF > "$CONTAINERFILE"
FROM $IMAGE
RUN apk add --no-cache openssh-server bash shadow && \
    ssh-keygen -A && \
    mkdir -p /root/.ssh && \
    chmod 700 /root/.ssh
RUN echo "root:root" | chpasswd && \
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    echo "UseDNS no" >> /etc/ssh/sshd_config
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
EOF
    elif [ "$DISTRO" = "ubuntu" ]; then
        cat <<EOF > "$CONTAINERFILE"
FROM $IMAGE
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y openssh-server bash && \
    mkdir -p /run/sshd && \
    mkdir -p /root/.ssh && \
    chmod 700 /root/.ssh
RUN echo "root:root" | chpasswd && \
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    echo "UseDNS no" >> /etc/ssh/sshd_config
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
EOF
    elif [ "$DISTRO" = "rocky" ]; then
        cat <<EOF > "$CONTAINERFILE"
FROM $IMAGE
RUN dnf install -y openssh-server bash && \
    ssh-keygen -A && \
    mkdir -p /root/.ssh && \
    chmod 700 /root/.ssh
RUN echo "root:root" | chpasswd && \
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    echo "UseDNS no" >> /etc/ssh/sshd_config
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
EOF
    fi

    # Build image
    echo "Building container image for $DISTRO..."
    podman build -t zzh-sshd-$DISTRO -f "$CONTAINERFILE" .
    rm "$CONTAINERFILE"

    # Run container
    echo "Starting container zzh-sshd-$DISTRO-run..."
    podman run -d --name zzh-sshd-$DISTRO-run -p $PORT:22 zzh-sshd-$DISTRO

    # Copy public key
    podman cp ~/.ssh/xhh_test_key.pub zzh-sshd-$DISTRO-run:/root/.ssh/authorized_keys
    podman exec zzh-sshd-$DISTRO-run chmod 600 /root/.ssh/authorized_keys
    podman exec zzh-sshd-$DISTRO-run chown -R root:root /root/.ssh

    # Wait for SSHD to become ready
    echo "Waiting for SSHD to start on port $PORT..."
    for j in {1..15}; do
        if nc -z localhost $PORT; then
            echo "SSHD is ready!"
            break
        fi
        sleep 1
    done

    # Run E2E tests for Nushell
    echo "Test Case 1: Testing Nushell basic command execution (+hc)..."
    OUT1=$(./zig-out/bin/zzh -p $PORT -i ~/.ssh/xhh_test_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 +s nu +hc "echo 'hello remote nu'")
    assert_contains "$OUT1" "hello remote nu" "Basic Nushell command execution on $DISTRO"

    echo "Test Case 2: Testing Nushell plugin installation (+I nu-gstat)..."
    rm -rf ~/.zzh/.zzh/plugins/xxh-plugin-nu-gstat
    OUT2=$(./zig-out/bin/zzh -p $PORT -i ~/.ssh/xhh_test_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 +s nu +I nu-gstat +hc "plugin list")
    assert_contains "$OUT2" "gstat" "Nushell plugin gstat registry verification on $DISTRO"

    echo "Test Case 3: Testing Nushell plugin command execution..."
    OUT3=$(./zig-out/bin/zzh -p $PORT -i ~/.ssh/xhh_test_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 +s nu +I nu-gstat +hc "gstat --help")
    assert_contains "$OUT3" "git status" "Nushell plugin gstat execution verify on $DISTRO"

    # Clean up container
    echo "Cleaning up container zzh-sshd-$DISTRO-run..."
    podman rm -f zzh-sshd-$DISTRO-run
done

echo "=== [4/4] Nushell & Plugin E2E Verification Complete for Alpine, Ubuntu, and Rocky Linux! ==="
