# Démonstration :

Chaque test que le jury peut demander, dans l'ordre du sujet :
1. déploiement initial ;
2. mise à jour sans interruption ;
3. justification des choix ;
4. questions de maîtrise.

Pour chaque test : les commandes, ce qu'on doit voir, et la section de [choices.md](choices.md) qui justifie le choix.

**Statut des tests**
- ✔ AKS : fait sur notre cluster AKS ;
- ✔ k3s : fait sur un cluster local de 2 nœuds ;


**Deux terminaux**, à la racine du dépôt :
- **T1** pour les boucles et les observations ;
- **T2** pour le reste.

---

## 0. 

**Allumer le cluster** (T2, quelques minutes) :

```bash
./azure.sh start          # si le cluster est arrêté
./azure.sh status         # état, nombre de nœuds, bornes de l'autoscaler
```

**Préparer T1 et T2**, dans chacun des deux :

```bash
set -a; . ./azure.env; set +a     # RESOURCE_GROUP, AKS_NAME, ACR_NAME
./azure.sh creds                  # kubeconfig du cluster
kubectl get nodes                 # 2 nœuds Ready
```

**Repartir d'un cluster vierge** (T2). Le sujet demande de déployer « starting from a fresh cluster ».

```bash
kubectl delete namespace poll-app     # efface tout : pods, votes, disque Postgres, IP publiques
kubectl get namespace poll-app        # doit répondre NotFound
```

**À vérifier aussi**
- Docker est lancé : `deploy.sh` construit les images en local.
- Un navigateur est ouvert.

---

## 1. Déploiement initial — *App working (4), Private registry (1), Persistent data (2)*

**T2** — le mot de passe Postgres est tiré au hasard et jamais affiché :

```bash
export POSTGRES_PASSWORD="$(openssl rand -hex 16)"
deploy/deploy.sh
```

**On doit voir**, à la fin : `poll http://…` et `result http://…`. Les images sont déjà dans l'ACR, donc le déploiement prend environ 1 min. ✔ AKS : 57 s.

**T2** — vérifier :

```bash
kubectl -n poll-app get pods -o wide     # 7 pods Running, 2 poll et 2 result répartis sur les 2 nœuds
kubectl -n poll-app get svc              # EXTERNAL-IP pour poll et result seulement
kubectl -n poll-app get hpa,pdb,pvc      # HPA, PDB, PVC data-postgres-0 Bound
```

- Le HPA affiche `<unknown>` pendant environ 1 min : metrics-server n'a pas encore de mesure.
- Donner les deux URL au jury. Il vote sur poll, et le vote apparaît sur result en 1 à 2 s. ✔ AKS.

**Ce que fait `deploy.sh`** : il construit les 3 images, les pousse dans l'ACR, puis lance `helm upgrade --install`. Si les pods ne sont pas prêts en 10 min, il revient en arrière tout seul.

---

## 2. Mise à jour sans interruption — *No-downtime update (2)*

Le jury modifie le code d'une des applications.

**T1** — lancer la boucle de requêtes, puis attendre que le compteur défile :

```bash
deploy/test-zero-downtime.sh
```

**T2** — modifier le code, puis redéployer. Exemple sur poll :

```bash
perl -pi -e 's#<title>.*?</title>#<title>Poll v2</title>#' poll-application/poll/templates/index.html
deploy/deploy.sh
curl -s "http://$(kubectl -n poll-app get svc poll -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/" | grep -o '<title>.*</title>'
```

**T1** — une fois le déploiement fini, Ctrl+C.

**On doit voir**
- T1 : `Bilan : N requêtes, 0 erreur(s)`. ✔ AKS : 1 165 requêtes, 0 erreur.
- T2 : `<title>Poll v2</title>`.
- Le pod `redis-…` garde le même nom : seuls les pods modifiés sont remplacés.

**Bon à savoir**
- Pas besoin de commiter : un code modifié reçoit un tag `<sha>-dirty-<horodatage>`, donc une nouvelle version.
- Pour result, modifier `poll-application/result/views/index.html`.
- Si le jury modifie le worker, le build est plus long : Maven retélécharge ses dépendances.
- À la fin : `git checkout -- poll-application/` remet le code d'origine.

