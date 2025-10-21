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

  # Ensure we have enough history for diff
  git fetch origin "$base_branch" --depth=50 >/dev/null 2>&1 || true

  # Handle shallow clones or missing base branch
  if ! git rev-parse --verify "$base_branch" >/dev/null 2>&1; then
    echo "Base branch '$base_branch' not found, using previous commit (HEAD^)..."
    if git rev-parse --verify "HEAD^" >/dev/null 2>&1; then
      base_branch="HEAD^"
    else
      echo "No previous commit found — likely first commit. Enforcing allowed path rule manually..."
      base_branch=""
    fi
  fi

  # Get changed files
  local changed_files=""
  if [[ -n "$base_branch" ]]; then
    changed_files=$(git diff --name-only "$base_branch"...HEAD 2>/dev/null || true)
  else
    # In rare first-commit cases, list all tracked files
    changed_files=$(git ls-files)
  fi

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
    # Only allow files under projects/vortex/**
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


#Function 4
check_new_tag_change_only() {
  echo "🔎 Running new tag change validation..."

  local role_code
  role_code=$(check_team_membership "$GITHUB_ACTOR" "$ORG" "vortex-admin" || true)

  # Step 1: Must be an admin
  if [[ "$role_code" != "10" ]]; then
    echo "❌ User '$GITHUB_ACTOR' is not an admin — cannot perform tag-only changes."
    return 20
  fi

  # Step 2: Must pass allowed files check
  local allowed_code
  allowed_code=$(check_allowed_files || true)
  if [[ "$allowed_code" != "10" ]]; then
    echo "❌ File restriction check failed — disallowed files changed."
    return 20
  fi

  # Step 3: Detect changed files
  local base_branch="${BASE_BRANCH:-origin/main}"
  git fetch origin "$base_branch" --depth=50 >/dev/null 2>&1 || true

  local changed_files
  changed_files=$(git diff --name-only "$base_branch"...HEAD 2>/dev/null || true)

  # Step 4: Ensure exactly one changed file
  local file_count
  file_count=$(echo "$changed_files" | grep -c '.')
  if [[ "$file_count" -ne 1 ]]; then
    echo "❌ Expected exactly one changed file, found $file_count."
    return 20
  fi

  local changed_file
  changed_file=$(echo "$changed_files" | head -n1)

  # Step 5: Ensure file path matches pattern
  if [[ ! "$changed_file" =~ ^projects/vortex/.*/kustomization\.yaml$ ]]; then
    echo "❌ File '$changed_file' is not a valid kustomization.yaml under projects/vortex/**."
    return 20
  fi

  # Step 6: Check diff for the newTag line
  local diff_output
  diff_output=$(git diff "$base_branch"...HEAD -- "$changed_file")

  # Extract added lines starting with '+'
  local added_lines
  added_lines=$(echo "$diff_output" | grep '^+' | grep -v '^+++' || true)

  # Must only contain one added line starting with newTag:
  local new_tag_line
  new_tag_line=$(echo "$added_lines" | grep -E '^\+\s*newTag:' || true)
  local new_tag_line_count
  new_tag_line_count=$(echo "$new_tag_line" | grep -c '^+newTag:' || true)

  if [[ "$new_tag_line_count" -ne 1 ]]; then
    echo "❌ The diff must contain exactly one added 'newTag:' line."
    return 20
  fi

  # Step 7: Extract the tag value inside quotes
  local tag_value
  tag_value=$(echo "$new_tag_line" | sed -E 's/.*newTag:[[:space:]]*"([^"]*)".*/\1/')

  if [[ -z "$tag_value" ]]; then
    echo "❌ Could not extract newTag value."
    return 20
  fi

  # Step 8: Validate tag length = 7 characters
  if [[ ${#tag_value} -ne 7 ]]; then
    echo "❌ Tag '$tag_value' length is not 7 characters."
    return 20
  fi

  echo "✅ New tag '$tag_value' is valid and change meets all rules."
  return 10
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

  echo "Running file restriction check..."
  if ! check_allowed_files; then
    echo "File restriction check failed."
    exit 1
  fi

  echo "Running newTag validation..."
  result=$(check_new_tag_change_only)
  if [[ "$result" == "20" ]]; then
    echo "newTag validation failed."
    exit 1
  fi

  echo " All checks passed successfully."
}

main
