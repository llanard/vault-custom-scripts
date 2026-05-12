# Procédure de test de résilience — Plateforme HashiCorp Vault Enterprise

**Haute disponibilité (Raft) et Disaster Recovery Replication**

*Procès-verbal de recette*

| Champ | Valeur |
|---|---|
| Référence | VAULT-RES-PV-001 |
| Version | 1.0 |
| Date | __ / __ / 2026 |
| Statut | Pour exécution |
| Classification | Confidentiel — Usage client |
| Émetteur | IBM France — HashiCorp Solutions |

---

## Sommaire

1. [Suivi du document](#1-suivi-du-document)
2. [Objet et portée](#2-objet-et-portée)
3. [Rappel d'architecture](#3-rappel-darchitecture)
4. [Prérequis et conditions de réalisation](#4-prérequis-et-conditions-de-réalisation)
5. [Scénarios de test — Haute disponibilité](#5-scénarios-de-test--haute-disponibilité-cluster-raft)
6. [Scénarios de test — Disaster Recovery Replication](#6-scénarios-de-test--disaster-recovery-replication)
7. [Scénarios de test — Résilience applicative](#7-scénarios-de-test--résilience-applicative)
8. [Mesures, métriques et reporting](#8-mesures-métriques-et-reporting)
9. [Grille de procès-verbal](#9-grille-de-procès-verbal)
10. [Annexes](#10-annexes)

---

## 1. Suivi du document

### 1.1 Historique des versions

| Version | Date | Auteur | Description |
|---|---|---|---|
| 1.0 | __/__/2026 | IBM France | Création initiale |
| | | | |

### 1.2 Validation

| Rôle | Nom | Entité | Signature / Date |
|---|---|---|---|
| Responsable plateforme Vault | | Client | |
| RSSI / Sécurité | | Client | |
| Architecte solution | | IBM France | |
| Pilote de recette | | IBM France | |

---

## 2. Objet et portée

### 2.1 Objet du document

Le présent document décrit la procédure formelle de validation de la résilience de la plateforme HashiCorp Vault Enterprise déployée dans le cadre du projet. Il a pour objectif de prouver, par l'exécution de scénarios de défaillance contrôlés, que la plateforme respecte les engagements de continuité et de reprise d'activité contractuels.

Ce document constitue le procès-verbal de recette de la couche de résilience. Sa signature engage le client et IBM France sur la conformité du dispositif tel que livré.

### 2.2 Périmètre couvert

La procédure couvre les deux dimensions de résilience opérationnelles de la plateforme :

- **Haute disponibilité intra-site** : cluster Vault Enterprise utilisant le backend de stockage intégré Raft, avec tolérance aux pannes de nœuds individuels et bascule automatique du leader.
- **Continuité d'activité inter-sites** : Disaster Recovery Replication entre un cluster primaire (site nominal) et un cluster secondaire (site de repli), avec promotion contrôlée du cluster DR en cas de sinistre majeur.

La procédure valide également la résilience des intégrations applicatives consommatrices :

- Applications Spring Boot utilisant Spring Vault (renouvellement de baux, reconnexion automatique).
- Charges de travail Kubernetes consommant des secrets via Vault Secrets Operator ou Vault Agent Injector.
- Workflows Vault Agent (sidecar et standalone) avec template rendering et auto-auth.
- Moteurs de secrets dynamiques : Database (PostgreSQL, Oracle, MSSQL) et AWS (IAM users, STS).

### 2.3 Hors périmètre

- Tests de performance et de montée en charge (couverts par une procédure distincte).
- Tests de sécurité applicative et de durcissement (couverts par l'audit ANSSI / pentest).
- Performance Replication multi-régions (non déployée à ce stade).
- Bascule de l'auto-unseal et du HSM (à valider via la procédure dédiée HSM si applicable).

---

## 3. Rappel d'architecture

### 3.1 Topologie cible

La plateforme est composée de deux clusters Vault Enterprise distincts, déployés sur deux datacenters géographiquement séparés.

| Élément | Cluster primaire (PRIMARY) | Cluster DR (SECONDARY) |
|---|---|---|
| **Rôle** | Production active | Disaster Recovery passif |
| **Site** | DC1 (nominal) | DC2 (repli) |
| **Nœuds Vault** | 3 nœuds (1 leader + 2 followers) | 3 nœuds (1 leader + 2 followers) |
| **Backend stockage** | Integrated Storage (Raft) | Integrated Storage (Raft) |
| **Quorum Raft** | 2/3 nœuds | 2/3 nœuds |
| **Réplication** | Émetteur DR | Récepteur DR |
| **Accès client** | Lecture/écriture | Refus (sauf token de batch DR) |

### 3.2 Engagements de service

| Indicateur | Cible | Mesure |
|---|---|---|
| **RTO bascule intra-cluster** | < 30 s | Délai entre arrêt du leader et reprise du service en écriture |
| **RTO bascule DR** | < 15 min | Délai entre déclenchement bascule et service nominal sur DC2 |
| **RPO DR** | < 5 s | Lag de réplication observé en régime nominal (métrique Vault) |
| **Disponibilité plateforme** | 99,95 % | Mesurée sur cycles glissants de 30 jours |

---

## 4. Prérequis et conditions de réalisation

### 4.1 Prérequis techniques

- Plateforme Vault Enterprise installée, configurée et opérationnelle sur les deux clusters.
- Disaster Recovery Replication activée : le cluster DR est en statut `stream-wals` (état nominal de réception).
- Au moins un secondary token DR valide est généré et stocké de manière sécurisée (coffre matériel ou processus break-glass défini).
- Accès SSH administrateur disponible sur l'ensemble des nœuds Vault des deux clusters.
- Accès console / CLI Vault avec un token root ou un token disposant des policies d'administration.
- Endpoint de monitoring `/sys/health` et `/sys/replication/dr/status` accessibles depuis l'orchestrateur de tests.
- Au moins une application Spring Boot de test (avec Spring Vault) déployée et fonctionnelle.
- Au moins un namespace Kubernetes de test avec Vault Secrets Operator ou Vault Agent Injector configuré.
- Moteurs de secrets dynamiques Database et AWS configurés avec des roles de test.

### 4.2 Prérequis organisationnels

- Fenêtre de maintenance planifiée et validée par le comité de pilotage.
- Notification préalable aux équipes applicatives consommatrices de Vault (préavis ≥ 5 jours ouvrés).
- Procédure de rollback documentée et validée par le RSSI.
- Cellule de crise virtuelle armée pendant toute la durée des tests (canal Teams/Slack dédié).
- Sauvegarde Raft complète (snapshot) réalisée et vérifiée moins de 4 heures avant le démarrage des tests.

### 4.3 Outils et instrumentation

- `vault` CLI version alignée avec la version serveur (cohérence des API).
- Script de monitoring continu de `/sys/health` (probe HTTP toutes les secondes pour mesurer le RTO).
- Outil de génération de charge applicative légère (k6, vegeta ou équivalent) pour mesurer l'impact côté applicatif.
- Accès aux logs Vault (audit device file) et aux logs applicatifs des consommateurs de test.
- Tableau de bord Prometheus/Grafana avec les métriques `vault_core_unsealed`, `vault_wal_*`, `vault_replication_*`.

### 4.4 Critères d'arrêt (kill switch)

Les tests sont immédiatement interrompus et la procédure de rollback déclenchée en cas de :

- Perte simultanée du quorum sur les deux clusters.
- Corruption détectée du journal Raft (`vault operator raft autopilot state` non recoverable).
- Impossibilité de restaurer le snapshot Raft de référence.
- Indisponibilité du HSM bloquant l'unseal automatique (si applicable au déploiement).

---

## 5. Scénarios de test — Haute disponibilité (cluster Raft)

Cette série de scénarios valide la résilience intra-site du cluster primaire. Tous les tests sont exécutés sur le cluster PRIMARY pendant que la réplication DR est active.

### Scénario HA-01 — Arrêt gracieux du leader Raft

| Champ | Valeur |
|---|---|
| **Objectif** | Vérifier la bascule automatique du leadership en moins de 30 secondes lors d'un arrêt contrôlé du nœud leader. |
| **Périmètre** | Cluster PRIMARY — nœud leader courant |
| **Criticité** | 🔴 **Critique** |
| **RTO cible** | < 30 secondes |
| **RPO cible** | 0 (aucune perte attendue) |

**Prérequis**
- Cluster en état nominal, 3 nœuds Healthy, leader identifié via `vault operator raft list-peers`
- Probe de monitoring active sur `/sys/health`
- Charge de fond constante (10 req/s en écriture sur un KV de test)

**Étapes d'exécution**
1. Identifier le leader courant : `vault operator raft list-peers`
2. Démarrer la mesure de temps (T0) et la capture des logs
3. Arrêter proprement le service Vault sur le leader : `systemctl stop vault`
4. Mesurer le délai jusqu'à élection du nouveau leader (logs : `entering leader state`)
5. Vérifier la reprise du service côté client (probe `/sys/health` = 200)
6. Mesurer le nombre de requêtes en erreur 5xx pendant la bascule
7. Redémarrer le nœud arrêté : `systemctl start vault`
8. Vérifier que le nœud rejoint le cluster en tant que follower

**Résultat attendu**
- Élection d'un nouveau leader en moins de 10 secondes
- Reprise complète du service en écriture en moins de 30 secondes
- Aucune perte de données (les écritures committées avant T0 sont préservées)
- Le nœud redémarré se resynchronise et rejoint le cluster sans intervention
- Statut final : 3/3 nœuds Healthy, leader stable

**Impact applicatif** — Brève interruption d'écriture (~5-15 s). Les lectures peuvent être redirigées via header `X-Vault-Forward`. Les baux existants ne sont pas affectés.

---

### Scénario HA-02 — Crash brutal du leader (kill -9)

| Champ | Valeur |
|---|---|
| **Objectif** | Valider la détection de perte de leader par timeout de heartbeat et la bascule en condition non gracieuse. |
| **Périmètre** | Cluster PRIMARY — nœud leader courant |
| **Criticité** | 🔴 **Critique** |
| **RTO cible** | < 30 secondes |
| **RPO cible** | 0 (les écritures committées sont préservées) |

**Prérequis**
- Mêmes conditions que HA-01
- Cluster revenu en état nominal post-HA-01

**Étapes d'exécution**
1. Identifier le leader courant
2. Démarrer la mesure de temps et le monitoring
3. Tuer brutalement le processus : `kill -9 $(pgrep vault)`
4. Mesurer le délai d'élection du nouveau leader
5. Mesurer le nombre de requêtes en erreur pendant la bascule
6. Inspecter les logs pour vérifier la cause de bascule (heartbeat timeout)
7. Redémarrer Vault sur le nœud abattu
8. Vérifier la resynchronisation du nœud

**Résultat attendu**
- Détection de perte de leader par expiration du heartbeat (~5-10 s selon `HEARTBEAT_TIMEOUT`)
- Élection d'un nouveau leader et reprise du service en moins de 30 secondes
- Pas de corruption du journal Raft
- Le nœud abattu rattrape son retard via snapshot ou log shipping sans intervention manuelle

**Impact applicatif** — Interruption d'écriture légèrement plus longue qu'en HA-01 (le temps du timeout). Possibles erreurs transitoires côté Spring Vault — vérifier le retry automatique.

---

### Scénario HA-03 — Perte d'un nœud follower

| Champ | Valeur |
|---|---|
| **Objectif** | Vérifier que la perte d'un seul follower n'affecte pas le service (quorum conservé 2/3). |
| **Périmètre** | Cluster PRIMARY — un nœud follower |
| **Criticité** | 🟢 **Mineure** |
| **RTO cible** | 0 (aucune interruption) |
| **RPO cible** | 0 |

**Prérequis**
- Cluster en état nominal, 3 nœuds Healthy

**Étapes d'exécution**
1. Identifier un nœud follower
2. Arrêter le service Vault sur ce nœud : `systemctl stop vault`
3. Vérifier sur le leader : `vault operator raft list-peers` (le nœud doit apparaître unhealthy après ~1 min)
4. Continuer la charge applicative pendant 10 minutes
5. Redémarrer le nœud
6. Vérifier le rattrapage (`vault operator raft autopilot state`)

**Résultat attendu**
- Aucune interruption de service
- Aucune erreur applicative observée
- Le quorum reste maintenu (2/3)
- Le nœud redémarré rejoint le cluster et redevient Healthy en moins de 2 minutes

**Impact applicatif** — Aucun. Cas nominal de tolérance aux pannes.

---

### Scénario HA-04 — Perte simultanée de deux nœuds (perte de quorum)

| Champ | Valeur |
|---|---|
| **Objectif** | Valider le comportement attendu en perte de quorum : indisponibilité totale du cluster, puis recovery via opérateur. |
| **Périmètre** | Cluster PRIMARY — 2 nœuds sur 3 |
| **Criticité** | 🔴 **Critique** |
| **RTO cible** | Recovery manuel (procédure documentée) |
| **RPO cible** | 0 si le nœud restant est à jour |

**Prérequis**
- Cluster en état nominal
- Procédure de `raft peers.json` recovery validée et accessible
- Snapshot Raft récent disponible

**Étapes d'exécution**
1. Arrêter simultanément deux nœuds (un follower puis le leader, à 5 secondes d'intervalle)
2. Constater l'indisponibilité du cluster (toutes les requêtes en échec)
3. Tenter le redémarrage à chaud d'un des deux nœuds arrêtés
4. Si recovery automatique impossible, appliquer la procédure `peers.json` sur le nœud survivant
5. Vérifier la reprise du service après recovery
6. Redémarrer les nœuds restants et les faire rejoindre

**Résultat attendu**
- Indisponibilité totale du cluster pendant la perte de quorum (comportement attendu et documenté)
- Recovery réussi via la procédure documentée en moins de 30 minutes
- Aucune perte de données committed
- Documentation de la procédure exécutée précisément (input pour le runbook client)

**Impact applicatif** — Indisponibilité totale du PRIMARY. Les applications doivent basculer en mode dégradé (cache local de secrets si configuré) ou échouer proprement (circuit breaker). Cas typique justifiant la bascule DR — voir scénario DR-01.

---

### Scénario HA-05 — Partition réseau entre nœuds (split-brain test)

| Champ | Valeur |
|---|---|
| **Objectif** | Vérifier qu'aucun split-brain n'est possible et que le côté minoritaire devient unavailable. |
| **Périmètre** | Cluster PRIMARY |
| **Criticité** | 🟠 **Majeure** |
| **RTO cible** | < 60 secondes après réparation réseau |
| **RPO cible** | 0 |

**Prérequis**
- Accès `iptables` ou équivalent (NSX, sécurité réseau) pour simuler la partition
- Cluster en état nominal

**Étapes d'exécution**
1. Identifier le leader
2. Isoler le leader des deux followers via règles `iptables` (DROP des paquets sur le port cluster 8201)
3. Observer côté followers : élection d'un nouveau leader (2 nœuds en quorum)
4. Observer côté leader isolé : il doit perdre son statut de leader (downgrade en follower ou unavailable)
5. Tenter des écritures sur le leader isolé : doivent échouer
6. Lever les règles `iptables`
7. Vérifier le retour à un cluster cohérent à 3 nœuds

**Résultat attendu**
- Le côté majoritaire (2 nœuds) élit un nouveau leader et reste opérationnel
- Le côté minoritaire (ancien leader isolé) refuse les écritures (pas de split-brain)
- Aucune divergence de données après réconciliation
- Le cluster revient à un état cohérent 3/3 après suppression des règles `iptables`

**Impact applicatif** — Côté majoritaire : bascule transparente. Côté minoritaire : refus des requêtes (les applications doivent retry et être redirigées via le load balancer).

---

## 6. Scénarios de test — Disaster Recovery Replication

Cette série valide la bascule contrôlée entre cluster PRIMARY et cluster DR. La promotion du DR est une opération destructive du point de vue de la topologie de réplication : elle doit être exécutée selon une procédure strictement définie.

### Scénario DR-01 — Bascule planifiée DR (promotion contrôlée)

| Champ | Valeur |
|---|---|
| **Objectif** | Valider la promotion du cluster DR en cluster primaire dans des conditions contrôlées (exercice de continuité). |
| **Périmètre** | Clusters PRIMARY et DR |
| **Criticité** | 🔴 **Critique** |
| **RTO cible** | < 15 minutes |
| **RPO cible** | < 5 secondes (état nominal de réplication) |

**Prérequis**
- Réplication DR en état `stream-wals` confirmé via `vault read sys/replication/dr/status`
- Lag de réplication < 5 secondes
- DNS / load balancer prêt à rediriger les clients vers le cluster DR (TTL court ou bascule manuelle préparée)
- Secondary token DR valide accessible

**Étapes d'exécution**
1. **T-15 min** : annoncer le début de la bascule sur le canal de crise
2. **T-10 min** : capturer le statut de réplication source et destination
3. **T-5 min** : générer un DR operation token sur le cluster DR (procédure unseal/recovery key threshold)
4. **T0** : arrêter le cluster PRIMARY (simuler la perte de DC1) — `systemctl stop vault` sur les 3 nœuds
5. **T0+1min** : promouvoir le cluster DR : `vault write -f sys/replication/dr/secondary/promote dr_operation_token=...`
6. **T0+2min** : vérifier que le DR accepte les écritures (`vault status`, `vault write sys/policy/test`)
7. **T0+3min** : basculer le DNS / VIP applicatif vers le cluster DR
8. **T0+5min** : vérifier la reconnexion des applications (Spring Vault, Vault Agent, VSO)
9. **T0+10min** : exécuter la batterie de tests fonctionnels minimaux (lecture/écriture KV, génération de credentials dynamiques)
10. Documenter le moment exact de reprise du service nominal

**Résultat attendu**
- Promotion réussie du cluster DR en moins de 5 minutes
- Service applicatif nominal restauré en moins de 15 minutes
- Aucune perte de données committed avant T0 (sous réserve d'un lag de réplication < RPO)
- Les applications Spring Vault renouvellent leur token via leur auth method configurée
- Les pods Kubernetes consommateurs reçoivent les secrets via le nouveau cluster
- Les credentials dynamiques DB et AWS restent valides jusqu'à leur expiration naturelle, puis sont renouvelés sur le nouveau primary

**Impact applicatif** — Interruption complète du service Vault pendant la fenêtre de bascule. Les baux dynamiques émis avant la bascule restent valides côté ressource cible (DB, AWS) jusqu'à leur expiration TTL — l'application peut continuer à les utiliser pendant la bascule. Les nouvelles demandes de credentials sont en attente jusqu'à promotion effective.

---

### Scénario DR-02 — Reconstruction du cluster initial en secondary DR

| Champ | Valeur |
|---|---|
| **Objectif** | Après une bascule, reconfigurer l'ancien primary en secondary DR pour rétablir la topologie de réplication. |
| **Périmètre** | Ancien cluster PRIMARY (à reconstruire) + nouveau primary (ex-DR) |
| **Criticité** | 🟠 **Majeure** |
| **RTO cible** | < 2 heures (selon volume de données) |
| **RPO cible** | N/A |

**Prérequis**
- Bascule DR-01 effectuée avec succès
- Cluster ex-PRIMARY redémarré et techniquement opérationnel
- Accès administrateur sur les deux clusters

**Étapes d'exécution**
1. Sur le nouveau primary (ex-DR) : activer le mode primary pour la réplication DR : `vault write -f sys/replication/dr/primary/enable`
2. Générer un secondary token sur le nouveau primary
3. Sur l'ancien primary : disable son rôle primary, puis enable comme secondary avec le token généré
4. Suivre la resynchronisation (statut `stream-wals`) via `sys/replication/dr/status`
5. Vérifier le rattrapage complet (lag à 0)
6. Tester en lecture sur l'ancien primary devenu secondary (doit refuser les écritures)

**Résultat attendu**
- Resynchronisation complète sans intervention manuelle au-delà des commandes d'enable
- Topologie inverse opérationnelle : ex-DR = primary, ex-PRIMARY = DR
- Lag de réplication revenu < 5 secondes
- Réplication stable observée pendant 30 minutes minimum

**Impact applicatif** — Aucun impact applicatif si la bascule DNS pointe correctement sur le nouveau primary. Charge réseau temporaire pendant la resynchronisation initiale (proportionnelle au volume de WALs / au snapshot).

---

### Scénario DR-03 — Bascule de retour vers le site nominal (failback)

| Champ | Valeur |
|---|---|
| **Objectif** | Repromouvoir le cluster d'origine (DC1) en primary après réparation, dans une fenêtre planifiée. |
| **Périmètre** | Les deux clusters |
| **Criticité** | 🟠 **Majeure** |
| **RTO cible** | < 15 minutes |
| **RPO cible** | < 5 secondes |

**Prérequis**
- Topologie DR-02 stable depuis au moins 24 heures
- Fenêtre de maintenance planifiée

**Étapes d'exécution**
1. Réappliquer la procédure DR-01 dans le sens inverse (promotion du cluster DC1)
2. Reconstituer le cluster DC2 comme secondary (procédure DR-02 inverse)
3. Basculer le DNS / VIP vers DC1
4. Vérifier la stabilité applicative pendant 1 heure

**Résultat attendu**
- Retour à la topologie nominale en moins de 15 minutes
- Aucune perte de données
- Toutes les intégrations applicatives fonctionnelles

**Impact applicatif** — Identique à DR-01.

---

### Scénario DR-04 — Mesure du lag de réplication sous charge

| Champ | Valeur |
|---|---|
| **Objectif** | Quantifier le RPO réel sous charge nominale et sous pic de charge. |
| **Périmètre** | Réplication DR |
| **Criticité** | 🟢 **Mineure** |
| **RTO cible** | N/A |
| **RPO cible** | Mesure |

**Prérequis**
- Outil de génération de charge configuré
- Métriques `vault_replication_wal_last_index` et `vault_replication_dr_state.last_wal` disponibles

**Étapes d'exécution**
1. Mesurer le lag en régime nominal pendant 30 minutes
2. Appliquer une charge constante (100 écritures/s) pendant 15 minutes — mesurer le lag
3. Appliquer un pic de charge (500 écritures/s) pendant 5 minutes — mesurer le lag
4. Revenir à la charge nominale et mesurer le retour à l'équilibre

**Résultat attendu**
- Lag nominal < 1 seconde
- Lag sous charge constante < 5 secondes (cible RPO)
- Lag sous pic de charge < 30 secondes
- Retour à l'équilibre en moins de 2 minutes après la fin du pic

**Impact applicatif** — Aucun impact applicatif sur le primary (réplication asynchrone). Risque de perte de données = lag observé au moment de la bascule.

---

### Scénario DR-05 — Perte du secondary token DR — régénération

| Champ | Valeur |
|---|---|
| **Objectif** | Valider la procédure de régénération d'un secondary token DR en cas de perte. |
| **Périmètre** | Cluster PRIMARY |
| **Criticité** | 🟢 **Mineure** |
| **RTO cible** | N/A |
| **RPO cible** | N/A |

**Prérequis**
- Quorum d'unseal keys disponible (threshold)
- Accès administrateur sur le primary

**Étapes d'exécution**
1. Initier la génération d'un nouveau secondary token : `vault write -f sys/replication/dr/primary/secondary-token id=...`
2. Le valider en simulant l'enrôlement d'un secondary de test
3. Stocker le token selon la procédure de gestion des secrets de break-glass

**Résultat attendu**
- Génération réussie d'un token utilisable
- Le secondary de test parvient à initier la réplication

**Impact applicatif** — Aucun.

---

## 7. Scénarios de test — Résilience applicative

Cette série valide que les intégrations applicatives consommatrices supportent correctement les évènements de bascule du cluster Vault.

### Scénario APP-01 — Spring Vault — résilience à une bascule de leader

| Champ | Valeur |
|---|---|
| **Objectif** | Vérifier que les applications Spring Boot reprennent leur consommation de secrets sans intervention manuelle après une bascule HA. |
| **Périmètre** | Application Spring Boot de test + Spring Vault |
| **Criticité** | 🔴 **Critique** |
| **RTO cible** | < 60 secondes |
| **RPO cible** | 0 |

**Prérequis**
- Application Spring Boot de test déployée, consommant un secret KV et des credentials DB dynamiques
- Auth method configurée (AppRole ou Kubernetes)
- `spring.cloud.vault.config.lifecycle.enabled=true` et renouvellement de baux actif

**Étapes d'exécution**
1. Démarrer l'application et capturer les logs
2. Vérifier la lecture initiale des secrets et la création d'un bail DB
3. Déclencher le scénario HA-01 (bascule gracieuse du leader)
4. Observer les logs applicatifs pendant et après la bascule
5. Vérifier que les requêtes applicatives utilisant les credentials DB continuent de fonctionner
6. Attendre l'échéance de renouvellement du bail et vérifier le renouvellement automatique

**Résultat attendu**
- L'application détecte la perte de connexion et retry automatiquement
- Aucune intervention manuelle requise
- Les baux existants restent valides pendant la bascule
- Le renouvellement de bail réussit sur le nouveau leader

**Impact applicatif** — Brève latence sur les opérations applicatives utilisant Vault (< 30 s).

---

### Scénario APP-02 — Spring Vault — résilience à une bascule DR

| Champ | Valeur |
|---|---|
| **Objectif** | Vérifier que les applications Spring Boot reprennent après une bascule DR complète. |
| **Périmètre** | Application Spring Boot + bascule DR |
| **Criticité** | 🔴 **Critique** |
| **RTO cible** | < 15 minutes (aligné sur RTO DR) |
| **RPO cible** | 0 (les credentials émis sont valides jusqu'à expiration) |

**Prérequis**
- Application APP-01 en fonctionnement
- URL Vault configurée via DNS (pas IP directe) pour permettre la bascule
- Auth method portable entre clusters (AppRole avec mêmes roles répliqués, ou Kubernetes auth replicable)

**Étapes d'exécution**
1. Démarrer le scénario DR-01 en parallèle
2. Observer le comportement applicatif pendant l'indisponibilité Vault
3. Après promotion DR et bascule DNS, observer la reconnexion
4. Vérifier le ré-authentification (nouveau token client)
5. Vérifier la création de nouveaux baux DB sur le cluster DR promu

**Résultat attendu**
- L'application gère proprement l'indisponibilité (pas de crash, retry avec backoff)
- Reconnexion réussie après bascule DNS
- Nouvelle authentification réussie
- Reprise nominale des opérations consommant Vault

**Impact applicatif** — Indisponibilité complète des opérations dépendant de Vault pendant la fenêtre de bascule. Les credentials émis avant bascule restent fonctionnels côté DB/AWS jusqu'à leur expiration TTL.

---

### Scénario APP-03 — Vault Agent — résilience templates et auto-auth

| Champ | Valeur |
|---|---|
| **Objectif** | Valider qu'un Vault Agent sidecar continue de rendre ses templates et de renouveler son token à travers les évènements de résilience. |
| **Périmètre** | Vault Agent en mode sidecar |
| **Criticité** | 🟠 **Majeure** |
| **RTO cible** | < 60 secondes (HA) / < 15 min (DR) |
| **RPO cible** | 0 |

**Prérequis**
- Vault Agent configuré avec auto-auth et template stanza vers un fichier consommé par une application
- Sink file accessible par l'application

**Étapes d'exécution**
1. Démarrer l'Agent et vérifier le rendering initial
2. Déclencher HA-01, puis HA-02
3. Observer les logs de l'Agent (retry, re-authentification)
4. Vérifier que le sink reste à jour ou ne contient pas de contenu invalide
5. Répéter avec DR-01

**Résultat attendu**
- L'Agent retry sur perte de connexion et reprend après la bascule
- Aucune corruption du sink file
- Le template est ré-évalué après reconnexion
- Le token Vault est renouvelé ou re-créé selon la stratégie configurée

**Impact applicatif** — Le sink file conserve sa dernière valeur valide pendant l'indisponibilité (sécurise les apps qui lisent ce fichier).

---

### Scénario APP-04 — Vault Secrets Operator (VSO) — résilience Kubernetes

| Champ | Valeur |
|---|---|
| **Objectif** | Valider que VSO maintient la synchronisation des secrets Kubernetes à travers les évènements de résilience. |
| **Périmètre** | Namespace Kubernetes avec VSO |
| **Criticité** | 🟠 **Majeure** |
| **RTO cible** | < 60 secondes (HA) / < 15 min (DR) |
| **RPO cible** | 0 |

**Prérequis**
- VSO déployé dans le cluster Kubernetes de test
- Au moins une ressource `VaultStaticSecret` et une `VaultDynamicSecret` en consommation active
- Pod applicatif consommant les Secrets Kubernetes générés

**Étapes d'exécution**
1. Vérifier le bon fonctionnement initial (Secrets K8s à jour)
2. Déclencher HA-01
3. Observer les logs du contrôleur VSO
4. Vérifier que les Secrets K8s restent à jour ou sont rapidement re-synchronisés
5. Vérifier que les pods applicatifs ne sont pas redémarrés inutilement
6. Répéter avec DR-01 (après bascule DNS)

**Résultat attendu**
- VSO retry et reprend la synchronisation après chaque bascule
- Les Secrets K8s gérés par VSO restent cohérents
- Les credentials dynamiques sont renouvelés normalement après reprise

**Impact applicatif** — Latence temporaire sur les rotations de credentials pendant la bascule. Les secrets statiques restent disponibles côté Kubernetes.

---

### Scénario APP-05 — Secrets dynamiques DB — comportement des baux pendant bascule

| Champ | Valeur |
|---|---|
| **Objectif** | Vérifier le cycle de vie des credentials DB dynamiques à travers une bascule HA et DR. |
| **Périmètre** | Database secrets engine (PostgreSQL ou Oracle) |
| **Criticité** | 🔴 **Critique** |
| **RTO cible** | < 60 secondes (HA) / < 15 min (DR) |
| **RPO cible** | Variable — voir résultats attendus |

**Prérequis**
- Database secrets engine configuré avec un role de test
- Au moins 3 baux DB actifs avec TTL > durée des tests

**Étapes d'exécution**
1. Capturer la liste des baux actifs sur le primary
2. Vérifier la présence des utilisateurs DB correspondants sur la base cible
3. Déclencher HA-01 — vérifier que les baux existants restent valides
4. Demander un nouveau credential pendant la bascule
5. Renouveler un bail existant pendant la bascule
6. Déclencher DR-01 — observer le sort des baux
7. Sur le cluster DR promu : tenter le renouvellement des baux émis avant bascule

**Résultat attendu**
- **HA** : baux existants conservés, renouvellements fonctionnels après bascule, nouvelles émissions possibles dès que le nouveau leader est élu
- **DR** : les baux émis avant bascule peuvent ne pas être renouvelables sur le cluster DR promu (les leases sont locales au cluster) — comportement à documenter précisément pour les applications
- Les utilisateurs DB créés par Vault avant bascule restent valides côté DB jusqu'à expiration TTL
- Les applications doivent demander de nouveaux credentials après bascule DR

**Impact applicatif** — ⚠️ C'est le scénario le plus important à documenter pour les équipes applicatives : **les leases ne sont pas répliqués**, les credentials émis avant bascule DR ne peuvent pas être renouvelés par Vault (mais restent valides côté DB jusqu'à expiration). Les applications doivent implémenter un fallback : sur erreur de renouvellement post-bascule, demander un nouveau credential.

---

### Scénario APP-06 — Secrets dynamiques AWS — comportement des baux pendant bascule

| Champ | Valeur |
|---|---|
| **Objectif** | Idem APP-05 pour le moteur AWS (IAM users ou STS). |
| **Périmètre** | AWS secrets engine |
| **Criticité** | 🟠 **Majeure** |
| **RTO cible** | < 60 secondes (HA) / < 15 min (DR) |
| **RPO cible** | Variable |

**Prérequis**
- AWS secrets engine configuré (IAM user et/ou STS AssumedRole)
- Roles de test fonctionnels

**Étapes d'exécution**
1. Émettre 3 credentials AWS (1 IAM user, 2 STS)
2. Utiliser les credentials côté AWS (call API simple : `aws s3 ls`)
3. Déclencher HA-01, puis DR-01
4. Vérifier le sort des credentials après chaque bascule
5. Sur le cluster promu, tenter de nouvelles émissions

**Résultat attendu**
- **STS** : les credentials émis avant bascule restent valides côté AWS jusqu'à expiration (typiquement 15 min à 1 h)
- **IAM user** : les credentials restent valides côté AWS jusqu'à révocation par Vault — attention à la persistance d'utilisateurs IAM orphelins après bascule DR (pas de révocation automatique côté DR)
- Nouvelles émissions fonctionnelles sur le cluster promu
- Point d'attention : prévoir une procédure de nettoyage des IAM users orphelins post-bascule

**Impact applicatif** — ⚠️ Risque opérationnel : IAM users orphelins après bascule DR. À documenter dans le runbook post-bascule.

---

## 8. Mesures, métriques et reporting

### 8.1 Métriques à capturer pour chaque scénario

- **T0** : horodatage de déclenchement de la perturbation.
- **T1** : horodatage de détection par le cluster (logs Vault).
- **T2** : horodatage d'élection du nouveau leader ou de promotion DR.
- **T3** : horodatage de reprise du service vérifié côté client (probe `/sys/health`).
- **T4** : horodatage de reprise complète vérifiée côté application.
- Nombre de requêtes en erreur 5xx ou timeout pendant la fenêtre [T0, T3].
- Lag de réplication maximal observé (scénarios DR).
- Logs Vault pertinents (audit device, system log).

### 8.2 Format de restitution

Chaque scénario donne lieu à une fiche de résultat normalisée comprenant :

- Identifiant et titre du scénario.
- Date et heure d'exécution.
- Opérateur en charge.
- Mesures relevées (T0 → T4, erreurs comptabilisées).
- **Verdict** : Conforme / Conforme avec réserves / Non conforme.
- Observations et écarts éventuels par rapport au résultat attendu.
- Captures d'écran ou extraits de logs significatifs.

---

## 9. Grille de procès-verbal

La grille ci-dessous est complétée à l'issue de l'exécution. Chaque ligne fait l'objet d'un verdict explicite.

| ID | Scénario | RTO mesuré | RPO mesuré | Verdict |
|---|---|---|---|---|
| HA-01 | Arrêt gracieux du leader Raft | | | |
| HA-02 | Crash brutal du leader | | | |
| HA-03 | Perte d'un follower | | | |
| HA-04 | Perte de quorum + recovery | | | |
| HA-05 | Partition réseau (split-brain test) | | | |
| DR-01 | Bascule planifiée DR | | | |
| DR-02 | Reconstruction en secondary | | | |
| DR-03 | Failback vers site nominal | | | |
| DR-04 | Lag de réplication sous charge | | | |
| DR-05 | Régénération secondary token | | | |
| APP-01 | Spring Vault — bascule HA | | | |
| APP-02 | Spring Vault — bascule DR | | | |
| APP-03 | Vault Agent — résilience | | | |
| APP-04 | VSO Kubernetes — résilience | | | |
| APP-05 | Secrets dynamiques DB | | | |
| APP-06 | Secrets dynamiques AWS | | | |

### 9.1 Synthèse

| Indicateur | Valeur |
|---|---|
| Nombre de scénarios exécutés | |
| Conformes | |
| Conformes avec réserves | |
| Non conformes | |
| **Décision globale** | ☐ Recette prononcée   ☐ Recette prononcée avec réserves   ☐ Recette refusée |

### 9.2 Signatures

| Pour le client | Pour IBM France | Pour HashiCorp |
|---|---|---|
| Nom : | Nom : | Nom : |
| Fonction : | Fonction : | Fonction : |
| Date : | Date : | Date : |
| Signature : | Signature : | Signature : |

---

## 10. Annexes

### 10.1 Commandes de référence

**Statut du cluster Raft**

```bash
vault operator raft list-peers
vault operator raft autopilot state
```

**Statut de la réplication DR**

```bash
vault read sys/replication/dr/status
vault read sys/replication/status
```

**Snapshot Raft (à exécuter en pré-test)**

```bash
vault operator raft snapshot save /backup/vault-snapshot-$(date +%Y%m%d-%H%M).snap
```

**Génération d'un DR operation token (procédure unseal threshold)**

```bash
vault operator generate-root -dr-token -init
# Puis collecter les nonces et soumettre les unseal keys :
vault operator generate-root -dr-token -nonce=<nonce> <unseal-key>
```

**Promotion du cluster DR**

```bash
vault write -f sys/replication/dr/secondary/promote dr_operation_token=<token>
```

**Procédure de recovery `peers.json` (perte de quorum)**

Fichier `raft/peers.json` à créer sur le nœud survivant :

```json
[{"id":"<node-id>","address":"<node-ip>:8201","non_voter":false}]
```

### 10.2 Métriques Prometheus utiles

- `vault.core.unsealed` (1 = unsealed)
- `vault.raft.leader` (1 = ce nœud est leader)
- `vault.raft.commitTime`
- `vault.replication.dr.state.lastRemoteWAL`
- `vault.replication.dr.state.lastWAL` (écart entre les deux = lag de réplication)
- `vault.audit.log_request`
- `vault.expire.num_leases`

### 10.3 Références

- HashiCorp — Vault Disaster Recovery Replication : <https://developer.hashicorp.com/vault/docs/enterprise/replication>
- HashiCorp — Raft Storage Backend : <https://developer.hashicorp.com/vault/docs/configuration/storage/raft>
- HashiCorp — Outage Recovery : <https://developer.hashicorp.com/vault/tutorials/raft/raft-outage-recovery>
- HashiCorp — DR Operation Token : <https://developer.hashicorp.com/vault/docs/enterprise/replication#disaster-recovery-operation-token>

---

*Fin du document — VAULT-RES-PV-001 v1.0*
