# Rotating KMIP Master Keys Consumed by Database Clients

How rotation works when a database (MongoDB, Percona, MariaDB, Oracle
TDE, SQL Server EKM, Cassandra, …) uses Vault's KMIP secrets engine as
its external key manager.

## Vault-specific constraint to know up front

Vault's KMIP engine **does not implement the KMIP `Rekey` or
`Rekey Key Pair` operations**. It supports `Activate`, `Revoke`, and
`Destroy` as lifecycle primitives, but not `Rekey`. This matters
because `Rekey` is the KMIP-spec-native way to rotate a key while
keeping the successor/predecessor link — and it's off the table for
Vault.

As a result, "rotation" against Vault KMIP is not a single atomic
operation. It's a short sequence of smaller KMIP ops issued by the
database's client library.

## Architecture every major DB converges on

```
┌─────────────────────┐            ┌──────────────────────────┐
│  Vault KMIP engine  │            │  Database                │
│                     │   KMIP     │                          │
│  ┌─────────────┐    │───────────▶│  master-key-id stored in │
│  │ master key  │    │   5696     │  DB system catalog       │
│  │ (AES-256)   │    │            │                          │
│  └─────────────┘    │            │  DEKs (one per table /   │
│                     │            │  tablespace / DB), each  │
│                     │            │  wrapped by master key   │
│                     │            │  and stored IN the DB    │
└─────────────────────┘            └──────────────────────────┘
```

- Bulk table data is encrypted by DEKs.
- DEKs never leave the DB; they are wrapped by the master key.
- The master key never leaves Vault.
- At boot, the DB authenticates to Vault via KMIP client cert, calls
  `Get` on its master key, uses it to unwrap the DEKs, and runs.

Rotation in this model means: rotate the **master key** (cheap),
re-wrap all DEKs under the new master key (fast — DEKs are few and
tiny), leave the bulk ciphertext on disk alone.

## Step-by-step, from the KMIP wire

Because `Rekey` is unavailable on Vault, the DB's KMIP client
implements rotation as:

```
1. Create            → Vault returns a new master-key UUID
2. Activate          → new master key state goes to "Active"
3. Get (new key)     → DB gets the raw key material to do local
                        unwrap/rewrap. (Or: DB calls KMIP Encrypt/
                        Decrypt and never sees the key material —
                        depends on vendor.)
4. <DB rewraps all DEKs locally with the new master key>
5. <DB persists the new master-key UUID in its own config/catalog>
6. Revoke (old key)  → old master key state goes to "Deactivated".
                        Still Get-able so existing backups keep
                        working.
7. <retention window — days to years, per backup policy>
8. Destroy (old key) → object is gone, cannot be recovered
```

Step 1 is where `Rekey` would normally bundle "create new + link to
old" into one call. Without `Rekey`, step 1 is just `Create` and there
is no built-in link between old and new keys. Most DB vendors do not
rely on the Link attribute anyway — they track the current master-key
ID in their own metadata — so this is a non-issue in practice.

## How each major DB actually triggers this

You do not write these KMIP ops yourself. You run a DB admin command
and the DB's KMIP client library produces the sequence above:

| Database | Command | Notes |
|---|---|---|
| MongoDB Enterprise | `db.adminCommand({rotateMasterKey: 1})` | Creates a new master key, re-wraps DEKs, activates the new one. Old one stays in Vault until `destroyMasterKey`. |
| Percona Server / MySQL | `ALTER INSTANCE ROTATE INNODB MASTER KEY` | Pure master-key rotation. Keyring-KMIP plugin translates to KMIP `Create` against Vault. |
| MariaDB | `ALTER INSTANCE ROTATE INNODB MASTER KEY` | Same pattern as Percona via the KMIP keyring plugin. |
| Oracle TDE (external KMIP KMS) | `ADMINISTER KEY MANAGEMENT USE KEY …` / `SET KEY …` | More involved; Oracle's wallet abstraction sits in front of KMIP. Master-key rotation = new KMIP key + re-encrypt TDE master-key references. |
| SQL Server EKM | `ALTER CRYPTOGRAPHIC PROVIDER` + `ALTER ASYMMETRIC KEY` | EKM provider wraps KMIP; rotation is provider-specific. |
| Cassandra / ScyllaDB (KMIP KMS) | Config change + restart, or `nodetool` / vendor-specific helper | Each node re-wraps local DEKs against the new master key. |

