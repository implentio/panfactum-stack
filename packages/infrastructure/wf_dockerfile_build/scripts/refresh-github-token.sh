#!/usr/bin/env bash

set -e

# Required environment variables
GITHUB_APP_ID=${GITHUB_APP_ID:?GITHUB_APP_ID is not set}
GITHUB_APP_PRIVATE_KEY=${GITHUB_APP_PRIVATE_KEY:?GITHUB_APP_PRIVATE_KEY is not set}
GITHUB_APP_INSTALLATION_ID=${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID is not set}
SHARED_VOLUME_PATH=${SHARED_VOLUME_PATH:-/tmp}

# Function to generate JWT
generate_jwt() {
    header='{"alg":"RS256","typ":"JWT"}'
    payload=$(jq -c -n --arg iat "$(date +%s)" --arg exp "$(($(date +%s) + 600))" --arg iss "$GITHUB_APP_ID" \
        '{iat: ($iat|tonumber), exp: ($exp|tonumber), iss: ($iss|tonumber)}')

    encoded_header=$(echo -n "$header" | openssl base64 -e | tr -d '\n=' | tr '/+' '_-')
    encoded_payload=$(echo -n "$payload" | openssl base64 -e | tr -d '\n=' | tr '/+' '_-')

    unsigned_token="${encoded_header}.${encoded_payload}"
    signature=$(echo -n "$unsigned_token" | openssl dgst -sha256 -sign <(echo "$GITHUB_APP_PRIVATE_KEY") | openssl base64 -e | tr -d '\n=' | tr '/+' '_-')

    echo "${unsigned_token}.${signature}"
}

# Generate JWT
JWT=$(generate_jwt)

# Fetch access token
token_response=$(curl -s -X POST -H "Authorization: Bearer $JWT" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/$GITHUB_APP_INSTALLATION_ID/access_tokens")

GITHUB_TOKEN=$(echo "$token_response" | jq -r '.token // empty')

if [ -z "$GITHUB_TOKEN" ]; then
    echo "Failed to retrieve GitHub token" >&2
    exit 1
fi

# Write token to shared volume
mkdir -p "$SHARED_VOLUME_PATH"
echo "$GITHUB_TOKEN" >"$SHARED_VOLUME_PATH/github_token"
echo "GitHub token fetched and written to $SHARED_VOLUME_PATH/github_token"
