#!/usr/bin/env python3
"""Count certificates (PKI) and secrets (KV) across all Vault namespaces."""

import os
import requests
import urllib3

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
    """Recursively list all namespaces starting from parent."""
    namespaces = [parent] if parent else [""]
    resp = vault_request("LIST", "sys/namespaces", namespace=parent or None)
    if resp.status_code != 200:
        return namespaces
    keys = resp.json().get("data", {}).get("keys", [])
    for key in keys:
        child = f"{parent}{key}" if parent else key
        namespaces.extend(list_namespaces(child))
    return namespaces


def list_engines_by_type(namespace=None):
    """Return dict with 'pki' and 'kv' lists of mount paths."""
    resp = vault_request("GET", "sys/mounts", namespace=namespace or None)
    if resp.status_code != 200:
        return {"pki": [], "kv": []}
    mounts = resp.json().get("data", {})
    result = {"pki": [], "kv": []}
    for path, info in mounts.items():
        engine_type = info.get("type", "")
        if engine_type == "pki":
            result["pki"].append(path)
        elif engine_type in ("kv", "generic"):
            version = info.get("options", {}).get("version", "1") if info.get("options") else "1"
            result["kv"].append((path, version))
    return result


def count_certificates(pki_path, namespace=None):
    """Count certificates in a PKI engine."""
    resp = vault_request("LIST", f"{pki_path}certs", namespace=namespace or None)
    if resp.status_code not in (200,):
        return 0
    return len(resp.json().get("data", {}).get("keys", []))


def count_kv_secrets(kv_path, version, namespace=None, prefix=""):
    """Recursively count secrets in a KV engine."""
    if version == "2":
        list_path = f"{kv_path}metadata/{prefix}"
    else:
        list_path = f"{kv_path}{prefix}"

    resp = vault_request("LIST", list_path, namespace=namespace or None)
    if resp.status_code != 200:
        return 0

    keys = resp.json().get("data", {}).get("keys", [])
    count = 0
    for key in keys:
        if key.endswith("/"):
            count += count_kv_secrets(kv_path, version, namespace, prefix=f"{prefix}{key}")
        else:
            count += 1
    return count


def main():
    if not VAULT_TOKEN:
        print("Error: VAULT_TOKEN environment variable is not set.")
        raise SystemExit(1)

    print(f"Vault: {VAULT_ADDR}\n")

    namespaces = list_namespaces()

    grand_total_certs = 0
    grand_total_secrets = 0

    for ns in namespaces:
        ns_display = ns.rstrip("/") if ns else "(root)"
        engines = list_engines_by_type(namespace=ns or None)
        pki_engines = engines["pki"]
        kv_engines = engines["kv"]

        print(f"Namespace: {ns_display}")
        print(f"  PKI engines: {len(pki_engines)}  |  KV engines: {len(kv_engines)}")

        if pki_engines:
            ns_certs = 0
            for pki in pki_engines:
                cert_count = count_certificates(pki, namespace=ns or None)
                ns_certs += cert_count
                print(f"    [PKI] {pki:<35} {cert_count:>8} certificates")
            grand_total_certs += ns_certs

        if kv_engines:
            ns_secrets = 0
            for kv_path, version in kv_engines:
                secret_count = count_kv_secrets(kv_path, version, namespace=ns or None)
                ns_secrets += secret_count
                print(f"    [KV{version}] {kv_path:<34} {secret_count:>8} secrets")
            grand_total_secrets += ns_secrets

        print()

    print("=" * 60)
    print(f"Total certificates: {grand_total_certs}")
    print(f"Total KV secrets:   {grand_total_secrets}")


if __name__ == "__main__":
    main()
