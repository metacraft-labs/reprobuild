#!/usr/bin/env bash
#
# Validate .github/ the way GitHub does, before pushing.
#
# Two gates live here:
#
#   1. actionlint over .github/workflows -- a workflow GitHub cannot LOAD.
#   2. sibling-repo pins -- explicit commit pins must agree with committed
#      locks; named refs must exist in the repository they name.
#
# WHY GATE 1 EXISTS
#
# Every release run between c46b65f5 and this check failed in the same second
# it started, with ZERO jobs created -- not even the first one. The cause was a
# JavaScript comment inside an `actions/github-script` `script:` block that
# spelled out the literal two-brace expression sequence with nothing between
# the braces. `script` is an Actions *input*, so GitHub scans its entire body,
# comments included, for expression syntax; an empty expression is a workflow
# LOAD error:
#
#   Invalid workflow file: .github/workflows/release.yml
#   (Line: 585, Col: 19): An expression was expected
#
# A rejected workflow never reaches the job graph, so there is no job, no log,
# and no annotation on the run -- only a failure run that exists to carry the
# message. GitHub also cannot read `on:` in a file it cannot load, so it stops
# filtering events: the release workflow, which subscribes only to `v*` tags,
# produced a failure run on every branch push.
#
# None of that was visible locally. The file is valid YAML, and every YAML
# parser we had said so. Actions expression syntax lives *inside* YAML scalars,
# so a YAML parse can never see it. That is the whole lesson, and it is why
# this check uses actionlint -- which models Actions expression grammar, the
# `needs` graph, matrix shapes, and context availability -- rather than a
# parser.
#
# Runs as part of `just lint`, which CI runs on every push (ci.yml).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

# Resolve actionlint ourselves rather than demanding the caller already be in
# the devshell. The managed pre-commit hook runs `just lint` OUTSIDE `nix
# develop`, so a PATH-only lookup made every commit in the repo fail once this
# check was wired in -- a check that blocks honest work is no better than one
# that proves nothing.
#
# Still fatal when no interpreter can be obtained: quietly doing nothing when
# the tool is missing is how a broken workflow reaches the remote.
ACTIONLINT=()
if command -v actionlint >/dev/null 2>&1; then
  ACTIONLINT=(actionlint)
elif command -v nix >/dev/null 2>&1 \
    && nix develop --command actionlint -version >/dev/null 2>&1; then
  ACTIONLINT=(nix develop --command actionlint)
