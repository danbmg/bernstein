# Bernstein : déploiement de l'application Poll sur Kubernetes

> 🎓 Projet Epitech (3e année, Epitech Nice, 2026), réalisé en équipe.

Une seule commande fait tout le chemin, du code source au cluster :
1. **build** des 3 images (poll, result, worker) ;
2. **push** dans un registre privé (Azure Container Registry) ;
3. **déploiement** sur AKS avec Helm.

Les pages **poll** (vote) et **result** (résultats) sont accessibles depuis Internet.

```
              IP publique 1                                              IP publique 2
Internet ──► LB Azure ──► poll (2-4 pods) ──► Redis ──► worker ──► PostgreSQL ◄── result (2-4 pods) ◄── LB Azure ◄── Internet
                          Flask              file      Java       StatefulSet      Node.js
                                             "votes"              + disque (PVC)   Socket.IO
```

| Fichier | Rôle |
|---|---|
| `deploy/deploy.sh` | **Point d'entrée** : build, push, puis `helm upgrade --install`. Relançable sans risque |
| `deploy/build-push.sh` | Build et push des 3 images, taguées avec le SHA git (jamais `latest`) |
| `deploy/helm/poll-app/` | Chart Helm : Deployments, StatefulSet, Services, HPA, PDB, Secret, ConfigMap |
| `deploy/test-zero-downtime.sh` | Requêtes en continu, avec comptage des erreurs, pendant une mise à jour |
| `azure.sh` | Création, arrêt et suppression de **notre** cluster AKS et de l'ACR (voir [README-azure.md](README-azure.md)) |
| `docs/choices.md` | **Justification de chaque choix technique**, avec les mesures et les tests |
| `poll-application/` | Code des 3 services, fourni par le sujet |

## Prérequis

- `az` (Azure CLI), `docker`, `kubectl`, `helm` (version 3 ou 4) ;
- un cluster **AKS** et un registre **ACR** dans le même abonnement. Pour les créer : `./azure.sh up` (voir [README-azure.md](README-azure.md)).

## Credentials et secrets : où les définir

Aucun secret n'est stocké dans ce dépôt.

| Secret | Où le définir | Détail |
|---|---|---|
| Identifiants Azure | `az login` dans le terminal qui déploie | Les scripts réutilisent cette session. En CI : `az login --service-principal -u <APP_ID> -p <SECRET> --tenant <TENANT>` |
| **`POSTGRES_PASSWORD`** | variable d'environnement, **avant** de lancer `deploy/deploy.sh` | `export POSTGRES_PASSWORD='…'`. Elle est transmise à Helm par un fichier temporaire, jamais dans la ligne de commande, puis stockée dans le Secret Kubernetes `poll-app-secrets`. Elle ne s'applique qu'à la **création** de la base |
| `REDIS_PASSWORD` | optionnel, même méthode | Sans valeur, il est généré au premier déploiement, puis réutilisé |
| Accès au registre | rien à faire | Le cluster tire les images avec son identité managée (rôle `AcrPull`, vérifié et posé par `deploy.sh`). Le compte admin de l'ACR est désactivé |

## Déploiement initial (cluster vierge)

```bash
git clone https://github.com/danbmg/bernstein.git && cd bernstein
az login
export RESOURCE_GROUP=<resource group du cluster> AKS_NAME=<nom du cluster> ACR_NAME=<nom du registre>
export POSTGRES_PASSWORD='<mot de passe>'
deploy/deploy.sh
```

