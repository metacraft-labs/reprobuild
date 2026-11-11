#!/usr/bin/env bash
#
# Publish the built user documentation (docs/users/public/) to Cloudflare
# Pages. Run it after `scripts/build_user_docs.sh build`, with wrangler on PATH
# (the flake's `.#ci` shell) and CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID in
# the environment.
#
#   REPRO_DOCS_PAGES_PROJECT   the Pages project (default: reprobuild-docs)
#   REPRO_DOCS_PAGES_BRANCH    the project's production branch (default:
#                              live-docs, the repository branch that publishes)
#
# The project is created on first use with that production branch, so a
# deployment to the branch is a production deployment, served at
# https://<project>.pages.dev and at any custom domain attached to the project.
#
# Writes `url=<deployment url>` to $GITHUB_OUTPUT when it is set.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="${REPRO_DOCS_PAGES_PROJECT:-reprobuild-docs}"
branch="${REPRO_DOCS_PAGES_BRANCH:-live-docs}"
public="${repo_root}/docs/users/public"

die() {
  echo "deploy_user_docs.sh: $*" >&2
  exit 1
}

[[ -f "${public}/index.html" ]] || die "${public}/index.html is missing; run scripts/build_user_docs.sh build first"
[[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || die "CLOUDFLARE_API_TOKEN is not set"
[[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]] || die "CLOUDFLARE_ACCOUNT_ID is not set"
command -v wrangler >/dev/null 2>&1 || die "wrangler is not on PATH; run this inside the flake's .#ci shell"

log="$(mktemp)"
trap 'rm -f "${log}"' EXIT

# Create the project if it does not exist. wrangler has no "create if missing",
# so an existing project is recognised by its refusal message; any other
# failure stops the deploy.
if ! wrangler pages project create "${project}" --production-branch="${branch}" >"${log}" 2>&1; then
  if grep -qi 'already exists' "${log}"; then
    echo "deploy_user_docs.sh: Pages project ${project} exists"
  else
    cat "${log}" >&2
    die "could not create Pages project ${project}"
  fi
else
  cat "${log}"
fi

commit="$(git -C "${repo_root}" rev-parse HEAD)"
wrangler pages deploy "${public}" \
  --project-name="${project}" \
  --branch="${branch}" \
  --commit-hash="${commit}" \
  --commit-dirty=true | tee "${log}"

url="$(grep -oE 'https://[a-z0-9.-]+\.pages\.dev' "${log}" | tail -1 || true)"
[[ -n "${url}" ]] || die "wrangler reported no deployment URL"
echo "Deployed ${commit} to ${url} (production: https://${project}.pages.dev)"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "url=https://${project}.pages.dev" >> "${GITHUB_OUTPUT}"
fi
