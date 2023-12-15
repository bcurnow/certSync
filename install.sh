#!/bin/bash

download () {
  local url=$1
  local target=$2

  curl --silent --fail-with-body --location -o "${target}" "${url}"

  if [ $? -ne 0 ]
  then
    echo "Installation failed! Failed to download '${url}' to '${target}'" >&2
    exit 1
  fi
}

update=$1
update_only=false
if [ -z "${update}" ] && [ "${update}" == "update" ]
then
  update_only=true
fi
  
YQ_VERSION=v4.35.1
YQ_BINARY=yq_linux_amd64

BASE_NAME=certSync
GITHUB_URL=https://github.com/bcurnow/${BASE_NAME}
BRANCH=main

OPT_DIR=/opt/${BASE_NAME}
ETC_DIR=/etc/${BASE_NAME}
SCRIPTS_DIR=${ETC_DIR}/scripts

if [ ${EUID} -ne 0 ]
then
  echo "This must be run as root" >&2
  exit 1
fi

if ! ${update_only}
then
  echo "Installing dependencies"
  apt-get update -qq && apt-get install -qq -y --no-install-recommends curl tar
  curl --silent --location https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}.tar.gz \
    tar xz && mv ${YQ_BINARY} /usr/bin/yq

  echo "Creating directories"
  for dir in ${OPT_DIR} ${ETC_DIR} ${SCRIPTS_DIR}
  do
    mkdir -p ${dir}
    chmod 755 ${dir}
  done
fi

echo "Downloading from GitHub (${BRANCH})"
download "${GITHUB_URL}/raw/${BRANCH}/${BASE_NAME}.sh" "${OPT_DIR}/${BASE_NAME}.sh"
download "${GITHUB_URL}/raw/${BRANCH}/${BASE_NAME}.yml.template" "${ETC_DIR}/${BASE_NAME}.yml.template"

echo "Installation complete!"
echo ""
echo "Please configure options by creating ${ETC_DIR}/${BASE_NAME}.yml (see ${ETC_DIR}/${BASE_NAME}.yml.template for examples)"
