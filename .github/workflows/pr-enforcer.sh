#!/usr/bin/env bash
set -euo pipefail

ORG="$ORG_NAME"
ALLOWED_TEAMS=("vortex-dev" "vortex-admin")

echo "Checking if user '$GITHUB_ACTOR' belongs to allowed teams..."

#function 1 
check_org_membership() {
  local user="$1"
  local org="$2"

  local state
  state=$(curl -s -H "Authorization: Bearer $ORG_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${org}/memberships/${user}" | jq -r '.state // empty')

  if [[ "$state" != "active" ]]; then
    echo "User '$user' is not an active member of organization '$org'."
    exit 1
  fi
}

#function 2
check_team_membership() {
  local user="$1"
  local org="$2"
  local team="$3"

  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $ORG_TOKEN" \
    "https://api.github.com/orgs/${org}/teams/${team}/memberships/${user}")

  if [[ "$status" == "200" ]]; then
    if [[ "$team" == "vortex-admin" ]]; then
      echo 10
    elif [[ "$team" == "vortex-dev" ]]; then
      echo 20
    fi
    return 0
  fi

  return 1
}

#function 3 
check_allowed_files() {
  echo "Checking changed files..."

  local base_branch="${BASE_BRANCH:-origin/main}"

  local changed_files
  changed_files=$(git diff --name-only "$base_branch"...HEAD)

  if [[ -z "$changed_files" ]]; then
    echo "No changed files detected."
    echo 10
    return 0
  fi

  local disallowed_found=false

  while IFS= read -r file; do
    if [[ ! "$file" =~ ^projects/vortex/ ]]; then
      echo "Disallowed file detected: $file"
      disallowed_found=true
    fi
  done <<< "$changed_files"

  if [[ "$disallowed_found" == true ]]; then
    echo "One or more files are outside the allowed directory (projects/vortex/**)."
    exit 1
  else
    echo "All changed files are within allowed paths."
    echo 10
    return 0
  fi
}

main() {
  check_org_membership "$GITHUB_ACTOR" "$ORG"

  for TEAM in "${ALLOWED_TEAMS[@]}"; do
    role_code=$(check_team_membership "$GITHUB_ACTOR" "$ORG" "$TEAM" || true)

    if [[ "$role_code" == "10" ]]; then
      echo "User '$GITHUB_ACTOR' is a member of team '$TEAM' (Admin) — returning code 10"
      exit 0
    elif [[ "$role_code" == "20" ]]; then
      echo "User '$GITHUB_ACTOR' is a member of team '$TEAM' (Dev) — returning code 20"
      exit 0
    fi
  done

  echo "Access denied: '$GITHUB_ACTOR' is not part of vortex-admin or vortex-dev teams."
  exit 1

  allowed_code=$(check_allowed_files)
  if [[ "$allowed_code" == "10" ]]; then
    echo "Allowed file check passed — code 10"
  else
    echo "File restriction check failed"
    exit 1
  fi

}

main
