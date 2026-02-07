#!/bin/bash -l
set -e

INPUT_SARIF=${INPUT_SARIF:-false}
INPUT_SARIF_FILE=${INPUT_SARIF_FILE:-lei-results.sarif}

cd /opt/app
mix local.hex --force

if [ "${INPUT_SARIF}" = "true" ]; then
  # SARIF mode: generate SARIF output for GitHub Security tab
  echo "Running LowEndInsight in SARIF mode..."
  mix lei.sarif "${GITHUB_WORKSPACE}" --output "${GITHUB_WORKSPACE}/${INPUT_SARIF_FILE}"
  echo "SARIF output written to ${INPUT_SARIF_FILE}"
  echo "sarif_file=${GITHUB_WORKSPACE}/${INPUT_SARIF_FILE}" >> "${GITHUB_OUTPUT}"
else
  # Legacy mode: generate JSON report and push to branch
  [ -z "${INPUT_BRANCH}" ] && {
      echo 'Missing input "branch: specified_branch".';
      exit 1;
  };
  [ -z "${INPUT_GITHUB_TOKEN}" ] && {
      echo 'Missing input "github_token: ${{ secrets.GITHUB_TOKEN }}".';
      exit 1;
  };

  OUTPUT=$(MIX_ENV=gha mix lei.scan "${GITHUB_WORKSPACE}")
  cd "${GITHUB_WORKSPACE}"

  INPUT_BRANCH=${INPUT_BRANCH}
  INPUT_FORCE=${INPUT_FORCE:-false}
  INPUT_TAGS=${INPUT_TAGS:-false}
  INPUT_DIRECTORY=${INPUT_DIRECTORY:-'.'}
  _FORCE_OPTION=''
  REPOSITORY=${INPUT_REPOSITORY:-$GITHUB_REPOSITORY}
  cd "${INPUT_DIRECTORY}"
  echo "Printing Report:"
  echo "${OUTPUT}"

  git config --local user.email "action@github.com"
  git config --local user.name "GitHub Action"
  filename="lei--$(date +'%Y-%m-%d--%H-%M-%S').json"
  touch "${filename}"
  echo "${OUTPUT}" > "${filename}"
  git add "${filename}"
  git commit -m "Add changes" -a

  echo "Push to branch ${INPUT_BRANCH}"

  if ${INPUT_FORCE}; then
      _FORCE_OPTION='--force'
  fi

  if ${INPUT_TAGS}; then
      _TAGS='--tags'
  fi

  remote_repo="https://${GITHUB_ACTOR}:${INPUT_GITHUB_TOKEN}@github.com/${REPOSITORY}.git"

  git push "${remote_repo}" HEAD:${INPUT_BRANCH} --follow-tags $_FORCE_OPTION $_TAGS;
fi
