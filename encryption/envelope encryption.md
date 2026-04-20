# Démo Vault Enterprise 2.0 — Transit envelope encryption

Démo courte : envelope encryption côté client via la sous-commande CLI `vault transit envelope`.

Toutes les commandes s'exécutent depuis `~/demos/vault2.0/`.

---

## Prérequis

### Démarrer Vault Enterprise

```sh
cd ~/demos/vault2.0/

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

## Démo — Envelope encryption via CLI

objective : `vault transit envelope` permet de chiffrer des fichiers de taille arbitraire **côté client**. La donnée en clair ne transite **jamais** vers Vault. Seule une petite clé de chiffrement éphémère (DEK) est envoyée à Vault pour être wrappée par la KEK.

### 1. Activer le moteur Transit et créer une KEK

```sh
./vault secrets enable transit
./vault write -f transit/keys/kek type=aes256-gcm96
```

### 2. Préparer un fichier à chiffrer

```sh
cat > secret.txt <<'EOF'
Hello from Vault Enterprise 2.0 envelope encryption!
Ce fichier va être chiffré côté client avec une DEK.
La DEK elle-même est wrappée par la KEK transit 'kek'.
EOF
```

### 3. Chiffrer en envelope

```sh
./vault transit envelope encrypt transit/keys/kek secret.txt
ls -l secret.txt secret.txt.vee
```

> Produit `secret.txt.vee`. Format = header + EDK (DEK wrappée) + ciphertext + tag GCM.

### 4. Inspecter l'en-tête (sans déchiffrer)

```sh
./vault transit envelope header secret.txt.vee
```

Affiche `algorithm=OAE2-AES256-GCM96-HKDF`, la clé utilisée (`kek` v1, mount `transit/`), la taille d'origine, la date. **Aucun contenu sensible.**

### 5. Déchiffrer et vérifier le round-trip

```sh
mv secret.txt secret.txt.orig
./vault transit envelope decrypt transit/keys/kek secret.txt.vee
diff -q secret.txt secret.txt.orig && echo "OK : roundtrip identique"
cat secret.txt
```

### 6. (Bonus) Rotation de KEK — les anciens `.vee` restent lisibles

```sh
./vault write -f transit/keys/kek/rotate
./vault read transit/keys/kek | grep latest_version       # passe à 2
./vault transit envelope decrypt transit/keys/kek secret.txt.vee -o -    # OK grâce au key_version du header
```

---

## Cleanup (fin de démo)

```sh
# nettoyage des artefacts générés par la démo
rm -f secret.txt secret.txt.orig secret.txt.vee

# reset Vault dans l'état initial (transit désactivé)
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN="$ROOT_TOKEN"   # racine Vault, ex. $(jq -r .root_token init.json)
./vault secrets disable transit 2>/dev/null
```

> Pour arrêter complètement Vault : `pkill -f "vault server -config"`. Les données raft restent dans `./raft/` (relancer reprend l'état).

---

## Rappel des messages clés

| Point | Détail |
|---|---|
| Qui chiffre la donnée ? | Le client, localement (AES-GCM sur une DEK fraîche) |
| Qui voit le plaintext ? | Jamais Vault |
| Qui gère le token ? | L'utilisateur (`VAULT_TOKEN=...`) |
| Taille max du fichier | Pas de limite pratique (stream) |
| Rotation KEK | Instantanée, anciens `.vee` toujours lisibles |
