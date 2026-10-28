#!/usr/bin/env bash

set -eo pipefail

# The refresh-github-token container mints this GitHub App token before setup runs.
GITHUB_APP_TOKEN=$(cat /tmp/github_token)
REPO="https://x-access-token:$GITHUB_APP_TOKEN@$CODE_REPO"

COMMIT_HASH=$(pf-get-commit-hash --repo "$REPO" --ref "$GIT_REF" --no-verify)
echo "$COMMIT_HASH" >/tmp/commit-hash

TAG="${IMAGE_TAG_PREFIX:+$IMAGE_TAG_PREFIX-}$COMMIT_HASH"
echo "$TAG" >/tmp/tag

if aws ecr describe-images --repository-name "$IMAGE_REPO" --image-ids imageTag="$TAG" --region "$IMAGE_REGION" >/dev/null 2>&1; then
  touch /tmp/exists
fi
