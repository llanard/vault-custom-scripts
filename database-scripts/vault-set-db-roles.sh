#!/usr/bin/env bash
set -euo pipefail

# Requires: VAULT_ADDR and VAULT_TOKEN (or valid auth) to be set
# Usage: ./vault-set-db-roles.sh <csv_file> <default_ttl> <max_ttl>
# Example: ./vault-set-db-roles.sh vault-db-roles.csv 1h 24h

CSV_FILE="${1:?Usage: $0 <csv_file> <default_ttl> <max_ttl>}"
DEFAULT_TTL="${2:?Usage: $0 <csv_file> <default_ttl> <max_ttl>}"
MAX_TTL="${3:?Usage: $0 <csv_file> <default_ttl> <max_ttl>}"

if [[ ! -f "$CSV_FILE" ]]; then
  echo "ERROR: file not found: $CSV_FILE" >&2
  exit 1
fi

if ! command -v vault &>/dev/null; then
  echo "ERROR: vault CLI not found in PATH" >&2
  exit 1
fi

if [[ -z "${VAULT_ADDR:-}" ]]; then
  echo "ERROR: VAULT_ADDR is not set" >&2
  exit 1
fi

# Count data lines (skip header)
total=$(tail -n +2 "$CSV_FILE" | wc -l | tr -d ' ')
current=0

echo "Applying default_ttl=$DEFAULT_TTL max_ttl=$MAX_TTL to $total roles..."
echo ""

while IFS=',' read -r namespace engine role _default_ttl _max_ttl; do
  ((current++))
  echo -ne "\r\033[K[${current}/${total}] ${namespace} / ${engine} / ${role}..."

  VAULT_NAMESPACE="$namespace" vault write "${engine}/roles/${role}" \
    default_ttl="$DEFAULT_TTL" \
    max_ttl="$MAX_TTL" \
    > /dev/null 2>&1

  if [[ $? -ne 0 ]]; then
    echo ""
    echo "  ERROR: failed to update ${namespace}/${engine}/${role}" >&2
  fi
done < <(tail -n +2 "$CSV_FILE")

echo -ne "\r\033[K"
echo "[${total}/${total}] Done."
