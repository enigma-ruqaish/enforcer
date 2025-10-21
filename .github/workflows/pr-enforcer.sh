#!/usr/bin/env bash
set -euo pipefail

ORG="$ORG_NAME"
ALLOWED_TEAMS=("vortex-dev" "vortex-admin")

echo "Checking if user '$GITHUB_ACTOR' belongs to allowed teams..."

# Function 1
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

# Function 2
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

# Function 3
check_allowed_files() {
  echo "🔍 Checking changed files..."
  local base_branch="${BASE_BRANCH:-origin/main}"

  git fetch --depth=2 origin "$base_branch" >/dev/null 2>&1 || true

  if ! git rev-parse --verify "$base_branch" >/dev/null 2>&1; then
    if git rev-parse --verify "HEAD^" >/dev/null 2>&1; then
      echo "Base branch '$base_branch' not found, using previous commit (HEAD^)..."
      base_branch="HEAD^"
    else
      echo "No previous commit found — likely first commit or shallow clone."
      echo 10
      return 0
    fi
  fi

  local changed_files
  changed_files=$(git diff --name-only "$base_branch"...HEAD 2>/dev/null || true)

  if [[ -z "$changed_files" ]]; then
    echo "No changed files detected."
    echo 10
    return 0
  fi

  echo "Changed files:"
  echo "$changed_files"
  echo

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

  local user_is_allowed=false
  for TEAM in "${ALLOWED_TEAMS[@]}"; do
    role_code=$(check_team_membership "$GITHUB_ACTOR" "$ORG" "$TEAM" || true)
    if [[ "$role_code" == "10" || "$role_code" == "20" ]]; then
      echo "User '$GITHUB_ACTOR' is part of allowed team '$TEAM'"
      user_is_allowed=true
      break
    fi
  done

  if [[ "$user_is_allowed" == false ]]; then
    echo "Access denied: '$GITHUB_ACTOR' is not part of vortex-admin or vortex-dev teams."
    exit 1
  fi

  echo "🔹 Running file restriction check..."
  if ! check_allowed_files; then
    echo "File restriction check failed."
    exit 1
  fi

  echo " All checks passed successfully."
}

main
