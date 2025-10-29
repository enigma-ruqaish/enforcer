#!/usr/bin/env bash
set -euo pipefail

# ===============================================================
# PR ENFORCER SCRIPT - FINAL VERSION
# ===============================================================

# Inputs from GitHub Actions
GITHUB_API="https://api.github.com"
REPO="$GITHUB_REPOSITORY"
PR_NUMBER="${PR_NUMBER:-${GITHUB_REF##*/}}"
GITHUB_TOKEN="${GITHUB_TOKEN:-${ENFORCER_TOKEN:-}}"
ACTOR="${GITHUB_ACTOR}"

ORG="enigma-ruqaish"
TEAM_ADMIN="vortex-admin"
TEAM_DEV="vortex-dev"
TEAM_DEVOPS="enigma-devops"
AUTO_APPROVER_TEAM="auto-approve"

# ===============================================================
# Helper functions
# ===============================================================

log() { echo -e "[$(date '+%H:%M:%S')] $*"; }

fail() {
  echo "❌ $*"
  exit 1
}

get_changed_files() {
  gh api repos/$REPO/pulls/$PR_NUMBER/files --jq '.[].filename'
}

get_user_team_role() {
  local user="$1" team="$2"
  if gh api orgs/$ORG/teams/$team/memberships/$user &>/dev/null; then
    echo "10"
  else
    echo "0"
  fi
}

auto_approve_pr() {
  local pr_number="$1"
  log "🔄 Attempting auto-approval for PR #$pr_number"
  local response
  response=$(curl -s -X POST \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GITHUB_API}/repos/${REPO}/pulls/${pr_number}/reviews" \
    -d '{"event":"APPROVE","body":"✅ Auto-approved by enigma-ruqaish/auto-approve"}')

  if echo "$response" | grep -q '"state": "APPROVED"'; then
    log "✅ PR #$pr_number successfully auto-approved."
  else
    log "⚠️ Auto-approve failed: $response"
  fi
}

# ===============================================================
# Main Logic
# ===============================================================

log "🔍 Running PR Enforcer for PR #$PR_NUMBER"
log "🧑 Actor: $ACTOR"

# Step 1: Determine team membership
ROLE_ADMIN=$(get_user_team_role "$ACTOR" "$TEAM_ADMIN")
ROLE_DEV=$(get_user_team_role "$ACTOR" "$TEAM_DEV")

log "👥 Admin team: $ROLE_ADMIN | Dev team: $ROLE_DEV"

# Step 2: Get changed files
CHANGED_FILES=$(get_changed_files)
log "🗂️ Changed files: $CHANGED_FILES"

# Step 3: Detect commit SHA pattern
COMMIT_ID=$(git rev-parse --short HEAD || echo "")
COMMIT_LEN=${#COMMIT_ID}
log "🔢 Commit ID length: $COMMIT_LEN"

# ===============================================================
# USE CASE 1: Tag/Kustomization change by Admin
# ===============================================================
if echo "$CHANGED_FILES" | grep -Eq 'kustomization|tag|version'; then
  if [[ "$ROLE_ADMIN" == "10" && "$COMMIT_LEN" == "7" ]]; then
    log "✅ Use Case 1 matched: Tag/Kustomization update by Admin"
    auto_approve_pr "$PR_NUMBER"
    log "🟢 Merge allowed for enigma-devops and vortex-admin"
    exit 0
  fi
fi

# ===============================================================
# USE CASE 2: Allowed files by Dev/Admin
# ===============================================================
ALLOWED_PATTERNS="^(projects/vortex/|scripts/|config/)"
if echo "$CHANGED_FILES" | grep -Eq "$ALLOWED_PATTERNS"; then
  if [[ "$ROLE_ADMIN" == "10" || "$ROLE_DEV" == "10" ]]; then
    log "✅ Use Case 2 matched: Allowed file change by Dev/Admin"
    log "🚫 No auto-approval — only enigma-devops can approve & merge."
    # We let CI pass but no bot approval occurs.
    exit 0
  fi
fi

# ===============================================================
# USE CASE 3: Unauthorized user
# ===============================================================
if [[ "$ROLE_ADMIN" != "10" && "$ROLE_DEV" != "10" ]]; then
  fail "Unauthorized change — user '$ACTOR' is not in an allowed team."
fi

log "✅ Validation complete."
exit 0
