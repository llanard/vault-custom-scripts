#!/usr/bin/env bash
# Configure automatic tidy on all PKI secret engines across all Vault namespaces.

set -uo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
DEBUG=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)   DEBUG=true ;;
        --dry-run) DRY_RUN=true ;;
        *)         echo "Usage: $0 [--debug] [--dry-run]"; exit 1 ;;
    esac
    shift
done

debug() {
    if $DEBUG; then
        echo "  [DEBUG] $*" >&2
    fi
}

vault_request() {
    local method="$1" path="$2" namespace="${3:-}" data="${4:-}"
    local -a headers=(-H "X-Vault-Token: ${VAULT_TOKEN}")
    [[ -n "$namespace" ]] && headers+=(-H "X-Vault-Namespace: ${namespace}")
    local url="${VAULT_ADDR}/v1/${path}"
    local original_method="$method"
    if [[ "$method" == "LIST" ]]; then
        method="GET"
        url="${url}?list=true"
    fi
    debug "$original_method $url (namespace: '${namespace:-<none>}')"
    local -a curl_args=(-sk --connect-timeout 5 --max-time 30 -w '\n%{http_code}' -X "$method" "${headers[@]}")
    if [[ -n "$data" ]]; then
        curl_args+=(-H "Content-Type: application/json" -d "$data")
    fi
    local resp http_code
    resp=$(curl "${curl_args[@]}" "$url")
    http_code=$(echo "$resp" | tail -n1)
    resp=$(echo "$resp" | sed '$d')
    debug "HTTP $http_code"
    if [[ "$http_code" -ge 400 ]] 2>/dev/null; then
        local errors
        errors=$(echo "$resp" | jq -r '.errors[]? // empty' 2>/dev/null)
        if [[ -n "$errors" ]]; then
            debug "Vault error: $errors"
        fi
        return 1
    fi
    echo "$resp"
}

list_namespaces() {
    local parent="${1:-}"
    if [[ -n "$parent" ]]; then
        echo "$parent"
    else
        echo ""
    fi

    local resp keys
    resp=$(vault_request "LIST" "sys/namespaces" "$parent") || return 0
    keys=$(echo "$resp" | jq -r '.data.keys[]? // empty' 2>/dev/null) || return 0

    local key child
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        if [[ -n "$parent" ]]; then
            child="${parent}${key}"
        else
            child="$key"
        fi
        list_namespaces "$child"
    done <<< "$keys"
}

# List PKI engine mount paths in a given namespace.
list_pki_engines() {
    local namespace="${1:-}"
    local resp
    resp=$(vault_request "GET" "sys/mounts" "$namespace") || return 0

    echo "$resp" | jq -r '
        .data // {} | to_entries[] |
        select(.value.type == "pki") |
        .key
    ' 2>/dev/null || true
}

# Count certificates in a PKI engine.
count_certificates() {
    local pki_path="$1" namespace="${2:-}"
    local resp
    resp=$(vault_request "LIST" "${pki_path}certs" "$namespace") || { echo 0; return; }
    echo "$resp" | jq -r '[.data.keys[]? // empty] | length' 2>/dev/null || echo 0
}

# Configure auto-tidy on a PKI engine.
configure_auto_tidy() {
    local pki_path="$1" namespace="${2:-}"
    local tidy_config
    tidy_config=$(cat <<'TIDYJSON'
{
    "enabled": true,
    "interval_duration": "336h",
    "tidy_cert_store": true,
    "tidy_revoked_certs": true,
    "tidy_revoked_cert_issuer_associations": true,
    "tidy_expired_issuers": true,
    "tidy_move_legacy_ca_bundle": true,
    "tidy_acme": true,
    "safety_buffer": "72h",
    "pause_duration": "0s"
}
TIDYJSON
)

    vault_request "POST" "${pki_path}config/auto-tidy" "$namespace" "$tidy_config" > /dev/null
}

main() {
    if [[ -z "$VAULT_TOKEN" ]]; then
        echo "Error: VAULT_TOKEN environment variable is not set."
        exit 1
    fi

    printf "Vault: %s\n" "$VAULT_ADDR"
    $DEBUG && printf "Debug mode enabled\n"
    $DRY_RUN && printf "Dry-run mode: no changes will be made\n"
    printf "\n"

    local -a namespaces=()
    while IFS= read -r _ns_line; do
        namespaces+=("$_ns_line")
    done < <(list_namespaces)

    local total_ns=${#namespaces[@]}
    local total_configured=0
    local total_failed=0
    local i=0

    if [[ $total_ns -eq 0 ]]; then
        echo "Warning: no namespaces found. Check Vault connectivity and token."
        exit 1
    fi

    for ns in "${namespaces[@]+${namespaces[@]}}"; do
        i=$((i + 1))
        local ns_display
        if [[ -n "$ns" ]]; then
            ns_display="${ns%/}"
        else
            ns_display="(root)"
        fi

        local -a pki_engines=()
        local line
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            pki_engines+=("$line")
        done < <(list_pki_engines "$ns")

        if [[ ${#pki_engines[@]} -eq 0 ]]; then
            debug "[${i}/${total_ns}] ${ns_display}: no PKI engines"
            continue
        fi

        printf "[%d/%d] Namespace: %s (%d PKI engines)\n" "$i" "$total_ns" "$ns_display" "${#pki_engines[@]}"

        for pki in "${pki_engines[@]}"; do
            local cert_count wait_seconds
            cert_count=$(count_certificates "$pki" "$ns")
            cert_count=${cert_count:-0}
            # 100 certs/sec tidy rate + 60s safety margin
            wait_seconds=$(( (cert_count / 100) + 60 ))

            if $DRY_RUN; then
                printf "  [DRY-RUN] Would configure auto-tidy on %s (%d certs, would sleep %ds)\n" "$pki" "$cert_count" "$wait_seconds"
                total_configured=$((total_configured + 1))
            elif configure_auto_tidy "$pki" "$ns"; then
                printf "  [OK]      Auto-tidy configured on %s (%d certs)\n" "$pki" "$cert_count"
                total_configured=$((total_configured + 1))
                if [[ $cert_count -gt 0 ]]; then
                    printf "            Waiting %ds for tidy to complete (%d certs @ 100 certs/s + 60s buffer)...\n" "$wait_seconds" "$cert_count"
                    sleep "$wait_seconds"
                    printf "            Done waiting.\n"
                fi
            else
                printf "  [FAIL]    Could not configure auto-tidy on %s\n" "$pki"
                total_failed=$((total_failed + 1))
            fi
        done
    done

    printf "\n%s\n" "$(printf '=%.0s' {1..52})"
    printf "PKI engines configured: %d\n" "$total_configured"
    if [[ $total_failed -gt 0 ]]; then
        printf "PKI engines failed:     %d\n" "$total_failed"
    fi
}

main
