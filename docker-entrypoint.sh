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
  -e ARTIFACTORY_URL=string                         URL d'Artifactory (ex: https://artifactory.sln.nc)
  -e ARTIFACTORY_USER=string                        Username d'accès à Artifactory (ex: prenom.nom)
  -e ARTIFACTORY_PASSWORD=string                    Mot de passe d'accès à Artifactory
  -e BRANCH_NAME=string                             Nom de la branch git - par défaut cette valeur est automatiquement découverte à partir des métadonnées du projet git
  -e KUBE_CONTEXT=string                            Nom du contexte kubernetes à utiliser - par défaut cette valeur est le contexte courant de la configuration .kube/config fournie
  -e NAMESPACE=string                               Nom du namespace kubernetes dans lequel déployer la release - par défaut cette valeur est déduite de la branche git et des règles de mapping
  -e KUBE_CONTEXT_MAPPING_RULES=<rules>             Règles de mapping spécifiques entre la branche git et le contexte kubernetes (ex: preprod=kubernetes-preprod@cluster-preprod,prod=kubernetes-prod@cluster-prod)
  -e NAMESPACE_MAPPING_RULES=<rules>                Règles de mapping spécifiques entre la branche git et le namespace kubernetes (ex: master=dev,prod=ns-prod) 
  -e TIMEOUT                                        Durée d'attente du déploiement de la release avant interruption en erreur
  --env-file ~/speed.env                            Fichier contenant les variables d'environnement précédentes
  -v \$(pwd):/srv/speed                              Bind mount du répertoire racine de l'application à dockérizer
  -v ~/.kube/config:~/.kube/config                  Bind mount de la configuration d'accès au cluster kubernetes
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
            exit
            ;;
    esac 
done

printmainstep "Déploiement de l'application"
printstep "Vérification des paramètres d'entrée"
init_artifactory_env

KUBECONFIG="/root/.kube/config"
if [ ! -f $KUBECONFIG ]; then
    printerror "Le configuration d'accès au cluster kubernetes doit être montée et associée au volume $KUBECONFIG du container (ex: -v ~/.kube/config:$KUBECONFIG)"
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

BRANCH_NAME=${BRANCH_NAME:-"master"}
if [[ -z $KUBE_CONTEXT ]]; then
   DEFAULT_KUBE_CONTEXT=$(kubectl config current-context)
   KUBE_CONTEXT=${KUBE_CONTEXT_MAPPING_RULES[$BRANCH_NAME]:-$DEFAULT_KUBE_CONTEXT}
fi
if [[ -z $NAMESPACE ]]; then
   NAMESPACE=${NAMESPACE_MAPPING_RULES[$BRANCH_NAME]:-$BRANCH_NAME}
fi
RELEASE=$NAMESPACE-$CHART_NAME
TIMEOUT=${TIMEOUT:-300}

printinfo "BRANCH_NAME    : $BRANCH_NAME"
printinfo "KUBE_CONTEXT   : $KUBE_CONTEXT"
printinfo "NAMESPACE      : $NAMESPACE"
printinfo "RELEASE        : $RELEASE"
printinfo "TIMEOUT        : $TIMEOUT"

printstep "Définir le contexte Kubernetes par défaut"
printcomment "kubectl config use-context $KUBE_CONTEXT"
kubectl config use-context $KUBE_CONTEXT

printstep "Vérification de la configuration helm"
printcomment "helm version"
helm version

printstep "Vérification de la syntaxe du chart $CHART_NAME"
cp -r /srv/speed /srv/$CHART_NAME
cd /srv/$CHART_NAME
printcomment "helm lint"
helm lint | colorize_error

printstep "Mise à jour des dépendances"

printstep "Vérification de l'historique de déploiement"
if [[ `helm ls --failed | grep $RELEASE` ]]; then
    printinfo "Reprise sur erreur d'un déploiement précédent"
    REVISION_COUNT=`helm history $RELEASE | tail -n +2 | wc -l`
    if [[ $REVISION_COUNT == 1 ]]; then
        printinfo "Suppression du premier déploiement en erreur"
        printcomment "helm delete --purge $RELEASE"
        helm delete --purge $RELEASE 
    elif [[ `helm history $RELEASE | tail -n 1 | grep FAILED` ]]; then
        printinfo "Suppression du dernier déploiement en erreur"
        printcomment "helm delete $RELEASE"
        helm delete $RELEASE 
    fi
fi

printstep "Installation du chart"
printcomment "helm upgrade --namespace $NAMESPACE --install $RELEASE --wait . --timeout $TIMEOUT"
helm upgrade --namespace $NAMESPACE --install $RELEASE --wait . --timeout $TIMEOUT | colorize_error && DEPLOY_STATUS="success"

printstep "Affichage de l'historique de déploiement de la release $RELEASE"
printcomment "helm history $RELEASE"
helm history $RELEASE | colorize_error

printstep "Affichage des infos de debug des pods ayant pour label release $RELEASE"
display_debug_info

if [[ $DEPLOY_STATUS != "success" ]]; then exit 1; fi
