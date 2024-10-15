# Use the official Ubuntu base image
FROM --platform=linux/amd64 myubuntu_python

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Install necessary utilities
RUN pip3 install locust

# Default command to execute when running the container

COPY locustfiles /locustfiles

WORKDIR /locustfiles

COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]

CMD ["locust", "-f", "/locustfiles/locustfile.py"]
