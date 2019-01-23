#!/bin/bash
set -e

source /init.sh

function help () {
# Using a here doc with standard out.
cat <<-END

Usage: docker run [OPTIONS] docker-artifactory.sln.nc/speed/speed-deploy-helm

Déployer l'application du répertoire courant sur un cluster kubernetes avec helm
L'action de déployer consiste à installer le chart helm du répertoire courant sur un cluster kubernetes.
Les opérations suivantes sont effectuées:
- Vérification et déduction de la configuration d'entrée
- Définition du contexte kubernetes cible
- Vérification de la configuration helm
- Vérification de la la syntaxe du chart
- Mise à jour des dépendances
- Suppression de la révision précédente si en échec
- Installation du chart
- Affichage de l'historique de déploiement
- Affichage des infos de debug

Options:
  -e ARTIFACTORY_URL=string               URL d'Artifactory (ex: https://artifactory.sln.nc)
  -e ARTIFACTORY_USER=string              Username d'accès à Artifactory (ex: prenom.nom)
  -e ARTIFACTORY_PASSWORD=string          Mot de passe d'accès à Artifactory
  -e BRANCH_NAME=string                   Nom de la branch git - par défaut cette valeur est automatiquement découverte à partir des métadonnées du projet git
  -e KUBE_CONTEXT=string                  Nom du contexte kubernetes à utiliser - par défaut cette valeur est le contexte courant de la configuration .kube/config fournie
  -e NAMESPACE=string                     Nom du namespace kubernetes dans lequel déployer la release - par défaut cette valeur est déduite de la branche git et des règles de mapping
  -e BRANCH_KUBE_CONTEXT_MAPPING=<rules>  Règles de mapping spécifiques entre les branches git et les contextes kubernetes (ex: preprod=kubernetes-preprod@cluster-preprod,prod=kubernetes-prod@cluster-prod)
  -e BRANCH_NAMESPACE_MAPPING=<rules>     Règles de mapping spécifiques entre les branches git et les namespaces kubernetes (ex: master=dev,prod=ns-prod) 
  -e KUBECONFIG_OVERRIDE=string           Configuration d'accès au cluster kubernetes (les guillements doivent être échappés) - surcharge la configuration passée par fichier
  -e TIMEOUT=integer                      Durée d'attente en secondes du déploiement de la release avant interruption en erreur
  --env-file ~/speed.env                  Fichier contenant les variables d'environnement précédentes
  -v \$(pwd):/srv/speed                    Bind mount du répertoire racine de l'application à dockérizer
  -v ~/.kube:/srv/kubeconfig:ro           Bind mount du répertoire de configuration d'accès aux clusters kubernetes
END
}

function colorize_error () {
while read data; do echo "$data" | grep --color -ie "^.*\(ImagePullBackOff\|CrashLoopBackOff\|ErrImagePull\|Failed\|Error\).*$" -e ^; done;
# sed version : while read data; do echo "$data" | sed 's/\(.*ImagePullBackOff.*\|.*CrashLoopBackOff.*\|.*ErrImagePull.*\|.*Failed.*\|.*Error.*\)/'"$COLOR"'\1'"$OFF"'/' ; done;
}

function display_hooks_debug_info () {
  printcomment "kubectl get po -n $NAMESPACE -l app.kubernetes.io/instance=$RELEASE,speed-updater=$1 -ojson | jq -r --arg deployment_startdate $DEPLOYMENT_STARTDATE '.items[] | select(.metadata.creationTimestamp | fromdate | tostring > $DEPLOYMENT_STARTDATE) | .metadata.name'"
  NEW_PODS=`kubectl get po -n $NAMESPACE -l app.kubernetes.io/instance=$RELEASE,speed-updater=$1 -ojson | jq -r --arg deployment_startdate $DEPLOYMENT_STARTDATE '.items[] | select(.metadata.creationTimestamp | fromdate | tostring > $deployment_startdate) | .metadata.name'`
  if [[ -z $NEW_PODS ]]; then
    printinfo "Aucun pod démarré dans ce déploiement"
  else
    for p in $NEW_PODS;
    do
        printcomment "kubectl logs $p -c updater-router-job -n $NAMESPACE"
        kubectl logs $p -c updater-router-job -n $NAMESPACE
        echo ""
    done
  fi
}

