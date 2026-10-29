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
## Step 1: CD to the codebase
###########################################################
cd /code/repo || exit

###########################################################
## Step 2: Create the image tag (with arch suffix if needed)
###########################################################
TAG="$(cat /tmp/tag)$([ "$USE_ARCH_SUFFIX" = "1" ] && echo "-$ARCH" || echo "")"

###########################################################
## Step 3: Check if the image already exists
###########################################################
if aws ecr describe-images --repository-name "$IMAGE_REPO" --image-ids imageTag="$TAG" --region "$IMAGE_REGION" >/dev/null 2>&1; then
  echo "Skipping. Platform-specific image already exists in the ECR repository."
  exit 0
fi

###########################################################
## Step 4: Get the ECR credentials
###########################################################

ECR_PASSWORD=$(aws ecr get-login-password --region "$IMAGE_REGION")
AUTH_TOKEN=$(echo "AWS:$ECR_PASSWORD" | base64 --wrap=0)
cat >"/.docker/config.json" <<EOF
{
    "auths": {
        "$IMAGE_REGISTRY": {
            "auth": "$AUTH_TOKEN"
        }
    }
}
EOF

###########################################################
## Step 5: Build the image
###########################################################
# shellcheck disable=SC1091
source pf-buildkit-validate

BUILD_LOG=$(mktemp)
MAX_ATTEMPTS=3
# buildctl's final error when buildkitd went away mid-build (spot reclaim, OOM restart, preemption).
# Matching only the final "error:" line keeps a RUN step's own output from triggering a retry.
CONNECTION_LOST='^error: .*(RST_STREAM|failed to list workers|closing transport|connection refused|connection reset by peer|error reading from server|code = Unavailable)'

function wait-for-buildkit() {
  local STATEFULSET_NAME="$BUILDKIT_STATEFULSET_NAME_PREFIX$ARCH"
  local DEADLINE
  DEADLINE=$(($(date +%s) + 600))
  until [[ $(kubectl get statefulset "$STATEFULSET_NAME" --namespace="$BUILDKIT_NAMESPACE" -o=jsonpath='{.status.availableReplicas}') -ge 1 ]]; do
    if [[ $(date +%s) -ge $DEADLINE ]]; then
      echo "$ARCH: Timeout reached while waiting for a ready replica of StatefulSet $STATEFULSET_NAME." >&2
      exit 1
    fi
    sleep 10
  done
}

function build() {
  # pf-buildkit-get-address picks the least busy Running pod, so ask again on every attempt.
  BUILDKIT_HOST=$(pf-buildkit-get-address --arch="$ARCH")
  export BUILDKIT_HOST
  pf-buildkit-record-build --arch="$ARCH"

  # shellcheck disable=SC2086
  buildctl \
    build \
    --frontend=dockerfile.v0 \
    --output "type=image,name=$IMAGE_REGISTRY/$IMAGE_REPO:$TAG,push=$PUSH_IMAGE" \
    --local context="$BUILD_CONTEXT" \
    --local dockerfile="$(dirname "$DOCKERFILE_PATH")" \
    --opt filename="./$(basename "$DOCKERFILE_PATH")" \
    $SECRET_ARGS \
    $BUILD_ARGS \
    --export-cache "type=s3,region=$BUILDKIT_BUCKET_REGION,bucket=$BUILDKIT_BUCKET_NAME,name=$IMAGE_REGISTRY/$IMAGE_REPO" \
    --import-cache "type=s3,region=$BUILDKIT_BUCKET_REGION,bucket=$BUILDKIT_BUCKET_NAME,name=$IMAGE_REGISTRY/$IMAGE_REPO" \
    2>&1 | tee "$BUILD_LOG"
}

ATTEMPT=1
until build; do
  if [[ $ATTEMPT -ge $MAX_ATTEMPTS ]] || ! grep -qE "$CONNECTION_LOST" "$BUILD_LOG"; then
    exit 1
  fi
  ATTEMPT=$((ATTEMPT + 1))
  echo "$ARCH: Lost the connection to buildkitd. Retrying on a ready replica (attempt $ATTEMPT of $MAX_ATTEMPTS)." >&2
  # Give the StatefulSet status time to drop the pod that just went away.
  sleep 10
  wait-for-buildkit
done
