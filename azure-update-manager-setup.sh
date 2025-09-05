#!/usr/bin/env bash
set -euo pipefail

# =============================
# Paramètres à adapter si besoin
# =============================
RG="rg-viona"
VM="viona-mvp-gpu"
MC_NAME="um-${VM}-weekly-sun-0200"
ASSIGN_NAME="${MC_NAME}-assignment"

# API versions
API_CFG="2023-09-01-preview"
API_ASSIGN="2023-10-01-preview"

echo "==> Subscription courante"
SUBS=$(az account show --query id -o tsv)
echo "   $SUBS"

echo "==> Région exacte de la VM"
VM_LOC=$(az vm show -g "$RG" -n "$VM" --query location -o tsv)
echo "   $VM_LOC"

# ======================
# Fenêtre de maintenance
# ======================
START_DATE="$(date -u -d 'next Sunday' +%Y-%m-%d) 02:00"
DURATION="04:00"          # max 240 minutes
RECUR="1Week Sunday"      # chaque dimanche
TIMEZONE="UTC"
REBOOT="Never"

BASE_ID="/subscriptions/${SUBS}/resourceGroups/${RG}"
MC_ID="${BASE_ID}/providers/Microsoft.Maintenance/maintenanceConfigurations/${MC_NAME}"
VM_SCOPE="${BASE_ID}/providers/Microsoft.Compute/virtualMachines/${VM}"
ASSIGN_ID="${VM_SCOPE}/providers/Microsoft.Maintenance/configurationAssignments/${ASSIGN_NAME}"

# =======================================
# 1) Créer/mettre à jour Maintenance Config
# =======================================
echo "==> 1) Création/MAJ Maintenance Configuration"
az rest --method put \
  --url "https://management.azure.com${MC_ID}?api-version=${API_CFG}" \
  --body @- <<EOF
{
  "location": "${VM_LOC}",
  "properties": {
    "maintenanceScope": "InGuestPatch",
    "extensionProperties": {
      "InGuestPatchMode": "User"
    },
    "installPatches": {
      "linuxParameters": {
        "classificationsToInclude": ["Security", "Critical"]
      },
      "rebootSetting": "${REBOOT}"
    },
    "maintenanceWindow": {
      "timeZone": "${TIMEZONE}",
      "startDateTime": "${START_DATE}",
      "recurEvery": "${RECUR}",
      "duration": "${DURATION}"
    },
    "visibility": "Custom"
  }
}
EOF

# ======================================================
# 2) Configurer la VM (patchMode + bypass requis Azure)
# ======================================================
echo "==> 2) Configurer la VM pour patching par Update Manager"
az vm update -g "$RG" -n "$VM" \
  --set osProfile.linuxConfiguration.patchSettings.patchMode=AutomaticByPlatform \
         osProfile.linuxConfiguration.patchSettings.assessmentMode=AutomaticByPlatform \
         osProfile.linuxConfiguration.patchSettings.automaticByPlatformSettings='{"bypassPlatformSafetyChecksOnUserSchedule": true}'

# =====================================================
# 3) Créer l’assignation (lier config <-> VM)
# =====================================================
echo "==> 3) Assigner la configuration à la VM"
az rest --method put \
  --url "https://management.azure.com${ASSIGN_ID}?api-version=${API_ASSIGN}" \
  --body @- <<EOF
{
  "location": "${VM_LOC}",
  "properties": {
    "maintenanceConfigurationId": "${MC_ID}"
  }
}
EOF

# =====================
# 4) Vérifications
# =====================
echo "==> 4) Vérification configuration"
az rest --method get \
  --url "https://management.azure.com${MC_ID}?api-version=${API_CFG}" \
  -o jsonc

echo "==> 5) Vérification assignation"
az rest --method get \
  --url "https://management.azure.com${ASSIGN_ID}?api-version=${API_ASSIGN}" \
  -o jsonc

# =====================
# Bonus: commandes utiles
# =====================
cat <<EOM

==============================================================
👉 Vérifier la politique active sur la VM :
   az vm show -g ${RG} -n ${VM} --query osProfile.linuxConfiguration.patchSettings -o jsonc

👉 Évaluer les patchs disponibles :
   az vm assess-patches -g ${RG} -n ${VM} -o jsonc

👉 Lancer un patch manuel Security+Critical (hors fenêtre) :
   az vm install-patches -g ${RG} -n ${VM} \\
     --maximum-duration PT2H \\
     --reboot-setting Never \\
     --linux-parameters '{"classificationsToInclude":["Security","Critical"]}' \\
     -o jsonc

👉 Supprimer l’assignation :
   az rest --method delete \\
     --url "https://management.azure.com${ASSIGN_ID}?api-version=${API_ASSIGN}"

👉 Supprimer la Maintenance Configuration :
   az rest --method delete \\
     --url "https://management.azure.com${MC_ID}?api-version=${API_CFG}"

--------------------------------------------------------------
⚙️ À exécuter *dans la VM Ubuntu* (une seule fois) pour désactiver
   les updates automatiques natifs :
   sudo systemctl disable --now apt-daily.timer
   sudo systemctl disable --now apt-daily-upgrade.timer
   sudo systemctl disable --now unattended-upgrades
   sudo apt remove -y unattended-upgrades

🔒 Geler les paquets sensibles (drivers NVIDIA, CUDA, kernel) :
   sudo apt-mark hold 'nvidia-*' 'cuda-*' 'nvidia-dkms-*' 'linux-image-*' 'linux-headers-*'

🔓 Lever le gel si besoin de mise à jour manuelle :
   sudo apt-mark unhold 'nvidia-*' 'cuda-*' 'nvidia-dkms-*' 'linux-image-*' 'linux-headers-*'
--------------------------------------------------------------

⚠️ Attention : la VM doit être en état "Running" pendant la fenêtre de patch.
==============================================================

EOM

echo "✅ Script terminé : configuration de patch hebdo créée et assignée à la VM ${VM}."

