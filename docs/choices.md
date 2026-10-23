# Choix techniques

Pour chaque choix : ce qu'on a fait, pourquoi, ce qu'on a écarté, et comment le vérifier sur le cluster.
Les commandes supposent le namespace par défaut : `-n poll-app`.

| Critère de la grille | Section |
|---|---|
| Private Docker registry | [1. Registre privé](#1-registre-privé) |
| Persistent data | [2. Données persistantes](#2-données-persistantes) |
| Replicas | [3. Replicas](#3-replicas) |
| Number of nodes | [4. Nombre de nœuds](#4-nombre-de-nœuds) |
| Probes | [5. Probes](#5-probes) |
| Restart policies | [6. Restart policy](#6-restart-policy) |
| Resource limits | [7. Ressources](#7-ressources-requests-et-limits) |
| Exposed ports | [8. Ports exposés](#8-ports-exposés) |
| Affinity policies | [9. Affinité](#9-affinité) |
| Load balancers | [10. Load balancers](#10-load-balancers) |
| Auto-scaling | [11. Auto-scaling](#11-auto-scaling) |
| No-downtime update | [12. Mise à jour sans interruption](#12-mise-à-jour-sans-interruption) |

Voir aussi : [13. Comportement en cas de panne](#13-comportement-en-cas-de-panne-testé), [14. Plateforme et outils](#14-plateforme-et-outils), [15. Limites connues](#15-limites-connues).

---

## 1. Registre privé

**Choix** : Azure Container Registry (ACR), SKU Basic, **compte admin désactivé**. Le cluster tire les images avec son identité managée (rôle `AcrPull` sur l'ACR, posé par `--attach-acr`).

**Pourquoi**
- Le registre est dans la même région que le cluster : pas de trafic sortant facturé, et des pulls rapides.
- Aucun mot de passe de registre n'existe : pas d'`imagePullSecret` à créer, à faire fuiter ou à renouveler. `deploy/deploy.sh` vérifie le rôle `AcrPull` et le pose s'il manque.
- Pour pousser, `az acr login` réutilise la session `az login` de la personne qui déploie.

**Tags** : chaque image est taguée avec le SHA git du dernier commit qui a modifié `poll-application/`, et **jamais `latest`**.
- Chaque déploiement désigne une version précise, ce qui permet le rollback.
- Si le code a changé mais n'est pas commité, on ajoute un suffixe `-dirty-<horodatage>` (`deploy/build-push.sh`).
- Un même tag pointe toujours sur la même image, donc `imagePullPolicy: IfNotPresent` est sûr.

**Écarté**
- Docker Hub en privé : un seul repo privé gratuit, et il faut un secret de pull.
- Le compte admin de l'ACR : c'est un mot de passe partagé.

**Le montrer**
```bash
az acr repository list --name <ACR_NAME> -o table               # poll, result, worker
az acr repository show-tags --name <ACR_NAME> --repository poll -o table
az acr show --name <ACR_NAME> --query "{admin:adminUserEnabled, anonymousPull:anonymousPullEnabled}"
docker logout <ACR_NAME>.azurecr.io && docker pull <ACR_NAME>.azurecr.io/poll:<tag>   # -> unauthorized
kubectl -n poll-app get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}'
```

## 2. Données persistantes

**Choix** : PostgreSQL en **StatefulSet** avec `volumeClaimTemplates`, ce qui crée le PVC `data-postgres-0`.
- Classe de stockage : celle du cluster par défaut, `managed-csi` sur AKS (un disque Azure).
- Taille de 1 Gi, en `ReadWriteOnce`.

| Point | Choix | Raison |
|---|---|---|
| StatefulSet plutôt que Deployment | identité stable `postgres-0`, et un PVC qui lui reste attaché | le pod recréé retrouve **son** disque, quel que soit le nœud |
| Point de montage | `/var/lib/postgresql` | Postgres 18 met ses données dans `/var/lib/postgresql/18/docker` : on monte le parent |
| Schéma | `schema.sql` en ConfigMap dans `/docker-entrypoint-initdb.d` | appliqué une seule fois, à la création de la base ; la `startupProbe` (TCP) ne passe qu'après |
| 1 Gi | quelques Mo de votes | Azure facture le disque à sa taille |

**Redis n'a pas de volume, et c'est voulu.**
- Redis n'est qu'une file de transit : le worker la vide en quelques millisecondes.
- Avec un disque Azure, déplacer Redis (drain, panne) oblige à détacher puis rattacher ce disque, soit environ une minute pendant laquelle poll ne peut plus enregistrer de votes.
- Sans disque, Redis redémarre en quelques secondes. Le prix à payer : les votes en attente à cet instant sont perdus, et il y en a presque toujours zéro.

**Le montrer** (testé : 2 votes avant, 2 votes après, même PVC)
```bash
kubectl -n poll-app get pvc
kubectl -n poll-app exec postgres-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT vote, count(*) FROM votes GROUP BY vote"'
kubectl -n poll-app delete pod postgres-0      # le StatefulSet le recrée sur le même PVC
# même requête : mêmes chiffres
```
**Vérifié sur AKS** : les votes du 22/10 étaient toujours là le 23/10, après un arrêt complet du cluster (`./azure.sh stop` éteint les VM, `start` les rallume, et le disque est rebranché à `postgres-0`).

`helm uninstall` **garde** le PVC : les données survivent à une désinstallation. Seul `kubectl delete namespace poll-app` (ou `kubectl delete pvc`) les efface.

## 3. Replicas

| Composant | Replicas | Raison |
|---|---|---|
| poll | 2 à 4 (HPA) | sans état : on peut en ajouter librement. 2 au minimum, pour qu'un pod puisse tomber ou être remplacé sans coupure |
| result | 2 à 4 (HPA) | idem. Le client Socket.IO fait du long-polling, d'où l'affinité de session (voir [10](#10-load-balancers)) |
| worker | 1 | deux workers en parallèle pourraient enregistrer **dans le désordre** deux votes successifs du même votant (le premier écraserait le second). Pendant un redémarrage, les votes attendent dans Redis : du retard, mais ni erreur ni perte |
| redis | 1 (stratégie `Recreate`) | deux Redis derrière le même Service couperaient la file en deux, et le worker n'en verrait qu'une moitié |
| postgres | 1 | un 2e pod sur le même disque est impossible (`ReadWriteOnce`). Une vraie réplication demande un opérateur (CloudNativePG) : hors périmètre |

Pour poll et result, `replicas` n'est **pas** écrit dans le Deployment : c'est le HPA qui le fixe. Sinon, chaque `helm upgrade` le remettrait à 2 et annulerait le travail du HPA.

## 4. Nombre de nœuds

**Choix** : **2 nœuds** `Standard_B2s_v2` (2 vCPU, 8 Gio), dans la région `denmarkeast`, avec l'**autoscaler de nœuds réglé de 2 à 3** (`azure.sh`, variables `NODE_COUNT` et `NODE_MAX_COUNT`).

Pourquoi des B2s_v2 : sur notre abonnement, la famille des B2s d'origine est limitée à 4 vCPU (`Standard BS Family vCPUs : 4`), soit 2 nœuds sans aucune marge. Les B2s_v2 appartiennent à une autre famille de VM.

**Pourquoi au moins 2**
- Avec 1 seul nœud, tout tombe avec lui : panne, `kubectl drain` ou mise à jour d'AKS.
- L'anti-affinité ([9](#9-affinité)) n'a de sens qu'avec au moins 2 nœuds.

**Pourquoi pas 3 en permanence**
- **Ce n'est pas nécessaire.** Mesuré sur AKS : nos pods et ceux d'AKS demandent 1,9 CPU sur les 3,8 allouables du cluster. Lors des deux drains testés sur AKS, tout a tenu sur le nœud restant.
- **Coût** : un 3e nœud, c'est +50 % de facture de calcul, pour des ressources qui resteraient inutilisées.
- **Quota** : le quota régional de l'abonnement est de **6 vCPU** (4 déjà utilisés par nos 2 nœuds). 3 nœuds de 2 vCPU l'occupent entièrement. Or une mise à jour d'AKS ajoute un nœud temporaire : à 3 nœuds permanents, elle n'aurait plus de place. Vérification : `az vm list-usage --location denmarkeast -o table`.
- **Pas de règle du nombre impair** : le « 3 nœuds pour le quorum » concerne etcd et le control plane. Sur AKS, c'est Azure qui les gère. Nos nœuds sont de simples workers, et 2 suffisent.

**Avec 3 nœuds** : c'est possible sans rien changer au chart (`NODE_COUNT=3`). On gagne une chose : pendant la maintenance d'un nœud, il en reste 2, donc on garde la haute disponibilité.
- L'autoscaler apporte ce 3e nœud automatiquement, mais seulement quand des pods ne trouvent plus de place (state `Pending`).
- Il le retire une fois devenu inutile.

## 5. Probes

| Composant | readiness (reçoit du trafic ?) | liveness (doit-on le redémarrer ?) | startup |
|---|---|---|---|
| poll | `GET /readyz` : Redis répond à PING | `GET /healthz` | — |
| result | `GET /readyz` : `SELECT 1` réussit | `GET /healthz` | — |
| worker | `GET /readyz` : Redis **et** Postgres | `GET /healthz` | — |
| redis | `redis-cli ping` = PONG | port TCP 6379 ouvert | — |
| postgres | `pg_isready` en TCP | `pg_isready` (6 échecs tolérés) | `pg_isready` toutes les 5 s, jusqu'à 30 fois |

**Règles appliquées**
- **readiness ≠ liveness.** Une readiness en échec retire le pod des Services, sans le redémarrer. Une liveness en échec le redémarre.
- **La liveness ne teste jamais une dépendance.** Si elle testait Redis, une panne de Redis ferait redémarrer en boucle tous les pods poll, pour rien. `/healthz` répond simplement « le processus vit ».
- **La readiness teste les dépendances.** Un pod qui ne joint pas Redis ou Postgres ne reçoit pas de trafic. Pendant une mise à jour, c'est ce qui bloque une nouvelle version mal configurée (mauvais mot de passe, etc.) : elle ne devient jamais prête, les anciens pods continuent de servir, puis Helm fait un rollback.
- **La startupProbe de Postgres** suspend la liveness pendant l'initialisation (initdb + `schema.sql`), qui peut prendre plus de temps qu'un démarrage normal. `pg_isready -h 127.0.0.1` passe par TCP : pendant l'init, le serveur temporaire n'écoute que sur un socket local, donc la probe échoue tant que le schéma n'est pas appliqué.

**Compromis assumé** : si Redis est injoignable plus de 15 s (3 échecs × 5 s), tous les pods poll deviennent non prêts et la page de vote est indisponible. On préfère cela à une page qui s'affiche puis renvoie une erreur 500 au vote. Et c'est le prix de la protection pendant les mises à jour.

**poll tourne avec 8 threads gunicorn** (correction après la recette sur AKS)
- Le Dockerfile fourni lance gunicorn avec **un seul worker synchrone**, qui traite une connexion à la fois.
- Sur AKS, poll se figeait par moments. Une connexion qui n'envoie rien, ou un `/readyz` qui attend Redis (jusqu'à 29 s, avec les nouvelles tentatives de la bibliothèque redis), bloquait tout le pod. `/healthz` ne répondait plus, et la liveness tuait le pod : `CrashLoopBackOff`, et 60 erreurs sur 350 requêtes pendant la mise à jour. result (Node.js) n'était pas touché, parce qu'il traite plusieurs connexions à la fois.
- La correction ne touche pas au code : la variable `GUNICORN_CMD_ARGS="--threads 8"` dans le Deployment (`poll.gunicornArgs` dans `values.yaml`). gunicorn passe alors en worker `gthread`, et une connexion lente n'occupe qu'un thread.
- **8 threads, et pas 4** : quand Redis est en panne, chaque `/readyz` dure ~30 s et le kubelet en lance un toutes les 5 s, donc jusqu'à 6 en même temps. Il reste des threads pour `/healthz` et pour les visiteurs.

Testé sur k3s, avec un générateur de connexions muettes (une connexion ouverte toutes les 2 s, gardée 10 s sans rien envoyer) :

| Test | 1 worker synchrone | 8 threads |
|---|---|---|
| Requêtes en continu pendant 60 s | 25 erreurs sur 152 requêtes, pods poll redémarrés | 0 erreur sur 3 949, aucun redémarrage |
| Mise à jour du code pendant les requêtes | — | 0 erreur sur 4 528 |
| Redis coupé pendant 60 s | — | poll non prêt (voulu), `/healthz` répond en 0,02 s, aucun redémarrage |

**Vérifié sur AKS (23/10)** : `Using worker: gthread` dans les logs de poll, et aucun redémarrage de toute la recette.

## 6. Restart policy

**Choix** : `restartPolicy: Always`, écrit explicitement dans les 5 pods.

- C'est la **seule valeur autorisée** dans un Deployment ou un StatefulSet. L'API refuse les autres :
  `spec.template.spec.restartPolicy: Unsupported value: "OnFailure": supported values: "Always"`.
- `OnFailure` et `Never` servent aux **Jobs** : des tâches qui doivent se terminer, comme une migration ou un import.
- Le redémarrage est fait par le **kubelet**, sur le même nœud et dans le même pod : le compteur `RESTARTS` augmente. C'est différent d'un pod supprimé, que le ReplicaSet remplace par un nouveau pod.
- En cas d'arrêts répétés, le délai entre deux redémarrages double à chaque fois (10 s, 20 s, 40 s… jusqu'à 5 min) : c'est l'état `CrashLoopBackOff`. Le délai revient à zéro après 10 min sans incident.
- **Le worker compte dessus** : il fait `exit(1)` à la moindre erreur Redis ou Postgres.

**Le montrer** (testé : code de sortie 143 = SIGTERM, `restarts=1`, le vote suivant est bien traité)
```bash
kubectl -n poll-app exec deploy/worker -- kill 1
kubectl -n poll-app get pods -l app.kubernetes.io/name=worker    # RESTARTS = 1
```

## 7. Ressources (requests et limits)

- **requests** : ce que le scheduler **réserve** sur un nœud pour placer le pod. C'est aussi la base de calcul du HPA (« 70 % du CPU demandé »).
- **limits** : un plafond.
  - Au-delà de la limite CPU, le conteneur est **ralenti** (throttling).
  - Au-delà de la limite mémoire, il est **tué** (`OOMKilled`), puis redémarré.

**Méthode** : on a mesuré chaque service avec `docker stats`, au repos puis sous charge (30 s de `ab` à 10 connexions sur poll et sur result). Ce sont les mêmes images qu'en production, en amd64. On a ensuite appliqué une règle unique :

| Règle | Pourquoi |
|---|---|
| request mémoire ≥ pic mesuré | un pod qui reste sous sa request n'est pas le premier évincé quand le nœud manque de mémoire |
| limit mémoire ≈ 2 × request | de la marge pour les pics. Un dépassement signale une anomalie (fuite) : mieux vaut tuer le pod que le nœud |
| request CPU petite | le CPU est compressible : un pod qui en manque ralentit, sans planter. C'est aussi le seuil du HPA |
| limit CPU | les B2s_v2 sont des VM « burstable » : en continu, elles ne garantissent qu'une fraction de leurs 2 vCPU, et tout dépassement consomme des crédits CPU. Sans plafond, un seul pod pourrait épuiser ces crédits au détriment des autres |

**Mesures et valeurs retenues**

| Service | Mémoire repos → pic | CPU pic (sans limite) | requests (CPU / mém.) | limits (CPU / mém.) | Raison spécifique |
|---|---|---|---|---|---|
| poll | 42 → 49 Mi (44 → 51 Mi avec 8 threads) | 0,9 cœur | 100m / 64Mi | 500m / 128Mi | à 0,5 CPU, un pod tient **220 votes/s** |
| result | 31 → 120 Mi | 1,45 cœur | 100m / 128Mi | 500m / 256Mi | à 0,5 CPU, **2 900 req/s** |
| worker | 70 → 114 Mi | 0,2 cœur | 100m / 192Mi | 1000m / 512Mi | la JVM prend 25 % de la limite pour son tas (128 Mi), plus ~60 Mi hors tas. 1 CPU pour accélérer son démarrage (JIT) |
| redis | 6 → 9 Mi | 0,16 cœur | 50m / 32Mi | 250m / 128Mi | mesuré : **1 million de votes en file = 62 Mo**. La limite absorbe une longue panne du worker |
| postgres | 36 → 38 Mi | 0,2 cœur | 100m / 128Mi | 1000m / 512Mi | son cache (`shared_buffers`) fait 128 Mo par défaut et se remplit avec les données |

**Vérifié sur AKS** : au repos, poll consomme 42 Mi, result 22 Mi, worker 43 Mi, postgres 36 Mi et redis 3 Mi. Tous restent sous leur request.

**Budget**, mesuré sur AKS (`kubectl describe node`, sections *Allocatable* et *Allocated resources*) :
- un nœud B2s_v2 offre **1,9 CPU et 5,65 Gio allouables** ; AKS garde le reste pour le système ;
- avec les pods d'AKS, les deux nœuds avaient 1,13 et 0,79 CPU demandés (59 % et 41 %).

| Situation | CPU demandé par nos pods | Mémoire demandée |
|---|---|---|
| Normal (2 poll, 2 result) | 0,65 CPU | 736 Mi |
| HPA au maximum (4 poll, 4 result) | 1,05 CPU | 1 120 Mi |

En temps normal, tout tient sur **un** nœud : vérifié lors des drains sur AKS. Si un drain arrive pendant que le HPA est au maximum, les pods d'AKS en plus pourraient dépasser 1,9 CPU sur le nœud restant. C'est le cas où l'autoscaler ajoute le 3e nœud. Tous nos pods sont en QoS `Burstable` (requests < limits).

**Limiter le CPU de Redis** (question classique) : c'est `redis.resources.limits.cpu` dans `values.yaml`, puis `deploy/deploy.sh`. Ou à chaud : `kubectl -n poll-app set resources deploy/redis --limits=cpu=100m`, écrasé au prochain déploiement Helm.

## 8. Ports exposés

| Composant | Port du conteneur | Service | Joignable depuis |
|---|---|---|---|
| poll | 80 | `LoadBalancer`, port 80 | **Internet** (IP publique 1) |
| result | 80 | `LoadBalancer`, port 80 | **Internet** (IP publique 2) |
| redis | 6379 | `ClusterIP`, port 6379 | l'intérieur du cluster uniquement |
| postgres | 5432 | `ClusterIP`, port 5432 (+ un Service headless pour le StatefulSet) | l'intérieur du cluster uniquement |
| worker | 80 (probes uniquement) | aucun | le kubelet seul (pour les probes) |

- **Ne sont exposés que les deux pages que le sujet demande d'ouvrir.** Les bases restent internes, et protégées par mot de passe en plus.
- Un Service `LoadBalancer` ouvre aussi un NodePort (30000-32767) sur chaque nœud. Mais les nœuds AKS n'ont pas d'IP publique, et le load balancer Azure ne transmet que le port 80.
- Le port 6379 de Redis est **codé en dur** dans le worker, donc le Service garde 6379.
- Les trois applications écoutent en dur sur le port 80, ce qui exige root ou la capacité `NET_BIND_SERVICE`. Voir [Limites](#15-limites-connues).

## 9. Affinité

**Choix** : une **anti-affinité de pods « preferred »** sur poll et result (`topologyKey: kubernetes.io/hostname`, poids 100), avec `matchLabelKeys: [pod-template-hash]`.

- **Le but** : les replicas d'un même service sur des nœuds différents. La panne ou le drain d'un nœud n'en coupe alors qu'une partie.
- **« preferred » et pas « required »**, pour trois raisons :
  - avec 2 nœuds et 2 replicas, un rolling update (`maxSurge: 1`) crée un 3e pod. En « required », il n'aurait aucun nœud libre et resterait `Pending`. Avec `maxUnavailable: 0`, la mise à jour serait **bloquée** ;
  - le HPA ne pourrait pas dépasser 2 pods ;
  - pendant un drain, le pod évincé ne pourrait pas être replacé.
- **`matchLabelKeys: [pod-template-hash]`** corrige un problème qu'on a **observé en test**. Sans ce champ, pendant un rolling update, les anciens pods (encore présents) comptent dans l'anti-affinité. Le scheduler « équilibre » alors en mettant **tous les nouveaux pods sur le même nœud**, et ils y restent une fois les anciens supprimés : les 2 pods result se retrouvaient sur un seul nœud. Avec ce champ, un pod n'évite que les pods de sa propre version.
  - Testé : 1 pod result et 2 pods poll par nœud après un upgrade, puis après un `rollout restart`.
  - Champ disponible depuis Kubernetes 1.31 (bêta, activé par défaut). Sur une version plus ancienne, il est ignoré.

**Écarté**
- `topologySpreadConstraints` donnerait un résultat équivalent. On a gardé l'anti-affinité, plus directe à lire pour notre besoin (« pas deux replicas au même endroit »).
- Pas d'affinité pour worker, redis et postgres : un seul pod chacun, il n'y a rien à répartir.

```bash
kubectl -n poll-app get pods -o wide        # colonne NODE
```

## 10. Load balancers

Le trafic traverse **deux niveaux de répartition** :

```
Internet ─► Load balancer Azure (L4) ─► un nœud (port du Service) ─► kube-proxy ─► un pod prêt (sur n'importe quel nœud)
              IP publique 1 : poll                                     règles iptables, choix aléatoire
              IP publique 2 : result                                   parmi les pods prêts
```

**Niveau 1, le load balancer Azure**
- Pour chaque Service `LoadBalancer`, AKS ajoute une IP publique et une règle sur **un seul** Azure Standard Load Balancer (nommé `kubernetes`, dans le resource group `MC_…`).
- Il répartit vers les nœuds sains, qu'il surveille lui-même par sonde.
- Il travaille en couche 4 (TCP) : il ne lit pas le HTTP.

**Niveau 2, kube-proxy**
- Sur le nœud qui reçoit le paquet, kube-proxy choisit un pod **prêt** du Service, au hasard.
- Si ce pod est sur un autre nœud, le paquet y est renvoyé. C'est le mode `externalTrafficPolicy: Cluster`, par défaut.
- Ce même mécanisme répartit le trafic interne vers `redis` et `postgres` (Services `ClusterIP`).

**Choix pour result : `sessionAffinity: ClientIP`**
- Le client Socket.IO de result ne fait que du long-polling : plusieurs requêtes HTTP qui doivent arriver **au même pod**, sinon erreur 400 « Session ID unknown ».
- `ClientIP` règle kube-proxy pour toujours envoyer une même IP vers le même pod. Sur AKS, il règle aussi le load balancer Azure en répartition par IP source.
- **Limite** : tous les clients derrière le même NAT (le réseau de l'école, par exemple) tombent sur le même pod result.

**Écarté**
- **Ingress / Gateway API** : une seule IP, du routage par chemin ou par nom de domaine, et du TLS. Mais il faut installer et exploiter un contrôleur en plus. ingress-nginx est en fin de vie (mars 2026), et Application Gateway coûte plus cher. Pour deux pages sans nom de domaine, deux IP en couche 4 suffisent.
- **`externalTrafficPolicy: Local`** : il garde l'IP du client et évite le rebond entre nœuds. Mais seuls les nœuds qui ont un pod reçoivent du trafic, ce qui déséquilibre la charge.

**Le montrer** : la page poll affiche le pod qui a répondu (« Processed by container ID … »).
```bash
kubectl -n poll-app get svc                                  # EXTERNAL-IP de poll et de result
for i in $(seq 20); do curl -s http://<IP_POLL> | grep -o 'poll-[a-z0-9]*-[a-z0-9]*'; done | sort | uniq -c
```
**Vérifié sur AKS (23/10)** : 6 et 14 réponses sur 20 pour les deux pods poll. kube-proxy tire au hasard, donc un écart de cet ordre sur 20 requêtes est normal. Dans le navigateur, aucune erreur 400 Socket.IO sur result.

## 11. Auto-scaling

Deux niveaux qui se complètent :

| | HPA (pods) | Autoscaler de nœuds (VM) |
|---|---|---|
| Où | `templates/poll.yaml`, `templates/result.yaml` (dans le chart, donc aussi sur le cluster de l'évaluateur) | `azure.sh` (propriété du cluster AKS) |
| Déclencheur | CPU moyen > 70 % de `requests.cpu` | des pods `Pending` faute de place (selon les **requests**, pas la consommation réelle) |
| Bornes | 2 à 4 pods pour poll et pour result | 2 à 3 nœuds |
| Réaction | montée immédiate ; descente après 5 min de calme | ajout d'un nœud en quelques minutes ; retrait après ~10 min d'inutilité |

**HPA**
- Calcul : pods voulus = ⌈ pods actuels × CPU mesuré / CPU cible ⌉. Exemple : 2 pods à 150 % donnent ⌈ 2 × 150 / 70 ⌉ = 5, plafonné à 4.
- Un écart de moins de 10 % est ignoré, pour éviter d'osciller.
- La mesure vient de metrics-server, installé par défaut sur AKS.
- **Pourquoi le CPU** : poll et result sont limités par le CPU (gunicorn, Node). Leur mémoire varie peu.
- **Pourquoi 70 %** : on scale bien avant que les pods atteignent leur limite (500m = 5 fois la request). Il reste ainsi de la marge pendant que le HPA réagit et que les nouveaux pods démarrent (environ une minute dans nos tests).
- **Pourquoi 4 au maximum** : à 220 votes/s par pod, 4 pods dépassent déjà largement le débit du worker unique. Et tout tient sur un nœud ([4](#4-nombre-de-nœuds)).
- **Le worker n'a pas de HPA** : son CPU ne reflète pas la file d'attente, et il doit rester seul ([3](#3-replicas)). L'outil adapté serait KEDA (scaling sur la longueur de la liste Redis), si l'ordre des votes n'importait pas.

**Testé sur AKS (23/10)** : sous la charge ci-dessous, poll est passé de 2 à 3 pods en 1 min 40 s, avec un CPU à 98 %.
- **Pourquoi 3 et pas 4** : ⌈ 2 × 98 / 70 ⌉ = ⌈ 2,8 ⌉ = 3. Avec 3 pods, la même charge donne 72 %. L'écart avec 70 % est sous la tolérance de 10 %, donc le HPA ne bouge plus : il a trouvé le nombre de pods qui ramène le CPU près de la cible.
- Sur k3s, le même test était monté à 4 : la charge que produit une seule boucle dépend de la machine.
- **La descente** a été observée sur k3s : retour à 2 pods 5 min 20 s après la fin de la charge. Sur AKS, elle n'a pas pu l'être le 23/10, parce que le pod de charge n'a jamais été supprimé et que le CPU est resté à 72 %. Le HPA avait raison : la charge était toujours là. D'où la charge qui s'arrête d'elle-même ci-dessous.

**Le montrer**
```bash
kubectl -n poll-app get hpa poll -w &
kubectl -n poll-app run load --image=busybox:1.37 --restart=Never -- sh -c 'fin=$(( $(date +%s) + 180 )); while [ "$(date +%s)" -lt "$fin" ]; do wget -q -O /dev/null http://poll; done'
# ~2 min plus tard : REPLICAS passe à 3. La charge s'arrête seule au bout de 3 min,
# et poll revient à 2 pods ~6 min après.
kubectl -n poll-app delete pod load    # ménage, une fois la démo finie
```

## 12. Mise à jour sans interruption

Une suite de mécanismes, chacun couvrant un moment de la mise à jour :

| Mécanisme | Où | Ce qu'il empêche |
|---|---|---|
| Tag d'image unique par version (SHA git, jamais `latest`) | `build-push.sh` | une mise à jour invisible pour Kubernetes, ou des pods sur des versions différentes |
| `RollingUpdate`, `maxSurge: 1`, `maxUnavailable: 0` | Deployments | une baisse de capacité : un ancien pod n'est retiré qu'une fois un nouveau prêt |
| readinessProbe | Deployments | du trafic envoyé à un pod qui n'est pas prêt, ou mal configuré |
| `minReadySeconds: 5` | poll, result | avancer sur un pod qui plante juste après être devenu prêt |
| `preStop: sleep 10` | poll, result | des requêtes envoyées à un pod déjà arrêté. Le retrait d'un pod des Services met un moment à se propager à tous les nœuds et au load balancer. Pendant ces 10 s, le pod continue de répondre |
| `terminationGracePeriodSeconds: 30` | poll, result | couper les requêtes en cours : après le preStop, il reste 20 s pour finir |
| `helm --rollback-on-failure` (`--atomic` en Helm 3) | `deploy.sh` | rester sur une version cassée : si les nouveaux pods ne sont pas prêts en 10 min, Helm revient à la version précédente |
| Annotations `checksum/config` et `checksum/secret` | Deployments | des pods qui gardent une ancienne config après un changement de ConfigMap ou de Secret. Le mot de passe Redis généré n'est tiré qu'une fois par déploiement : sinon l'empreinte différait du vrai Secret, et la mise à jour suivante redémarrait Redis pour rien (vu sur AKS, corrigé dans `_helpers.tpl`) |
| PodDisruptionBudget `minAvailable: 1` | poll, result | un drain ou une maintenance d'AKS qui évince toutes les replicas en même temps |

**Testé** sur un cluster k3s local de 2 nœuds : code de poll et de result modifié, puis redéploiement avec la même commande Helm que `deploy.sh`.

| Test | Résultat |
|---|---|
| `deploy/test-zero-downtime.sh` (boucle de GET sur poll et result) pendant le rollout | **4 383 requêtes, 0 erreur** |
| Même boucle pendant un `kubectl drain` d'un nœud | **3 881 requêtes, 0 erreur** |
| 20 clients en parallèle (`ab`) pendant le rollout, **sans** preStop | 748 erreurs sur 42 000 requêtes |
| Idem **avec** preStop | 106 erreurs sur 71 000 requêtes |
| Idem sans aucun rollout (référence) | 20 erreurs sur 74 000 requêtes : pods saturés, HPA à son maximum |

Le preStop divise les erreurs par 7 sous forte concurrence. Ce qui reste vient surtout de la saturation volontaire des pods.

**Sur AKS**, le premier essai (22/10) a donné 60 erreurs sur 350 requêtes, toutes sur poll, à cause de son worker gunicorn unique ([§ 5](#5-probes)). Après la correction (23/10), le même test donne **1 165 requêtes, 0 erreur**, et 0 erreur aussi pendant le drain d'un nœud. Le pod Redis est resté le même du début à la fin : les mises à jour ne le redémarrent plus.

Sur ce cluster local, la boucle de requêtes successives (le test de la soutenance) donnait aussi 0 erreur **sans** preStop : sur une seule machine, le retrait d'un pod se propage presque instantanément. Sur AKS, il faut en plus prévenir le kube-proxy de chaque VM et le load balancer Azure. C'est ce délai que le preStop couvre.

Comme les 3 images partagent le même tag, modifier un seul service redémarre aussi les deux autres. C'est sans coupure, mais un peu plus long.

## 13. Comportement en cas de panne (testé)

| Scénario | Ce qui se passe |
|---|---|
| `kubectl drain <nœud>` | Le PDB n'autorise l'éviction d'un pod poll ou result que s'il en reste un autre prêt. L'anti-affinité garantit que ce pod est sur l'autre nœud. Les pods évincés sont recréés sur le nœud restant. **Testé sur k3s et sur AKS : 0 erreur.** Sur AKS, les PDB des pods système (coredns, metrics-server, konnectivity) font patienter le drain quelques dizaines de secondes (`Cannot evict pod as it would violate the pod's disruption budget`, puis nouvelle tentative) : c'est le même mécanisme que le nôtre. Les pods ne reviennent pas d'eux-mêmes après `kubectl uncordon` : il faut un `kubectl rollout restart` pour rééquilibrer. |
| Drain du nœud de Redis | Redis est recréé ailleurs en quelques secondes (pas de disque à déplacer). Pendant ce temps, les votes échouent. Au-delà de 15 s, poll devient non prêt ([5](#5-probes)). |
| Drain du nœud de Postgres | `postgres-0` est recréé ailleurs, et le disque Azure est détaché puis rattaché. **Mesuré sur AKS** : `postgres-0` prêt sur l'autre nœud 85 s après le début du drain, dont 15 s à attendre la libération du disque (`Multi-Attach error`). result a été injoignable environ 30 s ; les votes ont attendu dans Redis. |
| Le worker plante | Le kubelet le redémarre (`restartPolicy: Always`) ; les votes attendent dans Redis. **Testé.** |
| `kubectl delete pod postgres-0` | Recréé sur le même PVC, sans perte de données. **Testé sur AKS : prêt en 10 s.** |
| Un nœud s'éteint | En moins d'une minute, il est déclaré `NotReady` et ses pods sont retirés des Services : les replicas de l'autre nœud prennent tout le trafic. Après 5 min, ces pods sont recréés ailleurs. Si l'autre nœud manque de place, l'autoscaler ajoute un nœud. |
| Pic de trafic | Le HPA monte jusqu'à 4 pods. **Testé : 2 → 3 sur AKS, 2 → 4 sur k3s** ([11](#11-auto-scaling)). |

## 14. Plateforme et outils

- **Azure (AKS en tier Free + ACR Basic)**
  - Ce sont les crédits fournis par Epitech, et la plateforme citée par le sujet.
  - Le control plane AKS (API server, etcd) est gratuit et géré par Azure : on ne paie que les nœuds.
  - Les nœuds sont en amd64 : `build-push.sh` force donc `--platform linux/amd64`, même depuis un Mac ARM.
- **Helm**, plutôt que des manifests appliqués avec `kubectl apply` ou Kustomize, pour :
  - un historique des versions déployées et `helm rollback` ;
  - l'attente que tout soit prêt, avec rollback automatique (`--wait --rollback-on-failure`) ;
  - des valeurs par environnement (AKS par défaut, minikube via `deploy/values-minikube.yaml`) ;
  - `lookup`, qui garde le mot de passe Redis existant entre deux déploiements.
- **Secrets**
  - `POSTGRES_PASSWORD` est lu dans l'environnement au moment du déploiement. Il passe à Helm par un fichier temporaire (`--set-file <(…)`), donc il n'apparaît jamais dans la ligne de commande, puis il est stocké dans le Secret `poll-app-secrets`.
  - `REDIS_PASSWORD` est généré au premier déploiement, puis réutilisé.
- **Un script, une commande** : `deploy/deploy.sh` enchaîne build, push et déploiement. Il est relançable : sans changement du code, rien n'est reconstruit ni redémarré.

## 15. Limites connues

Ce qu'on a choisi de ne pas faire, en connaissance de cause :

| Limite | Conséquence | Ce qu'il faudrait |
|---|---|---|
| Redis et Postgres en une seule instance | panne de quelques secondes (Redis) à quelques minutes (Postgres) si leur nœud tombe | Redis Sentinel ; opérateur CloudNativePG ; ou les services managés d'Azure (plus chers) |
| Redis sans persistance | perte des votes en attente si Redis redémarre (presque toujours 0) | `appendonly yes` + PVC, au prix d'un redémarrage plus lent |
| Conteneurs en root | une faille dans une app donnerait root dans son conteneur | modifier les apps pour écouter sur un port > 1024 et ajouter `runAsNonRoot` (hors périmètre : on ne modifie pas `poll-application/`) |
| Pas de NetworkPolicy | depuis le cluster, tout pod peut joindre Redis et Postgres (les mots de passe restent nécessaires) | activer un moteur de NetworkPolicy à la création d'AKS (Azure NPM, Cilium ou Calico), puis tout interdire sauf les flux utiles |
| Un tag commun aux 3 images | modifier un service redémarre les trois | un tag par service (SHA du dossier) |