elif command -v nix >/dev/null 2>&1 \
    && nix shell nixpkgs#actionlint --command actionlint -version >/dev/null 2>&1; then
  ACTIONLINT=(nix shell nixpkgs#actionlint --command actionlint)
else
  echo "FAIL: actionlint not found, and it could not be obtained via nix." >&2
  echo "      Install it, run inside the Nix devshell (nix develop)," >&2
  echo "      or: nix shell nixpkgs#actionlint" >&2
  exit 1
fi

# Info-level notes from shellcheck are stylistic (SC2016 single-quote expansion,
# SC2012 ls-vs-find, ...) and are not what this check is defending. Warnings and
# errors from shellcheck, and EVERY actionlint finding -- expression syntax,
# unknown `needs` edges, matrix shape, bad contexts, unknown runner labels --
# remain fatal.
ignore_stylistic='shellcheck reported issue in this script: SC[0-9]+:info:'

echo "== actionlint: self-test =="
# Prove the checker still has teeth before trusting a clean result from it.
# A stubbed binary, a too-greedy ignore pattern, or a silently-skipped shellcheck
# would otherwise turn this whole check into a green light that means nothing --
# which is exactly the failure mode being defended against. This fixture is a
# minimal copy of the defect that broke the release pipeline; actionlint MUST
# reject it.
canary_status=0
"${ACTIONLINT[@]}" -no-color -oneline -ignore "${ignore_stylistic}" \
  -stdin-filename '.github/workflows/__canary__.yml' - >/dev/null 2>&1 <<'CANARY' || canary_status=$?
name: canary
on: workflow_dispatch
jobs:
  canary:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/github-script@v7
        with:
          script: |
            // an empty ${{ }} expression -- a workflow LOAD error
            core.info('unreachable');
CANARY

if [ "${canary_status}" -eq 0 ]; then
  echo "FAIL: actionlint accepted a workflow GitHub rejects (empty expression)." >&2
  echo "      This check is not actually validating anything -- fix it before trusting it." >&2
  exit 1
fi
echo "ok: actionlint rejects a known-bad workflow"

echo "== actionlint: .github/workflows =="
"${ACTIONLINT[@]}" -no-color -oneline -ignore "${ignore_stylistic}" .github/workflows/*.yml
echo "ok: all workflow files load"

# =============================================================================
# GATE 2 -- explicit sibling pins agree with locks and named refs EXIST.
#
# WHY THIS EXISTS
#
# `.github/sibling-repos` is the bill of materials for the dev-shell CI jobs:
# the shared `clone-siblings` action clones each named repo adjacent to this
# checkout so Nim's sibling detection can resolve it. An entry is either
# `name` -- resolve the revision from the workspace lock -- or `name=ref`, an
# explicit pin that bypasses the lock.
#
# metacraft-labs renamed its mainline `main` -> `dev`, and this file went on
# pinning `=main` for three days (da6bff51 .. 0d4afc33). That pin failed in TWO
# different regimes, which is why this gate has two checks and not one:
#
#   2026-08-26 .. 08-28   `main` still EXISTED on reprobuild-test-adapters,
#                         frozen at d1ff8317 (2026-07-13) while `dev` moved on.
#                         The clone SUCCEEDED, silently, onto a six-week-old
#                         tree. Seven CI runs failed this way and none of them
#                         said anything about a branch.
#
#   2026-08-28 10:54Z ..  `main` was deleted. The same pin now fails loudly at
#                         clone time:
#                           ##[error]checkout of revision main failed for ...
#
# The quiet regime is the expensive one, and mere existence cannot see it -- so
# a pin naming `main` is additionally checked against the repo's default branch.
#
# This is the third instance of the same rename class in this repo family, and
# the second time a repo-wide fix was outrun by a branch already in flight. A
# sed is a snapshot of a moment; this gate is the rule, so a branch that pins a
# dead or abandoned ref fails lint ON THAT BRANCH instead of after it lands.
#
# The ref-existence check alone would not have caught the
# `undeclared identifier: 'testExecutionDeclaration'` compile error of the same
# week, and it must not be trusted to. `config.nims` resolves
# `repro_test_adapters` from `REPRO_TEST_ADAPTERS_SRC` -- exported by the dev
# shell from the `reprobuild-test-adapters-src` FLAKE INPUT -- in preference to
# the sibling checkout, so for that module the sibling set is never consulted at
# all. That failure was a stale `flake.lock` pin and was fixed there. Two stale
# pins of the same package, in two different mechanisms, at the same time.
# The offline lock-consistency check below now catches explicit SHA drift
# between these mechanisms; ref resolution still does not validate APIs.
#
# WHY IT RESOLVES REFS INSTEAD OF DEMANDING `dev`
#
# A static "must say dev" rule would be wrong in both directions. Some siblings
# legitimately do not use `dev`: a 40-hex SHA is a deliberate, stronger pin, and
# `codetracer-trace-format` defaults to `stable` while this file pins it to
# `dev` on purpose. And a static rule cannot see a typo: `=devel` would sail
# past it and fail exactly the way `=main` did. Asking the remote is the check
# that matches the defect.
#
# The `main` rule is narrower than "must equal the default branch" for the same
# reason: pinning a non-default branch is legitimate and done here deliberately.
# Only `main` on a repo that has MOVED OFF `main` is refused. A repo whose
# default still is `main` passes.
#
# ACCEPTED
#
#   name                -- lock-resolved; no explicit ref to verify.
#   name=<40-hex sha>   -- must agree with applicable repro/flake lock pins.
#   name=<ref>          -- must exist as a branch or tag in that repo, now;
#                          and if <ref> is `main`, that repo's default branch
#                          must still be `main`.
# =============================================================================
echo "== .github/sibling-repos pins =="

# Run offline and before remote lookups: an existing SHA can still be unusable
# when the consumer lock requires another revision. Both = and != forms must
# agree; acknowledging an override cannot waive the build's source check.
python3 scripts/test_sibling_lock_pins.py
python3 scripts/check_sibling_lock_pins.py

sibling_repos_file=".github/sibling-repos"
if [ ! -f "${sibling_repos_file}" ]; then
  echo "FAIL: ${sibling_repos_file} does not exist. Either the sibling-clone" >&2
  echo "      contract moved -- in which case this gate needs updating -- or" >&2
  echo "      the file was lost, which silently drops every sibling CI clones." >&2
  exit 1
fi

# Strips comments and blank lines, emitting one `name=ref` or bare `name` per
# line. Takes the file so the self-test below can run it over a fixture.
sibling_repo_entries() {
  sed -E 's/#.*$//; s/[[:space:]]+$//; s/^[[:space:]]+//' "$1" | grep -v '^$' || true
}

# Emits `<name> <ref>` for each entry carrying an explicit non-SHA ref -- the
# ones that have to be resolved against the remote.
#
# `name!=ref` is the same explicit pin, with the `!` acknowledging that it
# overrides a revision the workspace lock pins. The ref still has to exist, so
# the `!` is stripped and the entry checked like any other -- a gate that
# skipped the acknowledged form would exempt exactly the entries someone
# deliberately hand-pinned, which are the ones most likely to name a dead ref.
sibling_repo_branch_pins() {
  sibling_repo_entries "$1" |
    awk '
      {
        eq = index($0, "=")
        if (eq == 0) next                   # lock-resolved -- nothing to check
        name = substr($0, 1, eq - 1)
        ref = substr($0, eq + 1)
        sub(/!$/, "", name)                 # `name!=ref` -- acknowledged override
        if (name == "" || ref == "") next
        if (ref ~ /^[0-9a-f]{40}$/) next    # commit pin -- stronger than a branch
        print name, ref
      }
    '
}

# -----------------------------------------------------------------------------
# HOW REFS ARE LOOKED UP, AND WHY IT TAKES THREE ATTEMPTS
#
# This gate failed on EVERY CI run from the day it landed -- identically on
# `dev`, on `agents`, and on every `agents-to-dev-*` promotion branch, on four
# different runner classes -- while passing on every laptop. It always reported
# the same thing, "cannot reach github.com", and that reading was wrong twice
# over: the runner's network is fine, and the lookup did not time out. It failed
# in about 400ms, deterministically, with an HTTP 400.
#
# THE CAUSE. Two different things each install a github.com `extraHeader` in a
# CI job here, and neither knows about the other:
#
#   * `actions/checkout@v4` persists `http.https://github.com/.extraheader`
#     into THIS repo's .git/config, carrying the workflow GITHUB_TOKEN;
#   * `setup-dev-env` exports
#     `http.https://github.com/metacraft-labs/.extraHeader` through
#     GIT_CONFIG_*, carrying a GitHub App installation token.
#
# Both URL patterns match any `https://github.com/metacraft-labs/...` request.
# `http.extraHeader` is a MULTI-VALUED list, not a single setting, so git sends
# BOTH and github refuses the request:
#
#     remote: Duplicate header: "Authorization"
#     fatal: unable to access '...': The requested URL returned error: 400
#
# Every lookup in this gate ran from the repo root with both sources live, so
# every lookup got that 400 -- including the one probe that decides whether
# github is reachable at all. The gate concluded "offline", saw `$CI`, and
# refused. Promotions then either blocked on it or were waved through on
# evidence substituted from a laptop, where no second header exists.
#
# A LATENT RISK, noticed while fixing the above, which the anonymous arm covers.
# The installation token is SCOPED: ci.yml lists the repositories it covers, and
# `reprobuild` and `nixos-modules` -- the two repos THIS SCRIPT probes to decide
# reachability and to check its own resolvers -- are not on that list, nor is the
# `metacraft-github-actions=dev` entry.
#
# An earlier version of this comment went further and claimed those three
# therefore could not be read at all, on the theory that github answers 404 for
# a repo outside the installation's list even when the repo is public. That is
# NOT what was measured. The first green run of this gate
# (39000151336, job 117302107572, sha 1bc5a6c0a) reports
# `answered by: ambient=0 single-header=17 anonymous=0` -- all seventeen
# entries, those three included, resolved with one header, and the anonymous arm
# was never reached. The duplicate header was the entire cause of the failure.
#
# The scoping omission is still worth keeping in mind: the three entries are
# genuinely absent from ci.yml's `repositories:` list, so a future private
# sibling added there would need the anonymous arm or a wider token. It is a
# risk this script is built to survive, not a defect it was built to work
# around.
#
# Hence three arms, because no single credential state can resolve every entry:
#
#   ambient        -- whatever the environment already supplies, untouched.
#                     This is the arm that works on a laptop, where there is
#                     exactly one credential and nothing to collide with.
#   single-header  -- every config source neutralised, then exactly ONE
#                     discovered Authorization header re-added. This is the arm
#                     that works in CI, and the only one that can read the
#                     PRIVATE siblings (`codetracer-native-recorder`,
#                     `repo-workspaces`), which no anonymous request can see.
#   anonymous      -- no header, no helper, no repo-local config. Required in CI
#                     for every PUBLIC repo outside the token's closure,
#                     including both of this gate's own probe anchors.
#
# Each round is retried with backoff, so a network that is merely slow or flaky
# resolves rather than failing. A lookup that still cannot be answered is
# reported as UNRESOLVABLE, never as "this pin names a dead ref": the old
# resolver turned any non-zero exit into "the ref does not exist", so a
# credential problem would have arrived as a false accusation against a pin
# that was fine.
#
# And the reason is PRINTED. The old code sent every lookup's stderr to
# /dev/null, which is the single thing that made this cost five days: the
# message that identified the cause -- `Duplicate header: "Authorization"` --
# was produced on every run and thrown away, leaving only a sentence about the
# network that was not true.
#
# What is deliberately NOT done here: skipping in CI. A lookup that cannot be
# answered still fails this gate when `$CI` is set, for exactly the reason the
# original comment gave. The fix is to make the lookup succeed when it can, not
# to accept not knowing.
# -----------------------------------------------------------------------------

# Scratch space: one directory for the parser fixture and one neutral cwd for
# the anonymous attempt. `actions/checkout` writes its own
# `http.https://github.com/.extraheader` into THIS repo's .git/config, so an
# attempt made from the repo root is not anonymous no matter what the
# environment says. Running it from elsewhere is what makes it anonymous.
sibling_scratch="$(mktemp -d)"
trap 'rm -rf "${sibling_scratch}"' EXIT
sibling_parse_fixture="${sibling_scratch}/parse"
sibling_neutral_dir="${sibling_scratch}/neutral"
mkdir -p "${sibling_parse_fixture}" "${sibling_neutral_dir}"

# Bound every lookup. `timeout` where the host has it -- NixOS runners and the
# devshell do, a bare macOS laptop may not -- and never fatal when it is
# absent, because the http.lowSpeed* options below are git's OWN stall
# detector and need no helper. `env` stands in as a no-op prefix so the array
# is never empty.
if command -v timeout >/dev/null 2>&1; then
  sibling_timeout=(timeout "${SIBLING_LOOKUP_TIMEOUT:-25}")
elif command -v gtimeout >/dev/null 2>&1; then
  sibling_timeout=(gtimeout "${SIBLING_LOOKUP_TIMEOUT:-25}")
else
  sibling_timeout=(env)
fi
sibling_lookup_rounds="${SIBLING_LOOKUP_ROUNDS:-3}"

# Abort a transfer that is moving less than 1000 B/s for 20s instead of
# inheriting libcurl's effectively unbounded default, so a half-open
# connection cannot hang a job. git enforces this itself.
sibling_http_opts=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20)

# Diagnostics from the most recent lookup. These exist because the message the
# CI failure needed -- `fatal: could not read Username` -- was produced on
# every run for five days and discarded by a `2>/dev/null`.
#
# They are kept in FILES, not variables, and that is not incidental. Every
# caller reads a lookup through `out="$(sibling_ls_remote ...)"`, which runs
# the lookup in a subshell -- so a variable the lookup sets is gone by the
# time the failure message wants to print it, and the message would have come
# out with an empty reason. Which is the bug being fixed, reintroduced one
# layer down.
sibling_why_file="${sibling_scratch}/why"
sibling_arm_file="${sibling_scratch}/arm"
sibling_why() { cat "${sibling_why_file}" 2>/dev/null || true; }
sibling_arm() { cat "${sibling_arm_file}" 2>/dev/null || true; }

# One attempt with the ambient credentials, exactly as the environment supplies
# them. GIT_TERMINAL_PROMPT=0 so a host with no credential can never sit at a
# username prompt waiting for a CI runner that will never type one.
sibling_ls_remote_ambient() {
  GIT_TERMINAL_PROMPT=0 "${sibling_timeout[@]}" \
    git "${sibling_http_opts[@]}" ls-remote "$@" 2>"${sibling_scratch}/err"
}

# One attempt with every credential source removed:
#   * GIT_CONFIG_COUNT unset discards the whole GIT_CONFIG_KEY_*/VALUE_* set,
#     which is how CI injects the token;
#   * GIT_CONFIG_PARAMETERS unset discards config inherited from a parent
#     `git -c`, which is how a git subprocess passes options down;
#   * GIT_CONFIG_GLOBAL/SYSTEM=/dev/null discard user and machine config;
#   * `-C` moves off this repo so its .git/config extraheader does not apply --
#     and GIT_DIR/GIT_WORK_TREE/GIT_CONFIG are unset so it actually can. The
#     managed pre-commit hook runs this script with GIT_DIR exported, and with
#     that left in place `-C` moves nowhere and the repo-local extraheader is
#     still live;
#   * an empty credential.helper stops a helper re-supplying what the rest
#     just removed.
sibling_ls_remote_anon() {
  env -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG \
    -u GIT_DIR -u GIT_WORK_TREE \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_TERMINAL_PROMPT=0 \
    "${sibling_timeout[@]}" \
    git -C "${sibling_neutral_dir}" "${sibling_http_opts[@]}" \
    -c credential.helper= ls-remote "$@" 2>"${sibling_scratch}/err"
}

# Discovers EXACTLY ONE `Authorization` extraHeader to speak with, and prints
# it. Empty output means no header could be found, which is the normal state on
# a laptop.
#
# Preference order matters. The env-injected header is the GitHub App
# INSTALLATION token that ci.yml mints for cross-repo sibling access; the
# repo-local one `actions/checkout` persists is the workflow GITHUB_TOKEN, which
# can see this repository and nothing else. For resolving siblings the former is
# the only useful one, so it wins.
sibling_auth_header() {
  local n="${GIT_CONFIG_COUNT:-0}" i=0 k v
  while [ "${i}" -lt "${n}" ]; do
    eval "k=\${GIT_CONFIG_KEY_${i}:-}"
    eval "v=\${GIT_CONFIG_VALUE_${i}:-}"
    case "$(printf '%s' "${k}" | tr '[:upper:]' '[:lower:]')" in
      http.*extraheader)
        if [ -n "${v}" ]; then
          printf '%s' "${v}"
          return 0
        fi
        ;;
    esac
    i=$((i + 1))
  done
  # Fall back to whatever `actions/checkout` persisted into this repo's config.
  git config --local --get-regexp '^http\..*\.extraheader$' 2>/dev/null |
    head -1 | cut -d' ' -f2- || true
}

