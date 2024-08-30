# Use the official Ubuntu base image
FROM --platform=linux/amd64 myubuntu_python

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

COPY remote /remote

WORKDIR /remote/aerospike-server-enterprise_7.1.0.5_tools-11.0.2_ubuntu22.04_x86_64

RUN ./asinstall

COPY ./config/aerospike.conf /etc/aerospike/aerospike.conf

ADD entrypoint.sh entrypoint.sh

CMD ["bash"]
