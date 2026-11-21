#!/usr/bin/env bash
#
# Close the standing suite-artifact regeneration pull request once it is moot.
#
# WHY THIS EXISTS
#
# `.github/workflows/suite-case-counts.yml`'s `regenerate-on-dev` job opens
# ONE pull request into `dev`, from the standing branch
# `automation/regenerate-suite-artifacts`, when the suite gate refuses `dev`
# (see scripts/regenerate_suite_artifacts.py). Nothing guarantees that pull
# request is the fix that lands: someone may regenerate in their own change.
# Left open, it is a stale proposal to rewrite two tracked artifacts at an old
# commit -- one a reviewer might still merge, and one the next stale push
# would silently reuse. So it is closed, with a comment naming the `dev`
# commit that made it moot, and its branch is deleted, whenever:
#
#   - the gate PASSES on a push to `dev` (job `retire-regeneration-on-dev`):
#     `dev` was fixed another way;
#   - the gate fails on `dev` but the regeneration finds nothing to change
#     (exit 3): the two artifacts are current, so whatever is red needs a
#     judgement the pull request does not carry.
#
# A no-op when no such pull request is open, which is nearly always.
#
# USAGE
#
#   STANDING_BRANCH=automation/regenerate-suite-artifacts \
#     scripts/retire_regeneration_pr.sh <dev-sha> <why it is moot>
#
# Needs `gh` authenticated (GH_TOKEN) with pull-requests: write and, for the
# branch deletion, contents: write.
set -euo pipefail

green_sha="${1:?usage: retire_regeneration_pr.sh <dev-sha> <why it is moot>}"
why="${2:?usage: retire_regeneration_pr.sh <dev-sha> <why it is moot>}"
branch="${STANDING_BRANCH:?STANDING_BRANCH must name the standing regeneration branch}"

# `--delete-branch` below deletes the pull request's HEAD branch. Refuse
# anything outside the automation namespace, so a mis-set variable can never
# turn this into a deletion of `dev` or of someone's work.
case "${branch}" in
  automation/*) ;;
  *)
    echo "retire_regeneration_pr: refusing STANDING_BRANCH='${branch}':" \
      "only an automation/* branch may be retired." >&2
    exit 1
    ;;
esac

# `--head` matches by branch NAME, so a fork's identically named branch would
# match as well; closing it would act on someone else's pull request. Keep
# only same-repository pull requests whose head is exactly the standing branch.
# Filtered with `jq --arg` rather than `gh --jq`, which takes no variables: the
# branch is passed as data, never spliced into the filter text.
numbers="$(gh pr list --head "${branch}" --base dev --state open \
  --json number,headRefName,isCrossRepository |
  jq -r --arg branch "${branch}" \
    '.[] | select(.isCrossRepository == false and .headRefName == $branch) | .number')"

if [ -z "${numbers}" ]; then
  echo "retire_regeneration_pr: no open pull request from ${branch} into dev; nothing to do."
  exit 0
fi

comment="Closing as moot: \`dev\` at ${green_sha} ${why}. Nothing here needs merging. \`${branch}\` is deleted, and is recreated with a fresh pull request if \`dev\` goes stale again."
for number in ${numbers}; do
  gh pr close "${number}" --delete-branch --comment "${comment}"
  echo "retire_regeneration_pr: closed #${number} and deleted ${branch}."
done
