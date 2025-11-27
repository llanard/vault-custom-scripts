#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import Lock
from typing import Tuple

# Lock for thread-safe printing
print_lock = Lock()

def run_curl(args: list, insecure: bool = False) -> Tuple[int, str, str]:
    """
    Exécute curl et renvoie (status_code, stdout_sans_code, stderr).
    On appose le code HTTP à la fin via -w '%{http_code}' pour pouvoir le lire.
    """
    base = ["curl", "-sS", "-X"]
    if insecure:
        base.insert(1, "-k")  # ignorer TLS (optionnel)
    # On force l'impression du code HTTP à la fin de la sortie
    cmd = base + args + ["-w", "%{http_code}"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError:
        print("Erreur: 'curl' introuvable dans le PATH.", file=sys.stderr)
        sys.exit(1)

    out = proc.stdout or ""
    err = proc.stderr or ""
    # Le code HTTP sont les 3 derniers chiffres (ou 5 avec 3xx/4xx/5xx)
    code_str = out[-3:]
    try:
        code = int(code_str)
        body = out[:-3]
    except ValueError:
        # Si jamais introuvable, on considère tout comme body et code -1
        code = -1
        body = out
    return code, body, err

def create_namespace(vault_addr: str, token: str, ns_name: str, parent_ns: str, insecure: bool) -> int:
    url = f"{vault_addr.rstrip('/')}/v1/sys/namespaces/{ns_name}"
    cmd = [
        "POST",
        "-H", f"X-Vault-Token: {token}",
        "-H", f"X-Vault-Namespace: {parent_ns}",
        url
    ]
    code, body, err = run_curl(cmd, insecure=insecure)
    return code

def enable_kv2(vault_addr: str, token: str, ns_name: str, mount_path: str, insecure: bool) -> int:
    url = f"{vault_addr.rstrip('/')}/v1/sys/mounts/{mount_path}"
    payload = '{"type":"kv","options":{"version":"2"}}'
    cmd = [
        "POST",
        "-H", f"X-Vault-Token: {token}",
        "-H", f"X-Vault-Namespace: {ns_name}",
        "-H", "Content-Type: application/json",
        "--data", payload,
        url
    ]
    code, body, err = run_curl(cmd, insecure=insecure)
    return code

def safe_print(msg: str):
    """Thread-safe printing"""
    with print_lock:
        print(msg)

def create_namespace_with_kvs(vault_addr: str, token: str, ns_name: str,
                              parent_ns: str, full_ns_path: str,
                              mount_prefix: str, start_index: int, num_kvs: int,
                              width_kv: int, insecure: bool) -> dict:
    """
    Worker function to create a namespace and its KV engines.
    Returns a dict with status information.
    """
    results = {
        'ns_name': full_ns_path,
        'ns_created': False,
        'ns_code': 0,
        'kv_results': []
    }

    # Create namespace
    code_ns = create_namespace(vault_addr, token, ns_name, parent_ns, insecure)
    results['ns_code'] = code_ns

    if code_ns in (200, 201, 204):
        safe_print(f"[OK] Namespace créé: {full_ns_path} (HTTP {code_ns})")
        results['ns_created'] = True
    elif code_ns == 409:
        safe_print(f"[EXISTE] Namespace déjà présent: {full_ns_path} (HTTP 409)")
        results['ns_created'] = True
    elif code_ns == 400:
        safe_print(f"[WARN] Tentative de créer '{full_ns_path}' a renvoyé 400 (peut-être déjà présent ou nom invalide).")
        results['ns_created'] = True
    else:
        safe_print(f"[ERREUR] Création namespace '{full_ns_path}' a échoué (HTTP {code_ns}). On continue quand même.")
        results['ns_created'] = True

    # Create KV engines
    # For namespace header, remove 'root/' prefix from full path
    ns_for_kv = full_ns_path.replace("root/", "", 1) if full_ns_path.startswith("root/") else full_ns_path
    for k in range(start_index, start_index + num_kvs):
        mount = f"{mount_prefix}-{k:0{width_kv}d}"
        code_kv = enable_kv2(vault_addr, token, ns_for_kv, mount, insecure)
        results['kv_results'].append({'mount': mount, 'code': code_kv})

        if code_kv in (200, 201, 204):
            safe_print(f"  [OK] KV v2 monté: {full_ns_path}/{mount} (HTTP {code_kv})")
        elif code_kv == 400:
            safe_print(f"  [WARN] Montage '{mount}' a renvoyé 400 pour {full_ns_path} (peut-être déjà monté).")
        elif code_kv == 409:
            safe_print(f"  [EXISTE] Montage déjà présent: {full_ns_path}/{mount} (HTTP 409)")
        else:
            safe_print(f"  [ERREUR] Montage KV v2 '{mount}' dans {full_ns_path} a échoué (HTTP {code_kv}).")

    return results

def create_parent_namespace_tree(vault_addr: str, token: str, parent_name: str,
                                 ns_prefix: str, mount_prefix: str,
                                 start_index: int, num_kvs: int, ns_level2: int,
                                 width_parent: int, width_child: int, width_kv: int,
                                 insecure: bool) -> dict:
    """
    Creates a complete parent namespace tree depth-first:
    1. Create parent namespace
    2. Create KV engines in parent
    3. For each child namespace:
       a. Create child namespace
       b. Create KV engines in child
    Returns a dict with status information for the entire tree.
    """
    results = {
        'parent': parent_name,
        'parent_created': False,
        'children': []
    }

    # Step 1: Create parent namespace
    parent_full_path = f"root/{parent_name}"
    safe_print(f"[PARENT] Création du parent namespace: {parent_full_path}")

    parent_result = create_namespace_with_kvs(
        vault_addr, token, parent_name, "root", parent_full_path,
        mount_prefix, start_index, num_kvs, width_kv, insecure
    )
    results['parent_created'] = parent_result['ns_created']

    # Step 2: Create child namespaces depth-first
    if ns_level2 > 0:
        for j in range(start_index, start_index + ns_level2):
            child_name = f"{parent_name}-{j:0{width_child}d}"
            child_full_path = f"{parent_full_path}/{child_name}"

            safe_print(f"  [CHILD] Création du child namespace: {child_full_path}")

            child_result = create_namespace_with_kvs(
                vault_addr, token, child_name, parent_name, child_full_path,
                mount_prefix, start_index, num_kvs, width_kv, insecure
            )
            results['children'].append(child_result)

    return results

def main():
    parser = argparse.ArgumentParser(
        description="Créer n namespaces sous root et x moteurs KV v2 par namespace dans HashiCorp Vault (via curl)."
    )
    parser.add_argument("-n", "--namespaces", type=int, required=True,
                        help="Nombre de namespaces à créer (for depth=2) or number of parent namespaces (for depth=3).")
    parser.add_argument("-x", "--kvs", type=int, required=True,
                        help="Nombre de secret engines KV v2 à créer dans chaque namespace.")
    parser.add_argument("--depth", type=int, choices=[2, 3], default=2,
                        help="Depth of namespace architecture: 2 (root/ns) or 3 (root/parent/child). Default: 2.")
    parser.add_argument("--ns-level2", type=int, default=1,
                        help="For depth=3: number of child namespaces to create under each parent. Default: 1.")
    parser.add_argument("--ns-prefix", default="ns",
                        help="Préfixe pour nommer les namespaces (défaut: ns). Résultat: ns-001, ns-002, ...")
    parser.add_argument("--mount-prefix", default="kv",
                        help="Préfixe pour les chemins KV (défaut: kv). Résultat: kv-001, kv-002, ...")
    parser.add_argument("--start-index", type=int, default=1,
                        help="Index de départ pour la numérotation (défaut: 1).")
    parser.add_argument("--addr", default=os.environ.get("VAULT_ADDR"),
                        help="Adresse de Vault (ex: https://vault.example.com:8200). Par défaut: env VAULT_ADDR.")
    parser.add_argument("--token", default=os.environ.get("VAULT_TOKEN"),
                        help="Token Vault. Par défaut: env VAULT_TOKEN.")
    parser.add_argument("--insecure", action="store_true",
                        help="Ignorer la validation TLS (équivaut à curl -k).")
    parser.add_argument("--workers", type=int, default=20,
                        help="Nombre de workers parallèles pour créer les namespaces (défaut: 20).")
    args = parser.parse_args()

    if not args.addr or not args.token:
        print("Erreur: --addr/VAULT_ADDR et --token/VAULT_TOKEN sont requis.", file=sys.stderr)
        sys.exit(2)

    n = args.namespaces
    x = args.kvs
    depth = args.depth
    ns_level2 = args.ns_level2

    if n <= 0 or x < 0:
        print("Erreur: n doit être > 0 et x doit être >= 0.", file=sys.stderr)
        sys.exit(2)

    print(f"Target Vault: {args.addr}")

    if depth == 2:
        print(f"Création de {n} namespaces sous 'root' (depth=2) avec {x} KV v2 chacun.")
        total_ns = n
    else:  # depth == 3
        print(f"Création de {n} parent namespaces sous 'root', chacun avec {ns_level2} child namespaces (depth=3).")
        print(f"Chaque child namespace aura {x} KV v2.")
        total_ns = n * ns_level2

    print(f"Utilisation de {args.workers} workers parallèles.")
    print(f"Total de {total_ns} namespaces finaux à créer.\n")

    # Calcul des largeurs pour le formatage
    if depth == 2:
        width_ns = max(3, len(str(args.start_index + n - 1)))
    else:  # depth == 3
        width_parent = max(3, len(str(args.start_index + n - 1)))
        width_child = max(3, len(str(args.start_index + ns_level2 - 1)))

    width_kv = max(3, len(str(args.start_index + x - 1))) if x > 0 else 3

    # Préparation et exécution des tâches
    if depth == 2:
        # Depth 2: create namespaces directly under root (all in parallel)
        tasks = []
        for i in range(args.start_index, args.start_index + n):
            ns_name = f"{args.ns_prefix}-{i:0{width_ns}d}"
            full_path = f"root/{ns_name}"
            tasks.append((
                args.addr,
                args.token,
                ns_name,
                "root",
                full_path,
                args.mount_prefix,
                args.start_index,
                x,
                width_kv,
                args.insecure
            ))

        # Exécution parallèle
        completed = 0
        total = len(tasks)

        with ThreadPoolExecutor(max_workers=args.workers) as executor:
            future_to_ns = {
                executor.submit(create_namespace_with_kvs, *task): task[4]
                for task in tasks
            }

            for future in as_completed(future_to_ns):
                completed += 1
                ns_name = future_to_ns[future]
                try:
                    result = future.result()
                    safe_print(f"[PROGRESS] {completed}/{total} namespaces traités")
                except Exception as e:
                    safe_print(f"[EXCEPTION] Erreur lors du traitement de {ns_name}: {e}")

    else:  # depth == 3
        # Depth 3: create parent trees depth-first (parent + all children)
        # Each worker will handle a complete parent tree
        parent_tree_tasks = []
        for i in range(args.start_index, args.start_index + n):
            parent_name = f"{args.ns_prefix}{i:0{width_parent}d}"
            parent_tree_tasks.append((
                args.addr,
                args.token,
                parent_name,
                args.ns_prefix,
                args.mount_prefix,
                args.start_index,
                x,  # KV engines per namespace
                ns_level2,  # Number of children per parent
                width_parent,
                width_child,
                width_kv,
                args.insecure
            ))

        safe_print(f"Création de {n} parent namespace trees (depth-first)...")
        safe_print(f"Chaque parent aura {ns_level2} child namespaces avec {x} KV engine(s) chacun.\n")

        completed = 0
        total_trees = len(parent_tree_tasks)

        with ThreadPoolExecutor(max_workers=args.workers) as executor:
            future_to_parent = {
                executor.submit(create_parent_namespace_tree, *task): task[2]
                for task in parent_tree_tasks
            }

            for future in as_completed(future_to_parent):
                completed += 1
                parent_name = future_to_parent[future]
                try:
                    result = future.result()
                    num_children = len(result['children'])
                    safe_print(f"[PROGRESS] {completed}/{total_trees} parent trees traités - {parent_name} avec {num_children} enfants")
                except Exception as e:
                    safe_print(f"[EXCEPTION] Erreur lors du traitement de {parent_name}: {e}")

    print("\nTerminé.")

if __name__ == "__main__":
    main()
