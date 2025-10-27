#!/usr/bin/env bash
set -euo pipefail

ALLOWED_FILES_REGEX="(deployment\.yaml|hpa\.yaml|ingress\.yaml|kustomization\.yaml)$"

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

# ---------------- NEW FUNCTION ----------------
enable_auto_merge() {
  local pr_number=$1
  local pr_id

  # Get the PR GraphQL node_id (required by GraphQL API)
  pr_id=$(curl -s -H "Authorization: Bearer ${BOT_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/pulls/${pr_number}" | jq -r '.node_id')

  if [[ -z "$pr_id" || "$pr_id" == "null" ]]; then
    log "❌ Failed to fetch PR node_id for auto-merge."
    github_comment "Auto-approval succeeded, but could not enable auto-merge (missing node_id)."
    return
  fi

  # Enable auto-merge (squash) via GraphQL mutation
  local response
  response=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: bearer ${BOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"mutation { enablePullRequestAutoMerge(input:{pullRequestId:\\\"${pr_id}\\\", mergeMethod:SQUASH}) { clientMutationId }}\"}" \
    https://api.github.com/graphql)

  if [[ "$response" == "200" ]]; then
    log "✅ Auto-merge successfully enabled for PR #${pr_number}."
    github_comment "✅ Auto-merge enabled (squash). GitHub will merge once all checks pass."
  else
    log "⚠️ Auto-merge enablement failed (HTTP $response)."
    github_comment "Auto-approval succeeded, but auto-merge could not be enabled (HTTP $response). Please merge manually."
  fi
}

# ---------------- UPDATED AUTO-APPROVE ----------------
auto_approve_pr() {
  log "Attempting PR auto-approval via enigma-bot..."

  local response
  response=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${BOT_TOKEN}" \
    -d '{"event":"APPROVE","body":"Auto-approved by enigma-bot for authorized tag update."}' \
    "https://api.github.com/repos/${REPO}/pulls/${PR_NUMBER}/reviews")

  if [[ "$response" == "200" || "$response" == "201" ]]; then
    log "✅ PR auto-approved successfully via enigma-bot."
    log "Attempting to enable GitHub native auto-merge for PR #${PR_NUMBER}..."
    enable_auto_merge "${PR_NUMBER}"
  else
    log "Auto-approval failed (HTTP $response)."
    github_comment "Tag validated and ready. Manual approval required (GitHub Actions token cannot approve)."
  fi
}

main() {
  log "Fetching branches..."
  fetch_branches
  validate_changed_files

  TEAM_FOUND=$(check_team_membership || true)
  if [[ "$TEAM_FOUND" == *"-dev"* ]]; then
    log "User ${PR_AUTHOR} is part of a dev team (${TEAM_FOUND}). Auto-approval disabled."
    github_comment "👀 This PR requires manual review from **@enigma-ruqaish/enigma-devops**."
    exit 0
  fi

  if detect_image_tag_change; then
    log "Detected image tag update..."
    NEW_TAG=$(get_new_tag_value)
    TAG_LENGTH=${#NEW_TAG}

    if [[ $TAG_LENGTH -eq 7 ]]; then
      log "Detected 7-character tag ($NEW_TAG). Auto-approval conditions met."
      auto_approve_pr
      exit 0
    else
      log "Tag ($NEW_TAG) not 7 characters. Skipping auto-approval."
    fi
  else
    log "No image tag change detected."
  fi

  github_comment "This PR requires manual review from **@enigma-ruqaish/enigma-devops**."
}

main "$@"
