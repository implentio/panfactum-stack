#!/usr/bin/env bash
# Guards how force-unlock is wired in main.tf. Argo v3.7 (workflow/controller/workflowpod.go) creates no pod
# for a task hook once the workflow deadline has passed, and exempts only onExit pods, so a `deploy` that
# hits its 1 h deadline releases its state locks only if force-unlock is the workflow onExit handler.
#
# Run: bash packages/infrastructure/wf_tf_deploy/scripts/wf-spec.test.sh
set -u

MAIN="$(CDPATH='' cd "$(dirname "$0")/.." && pwd)/main.tf"
FAILS=0

check() { # $1 = name, rest = command that must succeed
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then echo "ok   $name"; else
    echo "FAIL $name"
    FAILS=$((FAILS + 1))
  fi
}

check "force-unlock is the workflow onExit handler" grep -Eq '^\s*on_exit\s*=\s*"force-unlock"' "$MAIN"
check "no task hook runs force-unlock" bash -c "! grep -Eq '^\s*hooks\s*=' '$MAIN' && ! grep -Eq 'template\s*=\s*\"force-unlock\"' '$MAIN'"
check "force-unlock pod does not mount the code EBS PVC" grep -Eq 'contains\(\["tmp", "cache", "code"\], volume\.name\)' "$MAIN"

if [[ $FAILS -gt 0 ]]; then
  echo "$FAILS failed"
  exit 1
fi
echo "all passed"
