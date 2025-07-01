# Use the official Ubuntu base image
FROM myubuntu_python

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

COPY binaries /remote

WORKDIR /remote/aerospike-server-enterprise_7.2.0.4_tools-11.1.1_ubuntu24.04_aarch64

RUN ./asinstall

RUN mkdir -p /opt/aerospike/log

COPY ./configs/aerospike.conf /opt/aerospike/config/aerospike.conf

COPY entrypoint.sh entrypoint.sh

ENTRYPOINT ["./entrypoint.sh"]

CMD ["asd"]
