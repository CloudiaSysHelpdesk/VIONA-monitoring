#!/usr/bin/env bash
set -euo pipefail

# =============================
# Paramètres (à adapter si besoin)
# =============================
RG="rg-viona"
VM="viona-mvp-gpu"
MC_NAME="um-${VM}-weekly-sun-0200"
ASSIGN_NAME="${MC_NAME}-assignment"

API_CFG="2023-09-01-preview"
API_ASSIGN="2023-10-01-preview"

echo "==> Subscription courante"
SUBS=$(az account show --query id -o tsv)
echo "   $SUBS"

BASE_ID="/subscriptions/${SUBS}/resourceGroups/${RG}"
MC_ID="${BASE_ID}/providers/Microsoft.Maintenance/maintenanceConfigurations/${MC_NAME}"
VM_SCOPE="${BASE_ID}/providers/Microsoft.Compute/virtualMachines/${VM}"
ASSIGN_ID="${VM_SCOPE}/providers/Microsoft.Maintenance/configurationAssignments/${ASSIGN_NAME}"

# =============================
# 1) Supprimer l’assignation
# =============================
echo "==> Suppression de l’assignation ${ASSIGN_NAME}"
az rest --method delete \
  --url "https://management.azure.com${ASSIGN_ID}?api-version=${API_ASSIGN}" || echo "⚠️ Assignation déjà absente"

# =============================
# 2) Supprimer la Maintenance Configuration
# =============================
echo "==> Suppression de la Maintenance Configuration ${MC_NAME}"
az rest --method delete \
  --url "https://management.azure.com${MC_ID}?api-version=${API_CFG}" || echo "⚠️ Configuration déjà absente"

echo "✅ Nettoyage terminé."
