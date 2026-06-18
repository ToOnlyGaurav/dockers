FROM myubuntu_noble_jdk_25

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux && \
    apt-get -o Acquire::AllowInsecureRepositories=true \
    -o Acquire::AllowDowngradeToInsecureRepositories=true update && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    zlib1g-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN set -eux && \
    curl -s "https://get.sdkman.io" | bash && \
    bash -c 'source "$HOME/.sdkman/bin/sdkman-init.sh" && sdk install java 25.0.2-graalce'

# Default command to execute when running the container
CMD ["bash"]
