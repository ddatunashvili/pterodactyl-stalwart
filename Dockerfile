FROM stalwartlabs/stalwart:v0.16.25

# Wings runs containers as its system user (default uid 988). Match it so the
# process has a passwd entry. Override with --build-arg if yours differs.
ARG CONTAINER_UID=988

USER root

# jq drives the one-time listener setup in the entrypoint (JMAP over curl).
RUN export DEBIAN_FRONTEND=noninteractive \
 && apt-get update \
 && apt-get install -yq --no-install-recommends jq \
 && rm -rf /var/lib/apt/lists/*

# The binary ships with the file capability cap_net_bind_service. Wings drops
# that capability from every container, and the kernel refuses to exec a
# binary whose file caps exceed the bounding set: "Operation not permitted".
# Every listener here is on a port above 1024, so nothing needs it.
RUN setcap -r /usr/local/bin/stalwart

# Everything Stalwart keeps lives in the server volume. The configuration
# names /home/container paths explicitly; the log directory is the one path
# the server's own defaults hard-code, so it is pointed into the volume too.
# /etc/stalwart and /var/lib/stalwart are left alone: the base image declares
# them as VOLUMEs, and a symlink there would be mounted over.
RUN useradd -m -u ${CONTAINER_UID} -d /home/container -s /bin/bash container \
 && rm -rf /var/log/stalwart \
 && ln -s /home/container/logs /var/log/stalwart

COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

ENV USER=container HOME=/home/container
USER container
WORKDIR /home/container

# The base image probes https on 443, which nothing here listens on.
HEALTHCHECK NONE
STOPSIGNAL SIGINT
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
CMD []
