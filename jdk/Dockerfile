# Use the official Ubuntu base image
FROM --platform=linux/amd64 myubuntu

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

COPY binaries /remote

## Install necessary utilities
#RUN apt-get update && \
#    apt-get install -y \
#    openjdk-17-jre-headless \
#    && apt-get clean

# Set JAVA_HOME environment variable
ENV JAVA_HOME=/remote/jdk-17

# Set PATH environment variable
ENV PATH="$JAVA_HOME/bin:$PATH"

# Verify Java installation
RUN java -version

# Define a working directory
WORKDIR /remote

# Default command to execute when running the container
CMD ["bash"]
