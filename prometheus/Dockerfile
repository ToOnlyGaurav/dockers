# Use the official Ubuntu base image
FROM --platform=linux/amd64 myubuntu

COPY binaries /remote

# Define a working directory
WORKDIR /remote/prometheus-2.43.0.linux-amd64
RUN mkdir -p /prometheus
COPY /configs/prometheus.yml /etc/prometheus/prometheus.yml
ENV PATH="/remote/prometheus-2.43.0.linux-amd64:$PATH"


COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
CMD ["prometheus", "--config.file=/etc/prometheus/prometheus.yml" ]
