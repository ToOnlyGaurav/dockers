# Use the official Ubuntu base image
FROM myubuntu_maven

# Installing required packages
RUN set -eux && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends \
    software-properties-common \
    build-essential \
    libprotobuf-dev \
    libcairo2-dev \
    pkg-config \
    libfontconfig \
    git \
    bash \
    curl \
    tzdata \
    python3 \
    python3-pip \
    python3-venv \
    iproute2 \
    zip \
    unzip \
    wget \
    ca-certificates \
    libreadline-dev \
    libncursesw5-dev \
    libssl-dev \
    libsqlite3-dev \
    tk-dev \
    libgdbm-dev \
    libc6-dev \
    libbz2-dev -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /tmp/venv

ENV PATH="${PATH}:/tmp/venv/bin/"

# Installing python to support script execution while building Docker Image
RUN add-apt-repository ppa:deadsnakes/ppa

# Timezone configuration
RUN ln -fs /usr/share/zoneinfo/Asia/Kolkata /etc/localtime && \
    dpkg-reconfigure --frontend noninteractive tzdata


# Installing docker
RUN curl -fsSL https://get.docker.com -o get-docker.sh
RUN sh get-docker.sh
# Define a working directory
WORKDIR /remote

# Verify Java installation
RUN mvn --version && docker --version

# Default command to execute when running the container
CMD ["bash"]
