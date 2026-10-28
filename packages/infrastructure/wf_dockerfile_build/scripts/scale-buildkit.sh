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
## Step 1: Scale up buildkit
###########################################################
# shellcheck disable=SC1091
source pf-buildkit-validate

ARCHES=(arm64 amd64)
WAIT=0
SCALE_UP_ARGS=()
for ARG in "$@"; do
  case "$ARG" in
  --wait) WAIT=1 ;;
  --only=*)
    ARCHES=("${ARG#--only=}")
    SCALE_UP_ARGS+=("$ARG")
    ;;
  *) SCALE_UP_ARGS+=("$ARG") ;;
  esac
done

/bin/pf-buildkit-scale-up "${SCALE_UP_ARGS[@]}"

###########################################################
## Step 2: Wait for one available replica per arch
###########################################################
# pf-buildkit-scale-up --wait polls every 10s, which added 0-10s to each cold start.
if [[ $WAIT == 1 ]]; then
  DEADLINE=$(($(date +%s) + 600))
  for ARCH in "${ARCHES[@]}"; do
    STATEFULSET_NAME="$BUILDKIT_STATEFULSET_NAME_PREFIX$ARCH"
    until [[ $(kubectl get statefulset "$STATEFULSET_NAME" --namespace="$BUILDKIT_NAMESPACE" -o=jsonpath='{.status.availableReplicas}') -ge 1 ]]; do
      if [[ $(date +%s) -ge $DEADLINE ]]; then
        echo "$ARCH: Timeout reached while waiting for StatefulSet $STATEFULSET_NAME to scale up." >&2
        exit 1
      fi
      echo "$ARCH: Waiting for at least one BuildKit replica to become available..." >&2
      sleep 2
    done
  done
fi
