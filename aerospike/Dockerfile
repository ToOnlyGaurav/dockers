# Use the official Ubuntu base image
FROM myubuntu-noble_python
# FROM myubuntu-jammy_python

# Define build arguments for version
ARG AEROSPIKE_VERSION=6.4.0.23
ARG TOOLS_VERSION=11.1.1
ARG UBUNTU_VERSION=24.04
ARG ARCH=aarch64

# Extract major version
ARG AEROSPIKE_MAJOR_VERSION=${AEROSPIKE_VERSION%%.*}

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Add this volume for cgroup access
VOLUME ["/sys/fs/cgroup"]

# Optionally, set environment variable for Aerospike
ENV CGROUP_PATH=/sys/fs/cgroup

COPY binaries /remote

RUN echo "AEROSPIKE_VERSION=${AEROSPIKE_VERSION} TOOLS_VERSION=${TOOLS_VERSION} UBUNTU_VERSION=${UBUNTU_VERSION} AEROSPIKE_MAJOR_VERSION=${AEROSPIKE_MAJOR_VERSION} ARCH=${ARCH}"

#WORKDIR /remote/aerospike-server-enterprise_7.2.0.4_tools-11.1.1_ubuntu24.04_aarch64
WORKDIR /remote/aerospike-server-enterprise_${AEROSPIKE_VERSION}_tools-${TOOLS_VERSION}_ubuntu${UBUNTU_VERSION}_${ARCH}

RUN ls -la && echo "Current directory: $(pwd)"

# Make sure the install script is executable
RUN chmod +x ./asinstall || echo "Failed to chmod: asinstall not found"

RUN ./asinstall

RUN mkdir -p /etc/aerospike/log /etc/aerospike/config

COPY ./configs/aerospike_${AEROSPIKE_MAJOR_VERSION}.conf /etc/aerospike/config/aerospike.conf

COPY entrypoint.sh entrypoint.sh

ENTRYPOINT ["./entrypoint.sh"]

CMD ["asd"]
#CMD ["bash"]
