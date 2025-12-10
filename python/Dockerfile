# Use the official Ubuntu base image
FROM myubuntu-noble
# FROM myubuntu-jammy

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Install necessary utilities
RUN apt-get update && \
    apt-get install -y \
#    build-essential libssl-dev libffi-dev python3-dev \
    python3 \
    python3-pip \
    python3-venv \
    && apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /tmp/venv

ENV PATH="${PATH}:/tmp/venv/bin/"

WORKDIR /remote

# Default command to execute when running the container
CMD ["bash"]
