#!/usr/bin/env bash
# Build les 3 images de l'app (poll, result, worker) et les pousse vers un registre privé.
#
# Usage : deploy/build-push.sh <registre> [tag]
#   registre : ex. monacr.azurecr.io. Docker doit déjà y être connecté (az acr login / docker login) :
#              deploy/deploy.sh s'en charge.
#   tag      : par défaut, le SHA git court du dernier commit qui a modifié poll-application/
#
# Les logs vont sur stderr ; stdout ne contient que le tag utilisé (pour deploy.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR=poll-application
SERVICES="poll result worker"
# Les nœuds AKS sont en amd64 : on force l'architecture, même si on build depuis un Mac ARM
PLATFORM="${PLATFORM:-linux/amd64}"

REGISTRY="${1:?Usage : $0 <registre> [tag]}"

# SHA du dernier commit qui touche le code de l'app : si seuls les fichiers de déploiement changent,
# le tag ne change pas et Kubernetes ne redémarre rien.
# Code modifié mais pas commité : on ajoute un horodatage pour que chaque build ait un tag unique.
default_tag() {
    local sha
    sha="$(git -C "$ROOT" log -1 --format=%h -- "$APP_DIR")"
    if [ -n "$(git -C "$ROOT" status --porcelain -- "$APP_DIR")" ]; then
        echo "WARN: code de l'app non commité, tag temporaire" >&2
        echo "$sha-dirty-$(date -u +%Y%m%d%H%M%S)"
    else
        echo "$sha"
    fi
}
TAG="${2:-$(default_tag)}"

for svc in $SERVICES; do
    image="$REGISTRY/$svc:$TAG"
    echo "==> $image" >&2
    docker build --platform "$PLATFORM" -t "$image" "$ROOT/$APP_DIR/$svc" >&2
    docker push "$image" >&2
done

echo "$TAG"
