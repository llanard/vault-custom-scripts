# Procédure de test de performance — Cluster HashiCorp Vault

## 1. Objectif

Évaluer les performances du cluster Vault sous charge réaliste, identifier les goulots d'étranglement (CPU, RAM, réseau, I/O disque du backend de stockage) et établir une ligne de base (baseline) pour les futures évolutions d'infrastructure.

---

## 2. Préalables

### 2.1 Environnement
- **Ne jamais exécuter sur le cluster de production.** Utiliser un cluster de pré-production *iso-topologie* (même nombre de nœuds, mêmes flavors VM/conteneurs, même backend de stockage — Raft intégré ou Consul).
- Disposer d'au moins **un nœud injecteur de charge** distinct du cluster Vault (idéalement dans le même VPC/sous-réseau pour isoler la latence réseau « client → Vault » du test).
- Pour une charge élevée, prévoir **plusieurs injecteurs** coordonnés (sinon le CPU de l'injecteur devient lui-même le bottleneck).

### 2.2 Outils
- `vault` CLI (mêmes version majeure/mineure que le cluster)
- `vault-benchmark` (binaire officiel HashiCorp : https://releases.hashicorp.com/vault-benchmark/)
- Supervision système : `node_exporter` + Prometheus/Grafana, ou `vmstat`, `iostat`, `sar`, `dstat`, `ss`, `ifstat`
- Télémétrie Vault activée (endpoint `/v1/sys/metrics?format=prometheus`)
- Agrégation de logs (audit device Vault activé sur un device de test)

### 2.3 Droits
- Token Vault avec une policy permettant la création de rôles/secrets sur les moteurs testés (AppRole, KV v2, Transit, PKI…).

---

## 3. Préparation du cluster et de la télémétrie

### 3.1 Activer la télémétrie Vault
Dans `vault.hcl` de chaque nœud :
```hcl
telemetry {
  prometheus_retention_time = "24h"
  disable_hostname          = true
}
```

### 3.2 Métriques système à scraper pendant le test
| Dimension | Métriques clés |
|---|---|
| CPU | `node_cpu_seconds_total` (user, system, iowait, steal) |
| RAM | `node_memory_MemAvailable_bytes`, `node_memory_SwapUsed_bytes` |
| Disque (Raft/Consul) | `node_disk_io_time_seconds_total`, `node_disk_read/write_bytes_total`, latence fsync |
| Réseau | `node_network_receive/transmit_bytes_total`, retransmissions TCP, saturation NIC |
| Vault | `vault.core.handle_request`, `vault.runtime.alloc_bytes`, `vault.raft.apply`, `vault.raft.replication.appendEntries.rpc`, `vault.barrier.*` |

### 3.3 Activer un audit device dédié au test
```bash
vault audit enable -path=bench file file_path=/var/log/vault/audit-bench.log
```
*(à désactiver après le test pour éviter tout impact futur)*

---

## 4. Installation de vault-benchmark sur l'injecteur

```bash
curl -O https://releases.hashicorp.com/vault-benchmark/0.x.x/vault-benchmark_<version>_linux_amd64.zip
unzip vault-benchmark_*.zip -d /usr/local/bin/
vault-benchmark version
```

Exporter les variables :
```bash
export VAULT_ADDR="https://vault.mon-domaine:8200"
export VAULT_TOKEN="<token-bench>"
```

---

## 5. Scénarios de test

### 5.1 Principe : charge progressive (ramp-up)
Exécuter la même configuration HCL avec des valeurs croissantes de `-workers` (ou `-rps`) afin de tracer la courbe **throughput vs latence** et identifier le point d'inflexion (knee point) au-delà duquel la latence p99 explose.

Séquence recommandée : `10 → 25 → 50 → 100 → 200 → 400` workers, chaque palier de `60s`.

### 5.2 Scénario A — Authentification AppRole (lecture intensive)
`approle-bench.hcl` :
```hcl
vault_addr    = "https://vault.mon-domaine:8200"
duration      = "60s"
cleanup       = true
report_mode   = "verbose"
random_mounts = true

test "approle_auth" "login_test" {
  weight = 100
  config {
    role {
      role_name     = "bench-role"
      token_ttl     = "2m"
      token_max_ttl = "5m"
    }
  }
}
```

### 5.3 Scénario B — Écriture KV v2 (écriture intensive sur le backend)
```hcl
duration = "60s"
cleanup  = true

test "kvv2_write" "kv_write" {
  weight = 100
  config {
    numkvs = 1000
    kvsize = 256
  }
}
```
Ce scénario stresse le consensus Raft / le backend Consul : c'est ici qu'on détectera les problèmes d'I/O disque et de réplication.

### 5.4 Scénario C — Mix réaliste (production-like)
```hcl
duration = "300s"
cleanup  = true

test "approle_auth" "logins"   { weight = 60 }
test "kvv2_read"   "kv_reads"  { weight = 30 }
test "kvv2_write"  "kv_writes" { weight = 10 }
```
Pondérer selon la télémétrie observée en production (ratio lectures/écritures réel).

### 5.5 Scénario D (optionnel) — Cryptographie (Transit)
Utile si vous utilisez le moteur Transit : cible le CPU des nœuds Vault.
```hcl
test "transit_sign" "sign_ops" {
  weight = 100
  config {
    payload_len = 128
    key_type    = "rsa-2048"
  }
}
```

---

## 6. Exécution

### 6.1 Lancement d'un palier
```bash
vault-benchmark run \
  -config=approle-bench.hcl \
  -workers=100 \
  -duration=60s \
  -report_mode=json \
  > results/approle-100w.json
```

### 6.2 Lancement automatisé du ramp-up
```bash
for W in 10 25 50 100 200 400; do
  echo "=== $W workers ==="
  vault-benchmark run -config=approle-bench.hcl \
    -workers=$W -duration=60s -report_mode=json \
    > results/approle-${W}w.json
  sleep 30  # laisse le cluster revenir à l'état stable
done
```

### 6.3 Pendant l'exécution
Collecter en parallèle (sur chaque nœud Vault) :
```bash
vmstat 1 60 > vmstat-$(hostname).log &
iostat -xz 1 60 > iostat-$(hostname).log &
ifstat -i eth0 1 60 > ifstat-$(hostname).log &
```

---

## 7. Résultats — format de sortie

Exemple :
```
op              count   rate     throughput  mean      95th%     99th%     successRatio
approle_logins  210721  7023.8   7023.7      720.46µs  1.64ms    2.78ms    100.00%
kvv2_write       15432   514.4    512.1      14.2ms    38.7ms    92.3ms     99.87%
```

Colonnes clés :
- **rate / throughput** : débit total vs débit des opérations réussies
- **mean / p95 / p99** : distribution de latence
- **successRatio** : fiabilité sous charge

---

## 8. Grille d'interprétation — identification des bottlenecks

### 8.1 Méthode générale
1. Tracer **throughput(x) = f(workers)** et **latence p99(x) = f(workers)**.
2. Identifier le **knee point** : palier où le throughput plafonne alors que la p99 augmente fortement.
3. Corréler ce palier avec les métriques système des nœuds Vault pour isoler la ressource saturée.

### 8.2 Matrice de diagnostic

| Symptôme vault-benchmark | Métrique système saturée | Bottleneck probable | Action |
|---|---|---|---|
| p99 ↑, throughput plafonne, `successRatio` = 100% | CPU user > 80% sur le leader | **CPU Vault** (souvent Transit, TLS, JSON parsing) | Scale-up CPU, activer perf standby (Enterprise), offload TLS |
| p99 ↑ sur scénario **écriture**, throughput bas | `iowait` ↑, `await` disque ↑, fsync lent | **I/O disque** du backend Raft/Consul | SSD NVMe dédié, séparer WAL, tuner `performance_multiplier` Raft |
| Erreurs `context deadline exceeded`, `successRatio` < 100% | retransmissions TCP, latence inter-nœuds ↑ | **Réseau** (bande passante ou latence entre nœuds Raft) | Vérifier MTU, colocaliser les nœuds dans une même AZ, augmenter bande passante |
| `alloc_bytes` Vault ↑ en continu, swap actif | RAM disponible ↓, swap utilisé | **RAM** (cache Vault, tokens en mémoire) | Augmenter RAM, réduire `cache_size`, vérifier fuite via `pprof` |
| throughput symétrique sur tous les nœuds faible | CPU injecteur = 100% | **Injecteur saturé** (faux positif) | Ajouter des injecteurs, distribuer la charge |
| p99 haute uniquement sur écriture, p99 lecture OK | `vault.raft.apply` ↑, `raft.replication.*` ↑ | **Consensus Raft** (trop de followers lents) | Vérifier latence inter-nœuds, réduire taille des secrets, sharder via namespaces |
| Erreurs 5xx sporadiques, `successRatio` ~99% | file d'attente OS (`ss -s` → recv-q pleine) | **Limite fichiers/sockets OS** | `ulimit -n`, tuning `net.core.somaxconn`, `net.ipv4.tcp_max_syn_backlog` |
| Latence ↑ sur login AppRole mais KV OK | CPU system ↑ (chiffrement) | **CPU cryptographique** | Activer AES-NI, envisager HSM/auto-unseal optimisé |

### 8.3 Seuils indicatifs (à adapter à votre SLO)
- **p99 login AppRole** : < 50 ms sous charge nominale
- **p99 KV v2 write** : < 100 ms
- **successRatio** : ≥ 99.95 % sur un palier soutenu de 5 min
- **CPU Vault leader** : rester < 70 % en régime nominal pour garder une marge de burst

### 8.4 Analyse comparative
Conserver tous les `results/*.json` dans un dépôt versionné. À chaque évolution (upgrade Vault, changement de VM type, patch kernel), relancer la même batterie et comparer les courbes pour détecter une régression ou valider un gain.

---

## 9. Post-test

- `vault audit disable bench`
- Vérifier que `cleanup = true` a bien supprimé les secrets/rôles de test
- Révoquer le token de benchmark
- Archiver : configs HCL, résultats JSON, dashboards Grafana (snapshot), logs `vmstat`/`iostat`
- Rédiger un rapport synthétique : baseline + knee point + bottleneck identifié + recommandation

---

## 10. Références
- Documentation officielle : https://developer.hashicorp.com/vault/tutorials/operations/benchmark-vault
- Dépôt `vault-benchmark` : https://github.com/hashicorp/vault-benchmark
- Vault Well-Architected Framework (performance tuning)
