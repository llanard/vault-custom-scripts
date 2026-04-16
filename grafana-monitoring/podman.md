# Procédure — Monitoring de Vault (HTTPS) avec Grafana (Podman) + Scrape direct Prometheus

Objectif : installer une stack Grafana + Prometheus centralisée avec **Podman** (sans Docker, sans docker-compose), et configurer Prometheus pour **scraper directement** les endpoints `/v1/sys/metrics` de chaque VM Vault (modèle pull natif Prometheus, sans agent sur les VMs).

Authentification : **token Vault long-lived** porté par une policy `prometheus-metrics`, lu par Prometheus via `authorization.credentials_file`.

> **Note Podman** : les deux conteneurs tournent dans un **pod** Podman. Dans un pod, les conteneurs partagent le même namespace réseau (comme dans un pod Kubernetes) → ils communiquent via `localhost`, pas par nom de conteneur.

Les dashboards seront construits dans un second temps.

---

## 1. Architecture cible

```
  ┌─────────────────────────┐         ┌──────────────────────────────────┐
  │ VM Vault 1 (HTTPS)      │         │ Serveur Monitoring (Podman)      │
  │  └─ vault :8200         │◀────────│  Pod "monitoring"                │
  │     /v1/sys/metrics     │ HTTPS   │   ├─ prometheus (localhost:9090) │
  └─────────────────────────┘ scrape  │   └─ grafana    (localhost:3000) │
                                      │                                  │
  ┌─────────────────────────┐         │                                  │
  │ VM Vault 2 (HTTPS)      │◀────────│                                  │
  │  └─ vault :8200         │         │                                  │
  └─────────────────────────┘         └──────────────────────────────────┘
```

- Prometheus (central) interroge chaque Vault en **HTTPS** sur `/v1/sys/metrics?format=prometheus`.
- Authentification par **bearer token** Vault (policy `prometheus-metrics`).
- Grafana interroge Prometheus via `localhost:9090` (même pod).

> **Conséquences du choix pull direct :**
> - Le serveur Prometheus doit pouvoir **joindre chaque VM Vault** en HTTPS (`8200/tcp` par défaut). Firewall / NAT / segmentation doivent être ouverts dans ce sens.
> - Pas de buffering côté VM : si Prometheus est indisponible, les points de la fenêtre manquée sont perdus (Vault conserve néanmoins `prometheus_retention_time`, voir §4.1).
> - Une seule configuration centrale à maintenir (`prometheus.yml`), pas d'agent à déployer/mettre à jour sur les VMs.

---

## 2. Prérequis

### Sur le serveur de monitoring
- **Podman ≥ 4.0** (aucun besoin de Docker ni de docker-compose).
- Ports ouverts en entrée : `3000/tcp` (Grafana), `9090/tcp` (Prometheus, optionnel en externe).
- Accès **sortant HTTPS** du serveur monitoring vers chaque VM Vault (`8200/tcp`).
- DNS ou IP fixes pour chaque VM Vault (ex. `vault-1.exemple.local`, `vault-2.exemple.local`).
- **CA interne de Vault** disponible en PEM (ex. `vault-ca.pem`) pour valider le certificat serveur.

### Sur chaque VM Vault
- Port API Vault (`8200/tcp`) en HTTPS, accessible depuis le serveur de monitoring.
- Vault Enterprise configuré avec la télémétrie Prometheus activée (voir §4.1).
- Un token Vault avec la policy de métriques (voir §4.2/4.3).

---

## 3. Partie A — Installation de la stack centrale (Grafana + Prometheus) avec Podman

### 3.1. Arborescence côté serveur monitoring

```
/opt/monitoring/
├── prometheus/
│   ├── prometheus.yml
│   ├── vault-ca.pem        # CA interne Vault (0644)
│   └── vault-token         # token bearer, mode 0600
└── grafana/
    ├── provisioning/
    │   ├── datasources/
    │   │   └── datasource.yml
    │   └── dashboards/
    │       └── dashboards.yml
    └── dashboards/
        └── vault-overview.json
```

### 3.2. Création du pod et des volumes

