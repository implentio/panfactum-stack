#!/usr/bin/env bash
# Regression tests for delete-locks.sh (the force-unlock hook's lock release).
#
# No AWS: a stub `aws` first on PATH answers `dynamodb scan` with $SCAN_FILE and records every
# `dynamodb delete-item --key` it receives in $DELETE_LOG. Real jq does the filtering.
#
# Run: bash packages/infrastructure/wf_tf_deploy/scripts/delete-locks.test.sh
set -u

SELF_DIR="$(CDPATH='' cd "$(dirname "$0")" && pwd)"
SCRIPT="$SELF_DIR/delete-locks.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
# Like the real CLI, it refuses an empty --key, and every call must name the ci profile (no default credentials).
cat >"$WORK/bin/aws" <<'STUB_EOF'
#!/usr/bin/env bash
op=""; key=""; profile=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    scan|delete-item) op="$1" ;;
    --key) shift; key="$1" ;;
    --profile) shift; profile="$1" ;;
  esac
  shift
done
[[ $profile == ci ]] || { echo "aws: no ci profile" >&2; exit 253; }
case "$op" in
  scan)
    [[ -z ${SCAN_FAIL:-} ]] || { echo "An error occurred (ExpiredTokenException)" >&2; exit 254; }
    cat "$SCAN_FILE"
    ;;
  delete-item)
    [[ -n $key ]] || { echo "aws: error: argument --key: expected one argument" >&2; exit 252; }
    printf '%s\n' "$key" >>"$DELETE_LOG"
    ;;
esac
STUB_EOF
chmod +x "$WORK/bin/aws"
export PATH="$WORK/bin:$PATH"
export DELETE_LOG="$WORK/deletes" SCAN_FILE="$WORK/scan.json"

WHO="@4503f3688856f8ad23d7e7eeb6b3cca2"
FAILS=0

lock() { # $1 = LockID, $2 = Info.S (already JSON-escaped as a string body)
  printf '{"LockID":{"S":"%s"},"Info":{"S":"%s"}}' "$1" "$2"
}

run_case() { # $1 = name, $2 = expected exit ("nonzero" for any failure), $3 = expected deletes (newline-separated)
  : >"$DELETE_LOG"
  bash "$SCRIPT" ci us-west-2 tf-production-royqu0nc "$WHO" >/dev/null 2>"$WORK/stderr"
  local code=$?
  local got
  got="$(cat "$DELETE_LOG")"
  local want_ok=0
  if [[ $2 == nonzero ]]; then [[ $code -ne 0 ]] && want_ok=1; else [[ $code -eq $2 ]] && want_ok=1; fi
  if [[ $want_ok -ne 1 || "$got" != "$3" ]]; then
    echo "FAIL $1: exit $code (want $2), deletes [$got] (want [$3])"
    sed 's/^/  stderr: /' "$WORK/stderr"
    FAILS=$((FAILS + 1))
  else
    echo "ok   $1"
  fi
}

MINE='{\"ID\":\"a\",\"Operation\":\"OperationTypeApply\",\"Who\":\"'"$WHO"'\",\"Path\":\"b/warehouse\"}'
OTHER='{\"ID\":\"c\",\"Operation\":\"OperationTypeApply\",\"Who\":\"@someone-else\",\"Path\":\"b/api\"}'

# The prod table state behind P-42 (and the 2026-10-19 toolbelt deploy): a lock whose Info is empty.
printf '{"Items":[%s,%s,%s,%s]}' \
  "$(lock b/broken '')" "$(lock b/warehouse "$MINE")" "$(lock b/api "$OTHER")" "$(lock b/junk 'not json')" >"$SCAN_FILE"
run_case "deletes only this workflow's lock when another lock's Info is empty or not JSON" 0 \
  '{"LockID":{"S":"b/warehouse"}}'

# Before the fix this is the exact jq program pf-tf-delete-locks ran; it must still fail on this table.
jq -c '.Items[] | select( if .Info.S then (.Info.S | fromjson).Who == "'"$WHO"'" else false end )' \
  "$SCAN_FILE" >/dev/null 2>&1
code=$?
if [[ $code -eq 5 ]]; then echo "ok   upstream filter exits 5 on the same table (the P-42 symptom)"; else
  echo "FAIL upstream filter exit $code (want 5)"; FAILS=$((FAILS + 1))
fi

printf '{"Items":[%s]}' "$(lock b/api "$OTHER")" >"$SCAN_FILE"
run_case "deletes nothing when no lock is this workflow's" 0 ''

printf '{"Items":[]}' >"$SCAN_FILE"
run_case "empty table" 0 ''

printf '{"Items":[%s,%s]}' "$(lock 'b/one' "$MINE")" "$(lock 'b/two' "$MINE")" >"$SCAN_FILE"
run_case "deletes every lock this workflow holds" 0 \
  "$(printf '%s\n%s' '{"LockID":{"S":"b/one"}}' '{"LockID":{"S":"b/two"}}')"

printf 'An error occurred (AccessDeniedException)' >"$SCAN_FILE"
run_case "a failed scan fails the hook" nonzero ''

printf '{"Items":[%s]}' "$(lock b/warehouse "$MINE")" >"$SCAN_FILE"
SCAN_FAIL=1 run_case "a scan that fails with no answer fails the hook (pipefail)" nonzero ''

: >"$DELETE_LOG"
bash "$SCRIPT" ci us-west-2 tf-production-royqu0nc "" >/dev/null 2>&1
code=$?
if [[ $code -eq 1 ]]; then echo "ok   missing argument exits 1"; else
  echo "FAIL missing argument exit $code (want 1)"; FAILS=$((FAILS + 1))
fi

if [[ $FAILS -gt 0 ]]; then
  echo "$FAILS failed"
  exit 1
fi
echo "all passed"
