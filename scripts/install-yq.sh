#!/bin/bash

OS=$(uname | sed 's/Darwin/darwin/;s/Linux/linux/')
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
YQ_VERSION="${YQ_VERSION:-v4.45.3}"
YQ_DEST_DIR="${YQ_DEST_DIR:-/usr/local/bin}"
BASE_URL="https://github.com/mikefarah/yq"
RELEASE_URL="${BASE_URL}/releases/download/${YQ_VERSION}/yq_${OS}_${ARCH}.tar.gz"

function install_yq () {
  WORK_DIR=$(pwd)
  TEMP_DIR=$(mktemp -d -t 'tmp')

  cd "${TEMP_DIR}" || exit

  curl -sfL --retry 1 "${RELEASE_URL}" | tar zx
  sudo install "yq_${OS}_${ARCH}" "${YQ_DEST_DIR}/yq"

  echo "Installed yq ${VERSION} at $(command -v yq)"

  cd "${WORK_DIR}" || exit 1
  rm -rf "${TEMP_DIR}"
}

if ! command -v yq > /dev/null 2>&1; then
  echo "Failed to detect yq, installing..."

  install_yq
fi
