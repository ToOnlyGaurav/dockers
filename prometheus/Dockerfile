# Use the official Ubuntu base image
FROM --platform=linux/amd64 myubuntu

COPY remote /remote

# Define a working directory
WORKDIR /remote/prometheus-2.43.0.linux-amd64
RUN mkdir -p /prometheus
COPY /config/prometheus.yml /etc/prometheus/prometheus.yml
ENV PATH="/remote/prometheus-2.43.0.linux-amd64:$PATH"

# Default command to execute when running the container
#ENTRYPOINT [ "/remote/prometheus-2.43.0.linux-amd64/prometheus" ]
#CMD        [ "--storage.tsdb.path=/prometheus"]

#CMD ["bash"]
CMD ["prometheus", "--config.file=/etc/prometheus/prometheus.yml" ]
