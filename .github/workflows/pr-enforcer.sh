#!/usr/bin/env bash
set -euo pipefail

echo "🔍 Checking if user '$GITHUB_ACTOR' belongs to allowed teams..."

ALLOWED_TEAMS=("vortex-dev" "vortex-admin")
ORG="$ORG_NAME"

# Fetch user's teams using GitHub API
USER_TEAMS=$(curl -s -H "Authorization: Bearer $ORG_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/${ORG}/memberships/${GITHUB_ACTOR}" | jq -r '.state // empty')

if [[ "$USER_TEAMS" != "active" ]]; then
  echo "User '$GITHUB_ACTOR' is not an active member of the organization '$ORG'."
  exit 1
fi

# Check team membership one by one
for TEAM in "${ALLOWED_TEAMS[@]}"; do
  IS_MEMBER=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $ORG_TOKEN" \
    "https://api.github.com/orgs/${ORG}/teams/${TEAM}/memberships/${GITHUB_ACTOR}")

  if [[ "$IS_MEMBER" == "200" ]]; then
    echo "User '$GITHUB_ACTOR' is a member of allowed team '${TEAM}'."
    exit 0
  fi
done

echo "Access denied: '$GITHUB_ACTOR' is not part of vortex-admin or vortex-dev teams."
exit 1
