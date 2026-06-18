# Use the official Ubuntu base image
FROM myubuntu_noble

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

COPY binaries /remote

ARG JAVA_HOME_VERSION=jdk-25.0.2


ENV JAVA_HOME=/remote/${JAVA_HOME_VERSION} \
    PATH=/remote/${JAVA_HOME_VERSION}/bin:$PATH

# Copy entrypoint (used for startup validation/display only - env already set above)
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Define a working directory
WORKDIR /remote

ENTRYPOINT ["/entrypoint.sh"]

# Default command to execute when running the container
CMD ["bash"]
