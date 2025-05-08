#!/bin/bash

VARS_TO_CHECK=(DOCKERFILE_DIR TEMPLATE_DIR NODE_VERSION)

if [[ "${IMAGE_NAME}" = "studiondev/node-secrets" ]]; then
  VARS_TO_CHECK+=(INFISICAL_VERSION) 
elif [[ "${IMAGE_NAME}" = "studiondev/node-security" ]]; then
  VARS_TO_CHECK+=(GITLEAKS_VERSION TRIVY_VERSION SEMGREP_VERSION)
else
  echo "Unknow image '${IMAGE_NAME}', specify different image and retry."

  exit 1
fi

for var in "${VARS_TO_CHECK[@]}"; do
  if [[ -z "$var" ]]; then
    echo "Environment varaible $var not found, set and retry."

    exit 1
  fi
done

envsubst < "${TEMPLATE_DIR}/Dockerfile.template" > "${DOCKERFILE_DIR}/Dockerfile"

echo "Successfully written Dockerfile at '${DOCKERFILE_DIR}'"
echo ""
cat "${DOCKERFILE_DIR}/Dockerfile"
