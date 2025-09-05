#!/bin/bash
# Azure VM Backup (safe & idempotent)
# - Creates/updates Vault + policy
# - Skips enable if VM already protected in target vault
# - Runs backup-now ONLY when protection is enabled in this run
set -euo pipefail

RG="rg-viona"
LOC="northeurope"
VAULT="rsv-viona-dev"
POLICY="daily-14d"
VM="viona-mvp-gpu"

# Daily schedule (UTC)
SCHEDULE_UTC="23:00:00"
TODAY_UTC="$(date -u +%Y-%m-%d)"
RETENTION_DAYS=14

# Manual backup retain-until (CLI expects DD-MM-YYYY)
RETAIN_UNTIL="01-10-2025"

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

echo "[*] Ensure Recovery Services Vault..."
if ! az backup vault show -g "$RG" -n "$VAULT" >/dev/null 2>&1; then
  az backup vault create -g "$RG" -n "$VAULT" -l "$LOC" >/dev/null
  echo "    Vault created: $VAULT"
else
  echo "    Vault exists: $VAULT"
fi

echo "[*] Vault properties (enable soft-delete)..."
az backup vault backup-properties set -g "$RG" -n "$VAULT" \
  --soft-delete-feature-state Enable >/dev/null || true

echo "[*] Get default VM policy schema..."
az backup policy get-default-for-vm -g "$RG" -v "$VAULT" > policy.default.json

echo "[*] Apply schedule ($SCHEDULE_UTC UTC) & retention ($RETENTION_DAYS days)..."
jq \
  --arg dt  "${TODAY_UTC}T${SCHEDULE_UTC}Z" \
  --argjson d "${RETENTION_DAYS}" '
  .properties.schedulePolicy.scheduleRunTimes = [$dt]
  | ( .properties.retentionPolicy.dailySchedule.retentionDuration.count? // empty ) as $x
    | if $x != null then
        .properties.retentionPolicy.dailySchedule.retentionDuration.count = $d
      else
        ( .properties.retentionPolicy.retentionDuration.count? // empty ) as $y
        | if $y != null then
            .properties.retentionPolicy.retentionDuration.count = $d
          else
            .
          end
      end
  ' policy.default.json > policy.final.json

echo "[*] Create/Update policy '$POLICY'..."
az backup policy set -g "$RG" -v "$VAULT" -n "$POLICY" --policy @policy.final.json >/dev/null

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
  while IFS= read -r VAULT_ID; do
    [[ -z "$VAULT_ID" ]] && continue
    OTHER_RG="$(echo "$VAULT_ID"   | awk -F/ '{for(i=1;i<=NF;i++) if($i=="resourceGroups"){print $(i+1)}}')"
    OTHER_VAULT="$(echo "$VAULT_ID"| awk -F/ '{print $NF}')"
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

  # Refresh item ID after enabling
  ITEM_ID_TARGET="$(az backup item list -g "$RG" -v "$VAULT" \
    --backup-management-type AzureIaasVM \
    --query "[?contains(properties.friendlyName, '$VM')].id" -o tsv)"

  # Only trigger backup-now on first enable
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
  --end-date   "$END_DATE" \
  --query "[].{name:name,operation:properties.operation,status:properties.status,entity:properties.entityFriendlyName,start:properties.startTime,end:properties.endTime}" \
  -o table || true

echo "[✔] Done. Daily backup scheduled at ${SCHEDULE_UTC} UTC with ${RETENTION_DAYS} days retention."

