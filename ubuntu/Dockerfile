ARG VERSION=noble
ARG PLATFORM=linux/amd64

FROM --platform=${PLATFORM} ubuntu:${VERSION}

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Install necessary utilities
RUN set -eux && \
    apt-get   -o Acquire::AllowInsecureRepositories=true \
    -o Acquire::AllowDowngradeToInsecureRepositories=true update && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    conntrack \
    curl \
    dirmngr \
    dnsutils \
    gnupg \
    gosu \
    iproute2 \
    iptables \
    iputils-ping \
    jq \
    less \
    net-tools \
    netcat-traditional \
    ngrep \
    procps \
    sudo \
    tar \
    tcpdump \
    tree \
    vim \
    wget \
    gettext-base \
    iptables \
    apt-transport-https -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
# Default command to execute when running the container
CMD ["bash"]
