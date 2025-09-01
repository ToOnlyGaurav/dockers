# Use the official Ubuntu base image
ARG VERSION=noble
FROM --platform=linux/arm64 ubuntu:${VERSION}

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Install necessary utilities
RUN set -eux && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends \
    curl \
    less \
    tar \
    tree \
    sudo \
    gnupg \
    vim \
    ca-certificates \
    dirmngr \
    gosu \
    gnupg \
    netcat-traditional \
    wget \
    conntrack \
    ngrep \
    net-tools \
    tcpdump \
    iproute2 \
    apt-transport-https -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
# Default command to execute when running the container
CMD ["bash"]
