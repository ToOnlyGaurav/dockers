# Use the official Ubuntu base image
FROM --platform=linux/amd64 myubuntu

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Install necessary utilities
RUN apt-get update && \
    apt-get install -y \
#    build-essential libssl-dev libffi-dev python3-dev \
    python3 \
#    python3-venv \
    && apt-get clean

# Default command to execute when running the container
CMD ["bash"]