**Justification** : [choices.md § 12](choices.md#12-mise-à-jour-sans-interruption).

---

## 3. Justification des choix, critère par critère

### Registre privé (1) — ✔ AKS · [§ 1](choices.md#1-registre-privé)

```bash
az acr repository list --name "$ACR_NAME" -o table                                   # poll, result, worker
az acr show --name "$ACR_NAME" --query "{admin:adminUserEnabled, anonymousPull:anonymousPullEnabled}"
kubectl -n poll-app get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}'
docker logout "$ACR_NAME.azurecr.io"
docker pull "$ACR_NAME.azurecr.io/poll:<tag>"                                        # -> unauthorized
```

- **On doit voir** : `admin: false`, `anonymousPull: false`, les images en `<ACR>.azurecr.io/…:<sha>`, puis `unauthorized`.
- Le cluster tire les images grâce à son identité managée (rôle `AcrPull`), sans mot de passe.
- `deploy.sh` reconnecte Docker tout seul au prochain déploiement.

### Données persistantes (2) — ✔ AKS · [§ 2](choices.md#2-données-persistantes)

```bash
kubectl -n poll-app get pvc,pv
kubectl -n poll-app exec postgres-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT vote, count(*) FROM votes GROUP BY vote"'
kubectl -n poll-app delete pod postgres-0
kubectl -n poll-app get pods -w          # postgres-0 de nouveau 1/1 en ~10 s, puis Ctrl+C
# relancer la requête psql : mêmes chiffres
```

- **On doit voir** : le PVC `data-postgres-0` `Bound`, et les mêmes votes avant et après.
- ✔ AKS : les votes ont aussi survécu à un arrêt complet du cluster.

### Replicas (1) — ✔ AKS · [§ 3](choices.md#3-replicas)

```bash
kubectl -n poll-app get deploy,statefulset      # poll 2/2, result 2/2, worker 1/1, redis 1/1, postgres 1/1
```

On dit combien chaque service a de replicas, et pourquoi le worker, Redis et Postgres restent à 1.

### Nombre de nœuds (1) — ✔ AKS · [§ 4](choices.md#4-nombre-de-nœuds)

```bash
kubectl get nodes -o wide
./azure.sh status                                          # min 2, max 3 (autoscaler)
az vm list-usage --location denmarkeast -o table | grep -i -E 'total regional|BS'
kubectl describe nodes | grep -A8 'Allocated resources'    # tout tient sur un nœud
```

### Probes (2) — ✔ AKS · [§ 5](choices.md#5-probes)

```bash
kubectl -n poll-app describe deploy poll | grep -E 'Liveness|Readiness'
kubectl -n poll-app describe statefulset postgres | grep -E 'Startup|Liveness|Readiness'
kubectl -n poll-app logs deploy/poll | grep 'Using worker'      # gthread : 8 threads
```

Démo possible, ✔ k3s : couper Redis montre la readiness à l'œuvre.

```bash
kubectl -n poll-app scale deploy/redis --replicas=0
kubectl -n poll-app get pods -w      # ~15 s : poll passe à 0/1, RESTARTS reste à 0. Ctrl+C
kubectl -n poll-app scale deploy/redis --replicas=1
```

- **On doit voir** : poll « non prêt », mais jamais redémarré.
- Le worker, lui, redémarre une fois : il fait `exit(1)` quand Redis tombe.
- Les votes envoyés pendant la coupure échouent.

### Restart policies (1) — ✔ AKS · [§ 6](choices.md#6-restart-policy)

```bash
kubectl -n poll-app get deploy,statefulset -o custom-columns='NOM:.metadata.name,RESTART:.spec.template.spec.restartPolicy'
kubectl -n poll-app exec deploy/worker -- kill 1
kubectl -n poll-app get pods -l app.kubernetes.io/name=worker      # RESTARTS passe à 1
```

### Resource limits (2) — ✔ AKS · [§ 7](choices.md#7-ressources-requests-et-limits)

```bash
kubectl -n poll-app get pods -o custom-columns='POD:.metadata.name,CPU_REQ:.spec.containers[0].resources.requests.cpu,CPU_LIM:.spec.containers[0].resources.limits.cpu,MEM_REQ:.spec.containers[0].resources.requests.memory,MEM_LIM:.spec.containers[0].resources.limits.memory'
kubectl -n poll-app top pods          # consommation réelle, sous les requests
```

Chaque valeur est commentée dans `deploy/helm/poll-app/values.yaml`. Les mesures sont dans le § 7.

### Ports exposés (1) — ✔ AKS · [§ 8](choices.md#8-ports-exposés)

```bash
kubectl -n poll-app get svc        # poll et result : LoadBalancer ; redis et postgres : ClusterIP, sans IP externe
```

### Affinité (2) — ✔ AKS · [§ 9](choices.md#9-affinité)

```bash
kubectl -n poll-app get pods -o wide -l 'app.kubernetes.io/name in (poll,result)'    # colonne NODE : 1 de chaque par nœud
kubectl -n poll-app get deploy poll -o jsonpath='{.spec.template.spec.affinity}{"\n"}'
```

### Load balancers (4) — ✔ AKS · [§ 10](choices.md#10-load-balancers)

```bash
kubectl -n poll-app get svc
POLL=$(kubectl -n poll-app get svc poll -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
for i in $(seq 20); do curl -s "http://$POLL/" | grep -o 'poll-[a-z0-9]*-[a-z0-9]*'; done | sort | uniq -c
```

- **On doit voir** : les 20 requêtes partagées entre les 2 pods poll. ✔ AKS : 6 / 14.
- Dans le navigateur, sur result : F12, onglet Réseau. Aucune requête `socket.io` en erreur 400, grâce à `sessionAffinity: ClientIP`.

Côté Azure ⚠ — le load balancer `kubernetes` et ses 2 IP publiques :

```bash
MC_RG=$(az aks show -g "$RESOURCE_GROUP" -n "$AKS_NAME" --query nodeResourceGroup -o tsv)
az network lb list -g "$MC_RG" -o table
az network public-ip list -g "$MC_RG" -o table
```

### Auto-scaling (6) — montée ✔ AKS, descente ✔ k3s · [§ 11](choices.md#11-auto-scaling)

**T1** — suivre le HPA :

```bash
kubectl -n poll-app get hpa poll -w
```

**T2** — 3 min de charge, qui s'arrête toute seule :

```bash
kubectl -n poll-app run load --image=busybox:1.37 --restart=Never -- sh -c 'fin=$(( $(date +%s) + 180 )); while [ "$(date +%s)" -lt "$fin" ]; do wget -q -O /dev/null http://poll; done'
```

- **On doit voir** : le CPU dépasse 70 %, puis `REPLICAS` passe de 2 à 3 en 1 à 2 min. ✔ AKS : 1 min 40.
- Ménage, une fois la démo finie : `kubectl -n poll-app delete pod load`.
- Historique des décisions du HPA : `kubectl -n poll-app describe hpa poll` (section Events).
- Autoscaler de nœuds : `./azure.sh status` affiche min 2, max 3. Il n'a jamais été déclenché, faute de pod sans place : on l'explique, on ne le montre pas.

### Documentation (2) et propreté du dépôt (1)

- [README.md](../README.md) : comment déployer, où mettre les secrets, vérifier, revenir en arrière.
- [README-azure.md](../README-azure.md) : créer, arrêter et supprimer l'infrastructure Azure.
- [choices.md](choices.md) : le pourquoi de chaque choix, avec les mesures.
- Ce fichier.

```bash
git status --short          # rien qui traîne
git ls-files                # aucun secret, aucun journal
```

---

## 4. « Que se passe-t-il si… ? »

| Si on… | Commande | Ce qu'on doit voir | Statut |
|---|---|---|---|
| vide un nœud (sans Postgres) | bloc ci-dessous, avec `test-zero-downtime.sh` dans T1 | 0 erreur ; pods recréés sur l'autre nœud | ✔ AKS |
| vide le nœud de Postgres | idem, avec `NODE=$PG_NODE` | `postgres-0` prêt ailleurs en ~85 s ; result injoignable ~30 s ; votes en attente dans Redis | ✔ AKS |
| supprime un pod poll | `kubectl -n poll-app delete pod <poll-…>` pendant `test-zero-downtime.sh` | 0 erreur : l'autre pod répond, un nouveau est créé | ⚠ |
| supprime `postgres-0` | voir Données persistantes | recréé sur le même disque en ~10 s | ✔ AKS |
| coupe Redis | voir Probes | poll non prêt mais pas redémarré ; le worker redémarre une fois | ✔ k3s |
| tue le worker | voir Restart policies | `RESTARTS` passe à 1, les votes attendent dans Redis | ✔ AKS |
| envoie beaucoup de trafic | voir Auto-scaling | le HPA monte à 3, jusqu'à 4 | ✔ AKS |

**Vider un nœud** (T2), pendant `deploy/test-zero-downtime.sh` dans T1 :

```bash
PG_NODE=$(kubectl -n poll-app get pod postgres-0 -o jsonpath='{.spec.nodeName}')
NODE=$(kubectl get nodes -o name | sed 's#^node/##' | grep -vx "$PG_NODE" | head -1)
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=5m
kubectl -n poll-app get pods -o wide
kubectl uncordon "$NODE"
kubectl -n poll-app rollout restart deploy/poll deploy/result      # rééquilibre sur les 2 nœuds
```

- Les messages `Cannot evict pod … disruption budget` sur coredns ou metrics-server sont normaux. Ce sont les PDB d'AKS, et le drain réessaie tout seul.
- Les pods ne reviennent pas d'eux-mêmes après `uncordon` : c'est le rôle du `rollout restart`.

---

## 5. « Comment ferait-on… ? »

**Limiter le CPU de Redis** ⚠
1. Dans `deploy/helm/poll-app/values.yaml`, régler `redis.resources.limits.cpu` (par exemple `100m`).
2. Lancer `deploy/deploy.sh`.
3. Vérifier : `kubectl -n poll-app get deploy redis -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'`.
- Redis est en `Recreate` : il redémarre, et les votes échouent quelques secondes.
- Au-delà de sa limite, Redis est ralenti, pas tué.

**Changer les bornes du HPA**
1. Dans `values.yaml`, régler `poll.autoscaling.maxReplicas` ou `targetCPUUtilizationPercentage`.
2. Lancer `deploy/deploy.sh`.

**Revenir à la version précédente** ⚠

```bash
helm history poll-app -n poll-app
helm rollback poll-app <REVISION> -n poll-app --wait
```

- C'est un rolling update, donc sans coupure.
- On ne fait pas de `kubectl rollout undo` : il désynchroniserait Helm de ce qui tourne vraiment.

**Passer à 3 nœuds** — à expliquer, pas à faire en démo
- Mettre `NODE_COUNT=3` dans `azure.env`, puis lancer `./azure.sh up`, qui met à jour le minimum de l'autoscaler.
- Le quota de 6 vCPU serait alors plein : voir le § 4.

**Changer le mot de passe Postgres**
1. D'abord en base : `ALTER USER … PASSWORD '…'`.
2. Puis `export POSTGRES_PASSWORD=…` et `deploy/deploy.sh`.
- Changer seulement la variable ne suffit pas : la base garde l'ancien mot de passe, et Helm annule la mise à jour.

**Lire les logs**

```bash
kubectl -n poll-app logs deploy/poll
kubectl -n poll-app logs deploy/worker
kubectl -n poll-app logs postgres-0
```

---

## 6.
```bash
./azure.sh stop       # plus de facturation des nœuds
```

## Dépannage

| Symptôme | Que faire |
|---|---|
| `deploy.sh` échoue au build | Docker n'est pas lancé |
| `POSTGRES_PASSWORD doit être défini` | relancer la ligne `export` de l'étape 1 dans ce terminal |
| `EXTERNAL-IP <pending>` | Azure crée l'IP publique : attendre 1 min |
| HPA `<unknown>` | metrics-server n'a pas encore de mesure : attendre 1 min |
| `deploy.sh` échoue après 10 min | Helm est revenu en arrière tout seul. Chercher la cause avec `kubectl -n poll-app get pods`, puis `describe pod` et `logs` sur le pod en défaut |
| `kubectl top` : `metrics not available yet` | attendre 1 min |
