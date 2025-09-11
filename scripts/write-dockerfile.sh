#!/bin/bash

VARS_TO_CHECK=(DOCKERFILE_DIR TEMPLATE_DIR)
VARS_TO_SUBST=(NODE_VERSION)

if [[ "${IMAGE_NAME}" = "studiondev/node-secrets" ]]; then
  VARS_TO_SUBST+=(INFISICAL_VERSION)
elif [[ "${IMAGE_NAME}" = "studiondev/node-security" ]]; then
  VARS_TO_SUBST+=(GITLEAKS_VERSION GRYPE_VERSION SEMGREP_VERSION SYFT_VERSION TRIVY_VERSION)
else
  echo "Unknown image '${IMAGE_NAME}', specify different image and retry."

  exit 1
fi

VARS_TO_CHECK+=("${VARS_TO_SUBST[@]}")

for var in "${VARS_TO_CHECK[@]}"; do
  if [[ -z "${!var}" ]]; then
    echo "Environment variable $var not found, set and retry."

    exit 1
  fi
done

set -x
# Explicitly specify variables for substitution to prevent replacing
# variables not defined in this context with empty string
# shellcheck disable=SC2016
envsubst "$(printf '${%s} ' "${VARS_TO_SUBST[@]}" | sed 's/ $//')" \
  <"${TEMPLATE_DIR}/Dockerfile.template" \
  >"${DOCKERFILE_DIR}/Dockerfile"
set +x

echo "Successfully written Dockerfile at '${DOCKERFILE_DIR}'"
echo ""
cat "${DOCKERFILE_DIR}/Dockerfile"
