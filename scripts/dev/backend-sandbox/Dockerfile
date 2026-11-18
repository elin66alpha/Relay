FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    g++ \
    make \
    procps \
    python3 \
    tar \
    zip \
  && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && npm install -g pm2 \
  && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash relay \
  && mkdir -p /home/relay \
  && chown -R relay:relay /home/relay

USER relay
WORKDIR /home/relay
ENV HOME=/home/relay

EXPOSE 18787

CMD ["bash", "-c", "trap 'pm2 kill >/dev/null 2>&1 || true; exit 0' TERM INT; rm -f \"$HOME/.pm2/rpc.sock\" \"$HOME/.pm2/pub.sock\" \"$HOME/.pm2/pm2.pid\"; if [ -f \"$HOME/.pm2/dump.pm2\" ]; then pm2 resurrect >/dev/null 2>&1 || true; else pm2 ping >/dev/null 2>&1 || true; fi; while :; do sleep 3600 & wait $!; done"]