# One attempt carrying exactly ONE Authorization header.
#
# THIS IS THE ARM THAT FIXES CI, and the reason it has to exist is worth
# stating plainly, because the obvious reading of the old failure was wrong.
#
# Two different things each install an extraHeader for github.com in a CI job:
#
#   * `actions/checkout@v4` persists
#     `http.https://github.com/.extraheader` into THIS repo's .git/config,
#     carrying the workflow GITHUB_TOKEN;
#   * `setup-dev-env` exports
#     `http.https://github.com/metacraft-labs/.extraHeader` through
#     GIT_CONFIG_*, carrying the installation token.
#
# Both URL patterns match any `https://github.com/metacraft-labs/...` request,
# and `http.extraHeader` is a MULTI-VALUED list rather than a single setting --
# so git sends BOTH, and github rejects the request outright:
#
#     remote: Duplicate header: "Authorization"
#     fatal: unable to access '...': The requested URL returned error: 400
#
# That is what every sibling-pin lookup in this gate was actually hitting. Not
# a slow network, not a timeout: a 400, in about 400ms, on every lookup, on
# every runner class, deterministically, since the day the gate landed.
#
# Neutralising every config source and re-adding one discovered header is the
# repair. It is deliberately not "turn off the repo-local one": this script does
# not own `actions/checkout`'s configuration and must not rewrite the
# repository's config as a side effect of linting it.
sibling_ls_remote_single_header() {
  local hdr
  hdr="$(sibling_auth_header)"
  [ -n "${hdr}" ] || return 1
  env -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG \
    -u GIT_DIR -u GIT_WORK_TREE \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_TERMINAL_PROMPT=0 \
    "${sibling_timeout[@]}" \
    git -C "${sibling_neutral_dir}" "${sibling_http_opts[@]}" \
    -c credential.helper= -c "http.extraHeader=${hdr}" \
    ls-remote "$@" 2>"${sibling_scratch}/err"
}

