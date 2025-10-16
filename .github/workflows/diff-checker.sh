#!/usr/bin/env bash
set -euo pipefail
tmpdir="/tmp/diff/"
diff_file="/tmp/diff.txt"
kustomize_args="--enable-helm"

git fetch origin ${GITHUB_BASE_REF} ${GITHUB_HEAD_REF}
git checkout ${GITHUB_HEAD_REF} --

#rebase from base branch
git config --global user.email "actions@github.com"
git config --global user.name "Github Actions"
git pull origin ${GITHUB_BASE_REF} --no-rebase


changed_files=$(git diff --name-only  origin/${GITHUB_BASE_REF}..HEAD)

find_kustomize(){
  if [[ $1 == "." ]]; then return; fi
  # Return other environments if base directory found
  if [[ $1 == *"/base" ]]; then
     find $(dirname $1) -iname 'kustomization.yaml' | xargs -I {} dirname {} | grep -vE '/base$';
     return
  fi
  # Keep going up the directories till we find a kustomize file
  [ -f $1/kustomization.yaml ] && echo $1 || find_kustomize $(dirname $1)
}

changed_projects(){
  # Find all the kustomize files corresponding to the changed file
  for file in $changed_files; do find_kustomize $file; done | uniq
}

for project in $(changed_projects); do
  mkdir -p ${tmpdir}${project}
  kustomize build ${kustomize_args} ${project} > ${tmpdir}${project}/source.yaml;
done

git checkout ${GITHUB_BASE_REF} --

for project in $(changed_projects); do
  mkdir -p ${tmpdir}${project}
  kustomize build ${kustomize_args} ${project} > ${tmpdir}${project}/target.yaml;
done

for dir in $(find ${tmpdir} -iname '*.yaml' | xargs -I {} dirname {} | uniq); do
  # If a file doesn't exist; create an empty yaml file
  [ -f ${dir}/target.yaml ] || echo '---' > ${dir}/target.yaml
  [ -f ${dir}/source.yaml ] || echo '---' > ${dir}/source.yaml
  dyff between \
        --omit-header \
        --ignore-order-changes \
        --ignore-whitespace-changes \
        --output github \
        ${dir}/target.yaml ${dir}/source.yaml \
          | sed -z 's/^\n//g' >> ${diff_file};
done

#Check if diff file is empty
if [ ! -s ${diff_file} ]; then
  echo -n '*No difference found*' > ${diff_file}
else
  sed -i -e '1 i\<details><summary>Expand</summary>\n\n```diff' -e '$ a\```\n</details>' ${diff_file}
fi

sed -i -e '1 i\#### Kubernetes Manifest Difference\n\n' ${diff_file}

#output diff file
cp ${diff_file} ${HOME}/
