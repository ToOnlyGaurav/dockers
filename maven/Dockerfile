# Use the official Ubuntu base image
FROM myubuntu_jdk

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

COPY binaries /remote

# Set MAVEN_HOME environment variable
ENV MAVEN_HOME=/remote/apache-maven-3.9.9

# Set PATH environment variable
ENV PATH="$MAVEN_HOME/bin:$PATH"

# Install necessary utilities
RUN set -eux && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y git-all  && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Define a working directory
WORKDIR /remote

# Verify Java installation
RUN mvn --version

# Default command to execute when running the container
CMD ["bash"]
