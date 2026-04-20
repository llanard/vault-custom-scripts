# Monthly HSM Key Rotation — Transit + Managed Keys

Procedure for rotating an HSM-resident keypair that backs a Vault Transit
signing key via the Managed Keys feature. Apps call `transit/sign/<name>`
and never need to know a rotation happened.

## Starting assumption (what you already have)

- HSM exposes a PKCS#11 library and slot, with PIN.
- Vault has a `kms_library "myhsm"` stanza in its config pointing at that `.so`.
- A managed key `hsm-signer-v1` registered at `sys/managed-keys/pkcs11/hsm-signer-v1`.
- A Transit key `payments-signer` of type `managed_key` currently pointing at `hsm-signer-v1`.
- The `transit/` mount has `allowed_managed_keys = ["hsm-signer-v1"]` (will add new ones during rotation).
- Apps call `vault write transit/sign/payments-signer input=...` — they never need to know which version answered.

---

## Step 1. Mint a new keypair in the HSM

Two paths — pick one and stick to it.

### Path A — let Vault ask the HSM to generate it (simpler, audit trail in Vault)

```bash
# Register a new managed key with allow_generate_key=true and a fresh label.
MONTH=$(date +%Y-%m)
vault write sys/managed-keys/pkcs11/hsm-signer-"$MONTH" \
    library=myhsm \
    slot=0 \
    pin="$HSM_PIN" \
    key_label="payments-signer-$MONTH" \
    key_id="payments-signer-$MONTH" \
    mechanism="0x0001"              `# CKM_RSA_PKCS — use 0x0040 for ECDSA` \
    key_bits=3072 \
    allow_generate_key=true         `# tells Vault to create the key in HSM if absent` \
    usages=sign,verify
```

The first `test/sign` call (step 3) triggers HSM keypair creation.

### Path B — create the keypair directly at the HSM, then point Vault at it

```bash
# On an admin host that has HSM PKCS#11 access (not Vault):
pkcs11-tool --module /opt/hsm/lib/libsofthsm2.so \
    --login --pin "$HSM_PIN" --slot 0 \
    --keypairgen --key-type rsa:3072 \
    --label "payments-signer-$MONTH" --id "$(printf '%s' payments-signer-$MONTH | xxd -p)"

# Then register the pre-existing key in Vault (no allow_generate_key).
vault write sys/managed-keys/pkcs11/hsm-signer-"$MONTH" \
    library=myhsm slot=0 pin="$HSM_PIN" \
    key_label="payments-signer-$MONTH" \
    key_id="payments-signer-$MONTH" \
    mechanism="0x0001" key_bits=3072 \
    usages=sign,verify
```

---

## Step 2. Allow Transit to reach the new managed key

Managed keys must be on the mount's allowlist.

```bash
vault secrets tune \
    -allowed-managed-keys="hsm-signer-v1,hsm-signer-$MONTH" \
    transit/
```

Keep the old name in the list until you decommission that version (step 5).

---

## Step 3. Prove the new managed key actually signs

```bash
vault write sys/managed-keys/pkcs11/hsm-signer-"$MONTH"/test/sign \
    hash_algorithm=sha2-256
# returns a signature -> HSM + PKCS#11 + PIN + mechanism are all correct.
```

If you chose Path A, this is also what causes the HSM to generate the key.

---

## Step 4. Rotate the Transit key to the new version

```bash
vault write -f transit/keys/payments-signer/rotate \
    managed_key_name="hsm-signer-$MONTH"
```

After this:

- Transit has a new version `N+1` that routes sign requests to
  `hsm-signer-$MONTH` → HSM.
- Previous versions stay; verify of prior signatures still works.
- Apps calling `vault write transit/sign/payments-signer input=...`
  automatically get the latest version (unless they pin `key_version`).

Verify:

```bash
vault read transit/keys/payments-signer | grep -E 'latest_version|min_decryption_version'
```

---

## Step 5. Retire old versions and the old HSM key

Do this one rotation later, or whenever your retention policy allows.

```bash
# Raise min_decryption_version. Do this only after you are sure no old
# signatures still need verification via that version.
vault write transit/keys/payments-signer/config \
    min_encryption_version=N+1 \
    min_decryption_version=N+1 \
    deletion_allowed=true

vault delete sys/managed-keys/pkcs11/hsm-signer-v1       # removes the Vault reference
# Destroy the key in the HSM with your vendor tool
# (pkcs11-tool --delete-object, vendor CLI, ...).
vault secrets tune -allowed-managed-keys="hsm-signer-$MONTH" transit/
```

---

## Step 6. Automate it monthly

Wrap steps 1–4 in a script, drive it from a monthly CI job or cron on a
Vault admin host. Use a scoped, policy-limited token with only:

```hcl
path "sys/managed-keys/pkcs11/hsm-signer-*"              { capabilities = ["create","update","read","delete"] }
path "sys/managed-keys/pkcs11/hsm-signer-*/test/sign"    { capabilities = ["update"] }
path "sys/mounts/transit/tune"                           { capabilities = ["update"] }
path "transit/keys/payments-signer"                      { capabilities = ["read","update"] }
path "transit/keys/payments-signer/rotate"               { capabilities = ["update"] }
path "transit/keys/payments-signer/config"               { capabilities = ["update"] }
```

Rotation should never require changes on the apps — they keep calling
`transit/sign/payments-signer`. The HSM stays the single source of truth
for the private keys; Vault is the policy / audit / routing layer.

---

## Caveats worth knowing up front

- **Transit verify across versions** only works if you keep the old
  managed-key reference registered until `min_decryption_version`
  advances past it. Delete too early → old signatures become
  unverifiable.
- **`allow_generate_key` scope** — keep it on a dedicated managed-key
  name per month (`hsm-signer-YYYY-MM`). Don't leave it set on
  long-lived names.
- **HSM PIN in requests** — the PIN is in every managed-key create
  payload. Put the script on a hardened host, pull PIN from an auth'd
  Vault KV (`kv/hsm/pin`) or the OS keychain, not a plaintext file.
- **Mechanism hex** — `0x0001` = `CKM_RSA_PKCS`,
  `0x0040` = `CKM_ECDSA`. Match to the key type you're minting.