Un pod Podman regroupe les conteneurs dans un namespace réseau partagé. Les ports sont exposés **au niveau du pod**.

```bash
# Créer les volumes nommés
podman volume create prometheus_data
podman volume create grafana_data

# Créer le pod avec les ports publiés
podman pod create \
  --name monitoring \
  -p 9090:9090 \
  -p 3000:3000
```

### 3.3. Lancer Prometheus

```bash
podman run -d \
  --pod monitoring \
  --name prometheus \
  --restart unless-stopped \
  -v /opt/monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro,Z \
  -v /opt/monitoring/prometheus/vault-ca.pem:/etc/prometheus/vault-ca.pem:ro,Z \
  -v /opt/monitoring/prometheus/vault-token:/etc/prometheus/vault-token:ro,Z \
  -v prometheus_data:/prometheus:Z \
  docker.io/prom/prometheus:v2.54.1 \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/prometheus \
    --storage.tsdb.retention.time=30d \
    --web.enable-lifecycle
```

> Le suffixe `:Z` sur les bind mounts applique le contexte SELinux si la VM utilise SELinux (RHEL/Rocky). Sur un système sans SELinux, il est ignoré sans erreur.

### 3.4. Lancer Grafana

```bash
podman run -d \
  --pod monitoring \
  --name grafana \
  --restart unless-stopped \
  -e GF_SECURITY_ADMIN_USER=admin \
  -e GF_SECURITY_ADMIN_PASSWORD=admin \
  -e GF_USERS_ALLOW_SIGN_UP=false \
  -v /opt/monitoring/grafana/provisioning:/etc/grafana/provisioning:ro,Z \
  -v /opt/monitoring/grafana/dashboards:/var/lib/grafana/dashboards:ro,Z \
  -v grafana_data:/var/lib/grafana:Z \
  docker.io/grafana/grafana:11.2.2
```

### 3.5. `prometheus/prometheus.yml`

Prometheus scrape chaque VM Vault en **HTTPS**. Le token est lu depuis un fichier monté en read-only dans le conteneur.

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    monitor: central

scrape_configs:
  # Auto-monitoring de Prometheus
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  # Scrape direct des VMs Vault (HTTPS)
  - job_name: vault
    metrics_path: /v1/sys/metrics
    params:
      format: ['prometheus']
    scheme: https
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/vault-token
    tls_config:
      ca_file: /etc/prometheus/vault-ca.pem
      insecure_skip_verify: false
      # server_name: vault.exemple.local          # si SNI nécessaire
    static_configs:
      - targets:
          - vault-1.exemple.local:8200
          - vault-2.exemple.local:8200
          - vault-3.exemple.local:8200
        labels:
          cluster: vault-prod
    relabel_configs:
      # Remplace le port par un hostname lisible dans l'étiquette `instance`
      - source_labels: [__address__]
        regex: '([^:]+)(:\d+)?'
        target_label: instance
        replacement: '$1'
```

> Prometheus relit `credentials_file` à chaque scrape : une rotation du token sur disque est prise en compte sans reload.

### 3.6. `grafana/provisioning/datasources/datasource.yml`

Dans un pod Podman, les conteneurs partagent `localhost`. L'URL de la datasource pointe vers `localhost:9090` (pas `http://prometheus:9090`).

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus                     # utilisé dans le JSON des dashboards
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: true
```

### 3.7. Vérifications après démarrage

```bash
# État du pod et des conteneurs
podman pod ps
podman ps --pod --filter pod=monitoring

# Prometheus ready ?
curl -s http://localhost:9090/-/ready

# Grafana accessible ?
curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/login
```

- Accès Grafana : `http://<ip-serveur>:3000` (admin / admin → changer le mot de passe).

### 3.8. Persistance avec systemd (redémarrage automatique)

Podman n'a pas de démon. Pour garantir le redémarrage au boot, on génère des unités systemd.

