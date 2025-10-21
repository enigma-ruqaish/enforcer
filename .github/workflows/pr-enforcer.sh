#!/usr/bin/env bash
set -euo pipefail

ORG="$ORG_NAME"
ALLOWED_TEAMS=("vortex-dev" "vortex-admin")

echo "🔍 Checking if user '$GITHUB_ACTOR' belongs to allowed teams..."

# ----------------------------
# 🔧 Function: check_org_membership
# ----------------------------
check_org_membership() {
  local user="$1"
  local org="$2"

  local state
  state=$(curl -s -H "Authorization: Bearer $ORG_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${org}/memberships/${user}" | jq -r '.state // empty')

  if [[ "$state" != "active" ]]; then
    echo "❌ User '$user' is not an active member of organization '$org'."
    exit 1
  fi
}

# ----------------------------
# 🔧 Function: check_team_membership
# ----------------------------
check_team_membership() {
  local user="$1"
  local org="$2"
  local team="$3"

  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $ORG_TOKEN" \
    "https://api.github.com/orgs/${org}/teams/${team}/memberships/${user}")

  if [[ "$status" == "200" ]]; then
    echo "✅ User '$user' is a member of team '$team'."
    if [[ "$team" == "vortex-admin" ]]; then
      return 1
    elif [[ "$team" == "vortex-dev" ]]; then
      return 0
    fi
  fi

  return 2
}

# ----------------------------
# 🚀 Main logic
# ----------------------------
main() {
  check_org_membership "$GITHUB_ACTOR" "$ORG"

  for TEAM in "${ALLOWED_TEAMS[@]}"; do
    check_team_membership "$GITHUB_ACTOR" "$ORG" "$TEAM"
    local code=$?

    if [[ "$code" -eq 1 ]]; then
      echo "🔰 User '$GITHUB_ACTOR' is an ADMIN member."
      exit 0
    elif [[ "$code" -eq 0 ]]; then
      echo "🧑‍💻 User '$GITHUB_ACTOR' is a DEV member."
      exit 0
    fi
  done

  echo "🚫 Access denied: '$GITHUB_ACTOR' is not part of vortex-admin or vortex-dev teams."
  exit 1
}

main
