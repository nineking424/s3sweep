FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates jq && \
    curl -O https://downloads.rclone.org/rclone-current-linux-amd64.deb && \
    dpkg -i rclone-current-linux-amd64.deb && \
    rm rclone-current-linux-amd64.deb && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY worker.sh /app/worker.sh
RUN chmod +x /app/worker.sh

ENTRYPOINT ["/app/worker.sh"]