# Runs `git ls-remote "$@"` through every arm, with retries, and prints the
# output of whichever answered.
#
#   0 -- github ANSWERED. stdout is the answer, and empty stdout is a real
#        answer: it means the ref is not there.
#   1 -- nothing answered. Nothing may be concluded about the ref.
sibling_ls_remote() {
  local round=1 out rc why=""
  : >"${sibling_why_file}"
  : >"${sibling_arm_file}"
  while :; do
    rc=0
    out="$(sibling_ls_remote_ambient "$@")" || rc=$?
    if [ "${rc}" -eq 0 ]; then
      printf 'ambient' >"${sibling_arm_file}"
      printf '%s' "${out}"
      return 0
    fi
    why="ambient: $(tr '\n' ' ' <"${sibling_scratch}/err")"

    rc=0
    out="$(sibling_ls_remote_single_header "$@")" || rc=$?
    if [ "${rc}" -eq 0 ]; then
      printf 'single-header' >"${sibling_arm_file}"
      printf '%s' "${out}"
      return 0
    fi
    why="${why} | single-header: $(tr '\n' ' ' <"${sibling_scratch}/err")"

    rc=0
    out="$(sibling_ls_remote_anon "$@")" || rc=$?
    if [ "${rc}" -eq 0 ]; then
      printf 'anonymous' >"${sibling_arm_file}"
      printf '%s' "${out}"
      return 0
    fi
    why="${why} | anonymous: $(tr '\n' ' ' <"${sibling_scratch}/err")"
    printf '%s' "${why}" >"${sibling_why_file}"

    if [ "${round}" -ge "${sibling_lookup_rounds}" ]; then
      return 1
    fi
    sleep "$((round * 3))"
    round=$((round + 1))
  done
}

