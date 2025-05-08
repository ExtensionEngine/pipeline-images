#!/bin/bash

if [[ -z "${ENV_FILE_PATH}" ]]; then
  echo "Provide path to file with build environment and retry."

  exit 1
fi

LTS_VERSION=$(curl -s https://nodejs.org/download/release/index.json | \
  jq -r '[.[] | select(.lts != false)] | .[0].version' | sed 's/^v//')
ENV_FILE_DIR=$(dirname "${ENV_FILE_PATH}")
IMAGE_NAME=""
IMAGE_NAME_WITH_TAG=""

if [[ "${ENV_FILE_DIR}" = *secrets* ]]; then
  IMAGE_NAME="studiondev/node-secrets"
elif [[ "${ENV_FILE_DIR}" = *security* ]]; then
  IMAGE_NAME="studiondev/node-security"
else
  echo "Failed to determine image from the directory ${ENV_FILE_DIR}"

  exit 1
fi

while read -r line; do
  # Exports NODE_VERSION, IMAGE_TAGS
  echo "export $line" >> "${BASH_ENV}"
done < "${ENV_FILE_PATH}"

# shellcheck disable=SC1090
source "${BASH_ENV}"

IMAGE_NAME_WITH_TAG="${IMAGE_NAME}:${IMAGE_TAGS[0]}"

{
  echo "export DOCKERFILE_DIR=${ENV_FILE_DIR}"
  echo "export TEMPLATE_DIR=${ENV_FILE_DIR}"
  echo "export LTS_VERSION=${LTS_VERSION}"
  echo "export IMAGE_NAME=${IMAGE_NAME}"
  echo "export IMAGE_NAME_WITH_TAG=${IMAGE_NAME_WITH_TAG}"
} >> "${BASH_ENV}"
