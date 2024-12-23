# Use the official Ubuntu base image
FROM myubuntu_python

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Install necessary utilities
RUN /tmp/venv/bin/pip install locust

# Default command to execute when running the container

COPY locustfiles /locustfiles

WORKDIR /locustfiles

COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]

CMD ["locust", "-f", "/locustfiles/locustfile.py"]
