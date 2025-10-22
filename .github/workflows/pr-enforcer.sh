#!/usr/bin/env bash
set -euo pipefail

#############################################
#  CONFIGURATION
#############################################

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

  local ORG="enigma-ruqaish"  # 👈 adjust this if needed
  local TEAMS=(${TEAM_MAP[$project_name]})
  local user_allowed=false

  for TEAM in "${TEAMS[@]}"; do
    if user_in_team "$ORG" "$TEAM"; then
      log "✅ User ${PR_AUTHOR} is part of ${TEAM} team."
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

  github_comment "✅ Auto-approved: Image tag update by authorized team lead (${PR_AUTHOR})."
  log "✅ Auto-approved image tag change by ${PR_AUTHOR}"
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

  if detect_image_tag_change; then
  log "Detected image tag update..."

  local project_name
  project_name=$(get_changed_files | head -1 | awk -F/ '{print $2}')
  local full_team
  full_team=$(grep -E "^projects/${project_name}/.*/live/kustomization.yaml" CODEOWNERS | awk '{print $3}' || true)

  if [[ -n "$full_team" ]]; then
    local ORG TEAM
    ORG=$(echo "$full_team" | awk -F'/' '{print $1}' | sed 's/@//')
    TEAM=$(echo "$full_team" | awk -F'/' '{print $2}')

    if user_in_team "$ORG" "$TEAM"; then
      # ✅ Check if this is an admin and tag is 7 chars long
      if [[ "$TEAM" == *"-admin" ]]; then
        NEW_TAG=$(git diff origin/master...HEAD | grep -Eo '[a-z0-9]{7}' | tail -1)
        TAG_LENGTH=${#NEW_TAG}

        if [[ $TAG_LENGTH -eq 7 ]]; then
          log "✅ Detected 7-character tag ($NEW_TAG). Auto-approving..."
          gh pr review "$PR_NUMBER" --approve --body "Auto-approved: 7-char tag change by admin"
          curl -s -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${ORG_TOKEN}" \
            -d "{\"body\":\"Auto-approved: 7-char tag change by admin (${PR_AUTHOR})\",\"event\":\"APPROVE\"}" \
            "https://api.github.com/repos/${REPO}/pulls/${PR_NUMBER}/reviews" > /dev/null

          github_comment "✅ Auto-approved: 7-char tag change by admin (${PR_AUTHOR})."
          log "✅ Auto-approved PR #${PR_NUMBER} for 7-char tag change by ${PR_AUTHOR}"
          exit 0
        else
          log "Tag found but not 7 characters ($TAG_LENGTH). Skipping auto-approval."
        fi
      else
        log "User is not an admin. Skipping auto-approval."
      fi
    fi
  fi
fi

  log "No auto-approval applied. PR requires manual review."
}

main "$@"
