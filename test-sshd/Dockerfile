FROM alpine:latest

RUN apk add --no-cache \
    openssh-server \
    bash \
    sudo \
    curl \
    wget \
    git \
    tar \
    unzip

RUN ssh-keygen -A
RUN mkdir -p /var/run/sshd

# Create testuser with password "test"
RUN adduser -D -s /bin/bash testuser && \
    echo "testuser:test" | chpasswd && \
    echo "root:root" | chpasswd && \
    echo "testuser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Enable password auth and disable DNS
RUN sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
RUN sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
RUN sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config || true
RUN echo "UseDNS no" >> /etc/ssh/sshd_config

EXPOSE 22

CMD ["/usr/sbin/sshd", "-D"]
