#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root (use sudo)." >&2
  exit 1
fi

for cmd in aws sed grep cp; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${cmd}" >&2
    exit 1
  fi
done

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-north-1}}"
TURN_USERNAME_PARAM="${TURN_USERNAME_PARAM:-/pixelstreaming/turn/username}"
TURN_CREDENTIAL_PARAM="${TURN_CREDENTIAL_PARAM:-/pixelstreaming/turn/credential}"
TURN_REALM="${TURN_REALM:-scaleworld-dev}"
TURN_CONFIG_PATH="${TURN_CONFIG_PATH:-/etc/turnserver.conf}"

if [[ ! -f "${TURN_CONFIG_PATH}" ]]; then
  echo "ERROR: TURN config file not found: ${TURN_CONFIG_PATH}" >&2
  exit 1
fi

echo "INFO: Loading TURN credentials from SSM (region: ${REGION})..."
TURN_USERNAME="$(aws ssm get-parameter --region "${REGION}" --name "${TURN_USERNAME_PARAM}" --with-decryption --query 'Parameter.Value' --output text)"
TURN_CREDENTIAL="$(aws ssm get-parameter --region "${REGION}" --name "${TURN_CREDENTIAL_PARAM}" --with-decryption --query 'Parameter.Value' --output text)"

if [[ -z "${TURN_USERNAME}" || -z "${TURN_CREDENTIAL}" ]]; then
  echo "ERROR: one or both TURN credential values were empty." >&2
  exit 1
fi

BACKUP_PATH="${TURN_CONFIG_PATH}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp "${TURN_CONFIG_PATH}" "${BACKUP_PATH}"

# Ensure long-term credential mode for static username/password usage.
sed -i -E 's/^(use-auth-secret|static-auth-secret)/#\0/' "${TURN_CONFIG_PATH}"
grep -q '^lt-cred-mech' "${TURN_CONFIG_PATH}" || printf '\nlt-cred-mech\n' >> "${TURN_CONFIG_PATH}"

if grep -q '^realm=' "${TURN_CONFIG_PATH}"; then
  sed -i -E "s/^realm=.*/realm=${TURN_REALM}/" "${TURN_CONFIG_PATH}"
else
  printf 'realm=%s\n' "${TURN_REALM}" >> "${TURN_CONFIG_PATH}"
fi

sed -i -E '/^user=/d' "${TURN_CONFIG_PATH}"
printf 'user=%s:%s\n' "${TURN_USERNAME}" "${TURN_CREDENTIAL}" >> "${TURN_CONFIG_PATH}"

echo "INFO: Updated ${TURN_CONFIG_PATH} (backup: ${BACKUP_PATH})."

if [[ "${1:-}" == "--restart" ]]; then
  echo "INFO: Restarting coturn..."
  systemctl restart coturn
  systemctl is-active --quiet coturn && echo "INFO: coturn is active."
fi

echo "INFO: Sync completed for TURN user '${TURN_USERNAME}'."
