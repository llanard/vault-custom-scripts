#!/bin/bash

# add raw_storage_endpoint = "true" in all your vault config files and reload/restart vault service

# Set Vault token and address
VAULT_ADDR="http://127.0.0.1:8200"
VAULT_TOKEN="<token>"

# Base path
BASE_PATH="sys/raw/logical"

OUTFILE="raw-secrets.csv"

# Start fresh CSV with header
printf 'secret_path,value\n' > "$OUTFILE"

# Recursive function
fetch_secrets_recursively() {
    local path="$1"

    # List the path contents
    local keys
    keys=$(curl -s \
        --header "X-Vault-Token: $VAULT_TOKEN" \
        --request LIST \
        "${VAULT_ADDR}/v1/${path}" | jq -r '.data.keys[]?' 2>/dev/null)

    # If this folder contains "oidc_tokens/", cancel search in this folder
    if [[ -n "$keys" ]] && grep -qx 'oidc_tokens/' <<< "$keys"; then
        echo "Skipping subtree (contains oidc_tokens/): /${path}"
        return 0
    fi

    # If the listing fails or there are no keys, it's likely a leaf (GET)
    if [ -z "$keys" ]; then
        # Read raw bytes-as-text from sys/raw (may contain newlines/control chars)
        local raw
        raw=$(curl -s \
            --header "X-Vault-Token: $VAULT_TOKEN" \
            --request GET \
            "${VAULT_ADDR}/v1/${path}" | jq -r '.data.value? // empty')

        if [[ -n "$raw" ]]; then
            # CSV-safe plaintext:
            # - escape double quotes
            # - strip CR
            # - convert newlines to "\n" (two characters) so CSV is one line per row
            local esc="$raw"
            esc=${esc//\"/\"\"}             # escape quotes
            esc=${esc//$'\r'/}              # drop carriage returns
            esc=${esc//$'\n'/\\n}           # newline -> \n

            printf '"%s","%s"\n' "/${path}" "$esc" >> "$OUTFILE"
            echo "SECRET: /${path}"
        fi
    else
        # Iterate through listed keys
        while IFS= read -r key; do
            if [[ "$key" == */ ]]; then
                # It's a folder – recurse
                fetch_secrets_recursively "${path}/${key%/}"
            else
                # It's a leaf – recurse to read value
                fetch_secrets_recursively "${path}/${key}"
            fi
        done <<< "$keys"
    fi
}

# Start recursive fetching
fetch_secrets_recursively "$BASE_PATH"

echo "CSV written to: $OUTFILE"
