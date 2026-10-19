#!/usr/bin/env bash
# Déploiement de bout en bout de l'app Poll : build -> push vers le registre privé -> helm upgrade --install.
# Relançable à volonté : sans changement du code de l'app, rien n'est reconstruit ni redémarré.
#
# Sur Azure (AKS + ACR) :
#   az login
#   export RESOURCE_GROUP=<groupe> AKS_NAME=<cluster> ACR_NAME=<registre> POSTGRES_PASSWORD=<mot de passe>
#   deploy/deploy.sh
#
# En local sur minikube (pour tester sans Azure) :
#   export POSTGRES_PASSWORD=<mot de passe>
#   deploy/deploy.sh --local
#
# Variables optionnelles :
#   REDIS_PASSWORD  sinon généré au premier déploiement, puis conservé
#   NAMESPACE       namespace Kubernetes (défaut : poll-app)
#   TAG             tag des images (défaut : SHA git du code de l'app, voir build-push.sh)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE=poll-app
NAMESPACE="${NAMESPACE:-poll-app}"

log() { printf '\n==> %s\n' "$*" >&2; }
die() { printf 'ERREUR : %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
    "") TARGET=azure ;;
    --local) TARGET=minikube ;;
    *) die "option inconnue '$1' (usage : $0 [--local])" ;;
esac

[ -n "${POSTGRES_PASSWORD:-}" ] || die "POSTGRES_PASSWORD doit être défini"
for cmd in docker kubectl helm; do
    command -v "$cmd" >/dev/null || die "$cmd n'est pas installé"
done

if [ "$TARGET" = azure ]; then
    for var in RESOURCE_GROUP AKS_NAME ACR_NAME; do
        [ -n "${!var:-}" ] || die "$var doit être défini"
    done
    command -v az >/dev/null || die "az (Azure CLI) n'est pas installé"
    az account show >/dev/null 2>&1 || die "pas connecté à Azure : lance 'az login'"

    log "Connexion au cluster $AKS_NAME"
    az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing >&2
    KUBE_CONTEXT="$AKS_NAME"

    # Le cluster tire les images avec sa propre identité (rôle AcrPull sur le registre) :
    # pas d'imagePullSecret à créer ni à renouveler
    log "Accès du cluster au registre $ACR_NAME"
    acr_id="$(az acr show --name "$ACR_NAME" --query id -o tsv)"
    kubelet_id="$(az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" \
        --query identityProfile.kubeletidentity.objectId -o tsv)"
    if [ -z "$(az role assignment list --assignee "$kubelet_id" --scope "$acr_id" --role AcrPull --query '[].id' -o tsv)" ]; then
        az aks update --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --attach-acr "$acr_id" >&2
    else
        echo "déjà autorisé" >&2
    fi

    REGISTRY="$(az acr show --name "$ACR_NAME" --query loginServer -o tsv)"
    log "Connexion de Docker au registre $REGISTRY"
    az acr login --name "$ACR_NAME" >&2
    VALUES_FILE=""
else
    command -v minikube >/dev/null || die "minikube n'est pas installé"
    minikube status >/dev/null 2>&1 || { log "Démarrage de minikube"; minikube start >&2; }
    KUBE_CONTEXT=minikube

    # Registre privé interne au cluster (addon minikube). Il n'est joignable que depuis le cluster :
    # on l'ouvre sur localhost:5000 le temps du push. Les nœuds le voient eux aussi sous localhost:5000.
    log "Registre interne de minikube"
    minikube addons enable registry >&2
    kubectl --context "$KUBE_CONTEXT" -n kube-system rollout status deployment/registry --timeout=120s >&2
    kubectl --context "$KUBE_CONTEXT" -n kube-system port-forward service/registry 5000:80 >/dev/null 2>&1 &
    pf_pid=$!
    trap 'kill "$pf_pid" 2>/dev/null || true' EXIT
    for _ in $(seq 30); do
        curl -fs http://localhost:5000/v2/ >/dev/null && break
        sleep 0.5
    done
    curl -fs http://localhost:5000/v2/ >/dev/null || die "registre minikube injoignable sur localhost:5000"
    REGISTRY=localhost:5000
    VALUES_FILE="$ROOT/deploy/values-minikube.yaml"
fi

log "Build et push des images vers $REGISTRY"
TAG="$("$ROOT/deploy/build-push.sh" "$REGISTRY" "${TAG:-}")"

log "Déploiement Helm de la version $TAG dans le namespace $NAMESPACE"
# Si les pods ne deviennent pas prêts, Helm revient à la version précédente.
# Helm 4 a renommé --atomic (Helm 3) en --rollback-on-failure.
if helm upgrade --help | grep -q -- --rollback-on-failure; then
    rollback_flag=--rollback-on-failure
else
    rollback_flag=--atomic
fi
# Les mots de passe passent par des fichiers temporaires <(...) : ils n'apparaissent pas dans la ligne de commande.
helm upgrade --install "$RELEASE" "$ROOT/deploy/helm/poll-app" \
    --kube-context "$KUBE_CONTEXT" \
    --namespace "$NAMESPACE" --create-namespace \
    "$rollback_flag" --wait --timeout 10m \
    ${VALUES_FILE:+--values "$VALUES_FILE"} \
    --set image.registry="$REGISTRY" \
    --set image.tag="$TAG" \
    --set-file postgres.schema="$ROOT/poll-application/schema.sql" \
    --set-file postgres.password=<(printf %s "$POSTGRES_PASSWORD") \
    --set-file redis.password=<(printf %s "${REDIS_PASSWORD:-}") >&2

log "Application déployée (version $TAG)"
for svc in poll result; do
    if [ "$TARGET" = azure ]; then
        # L'IP publique du load balancer Azure peut mettre une minute à apparaître
        ip=""
        for _ in $(seq 60); do
            ip="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get service "$svc" \
                -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
            [ -n "$ip" ] && break
            sleep 5
        done
        url="http://${ip:-<IP pas encore attribuée>}"
    else
        port="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get service "$svc" -o jsonpath='{.spec.ports[0].nodePort}')"
        url="http://$(minikube ip):$port"
    fi
    printf '%-7s %s\n' "$svc" "$url"
done
