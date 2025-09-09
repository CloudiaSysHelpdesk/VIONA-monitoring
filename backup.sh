#!/bin/bash
# Azure VM Backup (safe & idempotent) - LRS enforced + Policy V1 (Daily)
# - Crée/valide le Vault (LRS)
# - Policy: Daily @ 23:00 UTC, retention 14j
# - Active la protection si nécessaire
# - backup-now uniquement au premier enable

set -euo pipefail

# ----------- VARIABLES À ADAPTER -----------
RG="rg-viona"
LOC="northeurope"
VAULT="rsv-viona-dev"   # Doit être / rester en LRS
POLICY="daily-14d"
VM="viona-mvp-gpu"

# Planning Daily (UTC)
SCHEDULE_UTC="23:00:00"                 # HH:MM:SS
TODAY_UTC="$(date -u +%Y-%m-%d)"
DT="${TODAY_UTC}T${SCHEDULE_UTC}+00:00" # ISO complet avec offset +00:00
RETENTION_DAYS=14

# Manual backup retain-until (CLI attend DD-MM-YYYY)
RETAIN_UNTIL="01-10-2025"
# -------------------------------------------

cleanup() {
  rm -f policy.default.json policy.final.json >/dev/null 2>&1 || true
}
trap cleanup EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "[✘] '$1' required."; exit 1; } }

