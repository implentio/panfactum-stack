#!/usr/bin/env bash
# Regression tests for creds-sync.sh: a creds Secret is deleted only when its VSO Redis user is
# really missing from the master's ACL list (Panfactum/stack#387).
#
# No live cluster: stub `redis-cli`, `kubectl` and `sleep` binaries are put first on PATH. The ACL
# list has the VSO users first and thousands of users after them, so `echo "$USERS_SRC" | grep -q`
# would SIGPIPE on every check. The `sleep` stub exits 42 to end the script's endless loop.
#
# Run: bash packages/infrastructure/kube_redis_sentinel/creds-sync.test.sh
set -u

SELF_DIR="$(CDPATH='' cd "$(dirname "$0")" && pwd)"
SCRIPT="${CREDS_SYNC_SCRIPT:-$SELF_DIR/creds-sync.sh}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

cat >"$WORK/bin/redis-cli" <<'STUB_EOF'
#!/usr/bin/env bash
P="V_KUBERNETES-IMPLENTIO-REDIS-E50A"
# A write to a replica or sentinel (10.0.0.x) is logged, one line per call, one argument per field.
if [[ " $* " == *" ACL DELUSER "* || " $* " == *" ACL SETUSER "* ]]; then
  printf '%s|' "$@" >>"$REDIS_LOG"
  echo >>"$REDIS_LOG"
  exit 0
fi
if [[ " $* " == *" -h 10.0.0."* ]]; then
  # A replica's or sentinel's list: the VSO users, a filler, a user the master dropped, and one whose name is
  # only a part of a master user's name ("filler-use").
  [[ -n "${EMPTY_DST:-}" ]] && exit 0
  for ROLE in SUPERUSER ADMIN READER; do echo "user ${P}_${ROLE}_lease on #abc ~* &* +@all"; done
  echo "user filler-user-10${PAD:-} on #abc ~* &* +@read"
  echo "user dropped-user on #abc ~* &* +@read"
  echo "user filler-use on #abc ~* &* +@read"
  exit 0
fi
[[ -n "${EMPTY_SRC:-}" ]] && exit 0
for ROLE in SUPERUSER ADMIN READER; do
  [[ " ${MISSING_ROLES:-} " == *" $ROLE "* ]] || echo "user ${P}_${ROLE}_lease on #abc ~* &* +@all"
done
for i in $(seq 1 "${FILLERS:-5000}"); do
  echo "user filler-user-$i${PAD:-} on #abc ~* &* +@read"
done
STUB_EOF

cat >"$WORK/bin/kubectl" <<'STUB_EOF'
#!/usr/bin/env bash
echo "$*" >>"$KUBECTL_LOG"
# With SYNC_PODS: pod 1 is the replica, pods 0 and 1 run sentinels; pod N's IP is 10.0.0.N.
[[ -n "${SYNC_PODS:-}" ]] || exit 0
case "$*" in
*"isMaster!=true"*) echo "redis-e50a-1" ;;
*"get pods -l id=redis-e50a "*) printf 'redis-e50a-0\nredis-e50a-1\n' ;;
*"get pod redis-e50a-"*) echo "10.0.0.${5##*-}" ;;
esac
STUB_EOF

cat >"$WORK/bin/sleep" <<'STUB_EOF'
#!/usr/bin/env bash
exit 42
STUB_EOF

chmod +x "$WORK/bin/"*

FAILED=0

# $1 = case name, $2 = space-separated missing roles, $3 = expected deleted secret ("" for none)
run_case() {
  local NAME=$1 MISSING=$2 EXPECTED=$3
  local LOG="$WORK/$NAME.kubectl.log"
  : >"$LOG"
  PATH="$WORK/bin:$PATH" MISSING_ROLES="$MISSING" KUBECTL_LOG="$LOG" \
    SRC_REDIS_HOST=redis-e50a-master.implentio REDIS_NAMESPACE=implentio \
    REDIS_STS_NAME=redis-e50a REDIS_ID=redis-e50a LOGGING_ENABLED=0 \
    bash "$SCRIPT" >/dev/null 2>&1
  local STATUS=$?
  local DELETES
  DELETES=$(grep '^-n implentio delete secret' "$LOG" | awk '{print $5}')

  if [[ $STATUS -ne 42 ]]; then
    echo "FAIL $NAME: script exited $STATUS before its sleep"
    FAILED=1
  elif [[ "$DELETES" != "$EXPECTED" ]]; then
    echo "FAIL $NAME: deleted [${DELETES}], expected [${EXPECTED}]"
    FAILED=1
  else
    echo "ok   $NAME"
  fi
}