```bash
# Générer les unités (en tant que root)
mkdir -p /etc/systemd/system
podman generate systemd --new --name monitoring --files
mv pod-monitoring.service container-prometheus.service container-grafana.service \
  /etc/systemd/system/

# Activer au boot
systemctl daemon-reload
systemctl enable pod-monitoring.service
```

> `--new` fait que systemd recrée les conteneurs à chaque démarrage (au lieu de tenter un `podman start` sur un conteneur existant). Les volumes nommés persistent les données entre recréations.

Pour démarrer/arrêter la stack via systemd :

```bash
systemctl start pod-monitoring     # démarre le pod + ses conteneurs
systemctl stop pod-monitoring      # arrête tout
systemctl restart pod-monitoring   # redémarre
```

### 3.9. Sécurité (recommandations)

- **TLS vers Vault** : toujours utiliser `ca_file`, jamais `insecure_skip_verify: true` en production.
- **Fichier token** : monté en `:ro`, mode `0600` côté hôte.
- **SELinux** : les suffixes `:Z` relabellisent les fichiers pour le contexte du conteneur. Si les fichiers sont partagés entre plusieurs conteneurs, utiliser `:z` (minuscule) à la place.
- **Exposition de Prometheus** : ne pas publier `9090` sur Internet. Reverse proxy (Nginx/Caddy) avec TLS + Basic Auth si un accès externe est nécessaire.
- **Segmentation** : autoriser uniquement l'IP du serveur monitoring vers `8200/tcp` des VMs Vault.

---

## 4. Partie B — Préparer Vault pour l'exposition des métriques

À faire **une fois par cluster**.

### 4.1. Activer la télémétrie Prometheus

Dans le `vault.hcl` de chaque nœud :

```hcl
telemetry {
  prometheus_retention_time = "24h"
  disable_hostname          = true
}
```

Puis redémarrer Vault (rolling restart nœud par nœud).

### 4.2. Créer la policy Prometheus

`prometheus-metrics.hcl` :

```hcl
path "sys/metrics" {
  capabilities = ["read"]
}
```

```bash
vault policy write prometheus-metrics prometheus-metrics.hcl
```

### 4.3. Générer un token long-lived pour Prometheus

```bash
vault token create \
  -policy=prometheus-metrics \
  -period=720h \
  -display-name="prometheus-scraper" \
  -field=token > /tmp/vault-metrics-token
```

> Le flag `-period` rend le token **renouvelable indéfiniment** tant qu'il est renouvelé avant expiration. Prévoir un cron / script de renouvellement (`vault token renew`) ou régénérer périodiquement un nouveau token.

### 4.4. Déposer le token côté serveur monitoring

```bash
sudo install -o root -g root -m 0600 \
  /tmp/vault-metrics-token \
  /opt/monitoring/prometheus/vault-token

# Prometheus relit le fichier à chaque scrape — pas besoin de reload.
# (Un reload est utile uniquement si prometheus.yml a changé.)
```

---

## 5. Partie C — Ajouter un nouveau nœud / cluster Vault

Plus d'agent à installer : il suffit d'éditer `prometheus.yml`.

1. Ouvrir le port `8200/tcp` entre le serveur monitoring et la nouvelle VM.
2. Ajouter la cible dans `scrape_configs` :

   ```yaml
     - job_name: vault
       # ... (config existante)
       static_configs:
         - targets:
             - vault-1.exemple.local:8200
             - vault-2.exemple.local:8200
             - vault-3.exemple.local:8200
             - vault-4.exemple.local:8200   # nouveau nœud
           labels:
             cluster: vault-prod
   ```

3. Recharger Prometheus : `curl -X POST http://localhost:9090/-/reload`.

Pour un **second cluster**, dupliquer le bloc en changeant le label `cluster` et éventuellement le token :

```yaml
  - job_name: vault-dr
    metrics_path: /v1/sys/metrics
    params: { format: ['prometheus'] }
    scheme: https
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/vault-token-dr
    tls_config:
      ca_file: /etc/prometheus/vault-ca.pem
    static_configs:
      - targets: ['vault-dr-1.exemple.local:8200']
        labels:
          cluster: vault-dr
```

---

## 6. Partie D — Vérifications de bout en bout

