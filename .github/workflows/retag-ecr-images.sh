#!/bin/bash
set -exo pipefail

function retag_images {
  for file_path in $@; do
    env="$(basename $(dirname "$file_path"))"
    if [[ "$env" =~ ^review-app.* ]]; then
     echo "Skipping image retagging for $env environment"
    continue
    fi
    if ! [[ "$env" =~ ^(live|prelive|stag|dev).* ]]; then
    env="live";
    fi
    image_name=$(yq '.images[0].newName' $file_path);
    if [ "$image_name" == "null" ]; then
      continue;
    fi
    image_tag=$(yq '.images[0].newTag' $file_path);
    repository_name="$( cut -d/ -f2 <<< $image_name )";
    registry_id="$( cut -d. -f1 <<< $image_name )";
    region="$( cut -d. -f4 <<< $image_name )";
    is_image_tag_exist="$(aws ecr list-images --repository-name $repository_name --registry-id $registry_id --region $region --query "imageIds[?imageTag=='${env}-${image_tag}'].imageTag" --output text --no-cli-pager)";
    if [ "$is_image_tag_exist" != "" ]; then
      aws ecr batch-delete-image --repository-name $repository_name --registry-id $registry_id --region $region --image-ids imageTag=${env}-${image_tag};
    fi

    manifest=$(aws ecr batch-get-image --repository-name $repository_name --registry-id $registry_id --region $region --image-ids imageTag=${image_tag}  --output json | jq --raw-output --join-output '.images[0].imageManifest')
    if [ "$manifest" == "null" ]; then
      echo ${repository_name}:${env}-${image_tag} >> /tmp/failing-images
      continue;
    fi
    result=$(aws ecr put-image --repository-name $repository_name --registry-id $registry_id --region $region --image-tag "${env}-${image_tag}" --image-manifest "$manifest" )
  done
  if [ -s /tmp/failing-images ]; then
    send_slack_alert
    exit 1;
  fi
}

function retag_images_from_directory {
  base_path=$1
  changed_files=$(find ${base_path} -iname 'kustomization.yaml')
  retag_images $changed_files
}

function retag_images_from_commit {
  commit_refs=$1
  changed_files=$(git diff --name-only $commit_refs | grep -E 'kustomization\.yaml$' || true)
  retag_images $changed_files
}

function send_slack_alert {
curl -X POST -H 'Content-type: application/json' \
  --data "{\"text\":\"Image(s) failed to retag by retagger:\n\`\`\`\n$(cat /tmp/failing-images)\`\`\`\"}" \
  "${SLACK_WEBHOOK}"
}
