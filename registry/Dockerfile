FROM myubuntu_jdk

COPY binaries /remote

RUN useradd -m registry

WORKDIR /remote

RUN mkdir -p /var/lib/registry && chown registry:registry /var/lib/registry

COPY ./configs/registry.yml /etc/docker/registry/config.yml

EXPOSE 5000

USER registry

CMD ["/remote/registry", "serve", "/etc/docker/registry/config.yml"]