### 6.1. Depuis le serveur monitoring

```bash
# Joignabilité HTTPS et endpoint Vault :
curl -s --cacert /opt/monitoring/prometheus/vault-ca.pem \
     -H "Authorization: Bearer $(cat /opt/monitoring/prometheus/vault-token)" \
     "https://vault-1.exemple.local:8200/v1/sys/metrics?format=prometheus" | head

# État des cibles Prometheus :
curl -s http://localhost:9090/api/v1/targets \
  | jq '.data.activeTargets[] | {job:.labels.job, instance:.labels.instance, health:.health, lastError:.lastError}'

# Sanity-check :
curl -s 'http://localhost:9090/api/v1/query?query=vault_core_unsealed' | jq
curl -s 'http://localhost:9090/api/v1/query?query=up{job="vault"}' | jq
```

Dans Grafana (`http://<ip>:3000`) :
1. **Connections → Data sources → Prometheus** : **Save & test** → "Data source is working".
2. **Explore** → requête : `vault_core_unsealed` → une série par nœud Vault.

### 6.2. Checklist de validation

- [ ] `podman pod ps` : pod `monitoring` en `Running`.
- [ ] `podman ps --pod --filter pod=monitoring` : `prometheus` et `grafana` en `Up`.
- [ ] Page **Status → Targets** de Prometheus : chaque cible `vault` est `UP` (schéma `https`).
- [ ] `up{job="vault"}` retourne `1` pour chaque instance.
- [ ] Grafana → Explore affiche bien les métriques `vault_*`.
- [ ] Test de panne : couper le réseau d'une VM → cible `DOWN` dans les 15 s, repasse `UP` à la restauration.
- [ ] `systemctl is-enabled pod-monitoring` → `enabled` (redémarrage au boot).

---

## 7. Exploitation courante

| Action | Commande |
|---|---|
| État de la stack | `podman pod ps` / `podman ps --pod --filter pod=monitoring` |
| Logs Prometheus | `podman logs -f prometheus` |
| Logs Grafana | `podman logs -f grafana` |
| Recharger Prometheus (nouvelle config) | `curl -X POST http://localhost:9090/-/reload` |
| Ajouter/retirer un nœud Vault | éditer `prometheus.yml` + reload |
| Rotation du token Vault | `vault token create ...` → `install -m 0600` sur `/opt/monitoring/prometheus/vault-token` (pas de reload nécessaire) |
| Renouveler le token courant | `VAULT_TOKEN=$(cat …) vault token renew` (à planifier avant la fin de période) |
| Redémarrer la stack | `systemctl restart pod-monitoring` |
| Arrêter la stack | `systemctl stop pod-monitoring` |
| Exec dans un conteneur | `podman exec -it prometheus sh` |
| Recréer un conteneur (ex. upgrade image) | arrêter + `podman rm prometheus` + relancer la commande `podman run` de §3.3 |
| Voir les erreurs de scrape | UI Prometheus → **Status → Targets** (colonne *Last Error*) |

---

## 8. Partie E — Dashboards Grafana

Les métriques arrivent dans Prometheus. On ajoute maintenant :
- un **provisioning** de dashboards (versionnables dans git),
- un dashboard **custom "Vault Overview"** (santé cluster, performance, tokens/leases, runtime),
- l'import de dashboards communautaires pour les vues détaillées.

### 8.1. Provisioning — `grafana/provisioning/dashboards/dashboards.yml`

```yaml
apiVersion: 1
providers:
  - name: Vault
    orgId: 1
    folder: Vault
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
```

Après dépôt du fichier, redémarrer Grafana :

```bash
podman restart grafana
```

### 8.2. Dashboard custom — `grafana/dashboards/vault-overview.json`

Un dashboard unique avec 4 rangées : **Cluster Health**, **Performance**, **Tokens & Leases**, **Runtime**.

Variables : `$cluster` (label `cluster`) et `$instance` (label `instance`).

