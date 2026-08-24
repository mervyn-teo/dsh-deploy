#!/usr/bin/env bash
#
# Container entrypoint: renders the Caddyfile from env, starts Caddy (root,
# binds 80/443) and dsh web (unprivileged `dsh` user, 127.0.0.1:3080),
# then exits when either process dies so the container restarts cleanly.
#
# Env:
#   DSH_DOMAIN          public hostname, e.g. "dsh.example.com"
#                       (enables auto-HTTPS via Let's Encrypt + trusted-host).
#                       Default ":80" = plain HTTP, for local testing only.
#   DSH_AUTH_USER       basic-auth username (default "admin")
#   DSH_AUTH_PASSWORD   basic-auth password (plaintext env; hashed at boot).
#                       If unset, NO auth — never do this on a public host.
#   DSH_TRUSTED_HOST    optional extra Host authority for dsh's browser-trust
#                       fence, e.g. a bare public IP for plain-HTTP access.
set -euo pipefail

DOMAIN="${DSH_DOMAIN:-:80}"
AUTH_USER="${DSH_AUTH_USER:-admin}"

AUTH_BLOCK=""
TRUSTED_ARGS=()

if [[ -n "${DSH_AUTH_PASSWORD:-}" ]]; then
  HASH="$(caddy hash-password --plaintext "${DSH_AUTH_PASSWORD}")"
  AUTH_BLOCK=$'\tbasicauth {\n\t\t'"${AUTH_USER} ${HASH}"$'\n\t}'
else
  echo "WARNING: DSH_AUTH_PASSWORD is unset — the GUI has NO authentication." >&2
  echo "         dsh can execute arbitrary shell commands. Local testing only." >&2
fi

# dsh's /api browser-trust fence rejects unknown Host headers; allowlist the
# public domain (loopback binds are trusted automatically). DSH_TRUSTED_HOST
# declares an authority the domain logic can't cover — e.g. a bare Elastic IP
# when running plain HTTP without a domain.
if [[ -n "${DSH_TRUSTED_HOST:-}" ]]; then
  TRUSTED_ARGS=(--trusted-host "${DSH_TRUSTED_HOST}")
elif [[ "${DOMAIN}" != ":80" && "${DOMAIN}" != "localhost" ]]; then
  TRUSTED_ARGS=(--trusted-host "${DOMAIN}")
fi

cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
${AUTH_BLOCK}
	# dsh pins privileged API methods (settings/credentials RPCs) and some
	# plugin routes (e.g. /modlens/config) to LOOPBACK Host headers by design;
	# no --trusted-host value unlocks them. In this deployment Caddy + basic
	# auth is the trust boundary instead, so present every request as loopback.
	# Sec-Fetch-Site is deliberately left untouched: cross-site (CSRF/DNS-
	# rebinding) requests from a browser are still rejected by dsh's fence.
	reverse_proxy 127.0.0.1:3080 {
		header_up Host 127.0.0.1:3080
		header_up Origin http://127.0.0.1:3080
	}
}
EOF

# --- First-boot seeding -----------------------------------------------------
# Copy the local setup (settings, skills, web profile) from the image into
# the $DSH_HOME volume, materialize .credentials.yaml from env vars, and
# install the web profile's plugins. Runs once; /data/.seeded is the
# marker. If the plugin install fails the marker is skipped so the next
# container start retries.
SEED_DIR=/opt/dsh-seed
if [[ -d "${SEED_DIR}" && ! -f /data/.seeded ]]; then
  echo "First boot: seeding DSH home from ${SEED_DIR}"
  cp -r "${SEED_DIR}/." /data/

  if [[ ! -f /data/.credentials.yaml ]]; then
    : > /data/.credentials.yaml
    for VAR in DEEPSEEK_API_KEY KIMI_CODING_API_KEY; do
      if [[ -n "${!VAR:-}" ]]; then
        echo "${VAR}: ${!VAR}" >> /data/.credentials.yaml
      fi
    done
    chmod 600 /data/.credentials.yaml
  fi

  chown -R dsh:dsh /data

  if [[ -f /data/profiles/web/package.json ]]; then
    # pnpm, not npm: it is what `dsh plugin install` shells out to, and its
    # peer handling tolerates the plugins' ^0.1.0-rc.6 peer ranges against
    # newer rc harness builds where npm hard-fails with ERESOLVE.
    echo "Installing web-profile plugins (pnpm install in /data/profiles/web)"
    if gosu dsh pnpm --dir /data/profiles/web install; then
      gosu dsh touch /data/.seeded
    else
      echo "WARNING: plugin install failed — will retry on next container start." >&2
    fi
  else
    gosu dsh touch /data/.seeded
  fi
fi

echo "Starting Caddy (proxy :80/:443 -> 127.0.0.1:3080) for domain '${DOMAIN}'"
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &

echo "Starting dsh web on 127.0.0.1:3080 as user 'dsh'"
gosu dsh dsh web --no-open --port 3080 "${TRUSTED_ARGS[@]}" &

# Exit when the first process dies; stop the other so the container ends.
# (|| STATUS=$? guards against `set -e` exiting before the cleanup runs.)
STATUS=0
wait -n || STATUS=$?
kill $(jobs -p) 2>/dev/null || true
wait || true
exit "${STATUS}"
