#!/usr/bin/env bash
# Vérifie qu'une mise à jour se fait sans interruption : interroge poll et result en boucle
# et compte toute réponse autre que 200 (erreur HTTP, connexion refusée, délai dépassé = code 000).
#
# Usage : deploy/test-zero-downtime.sh [url_poll url_result]
#   Sans argument, les URL sont les IP externes des Services poll et result (namespace NAMESPACE, défaut poll-app).
#   Ctrl+C arrête la boucle et affiche le bilan. Code de sortie 1 s'il y a eu au moins une erreur.
#
# Démo : lancer ce script dans un terminal, modifier le code d'une app, puis deploy/deploy.sh dans un autre.
set -euo pipefail

NAMESPACE="${NAMESPACE:-poll-app}"

die() { printf 'ERREUR : %s\n' "$*" >&2; exit 1; }

service_url() {
    local ip
    ip="$(kubectl -n "$NAMESPACE" get service "$1" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
    [ -n "$ip" ] || die "le Service $1 n'a pas d'IP externe (namespace $NAMESPACE)"
    echo "http://$ip"
}

command -v curl >/dev/null || die "curl n'est pas installé"
case $# in
    2) urls=("$1" "$2") ;;
    0)
        command -v kubectl >/dev/null || die "kubectl n'est pas installé"
        urls=("$(service_url poll)" "$(service_url result)")
        ;;
    *) die "usage : $0 [url_poll url_result]" ;;
esac

total=0
errors=0
summary() {
    printf '\nBilan : %d requêtes, %d erreur(s)\n' "$total" "$errors"
    [ "$errors" -eq 0 ] && exit 0
    exit 1
}
trap summary INT TERM

echo "Requêtes en continu sur ${urls[*]} (Ctrl+C pour arrêter)"
while true; do
    for url in "${urls[@]}"; do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" || true)"
        total=$((total + 1))
        if [ "$code" != 200 ]; then
            errors=$((errors + 1))
            # \r\033[K : efface la ligne de progression, l'erreur reste affichée au-dessus
            printf '\r\033[K%s  %s -> %s\n' "$(date +%T)" "$url" "$code"
        fi
    done
    printf '\r%d requêtes, %d erreur(s)' "$total" "$errors"
done