```json
{
  "uid": "vault-overview",
  "title": "Vault — Overview",
  "tags": ["vault"],
  "schemaVersion": 39,
  "version": 1,
  "editable": true,
  "refresh": "30s",
  "time": { "from": "now-1h", "to": "now" },
  "timezone": "",
  "templating": {
    "list": [
      {
        "name": "cluster", "type": "query",
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "query": "label_values(vault_core_unsealed, cluster)",
        "refresh": 1, "includeAll": true, "multi": false, "current": { "text": "All", "value": "$__all" }
      },
      {
        "name": "instance", "type": "query",
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "query": "label_values(vault_core_unsealed{cluster=~\"$cluster\"}, instance)",
        "refresh": 1, "includeAll": true, "multi": true, "current": { "text": "All", "value": "$__all" }
      }
    ]
  },
  "panels": [
    { "type": "row", "title": "Cluster Health", "collapsed": false,
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 }, "id": 100 },

    { "type": "stat", "title": "Unsealed nodes", "id": 1,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 5, "w": 6, "x": 0, "y": 1 },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"], "fields": "" }, "colorMode": "background" },
      "fieldConfig": { "defaults": { "thresholds": { "mode": "absolute", "steps": [
        { "color": "red", "value": null }, { "color": "green", "value": 1 } ] }, "mappings": [
        { "type": "value", "options": { "0": { "text": "SEALED" }, "1": { "text": "UNSEALED" } } } ] } },
      "targets": [ { "expr": "vault_core_unsealed{cluster=~\"$cluster\",instance=~\"$instance\"}",
        "legendFormat": "{{instance}}", "refId": "A" } ] },

    { "type": "stat", "title": "Active leader", "id": 2,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 5, "w": 6, "x": 6, "y": 1 },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "textMode": "value_and_name" },
      "fieldConfig": { "defaults": { "thresholds": { "mode": "absolute", "steps": [
        { "color": "text", "value": null }, { "color": "green", "value": 1 } ] } } },
      "targets": [ { "expr": "vault_core_active{cluster=~\"$cluster\",instance=~\"$instance\"} == 1",
        "legendFormat": "{{instance}}", "refId": "A" } ] },

    { "type": "stat", "title": "Raft peers", "id": 3,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 5, "w": 6, "x": 12, "y": 1 },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value" },
      "fieldConfig": { "defaults": { "thresholds": { "mode": "absolute", "steps": [
        { "color": "red", "value": null }, { "color": "orange", "value": 2 }, { "color": "green", "value": 3 } ] } } },
      "targets": [ { "expr": "max(vault_raft_peers{cluster=~\"$cluster\"})",
        "legendFormat": "peers", "refId": "A" } ] },

    { "type": "stat", "title": "Leadership losses (24h)", "id": 4,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 5, "w": 6, "x": 18, "y": 1 },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background" },
      "fieldConfig": { "defaults": { "thresholds": { "mode": "absolute", "steps": [
        { "color": "green", "value": null }, { "color": "orange", "value": 1 }, { "color": "red", "value": 5 } ] } } },
      "targets": [ { "expr": "sum(increase(vault_core_leadership_lost_count{cluster=~\"$cluster\"}[24h]))",
        "legendFormat": "events", "refId": "A" } ] },

    { "type": "row", "title": "Performance", "collapsed": false,
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 6 }, "id": 101 },

    { "type": "timeseries", "title": "Request rate (req/s)", "id": 5,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 7 },
      "fieldConfig": { "defaults": { "unit": "reqps" } },
      "targets": [ { "expr": "sum by (instance) (rate(vault_core_handle_request_count{cluster=~\"$cluster\",instance=~\"$instance\"}[5m]))",
        "legendFormat": "{{instance}}", "refId": "A" } ] },

    { "type": "timeseries", "title": "Request latency (ms)", "id": 6,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 7 },
      "fieldConfig": { "defaults": { "unit": "ms" } },
      "targets": [
        { "expr": "avg(vault_core_handle_request{cluster=~\"$cluster\",instance=~\"$instance\",quantile=\"0.5\"})",
          "legendFormat": "p50", "refId": "A" },
        { "expr": "avg(vault_core_handle_request{cluster=~\"$cluster\",instance=~\"$instance\",quantile=\"0.9\"})",
          "legendFormat": "p90", "refId": "B" },
        { "expr": "avg(vault_core_handle_request{cluster=~\"$cluster\",instance=~\"$instance\",quantile=\"0.99\"})",
          "legendFormat": "p99", "refId": "C" } ] },

    { "type": "timeseries", "title": "Audit log failures (rate)", "id": 7,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 15 },
      "fieldConfig": { "defaults": { "unit": "short" } },
      "targets": [
        { "expr": "sum by (instance) (rate(vault_audit_log_request_failure{cluster=~\"$cluster\",instance=~\"$instance\"}[5m]))",
          "legendFormat": "{{instance}} requests", "refId": "A" },
        { "expr": "sum by (instance) (rate(vault_audit_log_response_failure{cluster=~\"$cluster\",instance=~\"$instance\"}[5m]))",
          "legendFormat": "{{instance}} responses", "refId": "B" } ] },

    { "type": "timeseries", "title": "Raft — time since leader contact (ms)", "id": 8,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 15 },
      "fieldConfig": { "defaults": { "unit": "ms" } },
      "targets": [ { "expr": "vault_raft_leader_last_contact{cluster=~\"$cluster\",instance=~\"$instance\"}",
        "legendFormat": "{{instance}}", "refId": "A" } ] },

    { "type": "timeseries", "title": "Request rate by type (login / other)", "id": 16,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 23 },
      "fieldConfig": { "defaults": { "unit": "reqps",
        "custom": { "stacking": { "mode": "normal", "group": "A" }, "fillOpacity": 30 } } },
      "options": { "legend": { "displayMode": "table", "placement": "right", "calcs": ["lastNotNull", "mean"] } },
      "targets": [
        { "expr": "sum by (instance) (rate(vault_core_handle_login_request_count{cluster=~\"$cluster\",instance=~\"$instance\"}[5m]))",
          "legendFormat": "login — {{instance}}", "refId": "A" },
        { "expr": "sum by (instance) (rate(vault_core_handle_request_count{cluster=~\"$cluster\",instance=~\"$instance\"}[5m]))",
          "legendFormat": "other — {{instance}}", "refId": "B" } ] },

    { "type": "timeseries", "title": "Login rate by namespace", "id": 17,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 31 },
      "fieldConfig": { "defaults": { "unit": "reqps" } },
      "targets": [ { "expr": "sum by (namespace) (rate(vault_core_handle_login_request_count{cluster=~\"$cluster\"}[5m]))",
        "legendFormat": "{{namespace}}", "refId": "A" } ] },

    { "type": "timeseries", "title": "Storage backend latency (p99)", "id": 18,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 31 },
      "fieldConfig": { "defaults": { "unit": "ms" } },
      "targets": [
        { "expr": "avg(vault_barrier_get{quantile=\"0.99\",cluster=~\"$cluster\",instance=~\"$instance\"})",
          "legendFormat": "barrier get", "refId": "A" },
        { "expr": "avg(vault_barrier_put{quantile=\"0.99\",cluster=~\"$cluster\",instance=~\"$instance\"})",
          "legendFormat": "barrier put", "refId": "B" },
        { "expr": "avg(vault_raft_storage_entry_get{quantile=\"0.99\",cluster=~\"$cluster\",instance=~\"$instance\"})",
          "legendFormat": "raft entry get", "refId": "C" },
        { "expr": "avg(vault_raft_storage_entry_put{quantile=\"0.99\",cluster=~\"$cluster\",instance=~\"$instance\"})",
          "legendFormat": "raft entry put", "refId": "D" } ] },

    { "type": "timeseries", "title": "WAL persist & flushready latency (p99)", "id": 19,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 39 },
      "fieldConfig": { "defaults": { "unit": "ms" } },
      "targets": [
        { "expr": "avg(vault_wal_persistwals{quantile=\"0.99\",cluster=~\"$cluster\",instance=~\"$instance\"})",
          "legendFormat": "persistwals p99 — {{instance}}", "refId": "A" },
        { "expr": "avg(vault_wal_flushready{quantile=\"0.99\",cluster=~\"$cluster\",instance=~\"$instance\"})",
          "legendFormat": "flushready p99 — {{instance}}", "refId": "B" } ] },

    { "type": "row", "title": "Tokens & Leases", "collapsed": false,
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 47 }, "id": 102 },

    { "type": "timeseries", "title": "Active tokens", "id": 9,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 48 },
      "fieldConfig": { "defaults": { "unit": "short" } },
      "targets": [ { "expr": "sum by (instance) (vault_token_count{cluster=~\"$cluster\",instance=~\"$instance\"})",
        "legendFormat": "{{instance}}", "refId": "A" } ] },

    { "type": "timeseries", "title": "Active leases", "id": 10,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 48 },
      "fieldConfig": { "defaults": { "unit": "short" } },
      "targets": [ { "expr": "sum by (instance) (vault_expire_num_leases{cluster=~\"$cluster\",instance=~\"$instance\"})",
        "legendFormat": "{{instance}}", "refId": "A" } ] },

    { "type": "timeseries", "title": "Token creation rate", "id": 11,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 56 },
      "fieldConfig": { "defaults": { "unit": "short" } },
      "targets": [ { "expr": "sum by (mount_point) (rate(vault_token_creation{cluster=~\"$cluster\"}[5m]))",
        "legendFormat": "{{mount_point}}", "refId": "A" } ] },

    { "type": "timeseries", "title": "Lease revocations (rate)", "id": 12,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 56 },
      "fieldConfig": { "defaults": { "unit": "short" } },
      "targets": [ { "expr": "sum by (instance) (rate(vault_expire_revoke_count{cluster=~\"$cluster\",instance=~\"$instance\"}[5m]))",
        "legendFormat": "{{instance}}", "refId": "A" } ] },

    { "type": "row", "title": "Runtime (Go)", "collapsed": false,
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 64 }, "id": 103 },

    { "type": "timeseries", "title": "Memory alloc (bytes)", "id": 13,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 8, "x": 0, "y": 65 },
      "fieldConfig": { "defaults": { "unit": "bytes" } },
      "targets": [ { "expr": "go_memstats_alloc_bytes{job=\"vault\",cluster=~\"$cluster\",instance=~\"$instance\"}",
        "legendFormat": "{{instance}}", "refId": "A" } ] },

    { "type": "timeseries", "title": "Resident memory (bytes)", "id": 14,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 8, "x": 8, "y": 65 },
      "fieldConfig": { "defaults": { "unit": "bytes" } },
      "targets": [ { "expr": "process_resident_memory_bytes{job=\"vault\",cluster=~\"$cluster\",instance=~\"$instance\"}",
        "legendFormat": "{{instance}}", "refId": "A" } ] },

    { "type": "timeseries", "title": "Goroutines", "id": 15,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 8, "x": 16, "y": 65 },
      "fieldConfig": { "defaults": { "unit": "short" } },
      "targets": [ { "expr": "go_goroutines{job=\"vault\",cluster=~\"$cluster\",instance=~\"$instance\"}",
        "legendFormat": "{{instance}}", "refId": "A" } ] },

    { "type": "timeseries", "title": "CPU usage (cores)", "id": 20,
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 73 },
      "fieldConfig": { "defaults": { "unit": "none",
        "custom": { "fillOpacity": 20 } } },
      "targets": [ { "expr": "rate(process_cpu_seconds_total{job=\"vault\",cluster=~\"$cluster\",instance=~\"$instance\"}[5m])",
        "legendFormat": "{{instance}}", "refId": "A" } ] }
  ]
}
```

