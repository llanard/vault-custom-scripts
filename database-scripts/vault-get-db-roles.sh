#!/usr/bin/env bash
set -euo pipefail

# Requires: VAULT_ADDR and VAULT_TOKEN (or valid auth) to be set
# Usage: ./list-vault-db-roles.sh [--csv output.csv]

CSV_FILE=""
if [[ "${1:-}" == "--csv" ]]; then
  CSV_FILE="${2:?Usage: --csv <output_file>}"
fi

if ! command -v vault &>/dev/null; then
  echo "ERROR: vault CLI not found in PATH" >&2
  exit 1
fi

if [[ -z "${VAULT_ADDR:-}" ]]; then
  echo "ERROR: VAULT_ADDR is not set" >&2
  exit 1
fi

# List all namespaces (root level)
namespaces=$(vault namespace list -format=json 2>/dev/null | jq -r '.[]' | sed 's|/$||')

if [[ -z "$namespaces" ]]; then
  echo "No namespaces found (or no permission to list them)."
  exit 0
fi

ns_total=$(echo "$namespaces" | wc -l | tr -d ' ')
ns_current=0

# Initialize CSV file with header
if [[ -n "$CSV_FILE" ]]; then
  echo "namespace,secret_engine,role,default_ttl,max_ttl" > "$CSV_FILE"
  echo "Output: $CSV_FILE"
  echo ""
fi

for ns in $namespaces; do
  ((ns_current++))
  echo -ne "\r\033[K[${ns_current}/${ns_total}] Processing namespace: ${ns}..."

  # List all secret engines in this namespace, filter for type "database"
  db_engines=$(VAULT_NAMESPACE="$ns" vault secrets list -format=json 2>/dev/null \
    | jq -r 'to_entries[] | select(.value.type == "database") | .key' | sed 's|/$||')

  if [[ -z "$db_engines" ]]; then
    continue
  fi

  for engine in $db_engines; do
    # List roles for this database engine
    roles=$(VAULT_NAMESPACE="$ns" vault list -format=json "${engine}/roles" 2>/dev/null \
      | jq -r '.[]' 2>/dev/null || true)

    if [[ -z "$roles" ]]; then
      continue
    fi

    for role in $roles; do
      # Read role config to get TTL values
      role_info=$(VAULT_NAMESPACE="$ns" vault read -format=json "${engine}/roles/${role}" 2>/dev/null)

      default_ttl=$(echo "$role_info" | jq -r '.data.default_ttl // "N/A"' | awk '{if($1+0==$1){printf "%.1fh\n",$1/3600}else{print}}')
      max_ttl=$(echo "$role_info" | jq -r '.data.max_ttl // "N/A"' | awk '{if($1+0==$1){printf "%.1fh\n",$1/3600}else{print}}')

      if [[ -n "$CSV_FILE" ]]; then
        echo "${ns},${engine},${role},${default_ttl},${max_ttl}" >> "$CSV_FILE"
      else
        # Text mode: print inline
        echo ""
        echo "  [$ns] $engine / $role — default_ttl: $default_ttl, max_ttl: $max_ttl"
      fi
    done
  done
done

echo -ne "\r\033[K"
echo "[${ns_total}/${ns_total}] Done."

if [[ -n "$CSV_FILE" && "$CSV_FILE" != "/dev/"* ]]; then
  echo ""
  cat "$CSV_FILE"
fi
