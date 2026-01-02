ARG PLATFORM=linux/amd64
FROM --platform=${PLATFORM} myubuntu
# FROM myubuntu-jammy

# Set environment variables to avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Install necessary utilities
RUN apt-get update && \
    apt-get install -y \
#    build-essential libssl-dev libffi-dev python3-dev \
    python3 \
    python3-pip \
    python3-venv \
#    aerospike \
    && apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

RUN python -m pip install --no-cache-dir \
    numpy \
    pandas \
    scipy \
    scikit-learn \
    matplotlib \
    seaborn \
    aerospike

WORKDIR /remote

# Default command to execute when running the container
CMD ["bash"]
