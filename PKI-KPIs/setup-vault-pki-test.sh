#!/usr/bin/env bash

set -euo pipefail

# Configuration
VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"
NUM_TEAMS=5
NUM_APPS_PER_TEAM=5

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
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

if [ -z "${VAULT_TOKEN:-}" ]; then
    echo -e "${RED}Error: VAULT_TOKEN environment variable is not set.${NC}"
    exit 1
fi

echo -e "${GREEN}Starting Vault PKI test setup...${NC}"
echo -e "${BLUE}Vault Address: ${VAULT_ADDR}${NC}"
echo -e "${BLUE}Teams: ${NUM_TEAMS}, Apps per team: ${NUM_APPS_PER_TEAM}${NC}\n"

# Function to make Vault API calls
vault_api_call() {
    local method="$1"
    local path="$2"
    local namespace="${3:-}"
    local data="${4:-}"

    local url="${VAULT_ADDR}/v1/${path}"
    local headers=(-H "X-Vault-Token: ${VAULT_TOKEN}" -H "Content-Type: application/json")

    if [ -n "$namespace" ]; then
        headers+=(-H "X-Vault-Namespace: ${namespace}")
    fi

    # Add timeout and show errors
    if [ -n "$data" ]; then
        curl -k -s --max-time 10 --connect-timeout 5 -X "$method" "${headers[@]}" -d "$data" "$url" 2>&1
    else
        curl -k -s --max-time 10 --connect-timeout 5 -X "$method" "${headers[@]}" "$url" 2>&1
    fi
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

# Verify we got valid data
if ! echo "$token_lookup" | jq -e '.data' &> /dev/null; then
    echo -e "${RED}Error: Unexpected response from Vault${NC}"
    echo "Response: $token_lookup"
    exit 1
fi

echo -e "${GREEN}✓ Connected to Vault${NC}\n"

# Function to create a namespace
create_namespace() {
    local namespace_path="$1"
    local parent_namespace="${2:-}"

    echo -e "${YELLOW}Creating namespace: ${namespace_path}${NC}"

    local response
    response=$(vault_api_call POST "sys/namespaces/${namespace_path}" "$parent_namespace" '{}')

    if echo "$response" | jq -e '.errors' &> /dev/null; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0]' 2>/dev/null || echo "Unknown error")

        # Check if namespace already exists
        if [[ "$error_msg" == *"already in use"* ]] || [[ "$error_msg" == *"existing key"* ]]; then
            echo -e "${YELLOW}  ⚠ Namespace already exists, skipping${NC}"
        else
            echo -e "${RED}  ✗ Failed to create namespace: ${error_msg}${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}  ✓ Namespace created${NC}"
    fi
}

# Function to enable PKI secret engine
enable_pki_engine() {
    local namespace="$1"
    local mount_path="pki"

    echo -e "${YELLOW}  Enabling PKI engine at ${mount_path} in namespace ${namespace}${NC}"

    local data='{
        "type": "pki",
        "description": "PKI engine for certificates",
        "config": {
            "max_lease_ttl": "87600h"
        }
    }'

    local response
    response=$(vault_api_call POST "sys/mounts/${mount_path}" "$namespace" "$data")

    if echo "$response" | jq -e '.errors' &> /dev/null; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0]' 2>/dev/null || echo "Unknown error")

        if [[ "$error_msg" == *"existing mount"* ]] || [[ "$error_msg" == *"path is already in use"* ]]; then
            echo -e "${YELLOW}    ⚠ PKI engine already exists, skipping${NC}"
        else
            echo -e "${RED}    ✗ Failed to enable PKI engine: ${error_msg}${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}    ✓ PKI engine enabled${NC}"
    fi
}

# Function to configure PKI root CA
configure_pki_root() {
    local namespace="$1"
    local mount_path="pki"
    local common_name="$2"

    echo -e "${YELLOW}    Configuring PKI root CA${NC}"

    local data
    data=$(jq -n \
        --arg cn "$common_name" \
        '{
            "common_name": $cn,
            "ttl": "87600h",
            "key_type": "rsa",
            "key_bits": 2048
        }')

    local response
    response=$(vault_api_call POST "${mount_path}/root/generate/internal" "$namespace" "$data")

    if echo "$response" | jq -e '.errors' &> /dev/null; then
        echo -e "${RED}    ✗ Failed to generate root CA${NC}"
        return 1
    else
        echo -e "${GREEN}    ✓ Root CA configured${NC}"
    fi
}

