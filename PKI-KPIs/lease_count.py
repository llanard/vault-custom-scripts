#!/usr/bin/env python3
"""Count active leases across all Vault namespaces."""

import os
import sys
import requests
import urllib3

sys.setrecursionlimit(10000)

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

VAULT_ADDR = os.environ.get("VAULT_ADDR", "https://127.0.0.1:8200")
VAULT_TOKEN = os.environ.get("VAULT_TOKEN", "")


def vault_request(method, path, namespace=None, **kwargs):
    headers = {"X-Vault-Token": VAULT_TOKEN}
    if namespace:
        headers["X-Vault-Namespace"] = namespace
    url = f"{VAULT_ADDR}/v1/{path}"
    return requests.request(method, url, headers=headers, verify=False, **kwargs)


def list_namespaces(parent=""):
    """Iteratively list all namespaces starting from parent."""
    namespaces = []
    stack = [parent]
    while stack:
        current = stack.pop()
        namespaces.append(current)
        resp = vault_request("LIST", "sys/namespaces", namespace=current or None)
        if resp.status_code != 200:
            continue
        keys = resp.json().get("data", {}).get("keys", [])
        for key in keys:
            child = f"{current}{key}" if current else key
            stack.append(child)
    return namespaces


def count_leases(prefix="", namespace=None):
    """Iteratively count leases under a given prefix."""
    count = 0
    stack = [prefix]
    while stack:
        current = stack.pop()
        resp = vault_request("LIST", f"sys/leases/lookup/{current}", namespace=namespace or None)
        if resp.status_code != 200:
            continue
        keys = resp.json().get("data", {}).get("keys", [])
        for key in keys:
            if key.endswith("/"):
                stack.append(f"{current}{key}")
            else:
                count += 1
    return count


def main():
    if not VAULT_TOKEN:
        print("Error: VAULT_TOKEN environment variable is not set.")
        raise SystemExit(1)

    print(f"Vault: {VAULT_ADDR}\n")

    namespaces = list_namespaces()
    grand_total = 0

    for ns in namespaces:
        ns_display = ns.rstrip("/") if ns else "(root)"
        ns_leases = count_leases(namespace=ns or None)
        grand_total += ns_leases
        print(f"  {ns_display:<40} {ns_leases:>8} leases")

    print()
    print("=" * 52)
    print(f"Total active leases: {grand_total}")


if __name__ == "__main__":
    main()
