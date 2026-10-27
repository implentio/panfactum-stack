#!/usr/bin/env bash
# Releases the DynamoDB state locks whose Info.Who is WHO, like pf-tf-delete-locks.
# pf-tf-delete-locks runs `fromjson` on every lock's Info, so one lock with an empty or non-JSON Info
# in the shared table makes jq exit 5 and no lock is released. This skips such locks.
#
# Usage: delete-locks.sh <profile> <region> <table> <who>

set -eo pipefail

PROFILE="$1"
REGION="$2"
TABLE="$3"
WHO="$4"

if [[ -z $PROFILE || -z $REGION || -z $TABLE || -z $WHO ]]; then
  echo "Usage: delete-locks.sh <profile> <region> <table> <who>" >&2
  exit 1
fi

echo "Releasing locks held by $WHO from $TABLE in $REGION using the $PROFILE AWS profile..." >&2

KEYS=$(
  aws \
    --profile "$PROFILE" \
    --region "$REGION" \
    dynamodb scan \
    --table-name "$TABLE" \
    --scan-filter '{"Info": {"ComparisonOperator": "NOT_NULL"}}' \
    --output json |
    jq -c --arg who "$WHO" \
      '.Items[] | select(try (.Info.S | fromjson | .Who == $who) catch false) | {LockID: {S: .LockID.S}}'
)

while read -r key; do
  [[ -n $key ]] || continue
  echo "Deleting lock $key" >&2
  aws \
    --profile "$PROFILE" \
    --region "$REGION" \
    dynamodb delete-item \
    --table-name "$TABLE" \
    --key "$key"
done <<<"$KEYS"
