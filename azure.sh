#!/usr/bin/env bash
#
# azure.sh — gestion de l'infrastructure Azure du projet Bernstein
#
# Usage : ./azure.sh <commande>
#
#   up      Crée le resource group, l'ACR (registry privé) et l'AKS (cluster),
#           relie l'ACR à l'AKS et récupère le kubeconfig. Idempotent.
#   creds   (Re)récupère le kubeconfig du cluster pour kubectl.
#   stop    Arrête le cluster (plus de coût de calcul tant qu'il est arrêté).
#   start   Redémarre le cluster.
#   status  Affiche l'état du cluster et des ressources.
#   down    Supprime TOUTES les ressources du projet (irréversible).
#
# Configuration : copier azure.env.example en azure.env et l'adapter.
# Prérequis : Azure CLI installée et `az login` effectué.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/azure.env" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/azure.env"
fi

RESOURCE_GROUP="${RESOURCE_GROUP:-bernstein-rg}"
LOCATION="${LOCATION:-francecentral}"
AKS_NAME="${AKS_NAME:-bernstein-aks}"
NODE_COUNT="${NODE_COUNT:-2}"
NODE_SIZE="${NODE_SIZE:-Standard_B2s}"
ACR_NAME="${ACR_NAME:-}"

die() { echo "Erreur : $*" >&2; exit 1; }
log() { echo -e "\n==> $*"; }

check_prereqs() {
  command -v az >/dev/null || die "Azure CLI introuvable (voir README)."
  az account show >/dev/null 2>&1 || die "Non connecté à Azure : lance 'az login'."
  [[ -n "$ACR_NAME" ]] || die "ACR_NAME non défini (dans azure.env). Nom unique, minuscules et chiffres uniquement."
  [[ "$ACR_NAME" =~ ^[a-z0-9]{5,50}$ ]] || die "ACR_NAME invalide : 5 à 50 caractères, minuscules et chiffres uniquement."
}

cmd_up() {
  log "Abonnement utilisé : $(az account show --query name -o tsv)"

  log "Enregistrement des fournisseurs Azure nécessaires (une seule fois par abonnement)"
  az provider register --namespace Microsoft.ContainerService --wait
  az provider register --namespace Microsoft.ContainerRegistry --wait

  log "Resource group '$RESOURCE_GROUP' ($LOCATION)"
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

  if az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
    log "ACR '$ACR_NAME' existe déjà"
  else
    log "Création de l'ACR '$ACR_NAME' (SKU Basic, compte admin désactivé)"
    az acr create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$ACR_NAME" \
      --sku Basic \
      --admin-enabled false \
      --output none
  fi

  if az aks show --name "$AKS_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
    log "AKS '$AKS_NAME' existe déjà, vérification du lien avec l'ACR"
    az aks update \
      --resource-group "$RESOURCE_GROUP" \
      --name "$AKS_NAME" \
      --attach-acr "$ACR_NAME" \
      --output none
  else
    log "Création de l'AKS '$AKS_NAME' ($NODE_COUNT x $NODE_SIZE) — compter 5 à 10 minutes"
    az aks create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$AKS_NAME" \
      --tier free \
      --node-count "$NODE_COUNT" \
      --node-vm-size "$NODE_SIZE" \
      --enable-managed-identity \
      --attach-acr "$ACR_NAME" \
      --generate-ssh-keys \
      --output none
  fi

  cmd_creds

  log "Terminé. Infos à transmettre pour les scripts de déploiement :"
  echo "  RESOURCE_GROUP = $RESOURCE_GROUP"
  echo "  AKS_NAME       = $AKS_NAME"
  echo "  ACR_NAME       = $ACR_NAME"
  echo "  ACR_LOGIN      = $(az acr show --name "$ACR_NAME" --query loginServer -o tsv)"
  echo
  echo "Pense à arrêter le cluster quand tu ne travailles pas : ./azure.sh stop"
}

cmd_creds() {
  log "Récupération du kubeconfig"
  az aks get-credentials \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AKS_NAME" \
    --overwrite-existing
  kubectl get nodes
}

cmd_stop() {
  log "Arrêt du cluster '$AKS_NAME'"
  az aks stop --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME"
  echo "Cluster arrêté. Note : l'ACR et les disques persistants restent facturés (faible coût)."
}

cmd_start() {
  log "Démarrage du cluster '$AKS_NAME'"
  az aks start --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME"
  cmd_creds
}

cmd_status() {
  log "Cluster"
  az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" \
    --query "{etat:powerState.code, version:kubernetesVersion, noeuds:agentPoolProfiles[0].count, taille:agentPoolProfiles[0].vmSize}" \
    --output table || echo "Cluster introuvable."
  log "Ressources du groupe '$RESOURCE_GROUP'"
  az resource list --resource-group "$RESOURCE_GROUP" --query "[].{nom:name, type:type}" --output table || true
}

cmd_down() {
  echo "ATTENTION : cela supprime définitivement '$RESOURCE_GROUP' et tout son contenu"
  echo "(cluster, registry, images, disques, base de données)."
  read -r -p "Taper le nom du resource group pour confirmer : " answer
  [[ "$answer" == "$RESOURCE_GROUP" ]] || die "Confirmation incorrecte, rien n'a été supprimé."
  az group delete --name "$RESOURCE_GROUP" --yes --no-wait
  echo "Suppression lancée (elle continue en arrière-plan sur Azure)."
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    up)     check_prereqs; cmd_up ;;
    creds)  check_prereqs; cmd_creds ;;
    stop)   check_prereqs; cmd_stop ;;
    start)  check_prereqs; cmd_start ;;
    status) check_prereqs; cmd_status ;;
    down)   check_prereqs; cmd_down ;;
    *)      sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
  esac
}

main "$@"
