# Use the official Ubuntu base image
FROM myubuntu_jdk

COPY binaries /remote

ENV ES_HOME=/remote/elasticsearch-8.17.0

ENV PATH="$ES_HOME/bin:$PATH"

ENV ES_JAVA_OPTS="-Xms1g -Xmx1g"

# Set the working directory
WORKDIR $ES_HOME

# Mount elasticsearch.yml config
ADD configs/elasticsearch.yml $ES_HOME/config/elasticsearch.yml

RUN groupadd -g 2000 elasticsearch && \
    useradd -r -u 2000 -g elasticsearch elasticsearch

# Create the Elasticsearch home directory
RUN mkdir -p $ES_HOME && chown -R elasticsearch:elasticsearch $ES_HOME

RUN sysctl -w vm.max_map_count=262144

# Expose the default Elasticsearch ports
EXPOSE 9200 9300

# Switch to the elasticsearch user
USER elasticsearch

COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]

CMD ["./bin/elasticsearch"]
#CMD ["bash"]