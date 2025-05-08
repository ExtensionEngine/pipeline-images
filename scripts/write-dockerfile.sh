#!/bin/bash

set -a
source "${ENV_FILE_PATH}"
set +a

envsubst < "${TEMPLATE_PATH}Dockerfile.template" > Dockerfile

exit 0
