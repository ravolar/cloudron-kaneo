# Kaneo for Cloudron.
#
# Thin packaging layer: the API and the built web app are copied unmodified from Kaneo's official
# bundled image (ghcr.io/usekaneo/kaneo), pinned by version and digest, and run under supervisor on
# the Cloudron base image: the API on 127.0.0.1:1337 and nginx on port 8000 (single origin, /api
# proxied to the API, like upstream's own image).

FROM ghcr.io/usekaneo/kaneo:2.36.0@sha256:3c1eaf6235569103c56b898b5aa2c8ea30cff6641add3d05d7d14b49bae8fd1d AS kaneo

FROM cloudron/node-base:24-20260920@sha256:d984683ec59bf2379130bf41cf3c2b6bc0453f327297d7183525cb05424e7b34

COPY --from=kaneo /app /app/code/kaneo
COPY --from=kaneo /usr/share/nginx/html /app/code/web
COPY --from=kaneo /docker-entrypoint.d/env.awk /app/code/env.awk
# Kept only to detect upstream changes (see upstream.sha256); this package does not run them.
COPY --from=kaneo /etc/nginx/conf.d/default.conf /app/code/upstream/nginx.kaneo.conf
COPY --from=kaneo /docker-entrypoint.d/env.sh /app/code/upstream/env.sh
COPY --from=kaneo /usr/local/bin/kaneo-entrypoint.sh /app/code/upstream/kaneo-entrypoint.sh

# Upstream's startup logic is re-implemented in start.sh and nginx.conf. If upstream changes it, stop
# here so the package is reviewed against the new version instead of silently drifting.
COPY upstream.sha256 /app/code/upstream/upstream.sha256
RUN set -eux; \
    cd /app/code; \
    if ! sha256sum -c upstream/upstream.sha256; then \
        echo "Upstream startup files changed: review them against start.sh/nginx.conf, then update upstream.sha256"; \
        exit 1; \
    fi

# Build-time gates: fail here, not on a user's server. Upstream builds on Alpine; all API runtime
# dependencies are pure JavaScript, so they must load on this glibc Node as well.
RUN set -eux; \
    cd /app/code/kaneo/apps/api; \
    node -e "const fs=require('fs');for(const m of ['bcryptjs','hono','pg','drizzle-orm','better-auth','ioredis','valibot','octokit','@modelcontextprotocol/sdk']){fs.accessSync('node_modules/'+m+'/package.json')}for(const m of ['email','permissions']){fs.accessSync('node_modules/@kaneo/'+m+'/dist/index.js')}"; \
    node --input-type=module -e "import { registerTools } from '@kaneo/mcp/tools'; if (typeof registerTools !== 'function') process.exit(1)"; \
    if find node_modules/ -name '*.node' | grep -q .; then echo "unexpected native modules"; find node_modules/ -name '*.node'; exit 1; fi; \
    test -f dist/index.js; \
    ls drizzle/*.sql >/dev/null; \
    test -f /app/code/web/index.html; \
    grep -rlq '`KANEO_API_URL`' /app/code/web/assets; \
    node -v

# Supervisor's own log and child logs default to /var/log, which is read-only on Cloudron.
RUN sed -e 's,^logfile=.*$,logfile=/run/supervisord.log,' \
        -e 's,^childlogdir=.*$,childlogdir=/run,' \
        -e 's,^\[supervisord\]$,[supervisord]\nuser=root,' \
        -i /etc/supervisor/supervisord.conf

COPY start.sh app-env.sh loopback.mjs nginx.conf /app/pkg/
COPY supervisor/ /etc/supervisor/conf.d/
# Set modes explicitly: the build context can arrive with 0600 files (seen with Cloudron's
# on-server build), and the processes run as `cloudron`.
RUN chmod 0755 /app/pkg /app/pkg/start.sh /app/pkg/app-env.sh \
    && chmod 0644 /app/pkg/loopback.mjs /app/pkg/nginx.conf /etc/supervisor/conf.d/*.conf

RUN mkdir -p /run/kaneo/nginx /run/kaneo/html && nginx -e stderr -t -c /app/pkg/nginx.conf && rm -rf /run/kaneo

CMD [ "/app/pkg/start.sh" ]
