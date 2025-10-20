#!/usr/bin/env bash
# set -euo pipefail

# export GITHUB_TOKEN=${GITHUB_TOKEN:-fake}
# export ORG_TOKEN=${ORG_TOKEN:-fake}

# github(){
#     jq -r $1 github.json
# }

# comment_pr() {
#     local message=$1
#     curl -s -X POST \
#         -H "Accept: application/vnd.github+json" \
#         -H "Authorization: Bearer ${GITHUB_TOKEN}" \
#         -d "{\"body\": \"${message}\"}" \
#         "https://api.github.com/repos/$(github .repository)/issues/$(github .event.pull_request.number)/comments" > /dev/null
# }

# approve_pr() {
#     curl -s -X POST \
#         -H "Accept: application/vnd.github+json" \
#         -H "Authorization: Bearer ${ORG_TOKEN}" \
#         -d '{"event":"APPROVE"}' \
#         "https://api.github.com/repos/$(github .repository)/pulls/$(github .event.pull_request.number)/reviews" > /dev/null
# }

# fetch_branches() {
#     git fetch origin "$(github .base_ref)" "$(github .head_ref)"
# }

# ALLOWED_FILES_REGEX="^(projects/.*/(deployment|hpa|ingress|kustomization)\.ya?ml)$"
# DIFF_BRANCHES="origin/$(github .base_ref)..origin/$(github .head_ref)"
# ENIGMA_TEAM="SectorLabs/enigma-devops"

# verify_allowed_files() {
#     echo "Verifying allowed file types..."
#     local disallowed
#     disallowed=$(git diff --name-only ${DIFF_BRANCHES} | grep -Ev "${ALLOWED_FILES_REGEX}" || true)
#     if [[ -n "${disallowed}" ]]; then
#         echo "Disallowed files modified:"
#         echo "${disallowed}"
#         comment_pr "PR contains disallowed file changes:\n\`\`\`\n${disallowed}\n\`\`\`\nAllowed files: deployment.yaml, hpa.yaml, ingress.yaml, kustomization.yaml."
#         exit 1
#     fi
# }

# get_project_from_file() {
#     local file=$1
#     echo "${file}" | awk -F/ '{ print $2 }'
# }

# get_team_from_codeowners() {
#     local project=$1
#     grep -E "^projects/${project}/" CODEOWNERS | grep '@SectorLabs' | awk '{ for(i=2;i<=NF;i++) print $i }' | sort -u
# }

# user_in_team() {
#     local org_team=$1
#     local username
#     username=$(github .event.pull_request.user.login)
#     local org=$(echo "${org_team}" | awk -F/ '{ print $1 }' | sed 's:@::g')
#     local team=$(echo "${org_team}" | awk -F/ '{ print $2 }')
#     curl -fs \
#         -H "Accept: application/vnd.github+json" \
#         -H "Authorization: Bearer ${ORG_TOKEN}" \
#         "https://api.github.com/orgs/${org}/teams/${team}/members" | \
#         jq -e ".|any(.login == \"${username}\")"
# }

# is_only_tag_change() {
#     local files_changed
#     files_changed=$(git diff --name-only ${DIFF_BRANCHES} | wc -l)
#     if [[ "${files_changed}" -ne 1 ]]; then
#         return 1
#     fi

#     local changed_file
#     changed_file=$(git diff --name-only ${DIFF_BRANCHES})
#     if [[ ! "${changed_file}" =~ kustomization\.ya?ml$ ]]; then
#         return 1
#     fi

#     local diff_lines
#     diff_lines=$(git diff ${DIFF_BRANCHES} -- ${changed_file} | grep -vE '^(---|\+\+\+)' | grep 'newTag' || true)
#     if [[ -z "${diff_lines}" ]]; then
#         return 1
#     fi

#     local new_tag
#     new_tag=$(echo "${diff_lines}" | grep -oE 'newTag: "?[A-Za-z0-9_-]+"?' | awk -F'"' '{print $2}' | tail -n1)

#     if [[ ${#new_tag} -eq 7 ]]; then
#         return 0 
#     else
#         echo "Invalid tag length: '${new_tag}' (${#new_tag} chars). Must be exactly 7."
#         return 1
#     fi
# }

# main() {
#     fetch_branches
#     verify_allowed_files

#     local changed_files project teams valid_team=false
#     changed_files=$(git diff --name-only ${DIFF_BRANCHES})
#     project=$(get_project_from_file "$(echo "${changed_files}" | head -n1)")
#     teams=$(get_team_from_codeowners "${project}")

#     echo "Project detected: ${project}"
#     echo "Teams with access: ${teams}"

#     for team in ${teams}; do
#         if user_in_team "${team}"; then
#             valid_team=true
#             echo "User is member of ${team}"
#             break
#         fi
#     done

#     if [[ "${valid_team}" != "true" ]]; then
#         echo "User not authorized for this project."
#         comment_pr "Access denied: You are not authorized to modify manifests for project **${project}**."
#         exit 1
#     fi

#     if is_only_tag_change; then
#         echo "Detected image tag-only change in kustomization.yaml"
#         lead_team=$(grep -E "projects/${project}/.*/live/" CODEOWNERS | awk '{ print $3 }' | sort -u)
#         if [[ -n "${lead_team}" ]] && user_in_team "${lead_team}"; then
#             echo "Auto-approving PR (team lead + tag change)."
#             approve_pr
#             exit 0
#         else
#             echo "Tag change by non-lead; requires Enigma DevOps approval."
#             exit 0
#         fi
#     else
#         echo "Valid team change, not tag-only. Passing workflow; requires Enigma DevOps review."
#         exit 0
#     fi
# }

# main


echo "Hi , I am Hamza Shah"
