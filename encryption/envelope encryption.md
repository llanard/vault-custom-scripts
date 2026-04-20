# Démo Vault Enterprise 2.0 — Transit envelope encryption

Deux démos courtes :

1. **Démo 1** : envelope encryption côté client via la sous-commande CLI `vault transit envelope`.
2. **Démo 2** : mêmes opérations, mais via **Vault Proxy** — le client n'a **plus aucun token Vault**, le proxy s'authentifie tout seul en AppRole et injecte le token dans les requêtes.

Toutes les commandes s'exécutent depuis `/Users/louis.lanard/demos/vault2.0/`.

---

## Prérequis

### Démarrer Vault Enterprise

```sh
cd /Users/louis.lanard/demos/vault2.0/

# démarre le serveur en arrière-plan (config : vault.hcl, storage raft local, license ADP)
./vault server -config=vault.hcl > vault.log 2>&1 &

export VAULT_ADDR=http://127.0.0.1:8200
```

### Initialiser (à faire **une seule fois**, au tout premier lancement)

```sh
./vault operator init -key-shares=1 -key-threshold=1 -format=json > init.json
cat init.json    # récupère unseal_keys_b64[0] et root_token
```

### Déverrouiller (à chaque (re)démarrage du serveur)

```sh
UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' init.json)
ROOT_TOKEN=$(jq -r '.root_token'         init.json)

./vault operator unseal "$UNSEAL_KEY"
export VAULT_TOKEN="$ROOT_TOKEN"
```

### Vérifier

```sh
./vault status                     # Sealed=false, HA Mode=active
./vault read sys/license/status    # doit lister les features Enterprise (ADP, etc.)
```

---

## Démo 1 — Envelope encryption via CLI

**Idée à faire passer** : `vault transit envelope` permet de chiffrer des fichiers de taille arbitraire **côté client**. La donnée en clair ne transite **jamais** vers Vault. Seule une petite clé de chiffrement éphémère (DEK) est envoyée à Vault pour être wrappée par la KEK.

### 1.1 Activer le moteur Transit et créer une KEK

```sh
./vault secrets enable transit
./vault write -f transit/keys/kek type=aes256-gcm96
```

### 1.2 Préparer un fichier à chiffrer

```sh
cat > secret.txt <<'EOF'
Hello from Vault Enterprise 2.0 envelope encryption!
Ce fichier va être chiffré côté client avec une DEK.
La DEK elle-même est wrappée par la KEK transit 'kek'.
EOF
```

### 1.3 Chiffrer en envelope

```sh
./vault transit envelope encrypt transit/keys/kek secret.txt
ls -l secret.txt secret.txt.vee
```

> Produit `secret.txt.vee`. Format = header + EDK (DEK wrappée) + ciphertext + tag GCM.

### 1.4 Inspecter l'en-tête (sans déchiffrer)

```sh
./vault transit envelope header secret.txt.vee
```

Affiche `algorithm=OAE2-AES256-GCM96-HKDF`, la clé utilisée (`kek` v1, mount `transit/`), la taille d'origine, la date. **Aucun contenu sensible.**

### 1.5 Déchiffrer et vérifier le round-trip

```sh
mv secret.txt secret.txt.orig
./vault transit envelope decrypt transit/keys/kek secret.txt.vee
diff -q secret.txt secret.txt.orig && echo "OK : roundtrip identique"
cat secret.txt
```

### 1.6 (Bonus) Rotation de KEK — les anciens `.vee` restent lisibles

```sh
./vault write -f transit/keys/kek/rotate
./vault read transit/keys/kek | grep latest_version       # passe à 2
./vault transit envelope decrypt transit/keys/kek secret.txt.vee -o -    # OK grâce au key_version du header
```

### Cleanup de la démo 1

```sh
rm -f secret.txt secret.txt.orig secret.txt.vee
```

---

## Démo 2 — Envelope via Vault Proxy (client sans token)

**Idée à faire passer** : dans un vrai déploiement, ton appli ne doit pas manipuler de token Vault. Vault Proxy tourne à côté (sidecar, daemon), s'authentifie en AppRole, garde un token vivant, et agit comme un reverse-proxy local qui **injecte le bon `X-Vault-Token`** sur chaque requête. L'appli fait du HTTP simple vers `127.0.0.1:8100`.

> Note : `vault proxy` est le nouveau binaire dédié. L'ancien `vault agent` a la même fonctionnalité (bloc `api_proxy`) mais sa partie proxy est en cours de dépréciation.

### 2.1 Créer une policy minimale et un AppRole

```sh
./vault policy write transit-client - <<'EOF'
path "transit/keys/kek"               { capabilities = ["read"] }
path "transit/encrypt/kek"            { capabilities = ["update"] }
path "transit/decrypt/kek"            { capabilities = ["update"] }
path "transit/datakey/plaintext/kek"  { capabilities = ["update"] }
path "transit/datakey/wrapped/kek"    { capabilities = ["update"] }
path "transit/datakeys/plaintext/kek" { capabilities = ["update"] }
path "transit/datakeys/wrapped/kek"   { capabilities = ["update"] }
EOF

./vault auth enable approle
./vault write auth/approle/role/transit-client \
  token_policies=transit-client token_ttl=1h token_max_ttl=4h

./vault read  -field=role_id   auth/approle/role/transit-client/role-id   > role_id
./vault write -f -field=secret_id auth/approle/role/transit-client/secret-id > secret_id
```

