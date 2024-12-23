# Use the official Ubuntu base image
FROM myubuntu

COPY binaries /remote
COPY configs/mariadb.cnf /remote/m

ENV MARIADB_HOME=/remote/mariadb-11.6.2-ubuntu-jammy-amd64-debs

# Set PATH environment variable
ENV PATH="$ZOOKEEPER_HOME/bin:$PATH"

RUN mkdir -p /var/lib/zookeeper

# Define a working directory
WORKDIR $ZOOKEEPER_HOME/bin

COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]

CMD ["zkServer.sh", "start-foreground"]