# Tri-state, because "I could not ask" is not "the answer is no":
#   0 -- the ref exists as a branch or a tag
#   1 -- github answered and the ref is not there
#   2 -- unresolvable; `sibling_why` says why
sibling_ref_state() {
  local name="$1" ref="$2" out
  out="$(sibling_ls_remote --heads --tags \
    "https://github.com/metacraft-labs/${name}" \
    "${ref}" "refs/tags/${ref}")" || return 2
  [ -n "${out}" ] || return 1
  return 0
}

# The repo's default branch, or empty when the lookup could not be answered.
sibling_default_branch() {
  local name="$1" out
  out="$(sibling_ls_remote --symref \
    "https://github.com/metacraft-labs/${name}" HEAD)" || return 1
  printf '%s' "${out}" |
    awk '/^ref:/ { sub(/^refs\/heads\//, "", $2); print $2; exit }'
}

# Prove the PARSER handles every entry form the clone action accepts, before
# any network is involved -- this part is free and runs even offline. A parser
# that drops a form silently checks fewer pins than it reports.
cat >"${sibling_parse_fixture}/sibling-repos" <<'PARSEFIX'
# a comment, and a blank line follow

bare-lock-resolved
plain-branch=dev
acknowledged-override!=dev
commit-pinned=0123456789abcdef0123456789abcdef01234567
  indented-branch=main   # trailing comment
PARSEFIX
expected_parse='plain-branch dev
acknowledged-override dev
indented-branch main'
actual_parse="$(sibling_repo_branch_pins "${sibling_parse_fixture}/sibling-repos")"
if [ "${actual_parse}" != "${expected_parse}" ]; then
  echo "FAIL: the sibling-repos parser does not read the format it claims to." >&2
  echo "      expected:" >&2
  printf '%s\n' "${expected_parse}" | sed 's/^/        /' >&2
  echo "      got:" >&2
  printf '%s\n' "${actual_parse}" | sed 's/^/        /' >&2
  echo "      A form it drops is a pin nobody checks. Fix it before trusting" >&2
  echo "      a clean run." >&2
  exit 1
