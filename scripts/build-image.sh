#!/bin/bash

VARS_TO_CHECK=(DOCKERFILE_DIR IMAGE_TAGS IMAGE_NAME NODE_VERSION LTS_VERSION)
EXIT_CODE=0

for var in "${VARS_TO_CHECK[@]}"; do
  if [[ -z "$var" ]]; then
    echo "Environment varaible $var not found, set and retry."

    exit 1
  fi
done

DOCKER_BUILD_ARGS=("--platform=linux/amd64")

for tag in "${IMAGE_TAGS[@]}"; do
  DOCKER_BUILD_ARGS+=("--tag=${IMAGE_NAME}:$tag")
done

if [[ "${NODE_VERSION}" = "${LTS_VERSION}" ]]; then
  DOCKER_BUILD_ARGS=("--tag=${IMAGE_NAME}:lts")
fi

DOCKER_BUILD_ARGS+=("${DOCKERFILE_DIR}")

set -x
docker buildx build "${DOCKER_BUILD_ARGS[@]}"

# Make sure to exit with the code returned from the build command
EXIT_CODE=$?
set +x

exit "${EXIT_CODE}"
