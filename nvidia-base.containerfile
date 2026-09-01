ARG BASE_IMAGE

# base: external base image (fedora-minimal), injected by Makefile
FROM ${BASE_IMAGE}

ARG \
  REPO_BASE_URL=""

ENV \
  LANG=ru_RU.UTF-8

RUN \
  set -euxo pipefail ; \
  source /etc/os-release ; \
  if ! [ -z "$REPO_BASE_URL" ] ; then \
    rm -f /etc/yum.repos.d/* ; \
    curl -SLo /etc/yum.repos.d/local.repo $REPO_BASE_URL/pub/fedora/linux/releases/$VERSION_ID/$(uname -m)/local.repo ; \
    echo $REPO_BASE_URL > /etc/dnf/vars/repobaseurl ; \
    dnf clean all ; \
  fi ; \
  dnf install -y \
    --disablerepo \* \
    --enablerepo fedora,updates \
    btop \
    glibc-langpack-{en,ru} \
    gzip \
    dnf5-plugins \
    procps-ng \
    tar \
    which \
  && \
  dnf config-manager setopt *.enabled=0 && \
  dnf config-manager setopt fedora.enabled=1 updates.enabled=1 && \
  dnf clean all