Le script :
1. vérifie les outils et la connexion Azure, puis récupère le kubeconfig du cluster ;
2. autorise le cluster à lire le registre (si ce n'est pas déjà fait) ;
3. build et pousse les 3 images ;
4. installe le chart dans le namespace `poll-app`, attend que tous les pods soient prêts (rollback automatique sinon) ;
5. affiche les URL de poll et result :

```
poll    http://20.x.x.x
result  http://20.y.y.y
```

## Vérifier

```bash
kubectl -n poll-app get pods -o wide        # 2 poll et 2 result, répartis sur les 2 nœuds
kubectl -n poll-app get svc                 # EXTERNAL-IP de poll et result ; redis et postgres internes
kubectl -n poll-app get hpa,pdb,pvc         # auto-scaling, protection pendant un drain, disque Postgres
```

Voter sur la page poll. Le vote apparaît sur la page result en une à deux secondes.

## Mise à jour sans interruption

```bash
# Terminal 1 : requêtes en continu sur poll et result
deploy/test-zero-downtime.sh

# Terminal 2 : modifier le code d'un service (ex. poll-application/poll/templates/index.html), puis
deploy/deploy.sh

# Terminal 1 : Ctrl+C une fois le déploiement fini -> « Bilan : N requêtes, 0 erreur(s) »
```

Pas besoin de commiter : un code modifié reçoit un tag `<sha>-dirty-<horodatage>`, donc une nouvelle version.

Pourquoi aucune requête n'échoue : [docs/choices.md § 12](docs/choices.md#12-mise-à-jour-sans-interruption).

## Rollback

En cas d'échec, `deploy.sh` revient tout seul à la version précédente. Pour revenir manuellement en arrière :

```bash
helm history poll-app -n poll-app                  # liste des versions déployées
helm rollback poll-app <REVISION> -n poll-app --wait
```

Le rollback est lui aussi un rolling update : il se fait sans coupure. Les anciennes images sont toujours dans l'ACR.

## Montrer les points clés

| Point | Commande |
|---|---|
| Registre privé | `az acr repository list --name $ACR_NAME -o table`, puis `docker logout $ACR_NAME.azurecr.io && docker pull $ACR_NAME.azurecr.io/poll:<tag>` (réponse : `unauthorized`) |
| Répartition de charge | `for i in $(seq 20); do curl -s http://<IP_POLL> \| grep -o 'poll-[a-z0-9]*-[a-z0-9]*'; done \| sort \| uniq -c` |
| Auto-scaling | `kubectl -n poll-app run load --image=busybox:1.37 --restart=Never -- sh -c 'fin=$(( $(date +%s) + 180 )); while [ "$(date +%s)" -lt "$fin" ]; do wget -q -O /dev/null http://poll; done'`, puis `kubectl -n poll-app get hpa -w` : 2 → 3 pods, puis retour à 2 environ 6 min après la fin de la charge, qui s'arrête seule au bout de 3 min. Ménage : `kubectl -n poll-app delete pod load` |
| Persistance | `kubectl -n poll-app delete pod postgres-0` : les votes sont toujours là |
| Restart policy | `kubectl -n poll-app exec deploy/worker -- kill 1`, puis `RESTARTS` passe à 1 |
| Drain d'un nœud | `kubectl drain <nœud> --ignore-daemonsets --delete-emptydir-data` pendant `test-zero-downtime.sh`, puis `kubectl uncordon <nœud>` |

## Test en local (minikube)

```bash
export POSTGRES_PASSWORD='<mot de passe>'
deploy/deploy.sh --local
```

Le script utilise le registre interne de minikube et metrics-server (nécessaire au HPA). poll et result sont exposés en NodePort.

Sans Kubernetes, `docker compose` lance l'application seule :

```bash
cp .env.example .env        # puis renseigner POSTGRES_PASSWORD et REDIS_PASSWORD
docker compose up --build   # poll : http://localhost:8080, result : http://localhost:8081
docker compose down -v      # arrête tout et supprime la base
```

Sur Fedora ou RHEL (SELinux actif), Postgres s'arrête avec `schema.sql: Permission denied` : ajouter `,z` à la fin du montage de `schema.sql` dans `docker-compose.yml` (`…/schema.sql:ro,z`).

## Nettoyage

```bash
helm uninstall poll-app -n poll-app     # supprime l'application, mais GARDE le disque Postgres (PVC)
kubectl delete namespace poll-app       # supprime tout, données comprises
./azure.sh stop                         # arrête notre cluster (plus de facturation des nœuds)
./azure.sh down                         # supprime toute notre infrastructure Azure (irréversible)
```
