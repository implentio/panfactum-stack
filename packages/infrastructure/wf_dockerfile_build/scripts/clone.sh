#!/usr/bin/env bash

set -eo pipefail

###########################################################
## Step 0: Check if the image already exists
###########################################################
if [[ -f "/tmp/exists" ]]; then
  echo "Skipping. Image already exists in the ECR repository."
  exit 0
fi

###########################################################
## Step 1: Clone the codebase
###########################################################
GITHUB_APP_TOKEN=$(cat /tmp/github_token)
cd /code
pf-wf-git-checkout \
  -r "$CODE_REPO" \
  -c "$GIT_REF" \
  -u x-access-token \
  -p "$GITHUB_APP_TOKEN"
cd repo
