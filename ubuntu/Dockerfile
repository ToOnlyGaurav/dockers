# Use the official Ubuntu base image
FROM --platform=linux/amd64 ubuntu:jammy

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Install necessary utilities
RUN apt-get update && \
    apt-get install -y \
    curl \
    tar \
    tree \
    sudo \
    gnupg \
    vim \
    apt-transport-https -y \
    && apt-get clean

# Default command to execute when running the container
CMD ["bash"]
