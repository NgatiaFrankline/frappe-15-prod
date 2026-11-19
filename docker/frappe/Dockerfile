# syntax=docker/dockerfile:1

ARG FRAPPE_VERSION=v15.122.0

# Build a Frappe-only bench and its static assets; extra apps are added separately.
FROM frappe/build:${FRAPPE_VERSION} AS builder
ARG FRAPPE_BRANCH=version-15
ARG FRAPPE_PATH=git@github.com:frappe/frappe.git

USER root
RUN apt-get update \
    && apt-get install --no-install-recommends -y openssh-client \
    && rm -rf /var/lib/apt/lists/*

USER frappe

# Initialize Frappe only; Compose/Supervisor provide process configuration and extra apps are not baked in.
# Forward the build host's SSH agent and known_hosts only while fetching Frappe.
RUN --mount=type=ssh,uid=1000,gid=0,mode=0600,required=true \
    --mount=type=secret,id=known_hosts,target=/tmp/known_hosts,uid=1000,gid=0,mode=0644,required=true \
    export GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=/tmp/known_hosts" \
    && bench init \
      --frappe-branch="${FRAPPE_BRANCH}" \
      --frappe-path="${FRAPPE_PATH}" \
      --no-procfile \
      --no-backups \
      --skip-redis-config-generation \
      --verbose \
      /home/frappe/frappe-bench \
    && cd /home/frappe/frappe-bench \
    && printf '{}\n' > sites/common_site_config.json \
    && find apps -mindepth 1 -type d -name .git -prune -exec rm -rf {} + \
    && chmod -R g=u /home/frappe/frappe-bench

# Install only the Node runtime dependencies needed by Frappe Socket.IO.
COPY --chown=frappe:0 config/node-runtime-package.json /home/frappe/frappe-node-runtime/package.json

RUN npm install \
      --prefix /home/frappe/frappe-node-runtime \
      --omit=dev \
      --ignore-scripts \
      --no-audit \
      --no-fund \
    && cd /home/frappe/frappe-bench \
    && rm -rf \
      apps/frappe/node_modules \
    && mv /home/frappe/frappe-node-runtime/node_modules apps/frappe/node_modules \
    && rm -rf /home/frappe/frappe-node-runtime \
    && chmod -R g=u /home/frappe/frappe-bench


# Reuse upstream Frappe runtime templates without carrying its full build image forward.
FROM frappe/base:${FRAPPE_VERSION} AS frappe-runtime-files

# Runtime-installed apps may require a newer Node.js than Debian Bookworm's
# default. Keep the Frappe 15 build stage unchanged and provide Node 22 at runtime.
FROM node:22-bookworm-slim AS node-runtime
RUN rm -f /usr/local/bin/yarn /usr/local/bin/yarnpkg \
    && npm install --global yarn@1.22.22 \
    && yarn --version


# Assemble a smaller production image with only runtime dependencies.
FROM python:3.11-slim-bookworm AS production

ARG BENCH_VERSION=5.31.0
ARG WKHTMLTOPDF_VERSION=0.12.6.1-3
ARG WKHTMLTOPDF_DISTRO=bookworm
# Default the image and cron to East Africa Time; Compose can override TZ.
ENV TZ=Africa/Nairobi
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
COPY --from=node-runtime /usr/local/ /usr/local/

# Install runtime libraries and Frappe Bench, plus architecture-specific wkhtmltopdf.
RUN useradd --uid 1000 --gid 0 --home-dir /home/frappe --create-home --shell /bin/bash frappe \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
      ca-certificates \
      cron \
      curl \
      file \
      fontconfig \
      gettext-base \
      git \
      libffi8 \
      libfontconfig1 \
      libfreetype6 \
      libgif7 \
      libharfbuzz0b \
      libjpeg62-turbo \
      liblcms2-2 \
      libldap-2.5-0 \
      libmariadb3 \
      mariadb-client \
      libopenjp2-7 \
      libpango-1.0-0 \
      libpangocairo-1.0-0 \
      libpangoft2-1.0-0 \
      libpq5 \
      libsasl2-2 \
      libtiff6 \
      libwebp7 \
      libxml2 \
      libxslt1.1 \
      nginx \
      openssh-client \
      procps \
      supervisor \
      tzdata \
      util-linux \
    && if [ "$(dpkg --print-architecture)" = "arm64" ]; then ARCH=arm64; else ARCH=amd64; fi \
    && wkhtmltopdf_package="wkhtmltox_${WKHTMLTOPDF_VERSION}.${WKHTMLTOPDF_DISTRO}_${ARCH}.deb" \
    && curl -fsSLO "https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/${wkhtmltopdf_package}" \
    && apt-get install --no-install-recommends -y "./${wkhtmltopdf_package}" \
    && rm -f "${wkhtmltopdf_package}" \
    && pip install --no-cache-dir "frappe-bench==${BENCH_VERSION}" \
    && sed -i '/user www-data/d' /etc/nginx/nginx.conf \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log \
    && mkdir -p /run/nginx \
    && touch /run/nginx.pid \
    && chgrp -R 0 /home/frappe /etc/nginx /var/log/nginx /var/lib/nginx /run \
    && chmod -R g=u /home/frappe /etc/nginx /var/log/nginx /var/lib/nginx /run \
    && chown frappe:0 /home/frappe \
    && chmod 2770 /home/frappe \
    && ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime \
    && printf '%s\n' "${TZ}" > /etc/timezone \
    && rm -rf /var/lib/apt/lists/*

# Use the upstream Nginx template and security headers with this image's Supervisor config.
COPY --from=frappe-runtime-files /templates/nginx/frappe.conf.template /templates/nginx/frappe.conf.template
COPY --from=frappe-runtime-files /etc/nginx/snippets/security_headers.conf /etc/nginx/snippets/security_headers.conf
COPY --from=frappe-runtime-files /usr/local/bin/nginx-entrypoint.sh /usr/local/bin/nginx-entrypoint.sh
COPY config/supervisor.conf /config/supervisor.conf

USER frappe

# Keep a pristine bench seed in the image. Entrypoint copies it into the shared
# bench volume only when that volume does not already contain a usable Frappe install.
COPY --from=builder --chown=frappe:0 /home/frappe/frappe-bench /copied-frappe-bench


FROM production AS frappe
USER root

# Install startup/service scripts and set ownership and permissions for runtime paths.
COPY scripts /scripts
RUN set -ex \
    && mkdir -p /backup /logs /archive \
    && chown -R root:0 /scripts /config \
    && find /scripts -type d -exec chmod 755 {} + \
    && find /scripts -type f -name '*.sh' -exec chmod 755 {} + \
    && chmod +x /scripts/*.sh \
    && chmod 644 /config/supervisor.conf \
    && install -o root -g root -m 0644 /config/supervisor.conf /etc/supervisor/supervisord.conf \
    && chown -R frappe:0 /backup /logs /archive \
    && chmod -R g=u /backup /logs /archive \
    && chmod 755 /usr/local/bin/nginx-entrypoint.sh \
    && chmod 644 /templates/nginx/frappe.conf.template

WORKDIR /home/frappe/frappe-bench
# The entrypoint prepares runtime paths before launching the default Supervisor program.
ENTRYPOINT ["/scripts/entrypoint.sh"]
EXPOSE 8080
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