function display_pods_debug_info () {
  printinfo "Liste de tous les pods"
  echo ""
  printcomment "kubectl get po -n $NAMESPACE -l release=$RELEASE -o wide"
  kubectl get po -n $NAMESPACE -l release=$RELEASE -o wide
  echo ""
  printinfo "Affichage des infos de debug des pods démarrés dans ce déploiement"
  echo ""
  printcomment "kubectl get po -n $NAMESPACE -l release=$RELEASE -ojson | jq -r --arg deployment_startdate $DEPLOYMENT_STARTDATE '.items[] | select(.metadata.creationTimestamp | fromdate | tostring > $DEPLOYMENT_STARTDATE) | select(.metadata.labels["speed-updater"]!="post-init" and .metadata.labels["speed-updater"]!="pre-init") | .metadata.name'"
  NEW_PODS=`kubectl get po -n $NAMESPACE -l release=$RELEASE -ojson | jq -r --arg deployment_startdate $DEPLOYMENT_STARTDATE '.items[] | select(.metadata.creationTimestamp | fromdate | tostring > $deployment_startdate)  | select(.metadata.labels["speed-updater"]!="post-init" and .metadata.labels["speed-updater"]!="pre-init") | .metadata.name'`
  if [[ -z $NEW_PODS ]]; then
    printinfo "Aucun pod démarré dans ce déploiement"
  else
    for p in $NEW_PODS;
    do
      printinfo "Info de debug du pod $p"
      echo ""
      printcomment "kubectl describe po $p -n $NAMESPACE | sed -e '/Events:/p' -e '0,/Events:/d'"
      kubectl describe po $p -n $NAMESPACE | sed -e '/Events:/p' -e '0,/Events:/d'
      echo ""
      printcomment "kubectl logs $p -n $NAMESPACE"
      echo "Logs:"
      kubectl logs $p -n $NAMESPACE
      echo ""
    done
  fi
}

while [ -n "$1" ]; do
    case "$1" in
        -h | --help | help)
            help
            exit 0
            ;;
        *)
            echo "Usage:  {h|--help|help} Afficher l'aide pour la configuration de lancement du container"
            exit 1
    esac 
done

printmainstep "Déploiement de l'application avec Kubernetes Helm"
printstep "Vérification des paramètres d'entrée"
init_artifactory_env

