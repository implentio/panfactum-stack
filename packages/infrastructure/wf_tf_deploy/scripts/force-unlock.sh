#!/usr/bin/env bash

set -eo pipefail

#####################################################
# Step 1: Clone the repo
#####################################################
# The refresh-github-token container in this pod mints this from the GitHub App.
GITHUB_APP_TOKEN=$(cat "$SHARED_VOLUME_PATH/github_token")
export GIT_USERNAME=x-access-token GIT_PASSWORD="$GITHUB_APP_TOKEN"

cd /code
pf-wf-git-checkout \
  -r "$REPO" \
  -c "$GIT_REF" \
  -u "$GIT_USERNAME" \
  -p "$GIT_PASSWORD"
cd repo

#####################################################
# Step 2: Setup AWS profile
#####################################################
export AWS_CONFIG_FILE="/.aws/config"
cat >"$AWS_CONFIG_FILE" <<EOF
[profile ci]
role_arn = $AWS_ROLE_ARN
web_identity_token_file = /var/run/secrets/eks.amazonaws.com/serviceaccount/token
role_session_name = ci-runner
EOF

#####################################################
# Step 3: Get the lock table and region
#####################################################
TG_VARIABLES=$(pf-get-terragrunt-variables "$TF_APPLY_DIR")
LOCK_TABLE=$(echo "$TG_VARIABLES" | jq '.tf_state_lock_table' -r)
LOCK_TABLE_REGION=$(echo "$TG_VARIABLES" | jq '.tf_state_region' -r)

#####################################################
# Step 4: Unlock
#####################################################
# Not pf-tf-delete-locks: it exits 5 on any lock in the table whose Info is not JSON.
/scripts/delete-locks.sh ci "$LOCK_TABLE_REGION" "$LOCK_TABLE" "$WHO"
