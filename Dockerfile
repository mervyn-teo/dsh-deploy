# syntax=docker/dockerfile:1
#
# DeepSeek Harness (dsh web) behind a Caddy TLS + auth reverse proxy.
#
# dsh web deliberately refuses to bind 0.0.0.0 ("would expose remote code
# execution to the network"), so Caddy runs in the same container and proxies
# public traffic to dsh on 127.0.0.1:3080. Caddy binds 80/443 as root;
# dsh itself runs as the unprivileged `dsh` user via gosu.

FROM node:24-bookworm-slim

ARG DSH_VERSION=0.1.0-rc.7

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      caddy \
      gosu \
      git \
      curl \
      ca-certificates \
      # node-gyp toolchain: dsh-plugin-terminal's node-pty builds from source.
      python3 \
      make \
      g++ \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" pnpm \
 && npm cache clean --force

# Unlock settings management for remote browsers. dsh gates settings and
# credentials to loopback TWICE: server-side via the Host fence (handled by
# the entrypoint's Host/Origin rewrite) and client-side via this isLoopback
# check on the page origin, which switches the settings mirror to a
# process-local "memory" mode and leaves the Models/Plugins settings pages
# empty. Behind Caddy's basic auth the remote operator IS the local admin
# (anyone past auth can already run arbitrary shell commands via the agent),
# so patch the client bundle to treat every origin as loopback. The grep
# makes the build fail loudly if a future dsh version changes this code.
RUN CLIENT=/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/client.js \
 && grep -qF 'isLoopback: pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname)' "$CLIENT" \
 && sed -i 's#isLoopback: pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname)#isLoopback: true /* dsh-deploy: authenticated remote operator = local admin */#' "$CLIENT"

RUN useradd --create-home --shell /bin/bash dsh \
 && mkdir -p /data \
 && chown dsh:dsh /data

# DSH state (settings, profiles, sessions) lives here — mount a volume.
ENV DSH_HOME=/data

# Local setup seeded into $DSH_HOME on first boot (settings, skills, web
# profile with plugin manifest). No secrets here — credentials are
# materialized by the entrypoint from env vars.
COPY seed /opt/dsh-seed

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80 443
VOLUME ["/data"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