## Vault-side prerequisites

1. The DB's KMIP role must include the operations it needs:
   - `operation_create`
   - `operation_activate`
   - `operation_get`
   - `operation_encrypt`
   - `operation_decrypt`
   - `operation_revoke`
   - `operation_destroy`

   If you set `operation_all = true`, they are all there. For a prod
   role, be selective.

2. `default_tls_client_ttl` long enough that the DB's KMIP connection
   does not expire mid-rotation, or set up a renew mechanism.
   Databases typically hold a long-lived KMIP connection.

From the engine's perspective, Vault is passive — it receives
`Create` → `Activate` → `Revoke` → `Destroy` calls and executes them.

## Operational constraints you have to reason about

1. **The old master key must stay accessible until every DEK wrapped
   by it has been re-wrapped under the new one.** Any DB backup taken
   before rotation was encrypted with DEKs wrapped by the
   pre-rotation master key. If you restore that backup, the DB's
   boot-time `Get` will be for the old key ID, not the new one.

   **Rule:** do not `Destroy` the old master key until every
   restorable backup has either been re-taken after rotation, or you
   have accepted losing the ability to restore from older backups.
   Most deployments keep `Revoked` (deactivated) old keys for the
   full backup retention window.

2. **Rotation is fast; do not confuse it with re-encryption.**
   `rotateMasterKey` returns in seconds — it's a handful of KMIP
   calls plus a rewrite of the DEK blobs (a few KB). The bulk data on
   disk is untouched. If you ever need to re-encrypt bulk data
   (because a DEK leaked, not the master key), that is a full
   `ALTER TABLE` rebuild, not a KMIP concern.

3. **Retention math.** Monthly rotation + 90-day backup retention =
   three co-existing master keys in Vault at any time (current + last
   month + two months ago). One-year retention = 13 keys. Plan your
   scope's key-count budget accordingly. On a Vault Raft cluster this
   is trivial; on HSM-backed seal-wrap with tight partition quotas,
   less so.

4. **Every DB does the re-wrap step differently.** MongoDB re-wraps
   synchronously during `rotateMasterKey` — you wait ~1s per DEK.
   Percona MySQL rotates one master key that wraps per-table keys;
   master-key rotation is near-instant but full re-key of the
   underlying table keys (`ALTER INSTANCE ROTATE INNODB TABLESPACE
   KEY`) is per-tablespace and much slower. Read your DB's docs for
   what "rotation" actually touches.

5. **Automate on the DB side, monitor on both.** Put the DB's
   rotation command on a monthly job (DB cron / operator CRD /
   Ansible). Add two monitors:
   - **Vault-side**: `LIST /kmip/scope/<scope>` count of keys in the
     Active state should be exactly one per DB. Drift triggers an
     alert.
   - **DB-side**: every DB should report the age of its current
     master key; alert if it exceeds the rotation period.

## Summary

Rotation of Vault-KMIP-backed master keys used by a database **is a
database-side procedure**. Vault is passive — it answers `Create` /
`Activate` / `Get` / `Revoke` / `Destroy` and that is all it needs to
do.

The absence of `Rekey` in Vault's KMIP implementation does not block
you, because no mainstream DB integration depends on `Rekey` — they
all drive rotation through `Create` + `Revoke` and track successor
state in their own catalog.

Your operational work is:

1. Provision the right KMIP role operations.
2. Schedule the DB's rotation command.
3. Respect the old-key retention window against your backup window.
