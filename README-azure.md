## Infrastructure Azure

### Prérequis

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash` sur Ubuntu)
- `kubectl` (`sudo az aks install-cli`)
- Docker
- Un abonnement Azure (le projet a été réalisé avec Azure for Students)

### Credentials Azure (non fournis dans le dépôt)

Aucune clé ni mot de passe Azure n'est stocké dans ce dépôt. L'authentification se fait avec votre propre compte :

```bash
az login                   # ouvre le navigateur ; sinon : az login --use-device-code
az account show            # vérifier l'abonnement actif
az account set --subscription "<nom ou id>"   # si vous en avez plusieurs
```

Les scripts utilisent ensuite la session `az` ouverte. Pour une exécution non interactive (CI), on peut utiliser un service principal :

```bash
az login --service-principal -u <APP_ID> -p <CLIENT_SECRET> --tenant <TENANT_ID>
```

L'accès du cluster au registry privé ne nécessite aucun mot de passe : l'AKS utilise son identité managée, qui a reçu le rôle `AcrPull` sur l'ACR (`--attach-acr`). Le compte admin de l'ACR est désactivé. Pour pousser des images, `az acr login --name <ACR_NAME>` utilise la session `az`.

### Configuration

```bash
cp azure.env.example azure.env
# éditer azure.env : au minimum ACR_NAME, qui doit être unique dans tout Azure
```

### Création de l'infrastructure

```bash
./azure.sh up
```

Crée le resource group, le registry privé (ACR) et le cluster (AKS), relie les deux et configure `kubectl`. Le script est idempotent : le relancer ne recrée rien.

Le cluster démarre avec 2 nœuds `Standard_B2s`. L'**autoscaler de nœuds** peut monter à 3 (`NODE_COUNT` et `NODE_MAX_COUNT` dans `azure.env`) :
- il ajoute un nœud seulement si des pods ne trouvent plus de place ;
- il le retire une fois devenu inutile.

Sur un cluster déjà créé, relancer `./azure.sh up` active ou met à jour l'autoscaler. Le pourquoi de ces chiffres est dans [docs/choices.md § 4](docs/choices.md#4-nombre-de-nœuds).

Avant de monter `NODE_MAX_COUNT`, vérifier le quota de vCPU de l'abonnement : `az vm list-usage --location francecentral -o table`. Un B2s compte 2 vCPU, et une mise à jour d'AKS ajoute temporairement un nœud.

Si vous avez déjà un cluster AKS prêt, renseignez simplement `RESOURCE_GROUP`, `AKS_NAME` et `ACR_NAME` dans `azure.env`, puis lancez `./azure.sh creds`.

### Gestion des coûts

| Commande | Effet |
|---|---|
| `./azure.sh stop` | Arrête le cluster : plus de facturation des nœuds |
| `./azure.sh start` | Redémarre le cluster et reconfigure `kubectl` |
| `./azure.sh status` | État du cluster (nombre de nœuds, bornes de l'autoscaler) et liste des ressources |
| `./azure.sh down` | Supprime tout le resource group (irréversible, demande confirmation) |

Une alerte budgétaire est configurée sur l'abonnement (portail Azure → *Budgets*) pour être prévenu en cas de dépense anormale.
