#!/bin/bash

YQ_DEST_DIR="${YQ_DEST_DIR:-/usr/local/bin}"
CONTINUE_CONFIG_PATH=".circleci/push-image.yml"
CHANGES_PARAM_KEY=".workflows.build-and-publish.jobs[0].new-job.matrix.parameters.changes"
DIFF_JSON_ARR=$(git diff --name-only --diff-filter=AM HEAD~1 \
  | grep -E '^node/(secrets|security)/[0-9]+$' \
  | jq -R -c -s 'split("\n")[:-1]')

function install_yq () {
  local os_arch
  local version
  local base_url
  local release_url
  
  os_arch="linux_amd64"
  version="4.45.3"
  base_url="https://github.com/mikefarah/yq"
  release_url="$base_url/releases/download/v$version/yq_$os_arch.tar.gz"

  WORK_DIR=$(pwd)
  TEMP_DIR=$(mktemp -d -t 'tmp')

  cd "${TEMP_DIR}" || exit

  curl -sL --retry 1 "$release_url" | tar zx
  sudo install "yq_$os_arch" "${YQ_DEST_DIR}/yq"
  command -v yq >/dev/null 2>&1

  echo "Installed yq v$version at ${YQ_DEST_DIR}"

  cd "${WORK_DIR}" || exit
  rm -rf "${TEMP_DIR}"

  return $?
}

if [[ "${DIFF_JSON_ARR}" = "[]" ]]; then
  echo "No image changes detected. Nothing to update."

  yq 'del(.orbs) 
  | del(.jobs) 
  | del(.workflows) 
  | .jobs={} 
  | .workflows={}' -i "${CONTINUE_CONFIG_PATH}"

  exit 0
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "Failed to detect yq, installing..."

  install_yq
fi

echo "Detected image changes: ${DIFF_JSON_ARR}"

yq "${CHANGES_PARAM_KEY}=${DIFF_JSON_ARR}" -i "${CONTINUE_CONFIG_PATH}"

echo "Updated ${CONTINUE_CONFIG_PATH} with image changes";