KUBECONFIG_ORIGIN_FOLDER="/srv/kubeconfig"
KUBECONFIG_FOLDER="/root/.kube"
KUBECONFIG_DEFAULT_PATH="$KUBECONFIG_FOLDER/config"
KUBECONFIG_OVERRIDE_PATH="$KUBECONFIG_FOLDER/config.override"
mkdir -p $KUBECONFIG_FOLDER
cp $KUBECONFIG_ORIGIN_FOLDER/*config* $KUBECONFIG_FOLDER

if [[ $KUBECONFIG_OVERRIDE ]]; then
    echo $KUBECONFIG_OVERRIDE | yq r - > $KUBECONFIG_OVERRIDE_PATH
fi

KUBECONFIG=""
for i in $KUBECONFIG_FOLDER/*config*; do
    KUBECONFIG="$KUBECONFIG:$i"
done

export KUBECONFIG=$KUBECONFIG
printinfo "KUBECONFIG                   : $KUBECONFIG"
KUBECONTEXT_LIST=`kubectl config get-contexts -o name`
if [[ -z $KUBECONTEXT_LIST ]]; then
    printerror "Aucun context kubernetes trouvé: la configuration d'accès au cluster kubernetes doit être renseignée (on recherche des fichiers contenant le mot clef config)"
    printerror "- soit en montant et associant le volume $KUBECONFIG_FOLDER au container (ex: -v ~/.kube:$KUBECONFIG_FOLDER)"
    printerror "- soit en renseignant la variable d'environnement KUBECONFIG_OVERRIDE (les guillements doivent être échappés)"
    exit 1
fi  

CHART_FILE_NAME="Chart.yaml"
if [ ! -f $CHART_FILE_NAME ]; then
    printerror "Le fichier de meta-données $CHART_FILE_NAME doit être présent dans le répertoire courrant"
    exit 1
fi

CHART_NAME=$(yq r Chart.yaml name)
if [ $CHART_NAME == null ]; then
    printerror "Le fichier de meta-données $CHART_FILE_NAME doit contenir le nom du chart (champ name)"
    exit 1
fi

declare -A KUBE_CONTEXT_MAPPING_RULES
if [[ $BRANCH_KUBE_CONTEXT_MAPPING  ]]; then
    while read name value; do
        KUBE_CONTEXT_MAPPING_RULES[$name]=$value
    done < <(<<<"$BRANCH_KUBE_CONTEXT_MAPPING" awk -F= '{print $1,$2}' RS=',|\n')
fi

declare -A NAMESPACE_MAPPING_RULES
NAMESPACE_MAPPING_RULES[master]=default
if [[ $BRANCH_NAMESPACE_MAPPING  ]]; then
    while read name value; do
        NAMESPACE_MAPPING_RULES[$name]=$value
    done < <(<<<"$BRANCH_NAMESPACE_MAPPING" awk -F= '{print $1,$2}' RS=',|\n')
fi

if [[ -z $BRANCH_NAME ]]; then
  if [[ ! $(git status | grep "Initial commit")  ]]; then
    BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)
  fi
  BRANCH_NAME=${BRANCH_NAME:-"master"}
fi

if [[ -z $KUBE_CONTEXT ]]; then
   DEFAULT_KUBE_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")
   KUBE_CONTEXT=${KUBE_CONTEXT_MAPPING_RULES[$BRANCH_NAME]:-$DEFAULT_KUBE_CONTEXT}
fi
if [[ -z $NAMESPACE ]]; then
   NAMESPACE=${NAMESPACE_MAPPING_RULES[$BRANCH_NAME]:-$BRANCH_NAME}
fi
SPEED_UPDATER_ENABLED="false"
if [[ -f templates/speed-update.yaml ]]; then
   SPEED_UPDATER_ENABLED="true";
fi
RELEASE=$CHART_NAME
TIMEOUT=${TIMEOUT:-300}

printinfo "BRANCH_NAME                 : $BRANCH_NAME"
printinfo "KUBE_CONTEXT                : $KUBE_CONTEXT"
printinfo "NAMESPACE                   : $NAMESPACE"
printinfo "RELEASE                     : $RELEASE"
printinfo "TIMEOUT                     : $TIMEOUT"
printinfo "BRANCH_KUBE_CONTEXT_MAPPING : $BRANCH_KUBE_CONTEXT_MAPPING"
printinfo "BRANCH_NAMESPACE_MAPPING    : $BRANCH_NAMESPACE_MAPPING"
printinfo "INGRESS_TLS_SECRET          : $INGRESS_TLS_SECRET"
printinfo "INGRESS_TLS_NAMESPACE       : $INGRESS_TLS_NAMESPACE"
printinfo "SPEED_UPDATER_ENABLED       : $SPEED_UPDATER_ENABLED"

printstep "Définition du contexte Kubernetes par défaut"
printcomment "kubectl config use-context $KUBE_CONTEXT"
kubectl config use-context $KUBE_CONTEXT

printstep "Création du namespace $NAMESPACE"
if ! kubectl get ns --ignore-not-found | grep -q $NAMESPACE ; then
    kubectl create ns $NAMESPACE
fi

printstep "Configuration de l'accès à la registry Docker privée $ARTIFACTORY_DOCKER_REGISTRY pour le namespace $NAMESPACE"
if ! kubectl get secrets -n $NAMESPACE --ignore-not-found | grep -q regsecret ; then
    printinfo "Création du secret regsecret" 
    kubectl create secret docker-registry regsecret --namespace=$NAMESPACE \
                                                    --docker-server=$ARTIFACTORY_DOCKER_REGISTRY \
                                                    --docker-username=$ARTIFACTORY_USER \
                                                    --docker-password=$ARTIFACTORY_PASSWORD \
                                                    --docker-email=speed@eramet-sln.nc
fi
if ! kubectl get secrets regsecret -n $NAMESPACE --output="jsonpath={.data.\.dockerconfigjson}" | base64 -d | grep -q $ARTIFACTORY_PASSWORD ; then
    printinfo "Mise à jour du secret regsecret" 
    ARTIFACTORY_FQDN=${ARTIFACTORY_URL##*/}
    ARTIFACTORY_DOCKER_REGISTRY=${ARTIFACTORY_DOCKER_REGISTRY:-"docker-$ARTIFACTORY_FQDN"} 
    kubectl delete secret regsecret --ignore-not-found=true --namespace=$NAMESPACE &&
    kubectl create secret docker-registry regsecret --namespace=$NAMESPACE \
                                                    --docker-server=$ARTIFACTORY_DOCKER_REGISTRY \
                                                    --docker-username=$ARTIFACTORY_USER \
                                                    --docker-password=$ARTIFACTORY_PASSWORD \
                                                    --docker-email=speed@eramet-sln.nc
