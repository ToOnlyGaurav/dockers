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
