#!/bin/bash

CONTINUE_CONFIG_PATH=".circleci/push-image.yml"
CHANGES_PARAM_KEY=".workflows.push-image-to-hub.jobs[0].write-build-push.matrix.parameters.env_file_path"
DIFF_JSON_ARR=$(git diff --name-only --diff-filter=AM HEAD~1 \
  | grep -E '^node/(secrets|security)/[0-9]+$' \
  | jq -R -c -s 'split("\n")[:-1]')


if [[ "${DIFF_JSON_ARR}" = "[]" ]]; then
  echo "No image changes detected. Nothing to update."

  yq 'del(.orbs)
  | del(.commands) 
  | del(.jobs) 
  | del(.workflows) 
  | .jobs={} 
  | .workflows={}' -i "${CONTINUE_CONFIG_PATH}"

  exit 0
fi

echo "Detected image changes: ${DIFF_JSON_ARR}"

yq "${CHANGES_PARAM_KEY}=${DIFF_JSON_ARR}" -i "${CONTINUE_CONFIG_PATH}"

echo "Updated ${CONTINUE_CONFIG_PATH} with image changes";
