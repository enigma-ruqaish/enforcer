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
    echo "⚠️ Base branch '$base_branch' not found, using previous commit (HEAD^)..."
    if git rev-parse --verify "HEAD^" >/dev/null 2>&1; then
      base_branch="HEAD^"
    else
      echo "⚠️ No previous commit found — likely first commit. Enforcing allowed path rule manually..."
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

  echo "📂 Changed files:"
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

# Function 4
check_new_tag_change_only() {
  echo "🔎 [START] Running newTag-only change validation..."

  # Step 1: Verify admin membership
  echo "📂 Step 1: Checking if user '$GITHUB_ACTOR' is in vortex-admin team..."
  local role_code
  role_code=$(check_team_membership "$GITHUB_ACTOR" "$ORG" "vortex-admin" || true)

  if [[ "$role_code" != "10" ]]; then
    echo "❌ Step 1 failed: User '$GITHUB_ACTOR' is NOT a vortex-admin member."
    return 20
  fi
  echo "✅ Step 1 passed: User is a vortex-admin member."

  # Step 2: Fetch base branch for diff
  local base_branch="${BASE_BRANCH:-origin/main}"
  echo "📂 Step 2: Using base branch '$base_branch' for diff comparison..."
  git fetch origin "$base_branch" --depth=50 >/dev/null 2>&1 || true

  # Step 3: Detect changed files
  local changed_files
  changed_files=$(git diff --name-only "$base_branch"...HEAD 2>/dev/null || true)
  echo "📂 Step 3: Changed files detected:"
  echo "$changed_files"

  local file_count
  file_count=$(echo "$changed_files" | grep -c '.')
  echo "🧮 Total changed files: $file_count"

  if [[ "$file_count" -ne 1 ]]; then
    echo "❌ Step 3 failed: Expected exactly ONE changed file, found $file_count."
    return 21
  fi
  echo "✅ Step 3 passed: Exactly one file changed."

  # Step 4: Validate changed file path
  local changed_file
  changed_file=$(echo "$changed_files" | head -n 1)
  echo "📘 Step 4: Validating changed file path '$changed_file'..."

  if [[ ! "$changed_file" =~ ^projects/vortex/.*/kustomization\.ya?ml$ ]]; then
    echo "❌ Step 4 failed: Changed file is not within 'projects/vortex/**/kustomization.yaml'."
    return 22
  fi
  echo "✅ Step 4 passed: File is a valid kustomization.yaml under projects/vortex/."

  # Step 5: Extract diff for this file
  echo "🔍 Step 5: Extracting diff for $changed_file..."
  local diff_output
  diff_output=$(git diff "$base_branch"...HEAD -- "$changed_file" || true)
  echo "🧾 Full diff output:"
  echo "$diff_output"

  # Step 6: Verify newTag change format
  echo "⚙️ Step 6: Checking if only 'newTag' changed and matches 7-char commit format..."
  local allowed_diff
  allowed_diff=$(echo "$diff_output" | grep -E '^\+\s*newTag:\s*"[0-9a-fA-F]{7}"' || true)

  if [[ -z "$allowed_diff" ]]; then
    echo "❌ Step 6 failed: No valid 'newTag' line found or incorrect format (expected 7-char hex with quotes)."
    return 23
  fi

  echo "✅ Step 6 passed: Valid newTag line found:"
  echo "$allowed_diff"

  # Step 7: Ensure only newTag line changed
  local total_diff_lines allowed_diff_lines
  total_diff_lines=$(echo "$diff_output" | grep -E '^[+-]' | grep -v '^\+\+\+' | grep -v '^---' | wc -l)
  allowed_diff_lines=$(echo "$allowed_diff" | wc -l)

  echo "🧮 Step 7: Total diff lines: $total_diff_lines"
  echo "🧮 Step 7: Allowed (newTag) diff lines: $allowed_diff_lines"

  if [[ "$total_diff_lines" -eq "$allowed_diff_lines" && "$allowed_diff_lines" -gt 0 ]]; then
    echo "✅ Step 7 passed: Only newTag value changed."
    echo "🎯 [SUCCESS] All validation checks passed — returning 100."
    return 100
  else
    echo "❌ Step 7 failed: Detected changes other than newTag."
    return 24
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

  echo "Running file restriction check..."
  if ! check_allowed_files; then
    echo "File restriction check failed."
    exit 1
  fi

  #Function 4 calling 

  echo "🚀 Running newTag-only validation..."
  check_new_tag_change_only
  new_tag_result=$?

  echo "📊 newTag validation result code: $new_tag_result"

  case "$new_tag_result" in
    100)
      echo "✅ Passed: Only 'newTag' (7-char commit) changed correctly."
      ;;
    20)
      echo "❌ Failed: User is not in vortex-admin team."
      exit 1
      ;;
    21)
      echo "❌ Failed: More than one file changed — expected exactly one."
      exit 1
      ;;
    22)
      echo "❌ Failed: File is not within 'projects/vortex/**/kustomization.yaml'."
      exit 1
      ;;
    23)
      echo "❌ Failed: 'newTag' line is missing or invalid format (must be quoted 7-char commit)."
      exit 1
      ;;
    24)
      echo "❌ Failed: Other lines besides 'newTag' were changed."
      exit 1
      ;;
    *)
      echo "⚠️ Unexpected return code: $new_tag_result. Please debug."
      exit 1
      ;;
  esac

  echo " All checks passed successfully."
}

main
