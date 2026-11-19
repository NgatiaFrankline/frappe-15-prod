ARG BENCH_VERSION=v5.31.0
ARG FRAPPE_VERSION=v15.122.0

# Upstream Frappe runtime files (Nginx template, security headers, entrypoint).
FROM frappe/base:${FRAPPE_VERSION} AS frappe-runtime-files


FROM frappe/bench:${BENCH_VERSION} AS bench-builder
ARG BENCH_VERSION
LABEL org.opencontainers.image.title="Bench Image"
LABEL org.opencontainers.image.description="Bench image for Frappe apps from frappe/bench"
LABEL org.opencontainers.image.version="${BENCH_VERSION}"
ENV TZ=Africa/Nairobi

USER root

# Install packages
RUN set -ex \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      cron \
      gettext-base \
      nginx \
      openssh-client \
      supervisor \
    && sed -i '/user www-data/d' /etc/nginx/nginx.conf \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log \
    && mkdir -p /run/nginx \
    && touch /run/nginx.pid \
    && chgrp -R 0 /etc/nginx /var/log/nginx /var/lib/nginx /run \
    && chmod -R g=u /etc/nginx /var/log/nginx /var/lib/nginx /run \
    && rm -rf /var/lib/apt/lists/*

# Nginx template, security headers and entrypoint used by 05_frontend.sh.
COPY --from=frappe-runtime-files /templates/nginx/frappe.conf.template /templates/nginx/frappe.conf.template
COPY --from=frappe-runtime-files /etc/nginx/snippets/security_headers.conf /etc/nginx/snippets/security_headers.conf
COPY --from=frappe-runtime-files /usr/local/bin/nginx-entrypoint.sh /usr/local/bin/nginx-entrypoint.sh
RUN set -ex \
    && chmod 755 /usr/local/bin/nginx-entrypoint.sh \
    && chmod 644 /templates/nginx/frappe.conf.template

RUN set -ex \
    && ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo "${TZ}" > /etc/timezone

FROM bench-builder AS bench-prod
USER root

# Install startup/service scripts and set ownership and permissions for runtime paths.
COPY scripts /scripts
COPY config /config
RUN set -eux \
    && DIRS="/scripts /config" \
    && chown -R root:root ${DIRS} \
    && chmod -R 755 ${DIRS} \
    && chmod +x /scripts/*.sh \
    && install -o root -g root -m 0644 /config/supervisor.conf /etc/supervisor/supervisord.conf \
    \
    && FRAPPE_WRITE_DIRS="/backup /logs /archive" \
    && mkdir -p ${FRAPPE_WRITE_DIRS} \
    && chown -R frappe:frappe ${FRAPPE_WRITE_DIRS} \
    && chmod -R 755 ${FRAPPE_WRITE_DIRS}

# PASSWORDLESS SUDO
#RUN set -ex \
#    && echo "frappe ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/frappe \
#    && chmod 0440 /etc/sudoers.d/frappe

WORKDIR /home/frappe/frappe-bench
# The entrypoint prepares runtime paths before launching the default Supervisor program.
ENTRYPOINT ["/scripts/entrypoint.sh"]
EXPOSE 8080
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