# Function to configure PKI URLs
configure_pki_urls() {
    local namespace="$1"
    local mount_path="pki"

    local data='{
        "issuing_certificates": ["'${VAULT_ADDR}'/v1/pki/ca"],
        "crl_distribution_points": ["'${VAULT_ADDR}'/v1/pki/crl"]
    }'

    vault_api_call POST "${mount_path}/config/urls" "$namespace" "$data" > /dev/null
}

# Function to create a PKI role
create_pki_role() {
    local namespace="$1"
    local mount_path="pki"
    local role_name="$2"
    local max_ttl="$3"

    local data
    data=$(jq -n \
        --arg ttl "$max_ttl" \
        '{
            "allowed_domains": ["example.com", "localhost"],
            "allow_subdomains": true,
            "allow_bare_domains": true,
            "allow_localhost": true,
            "allow_ip_sans": true,
            "max_ttl": $ttl,
            "key_type": "rsa",
            "key_bits": 2048
        }')

    vault_api_call POST "${mount_path}/roles/${role_name}" "$namespace" "$data" > /dev/null
}

# Function to issue a certificate
issue_certificate() {
    local namespace="$1"
    local mount_path="pki"
    local role_name="$2"
    local common_name="$3"
    local ttl="$4"

    echo -e "${YELLOW}    Issuing certificate: ${common_name} (TTL: ${ttl})${NC}"

    local data
    data=$(jq -n \
        --arg cn "$common_name" \
        --arg ttl "$ttl" \
        '{
            "common_name": $cn,
            "ttl": $ttl
        }')

    local response
    response=$(vault_api_call POST "${mount_path}/issue/${role_name}" "$namespace" "$data")

    if echo "$response" | jq -e '.errors' &> /dev/null; then
        echo -e "${RED}    ✗ Failed to issue certificate${NC}"
        return 1
    else
        local serial
        serial=$(echo "$response" | jq -r '.data.serial_number' 2>/dev/null || echo "unknown")
        echo -e "${GREEN}    ✓ Certificate issued (serial: ${serial})${NC}"
    fi
}

# Main setup process
echo -e "${BLUE}=== Starting Setup ===${NC}\n"

# Create teams and apps
for team_num in $(seq 1 $NUM_TEAMS); do
    team_name="team${team_num}"

    echo -e "${BLUE}━━━ Setting up ${team_name} ━━━${NC}"

    # Create team namespace
    create_namespace "$team_name" ""

    # Create app namespaces under team
    for app_num in $(seq 1 $NUM_APPS_PER_TEAM); do
        app_name="app${app_num}"
        full_namespace="${team_name}/${app_name}"

        echo -e "${BLUE}  ── Setting up ${app_name} ──${NC}"

        # Create app namespace
        create_namespace "$app_name" "$team_name"

        # Enable PKI engine in app namespace
        enable_pki_engine "$full_namespace"

        # Configure PKI root CA
        configure_pki_root "$full_namespace" "${team_name}-${app_name} Root CA"

        # Configure PKI URLs
        configure_pki_urls "$full_namespace"

        # Create roles for different TTLs
        create_pki_role "$full_namespace" "short-lived" "168h"  # 1 week
        create_pki_role "$full_namespace" "medium-lived" "720h" # 1 month

        # Issue certificate expiring in 1 week
        issue_certificate "$full_namespace" "short-lived" "${app_name}.${team_name}.example.com" "168h"

        # Issue certificate expiring in 1 month
        issue_certificate "$full_namespace" "medium-lived" "${app_name}-longterm.${team_name}.example.com" "720h"

        echo ""
    done

    echo ""
done

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Setup Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Summary:"
echo "  - Teams created: $NUM_TEAMS"
echo "  - Apps per team: $NUM_APPS_PER_TEAM"
echo "  - Total namespaces: $((NUM_TEAMS + NUM_TEAMS * NUM_APPS_PER_TEAM))"
echo "  - PKI engines created: $((NUM_TEAMS * NUM_APPS_PER_TEAM))"
echo "  - Certificates issued: $((NUM_TEAMS * NUM_APPS_PER_TEAM * 2))"
echo ""
echo -e "${BLUE}You can now run ./check-vault-pki-certs.sh to verify the certificates!${NC}"
