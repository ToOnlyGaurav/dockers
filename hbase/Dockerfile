# Use the official Ubuntu base image
FROM myubuntu_jdk

COPY binaries /remote

# Install HBase
ENV HBASE_HOME=/remote/hbase-3.0.0-beta-1 \
    HBASE_CONF_DIR=/conf \
    HBASE_DATA_DIR=/data \
    HBASE_DATA_LOG_DIR=/datalog \
    HBAE_LOG_DIR=/logs

ENV PATH="$HBASE_HOME/bin:$PATH"

# Add a user with an explicit UID/GID and create necessary directories
RUN set -eux; \
   groupadd -r hbase --gid=2000; \
   useradd -r -g hbase --uid=2000 hbase; \
   mkdir -p "$HBASE_DATA_LOG_DIR" "$HBASE_DATA_DIR" "$HBASE_CONF_DIR" "$HBASE_LOG_DIR"; \
   chown -R hbase:hbase "$HBASE_HOME" "$HBASE_LOG_DIR" "$HBASE_DATA_DIR" "$HBASE_CONF_DIR" "$HBASE_LOG_DIR"

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

CMD ["bash"]