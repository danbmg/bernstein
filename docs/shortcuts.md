# Raccourcis

Pour chaque critère : **où** c'est dans le code, **quoi** lancer, et **pourquoi** en une ou deux phrases.
Le détail de chaque choix est dans [choices.md](choices.md).

## Justification - Auto-scaling

| Quoi | Où |
|---|---|
| HPA de poll | [poll.yaml:104-124](../deploy/helm/poll-app/templates/poll.yaml#L104-L124), réglages en [values.yaml:29-35](../deploy/helm/poll-app/values.yaml#L29-L35) (2 à 4 pods, seuil 70 % CPU) |
| HPA de result | [result.yaml:95-114](../deploy/helm/poll-app/templates/result.yaml#L95-L114), réglages en [values.yaml:47-50](../deploy/helm/poll-app/values.yaml#L47-L50) |
| Ajout automatique de nœuds (2 à 3) | [azure.sh:76-104](../azure.sh#L76-L104) |

```bash
# Terminal 1
kubectl -n poll-app get hpa poll -w
# Terminal 2 : 3 min de charge, qui s'arrête toute seule
kubectl -n poll-app run load --image=busybox:1.37 --restart=Never -- sh -c 'fin=$(( $(date +%s) + 180 )); while [ "$(date +%s)" -lt "$fin" ]; do wget -q -O /dev/null http://poll; done'
# -> poll passe de 2 à 3 pods en ~2 min, puis redescend ~6 min après
kubectl -n poll-app delete pod load   # ménage
```

**Pourquoi** : quand le CPU moyen dépasse 70 %, Kubernetes ajoute des pods, jusqu'à 4. Si les nœuds sont pleins, Azure ajoute un nœud, jusqu'à 3.

**Pourquoi pas de `replicas` dans le Deployment ?** Sinon, chaque déploiement remettrait le nombre de pods à cette valeur et annulerait le travail du HPA.

## Initial deployment - Persistent data

| Quoi | Où |
|---|---|
| Disque demandé pour Postgres | [postgres.yaml:111-121](../deploy/helm/poll-app/templates/postgres.yaml#L111-L121), taille 1 Gi en [values.yaml:98](../deploy/helm/poll-app/values.yaml#L98) |
| Disque monté dans le conteneur | [postgres.yaml:84-85](../deploy/helm/poll-app/templates/postgres.yaml#L84-L85) |

```bash
kubectl -n poll-app get pvc                  # data-postgres-0 : Bound
kubectl -n poll-app delete pod postgres-0    # puis recharger result : les votes sont toujours là
```

**Pourquoi** : Postgres est un StatefulSet, donc le pod recréé retrouve toujours le même disque. Redis n'a pas de disque : ce n'est qu'une file d'attente, vidée en continu par le worker.

## Initial deployment - Private Docker registry

| Quoi | Où |
|---|---|
| Registre Azure (ACR), compte admin désactivé | [azure.sh:60-65](../azure.sh#L60-L65) (ligne 64) |
| Le cluster a le droit de lire le registre, sans mot de passe | [deploy.sh:49-59](../deploy/deploy.sh#L49-L59) |
| Images taguées avec le SHA git, jamais `latest` | [build-push.sh:20-33](../deploy/build-push.sh#L20-L33) |

```bash
az acr repository list --name "$ACR_NAME" -o table   # poll, result, worker
docker logout "$ACR_NAME.azurecr.io"
docker pull "$ACR_NAME.azurecr.io/poll:<tag>"        # -> unauthorized
```

**Pourquoi** : personne ne peut télécharger nos images sans être connecté. Le cluster utilise son identité Azure, donc il n'y a aucun mot de passe à stocker.

## Justification - Replicas

| Service | Nombre | Où |
|---|---|---|
| poll | 2 à 4 | [values.yaml:31-33](../deploy/helm/poll-app/values.yaml#L31-L33), lu par le HPA en [poll.yaml:116-117](../deploy/helm/poll-app/templates/poll.yaml#L116-L117) |
| result | 2 à 4 | [values.yaml:48-49](../deploy/helm/poll-app/values.yaml#L48-L49), lu par le HPA en [result.yaml:106-107](../deploy/helm/poll-app/templates/result.yaml#L106-L107) |
| worker | 1 | [values.yaml:64](../deploy/helm/poll-app/values.yaml#L64), lu en [worker.yaml:10](../deploy/helm/poll-app/templates/worker.yaml#L10) |
| redis | 1 | [redis.yaml:9](../deploy/helm/poll-app/templates/redis.yaml#L9) |
| postgres | 1 | [postgres.yaml:55](../deploy/helm/poll-app/templates/postgres.yaml#L55) |

```bash
kubectl -n poll-app get deploy,sts,hpa
```

**Pourquoi**
- poll et result : au moins 2, pour qu'un pod puisse tomber sans couper la page. Il n'y a pas de `replicas` dans leur Deployment ([poll.yaml:9-10](../deploy/helm/poll-app/templates/poll.yaml#L9-L10)) : c'est le HPA qui décide.
- worker : un seul, pour traiter les votes dans l'ordre.
- redis : un seul, pour avoir une seule file de votes.
- postgres : un seul, car un disque ne peut être branché que sur un pod.

## Justification - Number of nodes

**Où** : [azure.sh:29-32](../azure.sh#L29-L32) (2 nœuds, jusqu'à 3 automatiquement).

```bash
kubectl get nodes
```

**Pourquoi** : avec 2 nœuds, l'un peut tomber sans couper l'application. Un 3e permanent coûterait plus pour rien, puisque tout tient sur un seul nœud. Azure l'ajoute tout seul si la place manque.

## Justification - Repository cleanliness and structure

| Dossier / fichier | Rôle |
|---|---|
| [deploy/](../deploy/) | scripts de déploiement et chart Helm |
| [docs/](.) | justification des choix, démo, raccourcis |
| [poll-application/](../poll-application/) | code fourni par le sujet |
| [azure.sh](../azure.sh) | création et arrêt du cluster |
| [.env.example](../.env.example), [azure.env.example](../azure.env.example) | modèles à copier : les vrais fichiers ne sont jamais commités ([.gitignore:17](../.gitignore#L17), [.gitignore:33](../.gitignore#L33)) |

```bash
git status --short     # rien qui traîne
git ls-files           # aucun secret, aucun fichier généré
```

**Pourquoi** : chaque dossier a un rôle clair, et aucun mot de passe ni kubeconfig n'est dans le dépôt.

## Justification - Probes

| Service | Readiness : prêt à recevoir du trafic ? | Liveness : encore vivant ? |
|---|---|---|
| poll | [poll.yaml:70-74](../deploy/helm/poll-app/templates/poll.yaml#L70-L74) (Redis répond) | [poll.yaml:75-79](../deploy/helm/poll-app/templates/poll.yaml#L75-L79) |
| result | [result.yaml:60-64](../deploy/helm/poll-app/templates/result.yaml#L60-L64) (Postgres répond) | [result.yaml:65-69](../deploy/helm/poll-app/templates/result.yaml#L65-L69) |
| worker | [worker.yaml:53-57](../deploy/helm/poll-app/templates/worker.yaml#L53-L57) (Redis et Postgres répondent) | [worker.yaml:58-62](../deploy/helm/poll-app/templates/worker.yaml#L58-L62) |
| redis | [redis.yaml:46-49](../deploy/helm/poll-app/templates/redis.yaml#L46-L49) | [redis.yaml:50-53](../deploy/helm/poll-app/templates/redis.yaml#L50-L53) |
| postgres | [postgres.yaml:96-99](../deploy/helm/poll-app/templates/postgres.yaml#L96-L99) | [postgres.yaml:100-104](../deploy/helm/poll-app/templates/postgres.yaml#L100-L104), et une startupProbe pour le premier démarrage : [postgres.yaml:91-95](../deploy/helm/poll-app/templates/postgres.yaml#L91-L95) |

```bash
kubectl -n poll-app scale deploy/redis --replicas=0
kubectl -n poll-app get pods -w      # poll passe à 0/1 mais ne redémarre pas
kubectl -n poll-app scale deploy/redis --replicas=1
```

**Pourquoi** : si la readiness échoue, le pod ne reçoit plus de trafic. Si la liveness échoue, le pod est redémarré. La liveness ne teste pas Redis : sinon, une panne de Redis ferait redémarrer tous les pods poll pour rien.

## Justification - Documentation

- [README.md](../README.md) : déployer, où mettre les mots de passe, revenir en arrière ;
- [README-azure.md](../README-azure.md) : créer, arrêter et supprimer le cluster ;
- [choices.md](choices.md) : pourquoi chaque choix.

## Initial deployment - App working

**Où** : [deploy.sh](../deploy/deploy.sh) fait tout. Il build et pousse les images ([deploy.sh:90-91](../deploy/deploy.sh#L90-L91)), puis déploie avec Helm ([deploy.sh:102-111](../deploy/deploy.sh#L102-L111)).

```bash
kubectl delete namespace poll-app                 # repartir d'un cluster vide
export POSTGRES_PASSWORD="$(openssl rand -hex 16)"
deploy/deploy.sh                                  # affiche les 2 URL à la fin
```

**Attention** : un navigateur = un votant. Revoter depuis le même navigateur remplace le vote au lieu d'en ajouter un. Pour en ajouter un, utiliser une fenêtre privée.

## Redeployment - No-downtime update

Réglages (sur poll ; result a les mêmes) :

| Réglage | Où | Rôle |
|---|---|---|
| Tag = SHA git | [build-push.sh:20-33](../deploy/build-push.sh#L20-L33) | chaque version a un tag différent, donc Kubernetes voit le changement |
| `maxUnavailable: 0`, `maxSurge: 1` | [poll.yaml:14-18](../deploy/helm/poll-app/templates/poll.yaml#L14-L18) | le nouveau pod démarre avant que l'ancien soit retiré |
| Readiness | [poll.yaml:70-74](../deploy/helm/poll-app/templates/poll.yaml#L70-L74) | le nouveau pod ne reçoit du trafic qu'une fois prêt |
| `preStop: sleep 10` | [poll.yaml:80-85](../deploy/helm/poll-app/templates/poll.yaml#L80-L85) | l'ancien pod répond encore le temps d'être retiré du load balancer |
| PodDisruptionBudget | [poll.yaml:126-138](../deploy/helm/poll-app/templates/poll.yaml#L126-L138) | jamais tous les pods arrêtés en même temps |
| Rollback automatique | [deploy.sh:94-111](../deploy/deploy.sh#L94-L111) | si la nouvelle version ne démarre pas, Helm revient à l'ancienne |

```bash
# Terminal 1
deploy/test-zero-downtime.sh
# Terminal 2 : modifier poll-application/poll/templates/index.html, puis
deploy/deploy.sh
# Terminal 1 : Ctrl+C une fois le déploiement fini -> « 0 erreur(s) »
```

**Version cassée** : Helm attend 10 min avant de revenir en arrière. C'est plus rapide à la main : `helm rollback poll-app -n poll-app`.

## Justification - Restart policies

**Où** : `restartPolicy: Always` dans chaque pod : [poll.yaml:32](../deploy/helm/poll-app/templates/poll.yaml#L32), [result.yaml:28](../deploy/helm/poll-app/templates/result.yaml#L28), [worker.yaml:30](../deploy/helm/poll-app/templates/worker.yaml#L30), [redis.yaml:26](../deploy/helm/poll-app/templates/redis.yaml#L26), [postgres.yaml:65](../deploy/helm/poll-app/templates/postgres.yaml#L65).

```bash
kubectl -n poll-app exec deploy/worker -- kill 1
kubectl -n poll-app get pods          # RESTARTS du worker passe à 1
```

**Pourquoi** : `Always` est la seule valeur possible pour un Deployment ou un StatefulSet. Le worker s'arrête à la moindre erreur ([Worker.java:48-51](../poll-application/worker/src/main/java/worker/Worker.java#L48-L51)) et compte sur Kubernetes pour le relancer.

## Justification - Resource limits

| Service | Où |
|---|---|
| poll | [values.yaml:38-44](../deploy/helm/poll-app/values.yaml#L38-L44) |
| result | [values.yaml:53-59](../deploy/helm/poll-app/values.yaml#L53-L59) |
| worker | [values.yaml:65-73](../deploy/helm/poll-app/values.yaml#L65-L73) |
| redis | [values.yaml:79-86](../deploy/helm/poll-app/values.yaml#L79-L86) |
| postgres | [values.yaml:101-108](../deploy/helm/poll-app/values.yaml#L101-L108) |

```bash
kubectl -n poll-app top pods          # consommation réelle, sous les valeurs réservées
```

**Pourquoi** : `requests` est ce que Kubernetes réserve pour le pod, `limits` est le maximum autorisé. Les valeurs viennent de mesures sous charge ([choices.md § 7](choices.md#7-ressources-requests-et-limits)).

**Limiter le CPU de Redis** : changer `cpu` en [values.yaml:85](../deploy/helm/poll-app/values.yaml#L85), puis relancer `deploy/deploy.sh`.

## Justification - Exposed ports

| Service | Port | Accessible depuis | Où |
|---|---|---|---|
| poll | 80 | Internet | [poll.yaml:89-102](../deploy/helm/poll-app/templates/poll.yaml#L89-L102) |
| result | 80 | Internet | [result.yaml:77-93](../deploy/helm/poll-app/templates/result.yaml#L77-L93) |
| redis | 6379 | le cluster uniquement | [redis.yaml:57-69](../deploy/helm/poll-app/templates/redis.yaml#L57-L69) |
| postgres | 5432 | le cluster uniquement | [postgres.yaml:17-29](../deploy/helm/poll-app/templates/postgres.yaml#L17-L29) |
| worker | aucun | personne | [worker.yaml:2](../deploy/helm/poll-app/templates/worker.yaml#L2) |

```bash
kubectl -n poll-app get svc           # seuls poll et result ont une EXTERNAL-IP
```

**Pourquoi** : on n'ouvre que les deux pages demandées. Les bases de données restent internes.

## Justification - Affinity policies

**Où** : [poll.yaml:35-49](../deploy/helm/poll-app/templates/poll.yaml#L35-L49) et [result.yaml:32-42](../deploy/helm/poll-app/templates/result.yaml#L32-L42).

```bash
kubectl -n poll-app get pods -o wide  # colonne NODE : un poll et un result sur chaque nœud
```

**Pourquoi** : si un nœud tombe, il reste un poll et un result sur l'autre. C'est une préférence et pas une obligation, pour que Kubernetes puisse quand même ajouter un pod pendant une mise à jour ou un pic de trafic.

## Justification - Load balancers

| Quoi | Où |
|---|---|
| poll et result exposés en `LoadBalancer` | [values.yaml:36-37](../deploy/helm/poll-app/values.yaml#L36-L37) et [values.yaml:51-52](../deploy/helm/poll-app/values.yaml#L51-L52) |
| Un visiteur reste sur le même pod result | [result.yaml:87](../deploy/helm/poll-app/templates/result.yaml#L87) |

```bash
kubectl -n poll-app get svc
POLL=$(kubectl -n poll-app get svc poll -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
for i in $(seq 20); do curl -s "http://$POLL/" | grep -o 'poll-[a-z0-9]*-[a-z0-9]*'; done | sort | uniq -c
# -> les 20 requêtes sont réparties entre les 2 pods poll
```

**Pourquoi** : Azure donne une IP publique à chaque Service et répartit le trafic entre les pods. La page result se met à jour par une suite de requêtes ([app.js:2](../poll-application/result/views/app.js#L2)) qui doivent toutes arriver au même pod, d'où `sessionAffinity: ClientIP`.

**Pourquoi pas un Ingress ?** Il faudrait installer un composant en plus. Pour deux pages sans nom de domaine, deux IP suffisent.
