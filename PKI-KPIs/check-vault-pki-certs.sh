#!/usr/bin/env bash

set -euo pipefail

# Configuration
EXPIRY_THRESHOLD_DAYS=14
EXPIRY_THRESHOLD_SECONDS=$((EXPIRY_THRESHOLD_DAYS * 24 * 60 * 60))
CURRENT_TIMESTAMP=$(date +%s)
CSV_OUTPUT_FILE="vault-certificates-$(date +%Y%m%d-%H%M%S).csv"

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Check prerequisites
if ! command -v curl &> /dev/null; then
    echo -e "${RED}Error: curl not found. Please install curl.${NC}"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq not found. Please install jq.${NC}"
    exit 1
fi

if ! command -v openssl &> /dev/null; then
    echo -e "${RED}Error: openssl not found. Please install openssl.${NC}"
    exit 1
fi

if [ -z "${VAULT_ADDR:-}" ]; then
    echo -e "${RED}Error: VAULT_ADDR environment variable is not set.${NC}"
    exit 1
fi

if [ -z "${VAULT_TOKEN:-}" ]; then
    echo -e "${RED}Error: VAULT_TOKEN environment variable is not set.${NC}"
    exit 1
fi

# Function to make Vault API calls
vault_api_call() {
    local method="$1"
    local path="$2"
    local namespace="${3:-}"

    local url="${VAULT_ADDR}/v1/${path}"
    local headers=(-H "X-Vault-Token: ${VAULT_TOKEN}")

    if [ -n "$namespace" ]; then
        headers+=(-H "X-Vault-Namespace: ${namespace}")
    fi

    # Add timeout and allow insecure for localhost testing
    curl -k -s --max-time 10 --connect-timeout 5 -X "$method" "${headers[@]}" "$url" 2>&1
}

# Test vault connectivity
echo "Testing Vault connectivity to ${VAULT_ADDR}..."
token_lookup=$(vault_api_call GET "auth/token/lookup-self")

# Check if we got any response
if [ -z "$token_lookup" ]; then
    echo -e "${RED}Error: No response from Vault. Please check:${NC}"
    echo "  1. Is Vault running at ${VAULT_ADDR}?"
    echo "  2. Is the address correct?"
    echo "  3. Can you reach the server (firewall/network)?"
    exit 1
fi

# Check for curl errors
if echo "$token_lookup" | grep -q "curl:"; then
    echo -e "${RED}Error: Connection failed${NC}"
    echo "$token_lookup"
    exit 1
fi

# Check for Vault errors
if echo "$token_lookup" | jq -e '.errors' &> /dev/null; then
    echo -e "${RED}Error: Cannot authenticate to Vault. Check your VAULT_TOKEN.${NC}"
    echo "$token_lookup" | jq -r '.errors[]' 2>/dev/null
    exit 1
fi

echo -e "${GREEN}Connected to Vault at: ${VAULT_ADDR}${NC}"
echo -e "${GREEN}Searching for certificates expiring within ${EXPIRY_THRESHOLD_DAYS} days...${NC}\n"

# Initialize CSV file with header
echo "Namespace,Mount Path,Serial Number,Subject,Expiration Date,Days Until Expiry,Status" > "$CSV_OUTPUT_FILE"

# Track found certificates
TOTAL_CERTS_FOUND=0
EXPIRING_CERTS_FOUND=0

# Function to convert date string to timestamp
date_to_timestamp() {
    local date_string="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        date -j -f "%Y-%m-%dT%H:%M:%SZ" "$date_string" +%s 2>/dev/null || \
        date -j -f "%Y-%m-%dT%H:%M:%S" "${date_string%Z}" +%s 2>/dev/null || \
        echo "0"
    else
        # Linux
        date -d "$date_string" +%s 2>/dev/null || echo "0"
    fi
}

