#!/bin/bash
set -e

echo "=== [1/6] (Skipped) Build zzh on Windows host first ==="

echo "=== [2/6] Setting up test SSH keys ==="
mkdir -p ~/.ssh
if [ ! -f ~/.ssh/xhh_test_key ]; then
    ssh-keygen -t ed25519 -f ~/.ssh/xhh_test_key -N "" -q
fi

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
    podman rm -f xhh-sshd-$DISTRO-run 2>/dev/null || true

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
    podman build -t xhh-sshd-$DISTRO -f "$CONTAINERFILE" .
    rm "$CONTAINERFILE"

    # Run container
    echo "Starting container xhh-sshd-$DISTRO-run..."
    podman run -d --name xhh-sshd-$DISTRO-run -p $PORT:22 xhh-sshd-$DISTRO

    # Copy public key
    podman cp ~/.ssh/xhh_test_key.pub xhh-sshd-$DISTRO-run:/root/.ssh/authorized_keys
    podman exec xhh-sshd-$DISTRO-run chmod 600 /root/.ssh/authorized_keys
    podman exec xhh-sshd-$DISTRO-run chown -R root:root /root/.ssh

    # Wait for SSHD to become ready
    echo "Waiting for SSHD to start on port $PORT..."
    for j in {1..15}; do
        if nc -z localhost $PORT; then
            echo "SSHD is ready!"
            break
        fi
        sleep 1
    done

    echo "=== Running E2E tests for CLI options on $DISTRO ==="

    # 1. Test basic command execution (+hc)
    echo "Testing +hc (host execute command)..."
    OUT1=$(./zig-out/bin/zzh -p $PORT -i ~/.ssh/xhh_test_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 +hc "echo 'hello remote'")
    assert_contains "$OUT1" "hello remote" "Basic command execution (+hc)"

    # 2. Test environment variables (+e)
    echo "Testing +e (environment variables)..."
    OUT2=$(./zig-out/bin/zzh -p $PORT -i ~/.ssh/xhh_test_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 +e TEST_VAL="e2e_var_val" +hc "env")
    assert_contains "$OUT2" "TEST_VAL=e2e_var_val" "Environment variables (+e)"

    # 3. Test base64 environment variables (+eb)
    echo "Testing +eb (base64 environment variables)..."
    OUT3=$(./zig-out/bin/zzh -p $PORT -i ~/.ssh/xhh_test_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 +eb B64_VAL="ZTJlX2Jhc2U2NF92YWw=" +hc "env")
    assert_contains "$OUT3" "B64_VAL=e2e_base64_val" "Base64 environment variables (+eb)"

    # 4. Test custom remote home path (+hh)
    echo "Testing +hh (custom remote home path)..."
    ./zig-out/bin/zzh -p $PORT -i ~/.ssh/xhh_test_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 +hh '~/.xxh_custom' +hc "true"
    OUT4=$(podman exec xhh-sshd-$DISTRO-run ls -la /root)
    assert_contains "$OUT4" ".xxh_custom" "Custom remote home path (+hh)"

    # 5. Test home path remove cleanup (+hhr)
    echo "Testing +hhr (remove home path after execution)..."
    ./zig-out/bin/zzh -p $PORT -i ~/.ssh/xhh_test_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 +hh '~/.xxh_temp' +hhr +hc "true"
    OUT5=$(podman exec xhh-sshd-$DISTRO-run ls -la /root)
    assert_not_contains "$OUT5" ".xxh_temp" "Home path remove cleanup (+hhr)"

    # Clean up container
    echo "Cleaning up container xhh-sshd-$DISTRO-run..."
    podman rm -f xhh-sshd-$DISTRO-run
done

# 6. Test list packages (+L)
echo "Testing +L (list packages)..."
OUT6=$(./zig-out/bin/zzh +L)
assert_contains "$OUT6" "xxh-shell-zsh" "List packages (+L)"

# 7. Test list shells (+LS)
echo "Testing +LS (list shells)..."
OUT7=$(./zig-out/bin/zzh +LS)
assert_contains "$OUT7" "xxh-shell-zsh" "List shells (+LS)"

echo "=== [5/5] E2E Verification Complete for Alpine, Ubuntu, and Rocky Linux! ==="