fi
echo "ok: sibling-repos parser handles bare, =ref, !=ref, SHA and comments"

# The test-certificates-spec sibling is pinned to the exact revision the
# content-id conformance test reads its vectors at. clone-siblings clones
# shallow, so the sibling carries ONLY the revision its entry names; if the two
# drift, CI's clone lacks the pinned commit and the test fails at `git archive`
# with nothing pointing back here. Offline, so it runs before the network gate.
tcs_pin_file="tests/integration/content_id/test-certificates-spec-content-vectors.pin"
tcs_pin="$(tr -d '[:space:]' <"${tcs_pin_file}")"
tcs_entry="$(sibling_repo_entries "${sibling_repos_file}" |
  sed -nE 's/^test-certificates-spec!?=//p')"
if [ -z "${tcs_entry}" ] || [ "${tcs_entry}" != "${tcs_pin}" ]; then
  echo "FAIL: ${sibling_repos_file} pins test-certificates-spec to '${tcs_entry:-<no entry>}'," >&2
  echo "      but ${tcs_pin_file} pins '${tcs_pin}'." >&2
  echo "      CI clones that sibling shallow at its entry's revision, so the two" >&2
  echo "      must name the same commit. Move them together." >&2
  exit 1
fi
echo "ok: test-certificates-spec sibling pin matches the content-vector pin"

# Is github reachable at all? Resolved once, against this repo, so that a
# laptop that is merely offline does not report every entry as a missing ref.
# Tri-state: `unresolvable` is the offline case, while `absent` would mean the
# lookup worked and said `reprobuild` has no `dev`, which is a different and
# much louder problem.
sibling_probe_repo="reprobuild"
probe_state=0
sibling_ref_state "${sibling_probe_repo}" dev || probe_state=$?
probe_arm="$(sibling_arm)"
probe_why="$(sibling_why)"

if [ "${probe_state}" -eq 1 ]; then
  echo "FAIL: github answered, but says metacraft-labs/${sibling_probe_repo} has no" >&2
  echo "      \`dev\` branch -- which it certainly does. Either the resolver is" >&2
  echo "      broken or this repo was renamed; either way a clean run from here" >&2
  echo "      would mean nothing." >&2
  exit 1
fi

if [ "${probe_state}" -ne 0 ]; then
  # Never silently pass in CI. Offline is a plausible state for the pre-commit
  # hook on a laptop; it is not a plausible state for a CI runner, where it
  # means the check did not run and nobody was told.
  #
  # The reason the lookup failed is PRINTED. For five days this said only
  # "cannot reach github.com" while the actual message -- `fatal: could not
  # read Username`, a scoped token refusing a repo outside its closure -- was
  # being thrown away by a `2>/dev/null`, and the whole gate was misdiagnosed
  # as a network timeout because of it. Whatever the next cause turns out to
  # be, it should arrive with its own words attached.
  if [ -n "${CI:-}" ]; then
    echo "FAIL: cannot resolve sibling-repo pins, and \$CI is set. A CI run that" >&2
    echo "      cannot check the pins must not report success: that is how an" >&2
    echo "      unresolvable ref reaches the mainline." >&2
    echo "      Both credential arms were tried, ${sibling_lookup_rounds} times each. git said:" >&2
    printf '        %s\n' "${probe_why}" >&2
    echo "      If that mentions a duplicate Authorization header, two things" >&2
    echo "      are each setting one for github.com and git is sending both." >&2
    echo "      If it mentions a 404 on a PUBLIC repo, the ambient token is" >&2
    echo "      scoped and the anonymous arm is failing too -- check egress." >&2
    exit 1
  fi
  echo "SKIP: github.com unreachable; sibling-repo pins not resolved (offline)."
  echo "      git said: ${probe_why}"
  echo "      CI resolves them on every push -- this gate is fatal there."