# Function to check certificates in a PKI mount
check_pki_certs() {
    local namespace="$1"
    local mount_path="$2"

    echo -e "${YELLOW}Checking PKI mount: ${mount_path} in namespace: ${namespace}${NC}"

    # List all certificates using API
    local list_response
    list_response=$(vault_api_call LIST "${mount_path}/certs" "$namespace")

    # Check for errors
    if echo "$list_response" | jq -e '.errors' &> /dev/null; then
        echo "  No certificates found or unable to list certificates"
        return
    fi

    # Parse certificate serial numbers
    local serials
    serials=$(echo "$list_response" | jq -r '.data.keys[]?' 2>/dev/null || echo "")

    if [ -z "$serials" ]; then
        echo "  No certificates found"
        return
    fi

    # Check each certificate
    while IFS= read -r serial; do
        if [ -z "$serial" ]; then
            continue
        fi

        ((TOTAL_CERTS_FOUND++))

        # Read certificate details using API
        local cert_response
        cert_response=$(vault_api_call GET "${mount_path}/cert/${serial}" "$namespace")

        # Check for errors
        if echo "$cert_response" | jq -e '.errors' &> /dev/null; then
            echo -e "  ${RED}Failed to read certificate: ${serial}${NC}"
            continue
        fi

        # Extract certificate PEM
        local cert_pem
        cert_pem=$(echo "$cert_response" | jq -r '.data.certificate' 2>/dev/null || echo "")

        if [ -z "$cert_pem" ]; then
            continue
        fi

        # Get expiration date using openssl
        local expiry_date
        expiry_date=$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

        if [ -z "$expiry_date" ]; then
            continue
        fi

        # Convert to timestamp
        local expiry_timestamp
        if [[ "$OSTYPE" == "darwin"* ]]; then
            expiry_timestamp=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry_date" +%s 2>/dev/null || echo "0")
        else
            expiry_timestamp=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
        fi

        if [ "$expiry_timestamp" -eq 0 ]; then
            continue
        fi

        # Calculate days until expiry
        local seconds_until_expiry=$((expiry_timestamp - CURRENT_TIMESTAMP))
        local days_until_expiry=$((seconds_until_expiry / 86400))

        # Get subject/CN
        local subject
        subject=$(echo "$cert_pem" | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//' || echo "Unknown")

        # Escape commas and quotes in subject for CSV
        subject=$(echo "$subject" | sed 's/"/""/g')

        # Determine status
        local status
        if [ $seconds_until_expiry -le 0 ]; then
            status="EXPIRED"
        elif [ $seconds_until_expiry -le $EXPIRY_THRESHOLD_SECONDS ]; then
            status="EXPIRING SOON"
        else
            status="VALID"
        fi

        # Write all certificates to CSV
        echo "\"${namespace}\",\"${mount_path}\",\"${serial}\",\"${subject}\",\"${expiry_date}\",${days_until_expiry},\"${status}\"" >> "$CSV_OUTPUT_FILE"

        # Check if certificate is valid and expiring soon
        if [ $seconds_until_expiry -gt 0 ] && [ $seconds_until_expiry -le $EXPIRY_THRESHOLD_SECONDS ]; then
            ((EXPIRING_CERTS_FOUND++))

            echo -e "  ${RED}⚠ EXPIRING SOON:${NC}"
            echo "    Serial: $serial"
            echo "    Subject: $subject"
            echo "    Expires: $expiry_date"
            echo "    Days until expiry: $days_until_expiry"
            echo "    Namespace: $namespace"
            echo "    Mount: $mount_path"
            echo ""
        fi
    done <<< "$serials"
}

# Function to find PKI mounts in a namespace
find_pki_mounts() {
    local namespace="$1"

    # List all secret engines using API
    local mounts_response
    mounts_response=$(vault_api_call GET "sys/mounts" "$namespace")

    # Check for errors
    if echo "$mounts_response" | jq -e '.errors' &> /dev/null; then
        echo -e "${RED}Failed to list mounts in namespace: ${namespace}${NC}"
        return
    fi

    # Find PKI mounts
    local pki_paths
    pki_paths=$(echo "$mounts_response" | jq -r '.data | to_entries | .[] | select(.value.type == "pki") | .key' 2>/dev/null || echo "")

    if [ -n "$pki_paths" ]; then
        while IFS= read -r mount_path; do
            if [ -n "$mount_path" ]; then
                # Remove trailing slash
                mount_path="${mount_path%/}"
                check_pki_certs "$namespace" "$mount_path"
            fi
        done <<< "$pki_paths"
    fi
}

# Function to recursively traverse namespaces
traverse_namespaces() {
    local namespace="$1"

    # Check current namespace for PKI mounts
    find_pki_mounts "$namespace"

    # List child namespaces using API
    local ns_response
    ns_response=$(vault_api_call LIST "sys/namespaces" "$namespace")

    # Check if namespaces are supported and if there are any children
    if ! echo "$ns_response" | jq -e '.errors' &> /dev/null; then
        local children
        children=$(echo "$ns_response" | jq -r '.data.keys[]?' 2>/dev/null || echo "")

        if [ -n "$children" ]; then
            while IFS= read -r child; do
                if [ -n "$child" ]; then
                    # Remove trailing slash
                    child="${child%/}"

                    # Construct full namespace path
                    local full_namespace
                    if [ "$namespace" = "" ] || [ "$namespace" = "/" ]; then
                        full_namespace="$child"
                    else
                        full_namespace="${namespace}/${child}"
                    fi

                    # Recursively traverse child namespace
                    traverse_namespaces "$full_namespace"
                fi
            done <<< "$children"
        fi
    fi
}

# Start traversal from root namespace
echo "Starting namespace traversal..."
echo ""

traverse_namespaces ""

# Summary
echo ""
echo "========================================"
echo -e "${GREEN}Scan Complete${NC}"
echo "========================================"
echo "Total certificates checked: $TOTAL_CERTS_FOUND"
echo -e "Certificates expiring within ${EXPIRY_THRESHOLD_DAYS} days: ${RED}${EXPIRING_CERTS_FOUND}${NC}"
echo ""
echo -e "${GREEN}CSV report generated: ${CSV_OUTPUT_FILE}${NC}"
echo "  - Contains all $TOTAL_CERTS_FOUND certificates found during scan"
echo "  - Columns: Namespace, Mount Path, Serial Number, Subject, Expiration Date, Days Until Expiry, Status"
echo ""

if [ $EXPIRING_CERTS_FOUND -gt 0 ]; then
    exit 1
else
    exit 0
fi