for i in 1 2 3 4 5; do
  run_case "all-users-present-$i" "" ""
done
run_case "superuser-missing" "SUPERUSER" "redis-e50a-superuser-creds"
run_case "admin-missing" "ADMIN" "redis-e50a-admin-creds"
run_case "reader-missing" "READER" "redis-e50a-reader-creds"

# One loop with a replica (pod 1, port 6379) and two sentinels (pods 0 and 1, port 26379): on each, only the user that
# the master dropped and the one whose name is only a part of a master user's are deleted, then every master rule is
# set, one argument per word. The master's 63 user names are ~300 KB (60 fillers of 5,000 characters), more than a pipe
# holds, so a pipe into `grep -qw` would SIGPIPE on the early VSO users.
# $1 = case name, extra environment as the rest.
run_sync() {
  local NAME=$1
  shift
  local LOG="$WORK/$NAME.kubectl.log" RLOG="$WORK/$NAME.redis.log"
  : >"$LOG"
  : >"$RLOG"
  env PATH="$WORK/bin:$PATH" KUBECTL_LOG="$LOG" REDIS_LOG="$RLOG" SYNC_PODS=1 FILLERS=60 PAD="-$(printf 'x%.0s' {1..5000})" \
    SRC_REDIS_HOST=redis-e50a-master.implentio REDIS_NAMESPACE=implentio \
    REDIS_STS_NAME=redis-e50a REDIS_ID=redis-e50a LOGGING_ENABLED=0 "$@" \
    bash "$SCRIPT" >/dev/null 2>&1
  SYNC_STATUS=$?
  SYNC_LOG=$RLOG
}

expect_sync() {
  local NAME=$1 WANT_STATUS=$2 WANT=$3 GOT
  GOT=$(grep -c . "$SYNC_LOG"; grep DELUSER "$SYNC_LOG"; grep -m 1 SETUSER "$SYNC_LOG")
  if [[ $SYNC_STATUS -ne $WANT_STATUS ]]; then
    echo "FAIL $NAME: script exited $SYNC_STATUS, expected $WANT_STATUS"
    FAILED=1
  elif [[ "$GOT" != "$WANT" ]]; then
    printf 'FAIL %s: redis-cli writes\n%s\nexpected\n%s\n' "$NAME" "$GOT" "$WANT"
    FAILED=1
  else
    echo "ok   $NAME"
  fi
}

DELS() {
  local HOST PORT
  for HOST_PORT in "10.0.0.1 6379" "10.0.0.0 26379" "10.0.0.1 26379"; do
    read -r HOST PORT <<<"$HOST_PORT"
    printf -- '-e|-h|%s|-p|%s|ACL|DELUSER|%s|\n' "$HOST" "$PORT" dropped-user "$HOST" "$PORT" filler-use
  done
}
# 3 hosts x (2 deletes + 63 rules); the first rule is the superuser's, split into its words.
SYNC_WANT="$((3 * (2 + 63)))
$(DELS)
-e|-h|10.0.0.1|-p|6379|ACL|SETUSER|V_KUBERNETES-IMPLENTIO-REDIS-E50A_SUPERUSER_lease|on|#abc|~*|&*|+@all|"
for i in 1 2 3; do
  run_sync "sync-$i"
  expect_sync "sync-$i" 42 "$SYNC_WANT"
done
# The master answers no ACL list: stop before anything is deleted or synced.
run_sync "master-empty" EMPTY_SRC=1
if [[ $SYNC_STATUS -ne 1 || -s "$SYNC_LOG" ]] || grep -q delete "$WORK/master-empty.kubectl.log"; then
  echo "FAIL master-empty: exited $SYNC_STATUS, wrote $(wc -l <"$SYNC_LOG") redis lines, kubectl: $(grep -c delete "$WORK/master-empty.kubectl.log") deletes"
  FAILED=1
else
  echo "ok   master-empty"
fi
# A replica answers no ACL list: stop before any write to it.
run_sync "replica-empty" EMPTY_DST=1
expect_sync "replica-empty" 1 "0"

exit $FAILED
