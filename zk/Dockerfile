# Use the official Ubuntu base image
FROM myubuntu_jdk

COPY binaries /remote

# Install Zookeeper
ENV ZOOKEEPER_HOME=/remote/apache-zookeeper-3.9.3-bin \
    ZOO_CONF_DIR=/conf \
    ZOO_DATA_DIR=/data \
    ZOO_DATA_LOG_DIR=/datalog \
    ZOO_LOG_DIR=/logs \
    ZOO_MY_ID=1

# Add a user with an explicit UID/GID and create necessary directories
RUN set -eux; \
    groupadd -r zookeeper --gid=2000; \
    useradd -r -g zookeeper --uid=2000 zookeeper; \
    mkdir -p "$ZOO_DATA_LOG_DIR" "$ZOO_DATA_DIR" "$ZOO_CONF_DIR" "$ZOO_LOG_DIR"; \
    chown -R zookeeper:zookeeper "$ZOOKEEPER_HOME" "$ZOO_DATA_LOG_DIR" "$ZOO_DATA_DIR" "$ZOO_CONF_DIR" "$ZOO_LOG_DIR"

COPY configs/zoo.cfg ${ZOO_CONF_DIR}/

# Set PATH environment variable
ENV PATH="${ZOOKEEPER_HOME}/bin:${PATH}" \
    ZOOCFGDIR="${ZOO_CONF_DIR}"

# Define a working directory
WORKDIR ${ZOOKEEPER_HOME}/bin

VOLUME ["${ZOO_DATA_DIR}", "${ZOO_DATA_LOG_DIR}", "${ZOO_LOG_DIR}"]

EXPOSE 2181 2888 3888 8080

COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]

CMD ["zkServer.sh", "start-foreground"]