else
  # Prove the resolver still distinguishes a real ref from a missing one before
  # trusting a clean result from it. A resolver that has quietly started saying
  # "exists" for everything -- a changed ls-remote spelling, a URL typo that
  # makes every lookup fail the same way -- is a green light that means nothing.
  #
  # `absent` is asserted as absent and NOT merely as "not present": under the
  # old single-arm resolver a transport failure and a missing ref were the same
  # value, so this case passed on a lookup that never happened.
  selftest_state=0
  sibling_ref_state "${sibling_probe_repo}" __gate_selftest_absent_ref__ || selftest_state=$?
  if [ "${selftest_state}" -eq 0 ]; then
    echo "FAIL: the sibling-ref resolver reports a ref that cannot exist as" >&2
    echo "      present. It would accept every pin, including the \`=main\`" >&2
    echo "      entries this gate exists to catch." >&2
    exit 1
  fi
  if [ "${selftest_state}" -ne 1 ]; then
    echo "FAIL: the resolver could not answer for a ref it should have reported" >&2
    echo "      as absent, yet the reachability probe above succeeded. A lookup" >&2
    echo "      that fails this way would be counted as a dead pin." >&2
    printf '        %s\n' "$(sibling_why)" >&2
    exit 1
  fi
  echo "ok: sibling-ref resolver separates a live ref from a missing one (probe answered via ${probe_arm} credentials)"

  # Pin the ANONYMOUS arm on its own, by name.
  #
  # In CI it is the only arm that can answer for this gate's probe anchors, and
  # on a laptop it is normally the ambient arm that answers first -- so without
  # this case the arm CI depends on is exercised nowhere a developer can see it
  # and nowhere a local run would notice it breaking. That is precisely the
  # shape of the five-day failure: a property that holds on the arm one
  # environment runs is pinned on neither.
  if ! sibling_ls_remote_anon --heads \
      "https://github.com/metacraft-labs/${sibling_probe_repo}" dev |
      grep -q 'refs/heads/dev'; then
    echo "FAIL: the anonymous lookup arm cannot resolve \`dev\` in the public repo" >&2
    echo "      metacraft-labs/${sibling_probe_repo}. In CI this is the ONLY arm that can" >&2
    echo "      answer for a repo outside the installation token's closure, so" >&2
    echo "      with it broken this gate is back to failing every run." >&2
    printf '        %s\n' "$(tr '\n' ' ' <"${sibling_scratch}/err")" >&2
    exit 1
  fi
  echo "ok: the anonymous arm resolves a public repo unaided"

  # The abandoned-mainline probe needs its own anchor, because the check it
  # guards is invisible to the one above: `nixos-modules` still HAS a `main`,
  # so `sibling_ref_state` says yes, and only the default-branch lookup can
  # tell that `main` stopped being the mainline. If that lookup silently
  # started returning nothing, the whole check would pass everything.
  probe_default="$(sibling_default_branch nixos-modules || true)"
  if [ "${probe_default}" = "main" ] || [ -z "${probe_default}" ]; then
    echo "FAIL: the default-branch lookup returned '${probe_default:-<nothing>}'" >&2
    echo "      for metacraft-labs/nixos-modules, which has moved its default" >&2
    echo "      off \`main\` while keeping the branch. The abandoned-mainline" >&2
    echo "      check cannot work if this lookup does not answer; fix it before" >&2
    echo "      trusting a clean run." >&2
    printf '        %s\n' "$(sibling_why)" >&2
    exit 1
  fi
  echo "ok: default-branch lookup detects a mainline that moved (nixos-modules -> ${probe_default})"

  # Non-vacuity: this repo's CI clones siblings on every dev-shell job, so a
  # parse that finds no entries has stopped reading the file it claims to read.
  entry_count="$(sibling_repo_entries "${sibling_repos_file}" | wc -l | tr -d ' ')"
  if [ "${entry_count}" -lt 1 ]; then
    echo "FAIL: parsed 0 entries out of ${sibling_repos_file}, which is not empty." >&2
    echo "      The parser is not reading the format it claims to." >&2
    exit 1
  fi

  sibling_violations=""
  abandoned_violations=""
  unresolvable=""
  checked=0
  # Which arm answered, per entry. Reported at the end so a run SAYS which
  # credential state actually resolved what. Without this the gate could pass
  # on one arm while another silently rotted -- and the arm that rots is the
  # one no local run exercises.
  arm_ambient=0
  arm_single=0
  arm_anon=0
  while read -r name ref; do
    [ -n "${name}" ] || continue
    checked=$((checked + 1))
    entry_state=0
    sibling_ref_state "${name}" "${ref}" || entry_state=$?
    if [ "${entry_state}" -eq 2 ]; then
      # Reachability is already established, so this is one repo neither arm
      # can see rather than a network fault: a private sibling outside the
      # installation token's closure in CI, or a laptop with no credential for
      # it. Collected separately and NEVER reported as a dead ref -- the pin
      # may well be perfect and nobody here can tell.
      unresolvable="${unresolvable}${name}=${ref} -- $(sibling_why)"$'\n'
      continue
    fi
    if [ "${entry_state}" -eq 1 ]; then
      sibling_violations="${sibling_violations}${name}=${ref}"$'\n'
      continue
    fi
    case "$(sibling_arm)" in
      ambient) arm_ambient=$((arm_ambient + 1)) ;;
      single-header) arm_single=$((arm_single + 1)) ;;
      anonymous) arm_anon=$((arm_anon + 1)) ;;
    esac
    # The ref exists -- but `main` on a repo that has moved its default to
    # something else is the ABANDONED half of the rename, and existence alone
    # cannot see it. This is the regime the original incident ran in: between
    # 2026-08-26 and 2026-08-28 `reprobuild-test-adapters` still HAD a `main`,
    # frozen at d1ff8317 (2026-07-13) while `dev` carried on. The clone
    # succeeded, silently, onto a six-week-old tree, and the build failed
    # fifteen minutes later with `undeclared identifier`. `main` was not
    # deleted until 2026-08-28, and only then did it fail loudly at clone time.
    # A ref that resolves is not the same as a ref that is current.
    #
    # Scoped deliberately to `main`. Pinning a NON-default branch is legitimate
    # and common here -- codetracer-trace-format defaults to `stable` and is
    # pinned to `dev` on purpose -- so a general "must equal the default branch"
    # rule would reject correct entries. `main` on a repo whose default has
    # moved is the specific, recurring defect.
    if [ "${ref}" = "main" ]; then
      default_ref="$(sibling_default_branch "${name}" || true)"
      if [ -n "${default_ref}" ] && [ "${default_ref}" != "main" ]; then
        abandoned_violations="${abandoned_violations}${name}=main (default branch is '${default_ref}')"$'\n'
      fi
    fi
  done < <(sibling_repo_branch_pins "${sibling_repos_file}")

  # `wc -l`, not `grep -c`: this script runs under `set -o pipefail`, and
  # `grep -c` exits 1 when it counts zero -- so on the normal path, where
  # nothing is unresolvable, counting with grep aborted the whole gate at the
  # last line with no message at all.
  unresolvable_count="$(printf '%s' "${unresolvable}" | wc -l | tr -d ' ')"
  resolved_count=$((checked - unresolvable_count))

  if [ -n "${abandoned_violations}" ]; then
    echo "FAIL: ${sibling_repos_file} pins \`main\` on repo(s) that have moved off it:" >&2
    printf '%s' "${abandoned_violations}" | sed 's/^/      /' >&2
    echo "" >&2
    echo "      These refs still RESOLVE, so the clone succeeds and CI stays" >&2
    echo "      quiet -- onto a branch that stopped moving. That is how the" >&2
    echo "      2026-08-26 failure happened: reprobuild-test-adapters still had" >&2
    echo "      a \`main\`, frozen six weeks earlier, and the build failed with" >&2
    echo "      \`undeclared identifier\` rather than anything naming a branch." >&2
    echo "      Use the repo's current mainline, or a 40-hex SHA." >&2
    exit 1
  fi

  if [ -n "${sibling_violations}" ]; then
    echo "FAIL: ${sibling_repos_file} pins ref(s) that do not exist:" >&2
    printf '%s' "${sibling_violations}" | sed 's/^/      /' >&2
    echo "" >&2
    echo "      metacraft-labs renamed its mainline main -> dev, and several" >&2
    echo "      repos kept no \`main\` branch at all." >&2
    echo "" >&2
    echo "      A ref that does not resolve takes the job down at sibling-clone" >&2
    echo "      time: authenticated-clone.sh removes the destination and exits" >&2
    echo "      non-zero, so the Test job dies minutes in with" >&2
    echo "        ##[error]checkout of revision <ref> failed for <repo>" >&2
    echo "      which names a ref but not this file." >&2
    echo "" >&2
    echo "      Use the repo's real mainline (\`dev\` for most metacraft-labs" >&2
    echo "      repos), or a 40-hex commit SHA for a deliberate pin." >&2
    exit 1
  fi
  if [ -n "${unresolvable}" ]; then
    # github is reachable -- the probe proved that -- but these specific repos
    # could not be read by either credential arm. In CI that means the
    # installation token's `repositories:` closure in ci.yml does not cover a
    # private sibling this file pins, and the pin is therefore UNCHECKED. Same
    # principle as the offline branch: a CI run that did not check a pin must
    # not report success.
    if [ -n "${CI:-}" ]; then
      echo "FAIL: these sibling pins could not be resolved by either credential" >&2
      echo "      arm, so they were NOT checked, and \$CI is set:" >&2
      printf '%s' "${unresolvable}" | sed 's/^/      /' >&2
      echo "" >&2
      echo "      github itself is reachable (the probe succeeded), so this is not" >&2
      echo "      a network fault. Read git's words above:" >&2
      echo "        * \"Repository not found\" -- the repo NAME is wrong, or the" >&2
      echo "          repo was renamed or deleted. Fix the name." >&2
      echo "        * an auth failure on a repo that does exist -- a PERMISSION" >&2
      echo "          gap. A private sibling has to be listed in the" >&2
      echo "          \`repositories:\` closure of the token minted in" >&2
      echo "          .github/workflows/ci.yml, or no job can read it." >&2
      echo "      Either way the pin was not checked, so this run cannot pass." >&2
      exit 1
    fi
    echo "WARN: ${unresolvable_count} sibling pin(s) could not be read with any"
    echo "      credential on this host -- private siblings, most likely:"
    printf '%s' "${unresolvable}" | sed 's/^/        /'
    echo "      They are NOT reported as dead pins, because nothing here can"
    echo "      tell. CI holds a token for them and checks them on every push."
  fi
  echo "ok: ${resolved_count} of ${checked} explicit sibling-repo pin(s) resolve on the remote" \
    "(${unresolvable_count} unresolvable here)"
  echo "    answered by: ambient=${arm_ambient} single-header=${arm_single} anonymous=${arm_anon}"
fi
