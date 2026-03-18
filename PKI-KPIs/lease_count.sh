#!/usr/bin/env bash
# Count active leases across all Vault namespaces.

set -uo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
DEBUG=false
CSV_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) DEBUG=true ;;
        --csv)   CSV_FILE="${2:-lease_report.csv}"; shift ;;
        *)       echo "Usage: $0 [--debug] [--csv <file>]"; exit 1 ;;
    esac
    shift
done

debug() {
    if $DEBUG; then
        echo "  [DEBUG] $*" >&2
    fi
}

vault_request() {
    local method="$1" path="$2" namespace="${3:-}"
    local -a headers=(-H "X-Vault-Token: ${VAULT_TOKEN}")
    [[ -n "$namespace" ]] && headers+=(-H "X-Vault-Namespace: ${namespace}")
    local url="${VAULT_ADDR}/v1/${path}"
    local original_method="$method"
    if [[ "$method" == "LIST" ]]; then
        method="GET"
        url="${url}?list=true"
    fi
    debug "$original_method $url (namespace: '${namespace:-<none>}')"
    local resp http_code
    resp=$(curl -sk --connect-timeout 5 --max-time 30 -w '\n%{http_code}' -X "$method" "${headers[@]}" "$url")
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

# Recursively list all namespaces starting from parent.
# Results are printed one per line and captured by the caller.
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

# Iteratively count leases under a given prefix.
count_leases() {
    local namespace="${1:-}"
    local count=0
    local -a stack=("")

    while [[ ${#stack[@]} -gt 0 ]]; do
        local current="${stack[0]}"
        if [[ ${#stack[@]} -gt 1 ]]; then stack=("${stack[@]:1}"); else stack=(); fi

        local resp keys
        resp=$(vault_request "LIST" "sys/leases/lookup/${current}" "$namespace") || continue
        keys=$(echo "$resp" | jq -r '.data.keys[]? // empty' 2>/dev/null) || continue

        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            if [[ "$key" == */ ]]; then
                stack+=("${current}${key}")
            else
                count=$((count + 1))
            fi
        done <<< "$keys"
    done

    echo "$count"
}

main() {
    if [[ -z "$VAULT_TOKEN" ]]; then
        echo "Error: VAULT_TOKEN environment variable is not set."
        exit 1
    fi

    printf "Vault: %s\n" "$VAULT_ADDR"
    $DEBUG && printf "Debug mode enabled\n"
    if [[ -n "$CSV_FILE" ]]; then
        echo "namespace,leases" > "$CSV_FILE"
        printf "CSV output: %s\n" "$CSV_FILE"
    fi
    printf "\n"

    local -a namespaces=()
    while IFS= read -r _ns_line; do
        namespaces+=("$_ns_line")
    done < <(list_namespaces)

    local grand_total=0

    for ns in "${namespaces[@]+${namespaces[@]}}"; do
        local ns_display
        if [[ -n "$ns" ]]; then
            ns_display="${ns%/}"
        else
            ns_display="(root)"
        fi

        local ns_leases
        ns_leases=$(count_leases "$ns")
        ns_leases=${ns_leases:-0}
        grand_total=$((grand_total + ns_leases))
        printf "  %-40s %8d leases\n" "$ns_display" "$ns_leases"
        [[ -n "$CSV_FILE" ]] && echo "${ns_display},${ns_leases}" >> "$CSV_FILE"
    done

    printf "\n%s\n" "$(printf '=%.0s' {1..52})"
    printf "Total active leases: %d\n" "$grand_total"
}

main
