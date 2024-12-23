# Use the official Ubuntu base image
FROM myubuntu

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Install necessary utilities
RUN apt-get update && \
    apt-get install -y \
    nginx \
    && apt-get clean

COPY ./html /var/www/html

# Default command to execute when running the container
RUN /etc/init.d/nginx start
CMD ["bash"]
