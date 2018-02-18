#!/bin/bash
set -e

source /init.sh

function help () {
# Using a here doc with standard out.
cat <<-END

Usage: docker run [OPTIONS] docker-artifactory.sln.nc/speed/speed-dockerize

Dockerizer l'application du répertoire courant
Le fichier Dockerfile doit être présent à la racine du projet
L'action de dockérizer consiste à prendre des fichiers plats en entrée et générer une image docker en sortie.
Le nom de l'image est déduit de l'url Gitlab remote origin, il y a donc correspondance entre les noms de groupes et de projets entre Gitlab et Artifactory

Options:
  -e ARTIFACTORY_URL=string                         URL d'Artifactory (ex: https://artifactory.sln.nc)
  -e ARTIFACTORY_USER=string                        Username d'accès à Artifactory (ex: prenom.nom)
  -e ARTIFACTORY_PASSWORD=string                    Mot de passe d'accès à Artifactory
  --env-file ~/speed.env                             Fichier contenant les variables d'environnement précédentes
  -v \$(pwd):/srv/speed                              Bind mount du répertoire racine de l'application à dockérizer
  -v ~/.kube/config/~/.kube/config                  Configuration d'accès au cluster kubernetes
END
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
init_env

KUBECONFIG="/root/.kube/config"
if [ ! -f $KUBECONFIG ]; then
    printerror "Le configuration d'accès au cluster kubernetes doit être montée et associée au volume $KUBECONFIG du container (ex: -v $KUBECONFIG:$KUBECONFIG)"
    exit 1
fi  

BRANCH=$(git rev-parse --abbrev-ref HEAD)
BRANCH=${BRANCH:-"master"}
RELEASE=$BRANCH-$PROJECT_NAME
NAMESPACE=$BRANCH
CONTEXT=$(kubectl config current-context)

printinfo "BRANCH     : $BRANCH"
printinfo "RELEASE    : $RELEASE"
printinfo "NAMESPACE  : $NAMESPACE"
printinfo "CONTEXT    : $CONTEXT"

printstep "Vérification de la configuration helm"
helm version

printstep "Vérification de la syntaxe du chart"
cp -r /srv/speed /srv/$PROJECT_NAME
cd /srv/$PROJECT_NAME
helm lint

printstep "Mise à jour des dépendances"

printstep "Vérification de l'historique de déploiement"
if [[ `helm ls --failed | grep $RELEASE` ]]; then
    printinfo "Reprise sur erreur d'un déploiement précédent"
    REVISION_COUNT=`helm history $RELEASE | tail -n +2 | wc -l`
    if [[ $REVISION_COUNT == 1 ]]; then
        printinfo "Suppression du premier déploiement en erreur"
        helm delete --purge $RELEASE 
    fi
fi

printstep "Installation du chart"
helm upgrade --namespace $BRANCH --install $BRANCH-$PROJECT_NAME --wait .