> À montrer : `cat role_id` et `cat secret_id` — ce sont les seuls identifiants que le client/proxy aura besoin de connaître.

### 2.2 Écrire la config du proxy

```sh
cat > proxy.hcl <<'EOF'
pid_file = "/Users/louis.lanard/demos/vault2.0/proxy.pid"

vault {
  address = "http://127.0.0.1:8200"
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path   = "/Users/louis.lanard/demos/vault2.0/role_id"
      secret_id_file_path = "/Users/louis.lanard/demos/vault2.0/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = { path = "/Users/louis.lanard/demos/vault2.0/proxy.token" }
  }
}

api_proxy {
  use_auto_auth_token = "force"
}

listener "tcp" {
  address     = "127.0.0.1:8100"
  tls_disable = true
}
EOF
```

**Points à souligner en démo** :
- `auto_auth` → le proxy s'authentifie seul et renouvelle le token en continu.
- `use_auto_auth_token = "force"` → le proxy **remplace systématiquement** tout token envoyé par le client (même vide). Sans `"force"`, le CLI Vault envoie un header vide que le proxy respecterait → `403`.
- `listener` → port local écouté par les applis.
- Le sink `proxy.token` est facultatif, juste pratique pour observer.

### 2.3 Lancer le proxy

```sh
VAULT_ADDR=http://127.0.0.1:8200 ./vault proxy -config=proxy.hcl > proxy.log 2>&1 &
sleep 1
tail -5 proxy.log       # "authentication successful, sending token to sinks"
```

### 2.4 Démontrer : client **sans** token

```sh
unset VAULT_TOKEN
export VAULT_ADDR=http://127.0.0.1:8100      # on parle au proxy, plus à Vault

# (a) encrypt transit "classique" via curl, aucun header auth
PT=$(echo -n "Coucou via Vault Proxy, sans token !" | base64)
curl -s -X POST --data "{\"plaintext\":\"$PT\"}" \
     http://127.0.0.1:8100/v1/transit/encrypt/kek | jq

# (b) envelope encrypt/decrypt avec le CLI, toujours sans token
echo "fichier via proxy" > via_proxy.txt
./vault transit envelope encrypt transit/keys/kek via_proxy.txt
./vault transit envelope header  via_proxy.txt.vee

mv via_proxy.txt via_proxy.txt.orig
./vault transit envelope decrypt transit/keys/kek via_proxy.txt.vee
diff -q via_proxy.txt via_proxy.txt.orig && echo "OK : envelope via proxy, sans token côté client"
```

### 2.5 Preuve que c'est bien le proxy qui injecte le token

```sh
# même requête, en tapant directement Vault (127.0.0.1:8200) sans token → 403
curl -s -X POST --data "{\"plaintext\":\"$PT\"}" \
     http://127.0.0.1:8200/v1/transit/encrypt/kek
# → {"errors":["missing client token"]}
```

### Cleanup de la démo 2

```sh
pkill -f "vault proxy -config"
rm -f proxy.hcl proxy.log proxy.pid proxy.token \
      role_id secret_id \
      via_proxy.txt via_proxy.txt.orig via_proxy.txt.vee

export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN="$ROOT_TOKEN"   # racine Vault, ex. $(jq -r .root_token init.json)
./vault auth disable approle
./vault policy delete transit-client
```

---

## Cleanup complet (fin de démo)

```sh
# arrêter le proxy s'il tourne encore
pkill -f "vault proxy -config" 2>/dev/null

# nettoyage des artefacts générés par les démos
rm -f secret.txt secret.txt.orig secret.txt.vee \
      via_proxy.txt via_proxy.txt.orig via_proxy.txt.vee \
      proxy.hcl proxy.log proxy.pid proxy.token \
      role_id secret_id

# reset Vault dans l'état initial (transit désactivé, pas d'approle, pas de policy custom)
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN="$ROOT_TOKEN"   # racine Vault, ex. $(jq -r .root_token init.json)
./vault secrets disable transit       2>/dev/null
./vault auth disable approle          2>/dev/null
./vault policy delete transit-client  2>/dev/null
```

> Pour arrêter complètement Vault : `pkill -f "vault server -config"`. Les données raft restent dans `./raft/` (relancer reprend l'état).

---

## Rappel des messages clés

| Point | Démo 1 | Démo 2 |
|---|---|---|
| Qui chiffre la donnée ? | Le client, localement (AES-GCM sur une DEK fraîche) | Idem |
| Qui voit le plaintext ? | Jamais Vault | Jamais Vault, jamais le proxy |
| Qui gère le token ? | L'utilisateur (`VAULT_TOKEN=...`) | **Le proxy**, en auto-auth AppRole |
| Taille max du fichier | Pas de limite pratique (stream) | Idem |
| Rotation KEK | Instantanée, anciens `.vee` toujours lisibles | Idem |