fi
if ! kubectl get sa -n $NAMESPACE --ignore-not-found | grep -q default ; then
    kubectl create sa default --namespace ${NAMESPACE}
fi
if ! kubectl get sa -n $NAMESPACE default -o json | grep -q imagePullSecrets ; then
    kubectl patch sa -n $NAMESPACE default -p '{"imagePullSecrets": [{"name": "regsecret"}]}'
fi

if [[ $INGRESS_TLS_SECRET && $INGRESS_TLS_NAMESPACE ]]; then
   printstep "Configuration du certificat ingress TLS $INGRESS_TLS_SECRET pour le namespace $NAMESPACE"
   if ! kubectl get secrets -n $NAMESPACE --ignore-not-found | grep -q $INGRESS_TLS_SECRET ; then
       printinfo "Copie du certificat TLS $INGRESS_TLS_SECRET depuis le namespace $INGRESS_TLS_NAMESPACE"
       kubectl get secret -n $INGRESS_TLS_NAMESPACE $INGRESS_TLS_SECRET -o yaml --export | \
       kubectl -n $NAMESPACE apply -f -
   fi
fi

printstep "Installation de Tiller dans le namespace $NAMESPACE"
if ! kubectl get sa -n $NAMESPACE --ignore-not-found | grep -q tiller ; then
    kubectl create sa tiller --namespace ${NAMESPACE}
fi
if ! kubectl get sa -n $NAMESPACE tiller -o json | grep -q imagePullSecrets ; then
    kubectl patch sa -n $NAMESPACE tiller -p '{"imagePullSecrets": [{"name": "regsecret"}]}'
fi
if ! kubectl get roles -n $NAMESPACE --ignore-not-found | grep -q tiller-manager ; then
    cat <<EOF | kubectl create -f -
      kind: Role
      apiVersion: rbac.authorization.k8s.io/v1beta1
      metadata:
        name: tiller-manager
        namespace: $NAMESPACE
      rules:
      - apiGroups: ["*"]
        resources: ["*"]
        verbs: ["*"]
EOF
fi
if ! kubectl get rolebindings -n $NAMESPACE --ignore-not-found | grep -q tiller-binding ; then
    cat <<EOF | kubectl create -f -
      kind: RoleBinding
      apiVersion: rbac.authorization.k8s.io/v1beta1
      metadata:
        name: tiller-binding
        namespace: $NAMESPACE
      subjects:
      - kind: ServiceAccount
        name: tiller
        namespace: $NAMESPACE
      roleRef:
        kind: Role
        name: tiller-manager
        apiGroup: rbac.authorization.k8s.io
EOF
fi

