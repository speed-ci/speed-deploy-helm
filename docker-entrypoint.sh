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
  -v ~/.kube/config:~/.kube/config        Bind mount de la configuration d'accès au cluster kubernetes
END
}

function colorize_error () {
while read data; do echo "$data" | grep --color -ie "^.*\(ImagePullBackOff\|CrashLoopBackOff\|ErrImagePull\|Failed\|Error\).*$" -e ^; done;
}

function display_debug_info () {
printinfo "Liste des pods"
echo ""
printcomment "kubectl get po -n $NAMESPACE -l release=$RELEASE -o wide"
kubectl get po -n $NAMESPACE -l release=$RELEASE -o wide | colorize_error
echo ""
for p in `kubectl get po -n $NAMESPACE -l release=$RELEASE -o name`;
do
  printinfo "Info de debug du pod $p"
  echo ""
  printcomment "kubectl describe $p -n $NAMESPACE | sed -e '/Events:/p' -e '0,/Events:/d'"
  kubectl describe $p -n $NAMESPACE | sed -e '/Events:/p' -e '0,/Events:/d' | colorize_error
  echo ""
  printcomment "kubectl logs $p -n $NAMESPACE"
  echo "Logs:"
  kubectl logs $p -n $NAMESPACE || DEPLOY_STATUS="failed"
  echo ""
done
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
RELEASE=$CHART_NAME
TIMEOUT=${TIMEOUT:-300}

printinfo "BRANCH_NAME                 : $BRANCH_NAME"
printinfo "KUBE_CONTEXT                : $KUBE_CONTEXT"
printinfo "NAMESPACE                   : $NAMESPACE"
printinfo "RELEASE                     : $RELEASE"
printinfo "TIMEOUT                     : $TIMEOUT"
printinfo "BRANCH_KUBE_CONTEXT_MAPPING : $BRANCH_KUBE_CONTEXT_MAPPING"
printinfo "BRANCH_NAMESPACE_MAPPING    : $BRANCH_NAMESPACE_MAPPING"

printstep "Définition du contexte Kubernetes par défaut"
printcomment "kubectl config use-context $KUBE_CONTEXT"
kubectl config use-context $KUBE_CONTEXT

printstep "Création du namespace $NAMESPACE"
if ! kubectl get ns --ignore-not-found | grep -q $NAMESPACE ; then
    kubectl create ns $NAMESPACE
fi

printstep "Configuration de l'accès à la registry Docker privée pour le namespace $NAMESPACE"
if ! kubectl get secrets -n $NAMESPACE --ignore-not-found | grep -q regsecret ; then
    kubectl create secret docker-registry regsecret --namespace=$NAMESPACE \
                                                    --docker-server=$ARTIFACTORY_DOCKER_REGISTRY \
                                                    --docker-username=$ARTIFACTORY_USER \
                                                    --docker-password=$ARTIFACTORY_PASSWORD \
                                                    --docker-email=speed@eramet-sln.nc \                        
fi
if ! kubectl get secrets regsecret -n $NAMESPACE --output="jsonpath={.data.\.dockerconfigjson}" | base64 -d | grep -q $ARTIFACTORY_PASSWORD ; then
    ARTIFACTORY_FQDN=${ARTIFACTORY_URL##*/}
    ARTIFACTORY_DOCKER_REGISTRY=${ARTIFACTORY_DOCKER_REGISTRY:-"docker-$ARTIFACTORY_FQDN"} 
    kubectl delete secret regsecret --ignore-not-found=true --namespace=$NAMESPACE &&
    kubectl create secret docker-registry regsecret --namespace=$NAMESPACE \
                                                    --docker-server=$ARTIFACTORY_DOCKER_REGISTRY \
                                                    --docker-username=$ARTIFACTORY_USER \
                                                    --docker-password=$ARTIFACTORY_PASSWORD \
                                                    --docker-email=speed@eramet-sln.nc \                        
fi
if ! kubectl get sa -n $NAMESPACE --ignore-not-found | grep -q default ; then
    kubectl create sa default --namespace ${NAMESPACE}
fi
if ! kubectl get sa -n $NAMESPACE default -o json | grep -q imagePullSecrets ; then
    kubectl patch sa -n $NAMESPACE default -p '{"imagePullSecrets": [{"name": "regsecret"}]}'
fi

printstep "Installation de Tiller dans le namespace $NAMESPACE"
if ! kubectl get sa -n $NAMESPACE --ignore-not-found | grep -q tiller ; then
    kubectl create sa tiller --namespace ${NAMESPACE}
fi
if ! kubectl get sa -n $NAMESPACE tiller -o json | grep -q imagePullSecrets ; then
    kubectl patch sa -n $NAMESPACE tiller -p '{"imagePullSecrets": [{"name": "regsecret"}]}'
fi
if ! kubectl get clusterrolebindings --ignore-not-found | grep -q tiller-cluster-binding ; then
    cat <<EOF | kubectl create -f -
     kind: ClusterRoleBinding
     apiVersion: rbac.authorization.k8s.io/v1beta1
     metadata:
       name: tiller-cluster-binding
     subjects:
     - kind: ServiceAccount
       name: tiller
       namespace: $NAMESPACE
     roleRef:
       kind: ClusterRole
       name: cluster-admin
       apiGroup: rbac.authorization.k8s.io
EOF
fi

if ! kubectl get deploy -n dev --ignore-not-found | grep -q tiller-deploy ||
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

printstep "Vérification de la syntaxe du chart $CHART_NAME"
cp -r /srv/speed /srv/$CHART_NAME
cd /srv/$CHART_NAME
printcomment "helm lint"
helm lint | colorize_error

printstep "Mise à jour des dépendances"
printcomment "helm dependency update"
helm dependency update

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
printcomment "helm upgrade --namespace $NAMESPACE --install $RELEASE --wait . --timeout $TIMEOUT --tiller-namespace $NAMESPACE"
helm upgrade --namespace $NAMESPACE --install $RELEASE --wait . --timeout $TIMEOUT --tiller-namespace $NAMESPACE | colorize_error && DEPLOY_STATUS="success"

printstep "Affichage de l'historique de déploiement de la release $RELEASE"
printcomment "helm history $RELEASE --tiller-namespace $NAMESPACE"
helm history $RELEASE --tiller-namespace $NAMESPACE | colorize_error

printstep "Affichage des infos de debug des pods ayant pour label release $RELEASE"
display_debug_info

HELM_STATUS=`helm history $RELEASE --tiller-namespace $NAMESPACE | tail -n 1 | cut -f3`
if [[ $HELM_STATUS == "FAILED"* ]]; then DEPLOY_STATUS="failed"; fi

if [[ $DEPLOY_STATUS != "success" ]]; then
    printerror "Erreur lors du déploiement Helm"
    exit 1;
fi
