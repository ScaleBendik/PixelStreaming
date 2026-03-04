#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root (use sudo)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SYNC_SCRIPT="${SCRIPT_DIR}/sync-coturn-creds-from-ssm.sh"
TARGET_SYNC_SCRIPT="/usr/local/sbin/sync-coturn-creds-from-ssm.sh"
DROPIN_DIR="/etc/systemd/system/coturn.service.d"
DROPIN_FILE="${DROPIN_DIR}/10-ssm-turn-sync.conf"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-north-1}}"

if [[ ! -f "${SOURCE_SYNC_SCRIPT}" ]]; then
  echo "ERROR: source sync script not found: ${SOURCE_SYNC_SCRIPT}" >&2
  exit 1
fi

install -m 0755 "${SOURCE_SYNC_SCRIPT}" "${TARGET_SYNC_SCRIPT}"
mkdir -p "${DROPIN_DIR}"

cat > "${DROPIN_FILE}" <<EOF
[Service]
Environment=AWS_DEFAULT_REGION=${REGION}
ExecStartPre=${TARGET_SYNC_SCRIPT}
EOF

systemctl daemon-reload
systemctl restart coturn

echo "INFO: Installed coturn SSM sync hook."
echo "INFO: Drop-in file: ${DROPIN_FILE}"
systemctl status coturn --no-pager | sed -n '1,12p'
