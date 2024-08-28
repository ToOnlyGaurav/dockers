# Use the official Ubuntu base image
FROM --platform=linux/amd64 myubuntu

# Copy local JDK and Zookeeper tarballs into the container
COPY remote /remote

# Install Zookeeper
ENV ZOOKEEPER_HOME=/remote/apache-zookeeper-3.9.2-bin

# Set JAVA_HOME environment variable
ENV JAVA_HOME=/remote/jdk-17

# Set PATH environment variable
ENV PATH="$JAVA_HOME/bin:$ZOOKEEPER_HOME/bin:$PATH"

RUN mkdir -p /var/lib/zookeeper

# Verify Java installation
RUN java -version

# Define a working directory
WORKDIR /remote

# Default command to execute when running the container
CMD ["bash"]
