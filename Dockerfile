FROM docker-artifactory.sln.nc/speed/speed-base

ENV HELM_LATEST_VERSION="v2.8.1"

RUN apk add --update ca-certificates \
 && apk add --update -t deps wget \
 && wget http://storage.googleapis.com/kubernetes-helm/helm-${HELM_LATEST_VERSION}-linux-amd64.tar.gz \
 && tar -xvf helm-${HELM_LATEST_VERSION}-linux-amd64.tar.gz \
 && mv linux-amd64/helm /usr/local/bin \
 && apk del --purge deps \
 && rm /var/cache/apk/* \
 && rm -f /helm-${HELM_LATEST_VERSION}-linux-amd64.tar.gz

