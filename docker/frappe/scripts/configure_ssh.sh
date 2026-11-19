#!/usr/bin/env bash
set -euo pipefail

if ((EUID != 0)); then
  echo "configure_ssh.sh must run as root" >&2
  exit 1
fi

echo "Configuring SSH to accept new host keys without prompting..."
ssh_config_dir="/etc/ssh/ssh_config.d"
ssh_config_file="${ssh_config_dir}/99-hostkey-accept-new.conf"

install -d -o root -g root -m 0755 "${ssh_config_dir}"
temporary_file="$(mktemp "${ssh_config_file}.XXXXXX")"
trap 'rm -f -- "${temporary_file}"' EXIT

cat > "${temporary_file}" <<'EOF'
Host *
  StrictHostKeyChecking accept-new
EOF

chown root:root "${temporary_file}"
chmod 0644 "${temporary_file}"
mv -f -- "${temporary_file}" "${ssh_config_file}"
trap - EXIT

echo "Configured SSH to accept new host keys without prompting"
