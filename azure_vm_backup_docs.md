# 💾 Documentation – Azure VM Backup

## 🎯 Objectif

Automatiser une sauvegarde **sûre** d’une VM Azure via **Recovery Services Vault** :

- crée/met à jour le **Vault** et la **policy** si besoin,
- **n’active pas** la protection si la VM est déjà protégée dans ce Vault,
- exécute un **backup manuel (backup-now)** **uniquement** lors du **premier enable** (dans ce run),
- planifie un **backup quotidien** à l’heure UTC souhaitée, avec **rétention** configurée.

---

## ✅ Prérequis

- Azure CLI connecté : `az login`
- Accès sur le **Resource Group** et le **Recovery Services Vault**
- Outils côté OS : `bash`, `jq` (le script installe `jq` automatiquement via `apt-get` si absent)

---

## 🔧 Variables à adapter (en tête de script)

```bash
RG="rg-viona"          # Resource Group
LOC="northeurope"      # Région Azure
VAULT="rsv-viona-dev"  # Recovery Services Vault
POLICY="daily-14d"     # Nom de la policy créée/mise à jour
VM="viona-mvp-gpu"     # Nom de la VM à protéger

SCHEDULE_UTC="23:00:00" # Heure de backup quotidienne (UTC)
RETENTION_DAYS=14        # Rétention quotidienne
RETAIN_UNTIL="01-10-2025" # Rétention du backup manuel (DD-MM-YYYY)
```

> ℹ️ `TODAY_UTC` est calculée dynamiquement pour positionner l’heure de planification (champ `scheduleRunTimes`).

---

## 🧠 Ce que fait le script (vue d’ensemble)

1. **Vérifie l’environnement** (`az`, login, `jq`), crée le **Resource Group** si manquant.
2. **Crée ou détecte** le **Recovery Services Vault** (`rsv-*`), **active soft-delete**.
3. **Récupère la policy par défaut** pour VM et **l’adapte** (horaire & rétention) via `jq` → `policy.final.json`.
4. **Set/Update la policy** dans le Vault (`az backup policy set`).
5. **Contrôle la protection existante** de la VM :
   - si **déjà protégée dans ce Vault** → **aucun enable**, **pas de backup-now** (idempotence).
   - sinon, vérifie **tous les Vaults** → si protégée **ailleurs**, **stop** (message explicite).
   - si non protégée, **enable** la protection **dans ce Vault**, puis **backup-now** **une seule fois** (avec `--retain-until`).
6. **Affiche le résumé des jobs** des dernières 24h.

---

## 🪜 Étapes détaillées & commandes clés

### 1) Pré-checks & dépendances

- `need az` + `az account show` → vérifie le login.
- Installe `jq` si absent (via `apt-get`).

### 2) RG & Vault

```bash
az group show -n "$RG" || az group create -n "$RG" -l "$LOC"
az backup vault show -g "$RG" -n "$VAULT" || az backup vault create -g "$RG" -n "$VAULT" -l "$LOC"
az backup vault backup-properties set -g "$RG" -n "$VAULT" --soft-delete-feature-state Enable
```

> 🔐 Soft-delete conseillé pour protéger les points de restauration supprimés par erreur.

### 3) Policy horaire & rétention

```bash
az backup policy get-default-for-vm -g "$RG" -v "$VAULT" > policy.default.json
# Écrit l’heure (UTC) et met à jour la rétention via jq → policy.final.json
az backup policy set -g "$RG" -v "$VAULT" -n "$POLICY" --policy @policy.final.json
```

### 4) Détection protection existante & enable si besoin

```bash
az backup item list -g "$RG" -v "$VAULT" --backup-management-type AzureIaasVM \
  --query "[?contains(properties.friendlyName, '$VM')].id" -o tsv
# … liste aussi les autres vaults pour s’assurer que la VM n’est pas déjà protégée ailleurs
az backup protection enable-for-vm --vault-name "$VAULT" -g "$RG" \
  --vm "$VM" --policy-name "$POLICY"
```

### 5) Backup manuel (premier enable uniquement)

```bash
az backup protection backup-now --ids "$ITEM_ID_TARGET" --retain-until "$RETAIN_UNTIL"
```

### 6) Jobs (24h)

```bash
az backup job list -g "$RG" -v "$VAULT" --operation Backup \
  --start-date "$(date -u -d '-1 day' +%d-%m-%Y)" --end-date "$(date -u +%d-%m-%Y)" \
  --query "[].{name:name,operation:properties.operation,status:properties.status,entity:properties.entityFriendlyName,start:properties.startTime,end:properties.endTime}" -o table
```

---

## 🧪 Exemples d’utilisation

1. Rendre le script exécutable & lancer :

```bash
chmod +x backup.sh
./backup.sh
```

2. Vérifier que la VM est bien protégée dans le Vault :

```bash
az backup item list -g "$RG" -v "$VAULT" --backup-management-type AzureIaasVM -o table
```

3. Lancer un backup manuel ultérieurement (si déjà protégée) :

```bash
ITEM_ID=$(az backup item list -g "$RG" -v "$VAULT" --backup-management-type AzureIaasVM \
  --query "[?contains(properties.friendlyName, '$VM')].id" -o tsv)
az backup protection backup-now --ids "$ITEM_ID" --retain-until "DD-MM-YYYY"
```

---

## 📌 Notes 

-  Relancer `backup.sh` ne crée pas de doublons ni ne relance un backup-now si la VM est déjà protégée.
- **Fuseaux horaires** : l’horaire est en **UTC** (`SCHEDULE_UTC`).
- **Rétention** : `RETENTION_DAYS` pour le quotidien ; `RETAIN_UNTIL` pour le backup manuel initial (format **DD-MM-YYYY** requis par l’Azure CLI).
- **Protection ailleurs** : le script **refuse** l’activation si la VM est déjà protégée dans **un autre Vault** → désactiver là-bas d’abord.

---

