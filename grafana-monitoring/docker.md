# Procédure — Monitoring de Vault (HTTPS) avec Grafana (Docker) + Scrape direct Prometheus

Objectif : installer une stack Grafana + Prometheus centralisée dans Docker, et configurer Prometheus pour **scraper directement** les endpoints `/v1/sys/metrics` de chaque VM Vault (modèle pull natif Prometheus, sans agent sur les VMs).

Authentification : **token Vault long-lived** porté par une policy `prometheus-metrics`, lu par Prometheus via `authorization.credentials_file`.

Les dashboards seront construits dans un second temps.

---

## 1. Architecture cible

```
  ┌─────────────────────────┐         ┌──────────────────────────────┐
  │ VM Vault 1 (HTTPS)      │         │ Serveur Monitoring (Docker)  │
  │  └─ vault :8200         │◀────────│  ├─ Prometheus (9090)        │
  │     /v1/sys/metrics     │ HTTPS   │  └─ Grafana    (3000)        │
  └─────────────────────────┘ scrape  │                              │
                                      │                              │
  ┌─────────────────────────┐         │                              │
  │ VM Vault 2 (HTTPS)      │◀────────│                              │
  │  └─ vault :8200         │         │                              │
  └─────────────────────────┘         └──────────────────────────────┘
```

- Prometheus (central) interroge chaque Vault en **HTTPS** sur `/v1/sys/metrics?format=prometheus`.
- Authentification par **bearer token** Vault (policy `prometheus-metrics`).
- Grafana interroge Prometheus comme datasource.

> **Conséquences du choix pull direct :**
> - Le serveur Prometheus doit pouvoir **joindre chaque VM Vault** en HTTPS (`8200/tcp` par défaut). Firewall / NAT / segmentation doivent être ouverts dans ce sens.
> - Pas de buffering côté VM : si Prometheus est indisponible, les points de la fenêtre manquée sont perdus (Vault conserve néanmoins `prometheus_retention_time`, voir §4.1).
> - Une seule configuration centrale à maintenir (`prometheus.yml`), pas d'agent à déployer/mettre à jour sur les VMs.

---

## 2. Prérequis

### Sur le serveur de monitoring
- Docker ≥ 24 + Docker Compose v2
- Ports ouverts en entrée : `3000/tcp` (Grafana), `9090/tcp` (Prometheus, optionnel en externe).
- Accès **sortant HTTPS** du serveur monitoring vers chaque VM Vault (`8200/tcp`).
- DNS ou IP fixes pour chaque VM Vault (ex. `vault-1.exemple.local`, `vault-2.exemple.local`).
- **CA interne de Vault** disponible en PEM (ex. `vault-ca.pem`) pour valider le certificat serveur.

### Sur chaque VM Vault
- Port API Vault (`8200/tcp`) en HTTPS, accessible depuis le serveur de monitoring.
- Vault Enterprise configuré avec la télémétrie Prometheus activée (voir §4.1).
- Un token Vault avec la policy de métriques (voir §4.2/4.3).

---

## 3. Partie A — Installation de la stack centrale (Grafana + Prometheus) sur Docker

### 3.1. Arborescence côté serveur monitoring

```
/opt/monitoring/
├── docker-compose.yml
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

### 3.2. `docker-compose.yml`

```yaml
networks:
  monitoring:
    driver: bridge

volumes:
  prometheus_data:
  grafana_data:

services:
  prometheus:
    image: prom/prometheus:v2.54.1
    container_name: prometheus
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=30d
      - --web.enable-lifecycle
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/vault-ca.pem:/etc/prometheus/vault-ca.pem:ro
      - ./prometheus/vault-token:/etc/prometheus/vault-token:ro
      - prometheus_data:/prometheus
    ports:
      - "9090:9090"
    networks: [monitoring]

  grafana:
    image: grafana/grafana:11.2.2
    container_name: grafana
    restart: unless-stopped
    depends_on: [prometheus]
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin          # à changer !
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana_data:/var/lib/grafana
    ports:
      - "3000:3000"
    networks: [monitoring]
```

### 3.3. `prometheus/prometheus.yml`

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

### 3.4. `grafana/provisioning/datasources/datasource.yml`

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus                     # utilisé dans le JSON des dashboards
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
```

### 3.5. Démarrage

```bash
cd /opt/monitoring
docker compose up -d
docker compose ps
```

Vérifications :
- `curl -s http://localhost:9090/-/ready` → `Prometheus Server is Ready.`
- Accès Grafana : `http://<ip-serveur>:3000` (admin / admin → changer le mot de passe).

### 3.6. Sécurité (recommandations)

- **TLS vers Vault** : toujours utiliser `ca_file`, jamais `insecure_skip_verify: true` en production.
- **Fichier token** : monté en `:ro`, mode `0600` côté hôte.
- **Exposition de Prometheus** : ne pas publier `9090` sur Internet. Reverse proxy (Nginx/Traefik/Caddy) avec TLS + Basic Auth si un accès externe est nécessaire.
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

- [ ] `docker compose ps` : `prometheus` et `grafana` en `running / healthy`.
- [ ] Page **Status → Targets** de Prometheus : chaque cible `vault` est `UP` (schéma `https`).
- [ ] `up{job="vault"}` retourne `1` pour chaque instance.
- [ ] Grafana → Explore affiche bien les métriques `vault_*`.
- [ ] Test de panne : couper le réseau d'une VM → cible `DOWN` dans les 15 s, repasse `UP` à la restauration.

---

## 7. Exploitation courante

| Action | Commande |
|---|---|
| Recharger Prometheus (nouvelle config) | `curl -X POST http://localhost:9090/-/reload` |
| Ajouter/retirer un nœud Vault | éditer `prometheus.yml` + reload |
| Rotation du token Vault | `vault token create ...` → `install -m 0600` sur `/opt/monitoring/prometheus/vault-token` (pas de reload nécessaire) |
| Renouveler le token courant | `VAULT_TOKEN=$(cat …) vault token renew` (à planifier avant la fin de période) |
| Logs stack centrale | `docker compose -f /opt/monitoring/docker-compose.yml logs -f` |
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
docker compose -f /opt/monitoring/docker-compose.yml restart grafana
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
docker compose -f /opt/monitoring/docker-compose.yml restart grafana
```

Dans chaque JSON téléchargé, vérifier que l'uid de la datasource est `prometheus` (celui défini en §3.4). Si besoin, remplacer toute entrée `"uid": "${DS_PROMETHEUS}"` ou similaire par `"uid": "prometheus"`.

**Option B — import manuel via l'UI** : Grafana → **Dashboards → New → Import** → saisir l'ID → choisir la datasource *Prometheus*.

### 8.4. Vérifications

- `docker compose logs grafana | grep -i "provisioning"` : aucun `error` pour les providers `Vault`.
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