if ! kubectl get deploy -n $NAMESPACE --ignore-not-found | grep -q tiller-deploy ||
   ! helm version --tiller-namespace $NAMESPACE --template "{{ .Server.SemVer }}" | grep -q $HELM_LATEST_VERSION ; then
    printcomment "helm init --upgrade --tiller-image $ARTIFACTORY_DOCKER_REGISTRY/kubernetes-helm/tiller:$HELM_LATEST_VERSION --skip-refresh --service-account tiller --tiller-namespace $NAMESPACE --wait"
    helm init --upgrade --tiller-image $ARTIFACTORY_DOCKER_REGISTRY/kubernetes-helm/tiller:$HELM_LATEST_VERSION --skip-refresh --service-account tiller --tiller-namespace $NAMESPACE --wait
fi

printstep "Vérification de la configuration helm"
printcomment "helm version --tiller-namespace $NAMESPACE"
helm version --tiller-namespace $NAMESPACE

printstep "Configuration de l'accès au chart repository"
printcomment "helm init --client-only --skip-refresh"
helm init --client-only --skip-refresh
printcomment "helm repo remove local"
helm repo remove local
printcomment "helm repo add stable \$ARTIFACTORY_URL/artifactory/helm --username \$ARTIFACTORY_USER --password \$ARTIFACTORY_PASSWORD"
helm repo add stable "$ARTIFACTORY_URL/artifactory/helm" --username "$ARTIFACTORY_USER" --password "$ARTIFACTORY_PASSWORD"

printstep "Mise à jour des dépendances"
printcomment "helm dependency update"
helm dependency update

printstep "Vérification de la syntaxe du chart $CHART_NAME"
cp -r /srv/speed /srv/$CHART_NAME
cd /srv/$CHART_NAME
printcomment "helm lint"
helm lint

printstep "Vérification de l'historique de déploiement"
if [[ `helm ls --failed --tiller-namespace $NAMESPACE | grep $RELEASE` ]]; then
    printinfo "Reprise sur erreur d'un déploiement précédent"
    REVISION_COUNT=`helm history $RELEASE --tiller-namespace $NAMESPACE | tail -n +2 | wc -l`
    if [[ $REVISION_COUNT == 1 ]]; then
        printinfo "Suppression du premier déploiement en erreur"
        printcomment "helm delete --purge $RELEASE --tiller-namespace $NAMESPACE"
        helm delete --purge $RELEASE --tiller-namespace $NAMESPACE
    elif [[ `helm history $RELEASE --tiller-namespace $NAMESPACE | tail -n 1 | grep FAILED` ]]; then
        printinfo "Suppression du dernier déploiement en erreur"
        printcomment "helm delete $RELEASE --tiller-namespace $NAMESPACE"
        helm delete $RELEASE --tiller-namespace $NAMESPACE
    fi
fi

printstep "Installation du chart"
DEPLOYMENT_STARTDATE=`jq -n 'now'`
printcomment "helm upgrade --namespace $NAMESPACE --install $RELEASE --wait . --timeout $TIMEOUT --tiller-namespace $NAMESPACE --force"
helm upgrade --namespace $NAMESPACE --install $RELEASE --wait . --timeout $TIMEOUT --tiller-namespace $NAMESPACE --force && DEPLOY_STATUS="success"

printstep "Affichage de l'historique de déploiement de la release $RELEASE (si possible)"
printcomment "helm history $RELEASE --tiller-namespace $NAMESPACE || true"
helm history $RELEASE --tiller-namespace $NAMESPACE || true

if [[ $SPEED_UPDATER_ENABLED == "true" ]]; then
    printmainstep "Affichage des logs du hook de pre-init si démarré dans ce déploiement"
    display_hooks_debug_info pre-init
fi

printmainstep "Affichage des infos de debug des pods démarrés dans ce déploiement ayant le label release=$RELEASE"
display_pods_debug_info

if [[ $SPEED_UPDATER_ENABLED == "true" ]]; then
    printmainstep "Affichage des logs du hook de post-init si démarré dans ce déploiement"
    display_hooks_debug_info post-init
fi

HELM_STATUS=`helm history $RELEASE --tiller-namespace $NAMESPACE | tail -n 1 | cut -f3`
if [[ $HELM_STATUS == "FAILED"* ]]; then DEPLOY_STATUS="failed"; fi

if [[ $DEPLOY_STATUS != "success" ]]; then
    echo ""
    printerror "Erreur lors du déploiement Helm"
    exit 1;
fi