> **À valider selon la version de Vault déployée :**
> Certaines métriques utilisées dans ce dashboard peuvent apparaître sous un nom légèrement différent selon la version de Vault (suffixe `_count` sur les compteurs, renommages entre versions majeures). Points à vérifier après le premier démarrage :
> - **Panneau 11 *Token creation rate*** : `vault_token_creation` — selon la version peut s'appeler `vault_token_creation_count` ou `vault_token_creations`.
> - **Panneau 12 *Lease revocations (rate)*** : `vault_expire_revoke_count` — selon la version peut s'appeler `vault_expire_revoke` (summary exposant `_count`) ou `vault_expire_num_revoke`.
> - **Panneau 17 *Login rate by namespace*** : `vault_core_handle_login_request_count` — présent sur toutes les versions récentes ; label `namespace` uniquement si namespaces activés (Enterprise), sinon la série apparaît sans libellé.
> - **Panneau 18 *Storage backend latency*** : `vault_barrier_get/put` et `vault_raft_storage_entry_get/put` — exposées en *summaries* (labels `quantile`). Sur un backend non-Raft (Consul, etc.), les séries `vault_raft_*` n'existent pas : retirer les queries C et D.
> - **Panneau 19 *WAL persist & flushready latency*** : `vault_wal_persistwals` et `vault_wal_flushready` — présents uniquement lorsque le backend produit un WAL (Raft intégré). Noms stables sur Vault ≥ 1.10 ; sur versions plus anciennes, vérifier via Explore.
>
> Méthode : ouvrir Grafana → **Explore** → datasource *Prometheus* → taper `vault_token_`, `vault_expire_`, `vault_barrier_`, `vault_raft_`, `vault_wal_` pour lister les métriques réellement exposées par votre Vault, puis corriger les `expr` des panneaux concernés si nécessaire.

