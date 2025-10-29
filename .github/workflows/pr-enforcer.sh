#!/usr/bin/env bash
set -euo pipefail
# Allowed file types for modification
ALLOWED_FILES_REGEX="(deployment\.yaml|hpa\.yaml|ingress\.yaml|kustomization\.yaml)$"
# Temporary workspace for GitHub data
GITHUB_JSON="github.json"
DIFF_BRANCHES="origin/$(jq -r '.base_ref' $GITHUB_JSON)..origin/$(jq -r '.head_ref' $GITHUB_JSON)"
REPO="$(jq -r '.event.repository.full_name' $GITHUB_JSON)"
PR_NUMBER="$(jq -r '.event.pull_request.number' $GITHUB_JSON)"
PR_AUTHOR="$(jq -r '.event.pull_request.user.login' $GITHUB_JSON)"
#############################################
#  UTILITIES
#############################################
log() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }
github_comment() {
  local message="$1"
  curl -s -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -d "{\"body\":\"${message}\"}" \
    "https://api.github.com/repos/${REPO}/issues/${PR_NUMBER}/comments" > /dev/null
}
install_yq() {
  if ! command -v yq &>/dev/null; then
    log "Installing yq..."
    sudo curl -sL -o /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
    sudo chmod +x /usr/local/bin/yq
  fi
}
#############################################
#  GIT DIFF & VALIDATION
#############################################
fetch_branches() {
  git fetch origin "$(jq -r '.base_ref' $GITHUB_JSON)" "$(jq -r '.head_ref' $GITHUB_JSON)"
}
get_changed_files() {
  git diff --name-only ${DIFF_BRANCHES}
}
validate_changed_files() {
  local invalid_files=()
  for file in $(get_changed_files); do
    if [[ ! $file =~ $ALLOWED_FILES_REGEX ]]; then
      invalid_files+=("$file")
    fi
  done
  if (( ${#invalid_files[@]} > 0 )); then
    github_comment ":x: Unauthorized file changes detected:\n\\\\n${invalid_files[*]}\n\\\\nOnly deployment.yaml, hpa.yaml, ingress.yaml, and kustomization.yaml are allowed."
    error "Unauthorized file changes detected: ${invalid_files[*]}"
  fi
}
#############################################
#  TEAM MEMBERSHIP CHECK
#############################################
declare -A TEAM_MAP=(
  ["kevlar"]="kevlar"
  ["marvel"]="autos"
  ["vortex"]="vortex-admin vortex-dev"
)
# Determine if user belongs to a GitHub team
user_in_team() {
  local ORG="$1"
  local TEAM="$2"
  curl -fs -H "Accept: application/vnd.github+json" \
       -H "Authorization: Bearer ${ORG_TOKEN}" \
       "https://api.github.com/orgs/${ORG}/teams/${TEAM}/members" |
       jq -e ".[] | select(.login == \"${PR_AUTHOR}\")" > /dev/null
}
check_team_membership() {
  local project_name
  project_name=$(get_changed_files | head -1 | awk -F/ '{print $2}')
  # Check if the project exists in TEAM_MAP
  if [[ -z "${TEAM_MAP[$project_name]:-}" ]]; then
    github_comment ":warning: No team mapping found in TEAM_MAP for project '${project_name}'."
    error "No team mapping found for project '${project_name}'"
  fi
  local ORG="enigma-ruqaish"  # :point_left: adjust this if needed
  local TEAMS=(${TEAM_MAP[$project_name]})
  local user_allowed=false
  for TEAM in "${TEAMS[@]}"; do
    if user_in_team "$ORG" "$TEAM"; then
      log ":white_check_mark: User ${PR_AUTHOR} is part of ${TEAM} team."
      user_allowed=true
      break
    fi
  done
  if [[ "$user_allowed" == false ]]; then
    github_comment ":x: User *${PR_AUTHOR}* is not part of the authorized teams (*${TEAMS[]}**) for this project."
    error "User ${PR_AUTHOR} not in authorized team(s): ${TEAMS[*]}"
  fi
}
#############################################
#  IMAGE TAG CHECK & AUTO APPROVAL
#############################################
detect_image_tag_change() {
  git diff -U0 ${DIFF_BRANCHES} | grep -E '^\+' | grep -q 'newTag' || return 1
}
get_new_tag_value() {
  local kfile
  kfile=$(get_changed_files | grep 'kustomization.yaml' || true)
  [[ -n "$kfile" ]] && yq '.images[0].newTag' "$kfile"
}
auto_approve_pr() {
  curl -s -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${ORG_TOKEN}" \
    -d '{"event":"APPROVE"}' \
    "https://api.github.com/repos/${REPO}/pulls/${PR_NUMBER}/reviews" > /dev/null
  github_comment ":white_check_mark: Auto-approved: Image tag update by authorized team lead (${PR_AUTHOR})."
  log ":white_check_mark: Auto-approved image tag change by ${PR_AUTHOR}"
}
#############################################
#  MAIN EXECUTION FLOW
#############################################
main() {
  log "Fetching branches..."
  fetch_branches
  log "Validating changed files..."
  validate_changed_files
  log "Checking team membership..."
  check_team_membership
  # Authenticate GH CLI (ensures gh pr review works)
  echo "${GITHUB_TOKEN}" | gh auth login --with-token >/dev/null 2>&1 || true
  if detect_image_tag_change; then
    log "Detected image tag update..."
    local project_name
    project_name=$(get_changed_files | head -1 | awk -F/ '{print $2}')
    # :large_green_square: Match all CODEOWNERS lines for this project (can return multiple teams)
    local full_teams
    full_teams=$(grep -E "^projects/${project_name}/\\" CODEOWNERS | awk '{for (i=2;i<=NF;i++) print $i}' || true)
    # :large_green_square: Debug visibility
    log "Detected CODEOWNERS entry for ${project_name}: ${full_teams}"
    local found_admin_team=false
    # :large_green_square: Loop through all teams (e.g., vortex-dev and vortex-admin)
    for full_team in $full_teams; do
      local ORG TEAM
      ORG=$(echo "$full_team" | awk -F'/' '{print $1}' | sed 's/@//')
      TEAM=$(echo "$full_team" | awk -F'/' '{print $2}')
      log "Checking membership for ${PR_AUTHOR} in ${ORG}/${TEAM}..."
      if user_in_team "$ORG" "$TEAM"; then
        log ":white_check_mark: User ${PR_AUTHOR} is part of ${TEAM}"
        # :white_check_mark: Auto-approve only if in an admin team
        if [[ "$TEAM" == *"-admin" ]]; then
          found_admin_team=true
          # :large_green_square: Dynamic base_ref (supports both main and master)
          local BASE_REF
          BASE_REF=$(jq -r '.base_ref' "$GITHUB_JSON")
          # :large_green_square: Extract 7-char commit tag
          NEW_TAG=$(git diff origin/${BASE_REF}...HEAD | grep -Eo '[a-f0-9]{7}' | tail -1)
          TAG_LENGTH=${#NEW_TAG}
          if [[ $TAG_LENGTH -eq 7 ]]; then
            log ":white_check_mark: Detected 7-character tag ($NEW_TAG). Attempting auto-approval..."
            # :large_green_square: Improved approval logic with fallback
            if gh pr review "$PR_NUMBER" --approve --body "Auto-approved: 7-char tag change by admin (${PR_AUTHOR})"; then
              log ":white_check_mark: Auto-approval submitted successfully."
            else
              log ":warning: GitHub API blocked auto-approval (likely Actions restriction). Posting comment instead."
              github_comment ":white_check_mark: Tag validated and ready. Manual approval required since GitHub Actions cannot auto-approve via this token."
            fi
            exit 0
          else
            log ":warning: Tag found but not 7 characters ($TAG_LENGTH). Skipping auto-approval."
          fi
        else
          log ":information_source: User ${PR_AUTHOR} is in ${TEAM}, but not an admin team. Skipping auto-approval."
        fi
      fi
    done
    # :large_green_square: Handle case when user not in any admin teams
    if [[ "$found_admin_team" == false ]]; then
      log "User ${PR_AUTHOR} not in CODEOWNERS admin team (${full_teams}). Skipping auto-approval."
    fi
  else
    log "No image tag change detected, skipping auto-approval logic."
  fi
  # :warning: Require manual review from enigma-devops otherwise
  log "No auto-approval applied. Tagging enigma-devops for review..."
  github_comment ":eyes: This PR requires manual review from *@enigma-ruqaish/enigma-devops*."
  exit 0
}
main "$@"
2:36
#!/usr/bin/env bash
set -euo pipefail
# Allowed file types for modification
ALLOWED_FILES_REGEX="(deployment\.yaml|hpa\.yaml|ingress\.yaml|kustomization\.yaml)$"
# Temporary workspace for GitHub data
GITHUB_JSON="github.json"
DIFF_BRANCHES="origin/$(jq -r '.base_ref' $GITHUB_JSON)..origin/$(jq -r '.head_ref' $GITHUB_JSON)"
REPO="$(jq -r '.event.repository.full_name' $GITHUB_JSON)"
PR_NUMBER="$(jq -r '.event.pull_request.number' $GITHUB_JSON)"
PR_AUTHOR="$(jq -r '.event.pull_request.user.login' $GITHUB_JSON)"
#############################################
#  UTILITIES
#############################################
log() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }
github_comment() {
  local message="$1"
  curl -s -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -d "{\"body\":\"${message}\"}" \
    "https://api.github.com/repos/${REPO}/issues/${PR_NUMBER}/comments" > /dev/null
}
install_yq() {
  if ! command -v yq &>/dev/null; then
    log "Installing yq..."
    sudo curl -sL -o /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
    sudo chmod +x /usr/local/bin/yq
  fi
}
#############################################
#  GIT DIFF & VALIDATION
#############################################
fetch_branches() {
  git fetch origin "$(jq -r '.base_ref' $GITHUB_JSON)" "$(jq -r '.head_ref' $GITHUB_JSON)"
}
get_changed_files() {
  git diff --name-only ${DIFF_BRANCHES}
}
validate_changed_files() {
  local invalid_files=()
  for file in $(get_changed_files); do
    if [[ ! $file =~ $ALLOWED_FILES_REGEX ]]; then
      invalid_files+=("$file")
    fi
  done
  if (( ${#invalid_files[@]} > 0 )); then
    github_comment ":x: Unauthorized file changes detected:\n\`\`\`\n${invalid_files[*]}\n\`\`\`\nOnly deployment.yaml, hpa.yaml, ingress.yaml, and kustomization.yaml are allowed."
    error "Unauthorized file changes detected: ${invalid_files[*]}"
  fi
}
#############################################
#  TEAM MEMBERSHIP CHECK
#############################################
declare -A TEAM_MAP=(
  ["kevlar"]="kevlar"
  ["marvel"]="autos"
  ["vortex"]="vortex-admin vortex-dev"
)
# Determine if user belongs to a GitHub team
user_in_team() {
  local ORG="$1"
  local TEAM="$2"
  curl -fs -H "Accept: application/vnd.github+json" \
       -H "Authorization: Bearer ${ORG_TOKEN}" \
       "https://api.github.com/orgs/${ORG}/teams/${TEAM}/members" |
       jq -e ".[] | select(.login == \"${PR_AUTHOR}\")" > /dev/null
}
check_team_membership() {
  local project_name
  project_name=$(get_changed_files | head -1 | awk -F/ '{print $2}')
  # Check if the project exists in TEAM_MAP
  if [[ -z "${TEAM_MAP[$project_name]:-}" ]]; then
    github_comment ":warning: No team mapping found in TEAM_MAP for project '${project_name}'."
    error "No team mapping found for project '${project_name}'"
  fi
  local ORG="enigma-ruqaish"  # :point_left: adjust this if needed
  local TEAMS=(${TEAM_MAP[$project_name]})
  local user_allowed=false
  for TEAM in "${TEAMS[@]}"; do
    if user_in_team "$ORG" "$TEAM"; then
      log ":white_check_mark: User ${PR_AUTHOR} is part of ${TEAM} team."
      user_allowed=true
      break
    fi
  done
  if [[ "$user_allowed" == false ]]; then
    github_comment ":x: User **${PR_AUTHOR}** is not part of the authorized teams (**${TEAMS[*]}**) for this project."
    error "User ${PR_AUTHOR} not in authorized team(s): ${TEAMS[*]}"
  fi
}
#############################################
#  IMAGE TAG CHECK & AUTO APPROVAL
#############################################
detect_image_tag_change() {
  git diff -U0 ${DIFF_BRANCHES} | grep -E '^\+' | grep -q 'newTag' || return 1
}
get_new_tag_value() {
  local kfile
  kfile=$(get_changed_files | grep 'kustomization.yaml' || true)
  [[ -n "$kfile" ]] && yq '.images[0].newTag' "$kfile"
}
auto_approve_pr() {
  curl -s -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${ORG_TOKEN}" \
    -d '{"event":"APPROVE"}' \
    "https://api.github.com/repos/${REPO}/pulls/${PR_NUMBER}/reviews" > /dev/null
  github_comment ":white_check_mark: Auto-approved: Image tag update by authorized team lead (${PR_AUTHOR})."
  log ":white_check_mark: Auto-approved image tag change by ${PR_AUTHOR}"
}
#############################################
#  MAIN EXECUTION FLOW
#############################################
main() {
  log "Fetching branches..."
  fetch_branches
  log "Validating changed files..."
  validate_changed_files
  log "Checking team membership..."
  check_team_membership
  # Authenticate GH CLI (ensures gh pr review works)
  echo "${GITHUB_TOKEN}" | gh auth login --with-token >/dev/null 2>&1 || true
  if detect_image_tag_change; then
    log "Detected image tag update..."
    local project_name
    project_name=$(get_changed_files | head -1 | awk -F/ '{print $2}')
    # :large_green_square: Match all CODEOWNERS lines for this project (can return multiple teams)
    local full_teams
    full_teams=$(grep -E "^projects/${project_name}/\*\*" CODEOWNERS | awk '{for (i=2;i<=NF;i++) print $i}' || true)
    # :large_green_square: Debug visibility
    log "Detected CODEOWNERS entry for ${project_name}: ${full_teams}"
    local found_admin_team=false
    # :large_green_square: Loop through all teams (e.g., vortex-dev and vortex-admin)
    for full_team in $full_teams; do
      local ORG TEAM
      ORG=$(echo "$full_team" | awk -F'/' '{print $1}' | sed 's/@//')
      TEAM=$(echo "$full_team" | awk -F'/' '{print $2}')
      log "Checking membership for ${PR_AUTHOR} in ${ORG}/${TEAM}..."
      if user_in_team "$ORG" "$TEAM"; then
        log ":white_check_mark: User ${PR_AUTHOR} is part of ${TEAM}"
        # :white_check_mark: Auto-approve only if in an admin team
        if [[ "$TEAM" == *"-admin" ]]; then
          found_admin_team=true
          # :large_green_square: Dynamic base_ref (supports both main and master)
          local BASE_REF
          BASE_REF=$(jq -r '.base_ref' "$GITHUB_JSON")
          # :large_green_square: Extract 7-char commit tag
          NEW_TAG=$(git diff origin/${BASE_REF}...HEAD | grep -Eo '[a-f0-9]{7}' | tail -1)
          TAG_LENGTH=${#NEW_TAG}
          if [[ $TAG_LENGTH -eq 7 ]]; then
            log ":white_check_mark: Detected 7-character tag ($NEW_TAG). Attempting auto-approval..."
            # :large_green_square: Improved approval logic with fallback
            if gh pr review "$PR_NUMBER" --approve --body "Auto-approved: 7-char tag change by admin (${PR_AUTHOR})"; then
              log ":white_check_mark: Auto-approval submitted successfully."
            else
              log ":warning: GitHub API blocked auto-approval (likely Actions restriction). Posting comment instead."
              github_comment ":white_check_mark: Tag validated and ready. Manual approval required since GitHub Actions cannot auto-approve via this token."
            fi
            exit 0
          else
            log ":warning: Tag found but not 7 characters ($TAG_LENGTH). Skipping auto-approval."
          fi
        else
          log ":information_source: User ${PR_AUTHOR} is in ${TEAM}, but not an admin team. Skipping auto-approval."
        fi
      fi
    done
    # :large_green_square: Handle case when user not in any admin teams
    if [[ "$found_admin_team" == false ]]; then
      log "User ${PR_AUTHOR} not in CODEOWNERS admin team (${full_teams}). Skipping auto-approval."
    fi
  else
    log "No image tag change detected, skipping auto-approval logic."
  fi
  # :warning: Require manual review from enigma-devops otherwise
  log "No auto-approval applied. Tagging enigma-devops for review..."
  github_comment ":eyes: This PR requires manual review from **@enigma-ruqaish/enigma-devops**."
  exit 0
}
main "$@"
