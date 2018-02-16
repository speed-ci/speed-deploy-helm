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
  -v /var/run/docker.sock:/var/run/docker.sock      Bind mount de la socket docker pour le lancement de commandes docker lors de la dockérization
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

TAG=${TAG:-"latest"}
IMAGE=$ARTIFACTORY_DOCKER_REGISTRY/$PROJECT_NAMESPACE/$PROJECT_NAME:$TAG
BRANCH=$(git rev-parse --abbrev-ref HEAD)
BRANCH=${BRANCH:-"master"}

echo ""
printinfo "DOCKERFILE : $DOCKERFILE"
printinfo "IMAGE      : $IMAGE"
printinfo "PROXY      : $PROXY"
printinfo "NO_PROXY   : $NO_PROXY"
printinfo "BRANCH     : $BRANCH"
