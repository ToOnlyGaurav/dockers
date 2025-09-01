# Use the official Ubuntu base image
FROM myubuntu-noble

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

COPY binaries /remote

# Set JAVA_HOME environment variable
ENV JAVA_HOME=/remote/jdk-17.0.2

# Set PATH environment variable
ENV PATH="$JAVA_HOME/bin:$PATH"

# Verify Java installation
RUN java -version

# Define a working directory
WORKDIR /remote

# Default command to execute when running the container
CMD ["bash"]