### 8.3. Import de dashboards communautaires (compléments)

Deux références officielles utiles à ajouter en complément :

| ID Grafana.com | Dashboard | Usage |
|---|---|---|
| `12904` | *Vault — Prometheus* (HashiCorp) | Vue détaillée : audit, storage, token store, runtime |
| `13820` | *Vault Cluster* | Focus Raft / HA / réplication |

Deux options pour les provisionner :

**Option A — télécharger le JSON et le commit** (recommandé, figé en version) :

```bash
cd /opt/monitoring/grafana/dashboards
curl -sL https://grafana.com/api/dashboards/12904/revisions/latest/download \
  -o vault-hashicorp.json
curl -sL https://grafana.com/api/dashboards/13820/revisions/latest/download \
  -o vault-cluster.json
podman restart grafana
```

Dans chaque JSON téléchargé, vérifier que l'uid de la datasource est `prometheus` (celui défini en §3.6). Si besoin, remplacer toute entrée `"uid": "${DS_PROMETHEUS}"` ou similaire par `"uid": "prometheus"`.

**Option B — import manuel via l'UI** : Grafana → **Dashboards → New → Import** → saisir l'ID → choisir la datasource *Prometheus*.

### 8.4. Vérifications

- `podman logs grafana 2>&1 | grep -i "provisioning"` : aucun `error` pour les providers `Vault`.
- Grafana → **Dashboards → Vault** : le dashboard *Vault — Overview* apparaît, ainsi que les dashboards importés.
- Ouvrir *Vault — Overview*, choisir `cluster = vault-prod` : chaque panneau affiche des données (pas de "No data").
- Les variables `$cluster` et `$instance` proposent la liste des nœuds scrappés.

### 8.5. Conseils d'itération

- Les dashboards provisionnés sont **modifiables en UI** (`allowUiUpdates: true`), mais les changements sont **écrasés** au prochain reload du provider. Workflow recommandé :
  1. éditer en UI,
  2. **Export JSON → Save to file**,
  3. remplacer `vault-overview.json`,
  4. commit dans git.
- Pour ajouter un cluster : la variable `$cluster` est alimentée automatiquement par `label_values(...)` ; aucun changement JSON requis.

---

## 9. Prochaine étape

Dashboards en place. Pistes suivantes :
- **Alerting** : règles Prometheus (seal, leader absent, `vault_raft_leader_last_contact` > seuil, audit failures) + notifications Grafana.
- **Logs** : ajout de Loki + collecte des logs Vault (journalctl / fichiers d'audit).
- **Durcissement** : reverse proxy TLS devant Grafana, SSO (OIDC), rôles Grafana par équipe.