need az
az account show >/dev/null 2>&1 || { echo "[✘] Not logged in. Run: az login"; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "[*] Installing jq..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y && sudo apt-get install -y jq
  else
    echo "[✘] Please install 'jq' and re-run."; exit 1
  fi
fi

echo "[*] Ensure Resource Group..."
az group show -n "$RG" >/dev/null 2>&1 || az group create -n "$RG" -l "$LOC" >/dev/null

# ---------- helpers ----------
get_prop() {
  # $1 = JMESPath (ex: "[?name=='vaultstorageconfig'].properties.storageType | [0]")
  az backup vault backup-properties show -g "$RG" -n "$VAULT" \
    --query "$1" -o tsv 2>/dev/null || true
}
ensure_lrs_or_fail() {
  local stype sstate
  stype="$(get_prop "[?name=='vaultstorageconfig'].properties.storageType | [0]")"
  sstate="$(get_prop "[?name=='vaultstorageconfig'].properties.storageTypeState | [0]")"

  if [[ "$stype" == "LocallyRedundant" ]]; then
    echo "[✔] Vault '$VAULT' already LRS."
    return 0
  fi

  if [[ "$sstate" == "Locked" && "$stype" != "LocallyRedundant" ]]; then
    echo "[✘] Vault '$VAULT' storage is '$stype' and LOCKED. Can't switch to LRS."
    echo "Create a NEW vault in LRS and migrate protection."
    exit 1
  fi

  echo "[*] Setting storage redundancy to LRS..."
  az backup vault update -g "$RG" -n "$VAULT" \
    --backup-storage-redundancy LocallyRedundant >/dev/null

  stype="$(get_prop "[?name=='vaultstorageconfig'].properties.storageType | [0]")"
  if [[ "$stype" != "LocallyRedundant" ]]; then
    echo "[✘] Failed to set LRS (current: ${stype:-unknown})."
    exit 1
  fi
  echo "[✔] Vault '$VAULT' set to LRS."
}
# -----------------------------

echo "[*] Ensure Recovery Services Vault..."
if ! az backup vault show -g "$RG" -n "$VAULT" >/dev/null 2>&1; then
  az backup vault create -g "$RG" -n "$VAULT" -l "$LOC" >/dev/null
  echo "  Vault created: $VAULT"
else
  echo "  Vault exists: $VAULT"
fi

echo "[*] Vault properties (enable soft-delete)..."
az backup vault backup-properties set -g "$RG" -n "$VAULT" \
  --soft-delete-feature-state Enable >/dev/null || true

echo "[*] Enforce LRS on vault..."
ensure_lrs_or_fail

# ===================== POLICY (Daily @ SCHEDULE_UTC, retention RETENTION_DAYS) =====================
echo "[*] Create/Update policy '${POLICY}' (daily @ $SCHEDULE_UTC UTC, retention ${RETENTION_DAYS}d)..."

# Supprime l’ancienne policy si elle existe (évite des restes de structure incompatibles)
if az backup policy show -g "$RG" -v "$VAULT" -n "$POLICY" >/dev/null 2>&1; then
  echo "    Policy exists, deleting old version..."
  az backup policy delete -g "$RG" -v "$VAULT" -n "$POLICY" --yes
fi

# Récupère une policy par défaut VM (forme attendue par l’API)
az backup policy get-default-for-vm -g "$RG" -v "$VAULT" > policy.default.json

echo "[*] Apply schedule ($SCHEDULE_UTC UTC) & retention ($RETENTION_DAYS days)..."
jq \
  --arg dt "$DT" \
  --argjson d "$RETENTION_DAYS" '
  # Normalise la zone et la fréquence
  .properties.timeZone = "UTC"
  | .properties.schedulePolicy.scheduleRunFrequency = "Daily"
  # Horaire d’exécution (liste d’ISO datetimes)
  | .properties.schedulePolicy.scheduleRunTimes = [$dt]
  # Retention Daily (si le bloc existe dans la policy par défaut)
  | if .properties.retentionPolicy.dailySchedule? then
      .properties.retentionPolicy.dailySchedule.retentionTimes = [$dt]
      | .properties.retentionPolicy.dailySchedule.retentionDuration.count = $d
      | .properties.retentionPolicy.dailySchedule.retentionDuration.durationType = "Days"
    else . end
  # Certaines shapes mettent retentionDuration au niveau racine du retentionPolicy
  | if .properties.retentionPolicy.retentionDuration?.count? then
      .properties.retentionPolicy.retentionDuration.count = $d
      | .properties.retentionPolicy.retentionDuration.durationType = "Days"
    else . end
  # Si un weeklySchedule est présent par défaut, on lui met au moins la retentionTimes (même heure)
  | if .properties.retentionPolicy.weeklySchedule? then
      .properties.retentionPolicy.weeklySchedule.retentionTimes = [$dt]
    else . end
  ' policy.default.json > policy.final.json

# Petit contrôle visuel utile en cas de debug (décommente si besoin)
# jq '.properties.schedulePolicy.scheduleRunTimes,
#     .properties.retentionPolicy.dailySchedule?.retentionTimes,
#     .properties.retentionPolicy.dailySchedule?.retentionDuration,
#     .properties.retentionPolicy.retentionDuration? // "no-flat-retentionDuration",
#     .properties.timeZone' policy.final.json

echo "[*] Create/Update policy '$POLICY'..."
az backup policy set -g "$RG" -v "$VAULT" -n "$POLICY" --policy @policy.final.json >/dev/null

echo "[✔] Policy '${POLICY}' created successfully."
# ==============================================================================

# ---------- protection checks ----------
echo "[*] Check if VM is already protected in target vault..."
ITEM_ID_TARGET="$(az backup item list -g "$RG" -v "$VAULT" \
  --backup-management-type AzureIaasVM \
  --query "[?contains(properties.friendlyName, '$VM')].id" -o tsv || true)"

RUN_BACKUP_NOW="no"

if [[ -n "${ITEM_ID_TARGET:-}" ]]; then
  echo "[i] VM '$VM' is already protected in vault '$VAULT' → skipping enable and backup-now."
else
  echo "[*] Not protected in target vault. Checking other vaults..."
  FOUND_OTHER_ID=""

  # Liste de tous les vaults et inspection de la VM
  while IFS= read -r VAULT_ID; do
    [[ -z "$VAULT_ID" ]] && continue
    # (évite tout caractère NBSP parasite)
    VAULT_ID_CLEAN="$(printf "%s" "$VAULT_ID" | tr -d "\u00A0")"
    OTHER_RG="$(echo "$VAULT_ID_CLEAN"   | awk -F/ '{for(i=1;i<=NF;i++) if($i=="resourceGroups"){print $(i+1)}}')"
    OTHER_VAULT="$(echo "$VAULT_ID_CLEAN"| awk -F/ '{print $NF}')"

    MATCH_ID="$(az backup item list -g "$OTHER_RG" -v "$OTHER_VAULT" \
      --backup-management-type AzureIaasVM \
      --query "[?contains(properties.friendlyName, '$VM')].id" -o tsv || true)"

    if [[ -n "$MATCH_ID" ]]; then
      FOUND_OTHER_ID="$MATCH_ID"
      FOUND_OTHER_VAULT="$OTHER_VAULT"
      FOUND_OTHER_RG="$OTHER_RG"
      break
    fi
  done < <(az backup vault list --query "[].id" -o tsv)

  if [[ -n "${FOUND_OTHER_ID:-}" ]]; then
    echo "[✘] VM '$VM' is already protected in another vault: $FOUND_OTHER_VAULT (RG: $FOUND_OTHER_RG)"
    echo "    Disable there first (keep data recommended), then re-run."
    exit 1
  fi

  echo "[*] Enabling protection in '$VAULT'..."
  az backup protection enable-for-vm --vault-name "$VAULT" -g "$RG" \
    --vm "$VM" --policy-name "$POLICY" >/dev/null

  ITEM_ID_TARGET="$(az backup item list -g "$RG" -v "$VAULT" \
    --backup-management-type AzureIaasVM \
    --query "[?contains(properties.friendlyName, '$VM')].id" -o tsv)"

  RUN_BACKUP_NOW="yes"
fi
# --------------------------------------

if [[ -z "${ITEM_ID_TARGET:-}" ]]; then
  echo "[✘] Could not locate protected item ID for VM '$VM' in vault '$VAULT'."
  echo "    Run: az backup item list -g \"$RG\" -v \"$VAULT\" --backup-management-type AzureIaasVM -o table"
  exit 1
fi

if [[ "$RUN_BACKUP_NOW" == "yes" ]]; then
  echo "[*] Trigger manual backup-now (first protection only) — retain until $RETAIN_UNTIL..."
  az backup protection backup-now --ids "$ITEM_ID_TARGET" --retain-until "$RETAIN_UNTIL" >/dev/null
else
  echo "[i] Skipping manual backup-now (VM already protected)."
fi

# --- Optional: Jobs summary (last 24h) ---
START_DATE="$(date -u -d '-1 day' +%d-%m-%Y)"
END_DATE="$(date -u +%d-%m-%Y)"

echo "[*] Jobs in last 24h:"
az backup job list -g "$RG" -v "$VAULT" \
  --operation Backup \
  --start-date "$START_DATE" \
  --end-date "$END_DATE" \
  --query "[].{name:name,operation:properties.operation,status:properties.status,entity:properties.entityFriendlyName,start:properties.startTime,end:properties.endTime}" \
  -o table || true

echo "[✔] Done. Daily backup scheduled at ${SCHEDULE_UTC} UTC with ${RETENTION_DAYS} days retention."

