# Production Frappe image

The production image extends `frappe/bench` and installs Nginx and runtime
service scripts. At first backend startup, `bench-init.sh` runs `bench init`
with the defaults provided by the Bench image. An already
initialized bench is left unchanged. A non-empty uninitialized bench volume is
left untouched and causes startup to fail with an error instead of deleting
its data. The `frappe` and `queue-long` containers share the persistent bench
volume, which also holds installed apps and sites.
In production, Supervisor runs the backend, Socket.IO, short/default worker,
scheduler, and Nginx frontend in one container; the long-queue worker runs in
its own container. The `frappe` container starts system cron from its entrypoint
as root; the scheduled backup job runs as `frappe`.
At startup, its entrypoint recursively sets the shared bench owner to
`frappe:0` and mirrors owner permissions to the group; the `queue-long`
container skips this repair because it runs as `frappe` and shares the bench.

When Supervisor starts the backend, `/scripts/service/01_backend.sh` runs
`bench-init.sh`, which initializes the bench if needed and then executes the
optional commands in `conf/frappe/benchinit_commands.conf` before starting Gunicorn. Keep one shell
command per line; an absent or empty file skips additional configuration; a
failing command stops backend startup.
The separate `queue-long` container does not run bench initialization.

Before bench initialization, the backend checks that MariaDB responds with a
protocol greeting and both Redis services answer `PING`.
Supervisor starts backend first. The other service wrappers wait for the
backend ping endpoint on port 8000 before starting their process; the frontend
also waits for a successful Socket.IO handshake on port 9000. Numeric prefixes
and Supervisor priorities document and enforce the startup order. Each
service's stdout and stderr lines are prefixed with its Supervisor program
name in the container logs.

The backup runs in system cron, independently of Frappe's scheduler. Set
`BACKUP_CRON_SCHEDULE` using the standard five-field syntax
`minute hour day month weekday` (default `0 2 * * *`, daily at 02:00 using the
container timezone configured by `TZ`, which defaults to `Africa/Nairobi`). It
creates database and site-file backups under
`/backup/<SITE_NAME>/<DD-MM-YYYY>` and retains the latest two date folders.
Scheduled backup output is written to `/logs/bench-backup-cron.log`.

To remove a site, run `/scripts/site_drop.sh`. It creates and verifies a
database and public/private files backup under
`/archive/site-dropped-backup-<SITE_NAME>-<date>` before running `bench drop-site`. The
`/archive` directory is persisted at `./frappe-data/archive` by Compose.
Interactive runs require typing the site name; use `--force` only when
confirming the drop non-interactively. If the backup fails or is incomplete,
the site is left intact. If `/scripts/site_init.sh` is used to reinstall or
recreate a site that already has a site config, it similarly saves and verifies
a backup under `/archive/site-init-backup-<SITE_NAME>-<date>` before replacing
the old site.

Build the production image locally from the repository root:

```bash
docker compose build frappe
```

Frappe itself is fetched at runtime, so no SSH build forwarding or Frappe
build arguments are needed. Set `FRAPPE_VERSION` in the deployment environment.
To build the image directly:

```bash
docker build --file docker/frappe/Dockerfile --tag uoe-helpdesk:latest docker/frappe
```

For deployment to another host, push the image to a registry and set
`FRAPPE_IMAGE` to that registry reference:

```bash
docker tag uoe-helpdesk:latest ghcr.io/your-org/uoe-helpdesk:latest
docker push ghcr.io/your-org/uoe-helpdesk:latest
```

Set the deployment's `FRAPPE_IMAGE` to the pushed image reference, for example:

```env
FRAPPE_IMAGE=ghcr.io/your-org/uoe-helpdesk:latest
```

Supervisor-managed workers use `HOME=/home/frappe`. The image makes that home
directory owned by `frappe:0` with mode `2770`; processes can create their
application-specific runtime directories there on demand without the entrypoint
having to pre-create each one.

App installation is intentionally not automated by this image. Use explicit
Bench commands to fetch and install apps on the intended site, then build
assets and migrate as required by the app. Set `REFRESH_CODEBASE_APPS` to the
comma-separated list of installed app names to update, for example
`kustomize,tiksupport`. `/scripts/refresh-codebase.sh` updates only those
already-installed apps and processes them in the listed order. Each checkout
must be clean and have its upstream branch configured; the script does not
install missing apps or switch branches.
The `frappe` service mounts the host's SSH config and key read-only for Git
operations; `queue-long` does not receive SSH credentials. At startup,
`/scripts/configure_ssh.sh` configures SSH to accept and record new host keys
without prompting, while still rejecting changed host keys. Image builds
still require an active SSH agent and the host's `~/.ssh/known_hosts` file as
shown above. SSH credentials are never baked into the image.

To uninstall an app interactively, run `/scripts/uninstall_app.sh`. Choose a
site and one of its installed apps, then choose whether to remove the app from
the shared bench as well. Bench app files are retained if another site still
uses the app or if that site's app list cannot be checked.

For later app updates, push the changes to each checkout's upstream branch and
run the refresh script:

```bash
docker compose exec frappe /scripts/refresh-codebase.sh
docker compose restart frappe queue-long
```

The refresh script fast-forwards clean app checkouts in the configured order.
It skips package installation, migrations, and service reload when every app
is already up to date; Python packages are refreshed only when package
metadata changes. It does not discard local changes, switch branches, or rebuild
assets.
