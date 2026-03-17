#!/usr/bin/env bash
# Count certificates (PKI) and secrets (KV) across all Vault namespaces.

set -uo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
DEBUG=false

if [[ "${1:-}" == "--debug" ]]; then
    DEBUG=true
fi

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

# Print lines of "type|path|version" for PKI and KV engines.
list_engines_by_type() {
    local namespace="${1:-}"
    local resp
    resp=$(vault_request "GET" "sys/mounts" "$namespace") || return 0

    echo "$resp" | jq -r '
        .data // {} | to_entries[] |
        if .value.type == "pki" then
            "pki|\(.key)|"
        elif (.value.type == "kv" or .value.type == "generic") then
            "kv|\(.key)|\(.value.options.version // "1")"
        else
            empty
        end
    ' 2>/dev/null || true
}

count_certificates() {
    local pki_path="$1" namespace="${2:-}"
    local resp
    resp=$(vault_request "LIST" "${pki_path}certs" "$namespace") || { echo 0; return; }
    echo "$resp" | jq -r '[.data.keys[]? // empty] | length' 2>/dev/null || echo 0
}

# Recursively count secrets in a KV engine.
count_kv_secrets() {
    local kv_path="$1" version="$2" namespace="${3:-}" prefix="${4:-}"
    local list_path
    if [[ "$version" == "2" ]]; then
        list_path="${kv_path}metadata/${prefix}"
    else
        list_path="${kv_path}${prefix}"
    fi

    local resp keys
    resp=$(vault_request "LIST" "$list_path" "$namespace") || { echo 0; return; }
    keys=$(echo "$resp" | jq -r '.data.keys[]? // empty' 2>/dev/null) || { echo 0; return; }

    local count=0 key sub
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        if [[ "$key" == */ ]]; then
            sub=$(count_kv_secrets "$kv_path" "$version" "$namespace" "${prefix}${key}")
            count=$((count + sub))
        else
            count=$((count + 1))
        fi
    done <<< "$keys"
    echo "$count"
}

main() {
    if [[ -z "$VAULT_TOKEN" ]]; then
        echo "Error: VAULT_TOKEN environment variable is not set."
        exit 1
    fi

    printf "Vault: %s\n" "$VAULT_ADDR"
    $DEBUG && printf "Debug mode enabled\n"
    printf "\n"

    local -a namespaces=()
    while IFS= read -r _ns_line; do
        namespaces+=("$_ns_line")
    done < <(list_namespaces)

    local grand_total_certs=0
    local grand_total_secrets=0
    local total_ns=${#namespaces[@]}
    local i=0

    if [[ $total_ns -eq 0 ]]; then
        echo "Warning: no namespaces found. Check Vault connectivity and token."
    fi

    for ns in "${namespaces[@]+${namespaces[@]}}"; do
        i=$((i + 1))
        local ns_display
        if [[ -n "$ns" ]]; then
            ns_display="${ns%/}"
        else
            ns_display="(root)"
        fi
        printf "[%d/%d] Namespace: %s\n" "$i" "$total_ns" "$ns_display"

        local -a pki_engines=() kv_engines=()
        local line
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local etype epath eversion
            IFS='|' read -r etype epath eversion <<< "$line"
            if [[ "$etype" == "pki" ]]; then
                pki_engines+=("$epath")
            elif [[ "$etype" == "kv" ]]; then
                kv_engines+=("${epath}|${eversion}")
            fi
        done < <(list_engines_by_type "$ns")

        printf "  PKI engines: %d  |  KV engines: %d\n" "${#pki_engines[@]}" "${#kv_engines[@]}"

        if [[ ${#pki_engines[@]} -gt 0 ]]; then
            local ns_certs=0
            for pki in "${pki_engines[@]}"; do
                local cert_count
                cert_count=$(count_certificates "$pki" "$ns")
                cert_count=${cert_count:-0}
                ns_certs=$((ns_certs + cert_count))
                printf "    [PKI] %-35s %8d certificates\n" "$pki" "$cert_count"
            done
            grand_total_certs=$((grand_total_certs + ns_certs))
        fi

        if [[ ${#kv_engines[@]} -gt 0 ]]; then
            local ns_secrets=0
            for kv_entry in "${kv_engines[@]}"; do
                local kv_path version secret_count
                IFS='|' read -r kv_path version <<< "$kv_entry"
                secret_count=$(count_kv_secrets "$kv_path" "$version" "$ns")
                secret_count=${secret_count:-0}
                ns_secrets=$((ns_secrets + secret_count))
                printf "    [KV%s] %-34s %8d secrets\n" "$version" "$kv_path" "$secret_count"
            done
            grand_total_secrets=$((grand_total_secrets + ns_secrets))
        fi

        echo
    done

    printf "%s\n" "$(printf '=%.0s' {1..60})"
    printf "Total certificates: %d\n" "$grand_total_certs"
    printf "Total KV secrets:   %d\n" "$grand_total_secrets"
}

main
