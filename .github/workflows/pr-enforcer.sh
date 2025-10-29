#!/usr/bin/env bash
set -euo pipefail

# Allowed files pattern
ALLOWED_FILES_REGEX="(deployment\.yaml|hpa\.yaml|ingress\.yaml|kustomization\.yaml)$"

# GitHub event data
GITHUB_JSON="github.json"
DIFF_BRANCHES="origin/$(jq -r '.base_ref' $GITHUB_JSON)..origin/$(jq -r '.head_ref' $GITHUB_JSON)"
REPO="$(jq -r '.event.repository.full_name' $GITHUB_JSON)"
PR_NUMBER="$(jq -r '.event.pull_request.number' $GITHUB_JSON)"
PR_AUTHOR="$(jq -r '.event.pull_request.user.login' $GITHUB_JSON)"
TEAM_CONFIG="codeowners-teams.conf"

log() { echo -e "\033[1;34m[INFO]\033[0m $*"; }

github_comment() {
  local message="$1"
  curl -s -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -d "{\"body\":\"${message}\"}" \
    "https://api.github.com/repos/${REPO}/issues/${PR_NUMBER}/comments" > /dev/null
}

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
    exit 1
  fi
}

get_teams_for_project() {
  local project_name="$1"
  local teams=()

  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    if [[ "$line" == "projects/${project_name}/"* ]]; then
      team_slug=$(echo "$line" | grep -oE "@[^ ]+" | sed 's/@enigma-ruqaish\///')
      teams+=("$team_slug")
    fi
  done < "$TEAM_CONFIG"

  if [[ ${#teams[@]} -eq 0 ]]; then
    github_comment ":warning: No team mapping found for project '${project_name}' in ${TEAM_CONFIG}."
    exit 1
  fi

  echo "${teams[@]}"
}

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

  local ORG="enigma-ruqaish"
  local TEAMS
  TEAMS=($(get_teams_for_project "$project_name"))

  for TEAM in "${TEAMS[@]}"; do
    if user_in_team "$ORG" "$TEAM"; then
      log "User ${PR_AUTHOR} is part of ${TEAM}."
      echo "$TEAM"
      return 0
    fi
  done

  github_comment ":x: User **${PR_AUTHOR}** is not authorized for project '${project_name}'."
  exit 1
}

detect_image_tag_change() {
  git diff -U0 ${DIFF_BRANCHES} | grep -E '^\+' | grep -q 'newTag' || return 1
}

get_new_tag_value() {
  local kfile
  kfile=$(get_changed_files | grep 'kustomization.yaml' || true)
  [[ -n "$kfile" ]] && yq '.images[0].newTag' "$kfile"
}

auto_approve_pr() {
  log "Attempting PR auto-approval via enigma-bot..."

  local response
  response=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${BOT_TOKEN}" \
    -d '{"event":"APPROVE","body":"Auto-approved by enigma-bot for authorized 7-char tag update."}' \
    "https://api.github.com/repos/${REPO}/pulls/${PR_NUMBER}/reviews")

  if [[ "$response" == "200" || "$response" == "201" ]]; then
    log "PR auto-approved successfully via enigma-bot."
  else
    log "Auto-approval failed (HTTP $response). Posting fallback comment."
    github_comment "Tag validated and ready. Manual approval required (GitHub Actions token cannot approve)."
  fi
}

main() {
  log "Fetching branches..."
  fetch_branches
  validate_changed_files

  TEAM_FOUND=$(check_team_membership || true)

  # CASE 3: Unauthorized
  if [[ -z "$TEAM_FOUND" ]]; then
    github_comment ":x: CI failed. User **${PR_AUTHOR}** not in any authorized team (dev/admin)."
    exit 1
  fi

  # CASE 1: Admin + tag change + 7-char
  if [[ "$TEAM_FOUND" == *"-admin" ]]; then
    if detect_image_tag_change; then
      NEW_TAG=$(get_new_tag_value)
      if [[ ${#NEW_TAG} -eq 7 ]]; then
        log "Admin user with 7-char tag detected. Auto-approving..."
        auto_approve_pr
        github_comment ":white_check_mark: Auto-approved by **@enigma-ruqaish/auto-approve**.  
Only **vortex-admin** or **enigma-devops** can merge this PR."
        exit 0
      fi
    fi
    github_comment ":white_check_mark: Changes valid. No auto-approval. Only **enigma-devops** can merge."
    exit 0
  fi

  # CASE 2: Dev user
  if [[ "$TEAM_FOUND" == *"-dev" ]]; then
    github_comment ":white_check_mark: CI passed. Manual review required.  
Only **enigma-devops** can merge this PR."
    exit 0
  fi

  github_comment ":x: Unexpected condition hit. Please check the CI logic."
  exit 1
}

main "$@"
