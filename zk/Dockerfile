# Use the official Ubuntu base image
FROM --platform=linux/amd64 myubuntu_jdk

# Copy local JDK and Zookeeper tarballs into the container
COPY binaries /remote
COPY configs/zoo.cfg /remote/apache-zookeeper-3.9.2-bin/conf/

# Install Zookeeper
ENV ZOOKEEPER_HOME=/remote/apache-zookeeper-3.9.2-bin

# Set PATH environment variable
ENV PATH="$ZOOKEEPER_HOME/bin:$PATH"

RUN mkdir -p /var/lib/zookeeper

# Define a working directory
WORKDIR $ZOOKEEPER_HOME/bin

COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]

CMD ["zkServer.sh", "start-foreground"]