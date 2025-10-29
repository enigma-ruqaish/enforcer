#!/usr/bin/env bash
set -euo pipefail

# Allowed YAML files that can be modified in PRs
ALLOWED_FILES_REGEX="(deployment\.yaml|hpa\.yaml|ingress\.yaml|kustomization\.yaml)$"

# GitHub and PR metadata
GITHUB_JSON="github.json"
DIFF_BRANCHES="origin/$(jq -r '.base_ref' $GITHUB_JSON)..origin/$(jq -r '.head_ref' $GITHUB_JSON)"
REPO="$(jq -r '.event.repository.full_name' $GITHUB_JSON)"
PR_NUMBER="$(jq -r '.event.pull_request.number' $GITHUB_JSON)"
PR_AUTHOR="$(jq -r '.event.pull_request.user.login' $GITHUB_JSON)"
TEAM_CONFIG="codeowners-teams.conf"

# Utility functions
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
    -d '{"event":"APPROVE","body":"Auto-approved by enigma-bot for authorized tag update."}' \
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

  # 🧱 Rule ③ — Unauthorized user (TEAM_FOUND empty)
  if [[ -z "$TEAM_FOUND" ]]; then
    log "Unauthorized user ${PR_AUTHOR} — exiting with failure."
    exit 1
  fi

  # 🔍 Check if there is an image tag change
  if detect_image_tag_change; then
    log "Detected image tag update..."
    NEW_TAG=$(get_new_tag_value)
    TAG_LENGTH=${#NEW_TAG}

    # 🧠 Rule ① — Auto-approve if team lead and tag valid
    if [[ "$TEAM_FOUND" == *"-lead"* && $TAG_LENGTH -eq 7 ]]; then
      log "User ${PR_AUTHOR} is a team lead and tag is valid (${NEW_TAG}). Auto-approving."
      github_comment "✅ **Rule ① Applied:** Tag update detected by team lead **${PR_AUTHOR}** (${TEAM_FOUND}).  
Auto-approved by enigma-bot for authorized tag update."
      auto_approve_pr
      exit 0
    else
      # Tag change but not lead
      log "Tag change detected but user is not lead or tag invalid — manual review required."
      github_comment "⚠️ **Rule ② Applied:** Tag update by **${PR_AUTHOR}** (${TEAM_FOUND}).  
Manual review required from **@enigma-ruqaish/enigma-devops**."
      exit 0
    fi
  fi

  # ✅ Rule ② — Valid team member, no tag change
  log "Valid PR from ${PR_AUTHOR} in team ${TEAM_FOUND}, no tag change."
  github_comment "✅ **Rule ② Applied:** PR by **${PR_AUTHOR}** from *${TEAM_FOUND}* team.  
No image tag change detected — PR ready for manual review by **@enigma-ruqaish/enigma-devops**."
  exit 0
}

main "$@"
