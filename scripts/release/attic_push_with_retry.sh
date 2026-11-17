#!/usr/bin/env bash
# attic_push_with_retry.sh <cache> <store-path>...
#
# Run `attic push <cache> <store-path>...`, retrying with exponential backoff
# when the failure looks transient (the server or the network), and failing at
# once when it does not (credentials, a missing cache, a malformed request).
#
# Exit 0 when a push succeeds, 1 when it fails for good (a permanent failure,
# an unrecognised one, or every attempt used up), 2 on a usage error.
#
# WHY. The release workflow pushes the reprobuild Nix package of the release
# revision to the organisation's Attic cache (cache.metacraft-labs.com), so
# consumers that build `github:metacraft-labs/reprobuild/<rev>#reprobuild`
# substitute it instead of compiling the engine. On v0.2.26 (Release run
# 43892878762, attempt 1) that push failed with
#
#   ❌ dshxrj8ghlmmaiwbdxkbrnmscxj732b9-reprobuild-0.2.26: InternalServerError: The server encountered an internal error or misconfiguration.
#   Error: InternalServerError: The server encountered an internal error or misconfiguration.
#
# while the same push for v0.2.25 had taken 40 seconds, and the cache answered
# normally twenty minutes later. atticd returns HTTP 500 in bursts when its
# database connection pool times out. One attempt is not enough for a service
# that fails that way; a bounded retry is.
#
# HOW A FAILURE IS CLASSIFIED. The attic client prints a server error in one
# of two shapes (client/src/api/mod.rs, `ApiError`, in
# https://github.com/zhaofengli/attic):
#
#   * structured, when the body is atticd's JSON error: `<Name>: <message>`,
#     `<Name>` being `ErrorKind::name()` in server/src/error.rs (or, for an
#     `AtticError`, its own name in attic/src/error.rs);
#   * unstructured, for any other body, e.g. a reverse proxy's HTML page:
#     `HTTP <status>: <body>`.
#
# A failure before any response comes from reqwest/hyper and names the
# connection instead ("error sending request", "connection refused", ...).
#
#   transient, retried:
#     InternalServerError  -- 500. atticd maps DatabaseError, StorageError and
#                             ManifestSerializationError to it before replying
#                             (`into_clients`), so a pool timeout reads this way.
#     IncompleteNar        -- 503: the upload did not arrive whole.
#     HTTP 5xx, HTTP 408, HTTP 429
#                          -- a proxy or the server said "not now".
#     connection errors, and an attempt that outlives its time limit.
#   permanent, not retried:
#     Unauthorized, AccessError, NoSuchCache, NoSuchObject, NotFound
#                          -- 401/403/404: the token or the cache name is
#                             wrong, and a retry would send the same ones.
#     RequestError, CacheAlreadyExists, InvalidCompressionType,
#     InvalidStorePath*, InvalidCacheName, HTTP 4xx (other than 408/429)
#                          -- the request itself is wrong.
#
# A permanent marker wins over a transient one in the same output: attic
# uploads paths in parallel, and when one path is refused for a bad token a
# 500 on another path does not make a retry worth waiting for.
#
# An UNRECOGNISED failure is not retried. Retrying it could only hide a new
# failure mode behind half an hour of waiting; failing names it. The release
# does not wait on this push (see release.yml, job `publish-nix-cache`), so a
# failure here costs a re-run of that job, not the release.
#
# Configuration, all optional (the defaults are the release workflow's):
#   ATTIC_PUSH_ATTEMPTS                  attempts in total            (6)
#   ATTIC_PUSH_BACKOFF_BASE_SECONDS      wait after attempt n is
#                                        base * 2^(n-1) seconds       (60:
#                                        1, 2, 4, 8, 16 minutes)
#   ATTIC_PUSH_ATTEMPT_TIMEOUT_SECONDS   time limit of one attempt    (1800)
#   ATTIC                                the attic client command     (attic)
#
# The 30-minute limit per attempt is above the slowest failing attempt seen
# (v0.2.26: 00:37:41 to 00:56:10, 18.5 minutes) and far above a successful one
# (v0.2.25: 40 seconds). Six attempts with those waits bound the step at
# 6 * 30 + 31 = 211 minutes.
set -euo pipefail

me="attic_push_with_retry.sh"

if [ "$#" -lt 2 ]; then
  echo "usage: ${me} <cache> <store-path>..." >&2
  exit 2
fi

cache="$1"
shift

attempts="${ATTIC_PUSH_ATTEMPTS:-6}"
base="${ATTIC_PUSH_BACKOFF_BASE_SECONDS:-60}"
limit="${ATTIC_PUSH_ATTEMPT_TIMEOUT_SECONDS:-1800}"
# Word-split on purpose: the caller may name a command with arguments
# (e.g. `nix shell nixpkgs#attic-client -c attic`).
read -r -a attic <<<"${ATTIC:-attic}"

for pair in "ATTIC_PUSH_ATTEMPTS=${attempts}" \
  "ATTIC_PUSH_BACKOFF_BASE_SECONDS=${base}" \
  "ATTIC_PUSH_ATTEMPT_TIMEOUT_SECONDS=${limit}"; do
  value="${pair#*=}"
  if ! [[ "${value}" =~ ^[0-9]+$ ]]; then
    echo "${me}: ${pair%%=*} must be a non-negative integer, got '${value}'" >&2
    exit 2
  fi
done
if [ "${attempts}" -lt 1 ] || [ "${limit}" -lt 1 ]; then
  echo "${me}: ATTIC_PUSH_ATTEMPTS and ATTIC_PUSH_ATTEMPT_TIMEOUT_SECONDS must be at least 1" >&2
  exit 2
fi

# Append a line to the job summary when there is one (GitHub Actions), so the
# attempt history is on the run page, not only in the step log.
summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$*" >>"${GITHUB_STEP_SUMMARY}"
  fi
}

# classify <log> <exit-status>: print `permanent`, `transient` or `unknown`,
# followed by a tab and the evidence (the matching line, or a description).
classify() {
  local log="$1" status="$2" line
  # 124: `timeout` stopped the attempt; 137: it had to SIGKILL it after the
  # grace period. Checked first: a hung attempt may have printed nothing.
  if [ "${status}" -eq 124 ] || [ "${status}" -eq 137 ]; then
    printf 'transient\tthe attempt did not finish within %s s\n' "${limit}"
    return
  fi
  # `(^|[^A-Za-z])Name:` -- the error name as a whole word followed by the
  # colon attic prints after it, so a store path or a message that merely
  # contains the word does not match.
  local permanent='(^|[^A-Za-z])(Unauthorized|AccessError|NoSuchCache|NoSuchObject|NotFound|RequestError|CacheAlreadyExists|InvalidCompressionType|InvalidStorePath|InvalidStorePathName|InvalidStorePathHash|InvalidCacheName):'
  local transient='(^|[^A-Za-z])(InternalServerError|IncompleteNar):|HTTP (5[0-9][0-9]|408|429)[^0-9]|error sending request|error trying to connect|[Cc]onnection (refused|reset|closed)|[Oo]peration timed out|[Bb]roken pipe|dns error|[Tt]emporary failure in name resolution'
  # A 4xx other than 408 (Request Timeout) and 429 (Too Many Requests), which
  # are the server asking to be tried again and so are transient above.
  # (No `-m1` on the second grep of that pipeline: stopping it early could
  # SIGPIPE the first, and under `pipefail` a match would then read as none.)
  if line="$(grep -E -m1 -- "${permanent}" "${log}")" ||
    line="$(grep -E -- 'HTTP 4[0-9][0-9][^0-9]' "${log}" | grep -Ev -- 'HTTP (408|429)[^0-9]')"; then
    printf 'permanent\t%s\n' "${line%%$'\n'*}"
  elif line="$(grep -E -m1 -- "${transient}" "${log}")"; then
    printf 'transient\t%s\n' "${line}"
  else
    printf 'unknown\texit status %s with no recognised attic or connection error\n' "${status}"
  fi
}

log="$(mktemp "${TMPDIR:-/tmp}/attic-push.XXXXXX")"
trap 'rm -f "${log}"' EXIT

summary "### Attic push to \`${cache}\`"
summary ""

attempt=1
while :; do
  echo "${me}: attempt ${attempt}/${attempts}: attic push ${cache} $*"
  set +e
  # Through `tee` so the output still streams into the step log while it is
  # kept for classification. `--kill-after` turns a push that ignores SIGTERM
  # into exit 137 rather than an unbounded wait.
  timeout --kill-after=60 "${limit}" "${attic[@]}" push "${cache}" "$@" 2>&1 | tee "${log}"
  status="${PIPESTATUS[0]}"
  set -e

  if [ "${status}" -eq 0 ]; then
    summary "- attempt ${attempt}/${attempts}: pushed"
    echo "${me}: pushed on attempt ${attempt}/${attempts}"
    exit 0
  fi

  verdict="$(classify "${log}" "${status}")"
  kind="${verdict%%$'\t'*}"
  evidence="${verdict#*$'\t'}"
  summary "- attempt ${attempt}/${attempts}: failed (${kind}): \`${evidence}\`"

  case "${kind}" in
    permanent)
      echo "::error::Attic push to ${cache} failed with a permanent error; not retrying: ${evidence}"
      exit 1
      ;;
    unknown)
      echo "::error::Attic push to ${cache} failed and the failure is not one this script knows to be transient; not retrying: ${evidence}"
      exit 1
      ;;
  esac

  if [ "${attempt}" -ge "${attempts}" ]; then
    echo "::error::Attic push to ${cache} still failing after ${attempts} attempts: ${evidence}"
    exit 1
  fi

  wait_s=$((base * (1 << (attempt - 1))))
  echo "::warning::Attic push to ${cache} failed (attempt ${attempt}/${attempts}, transient: ${evidence}); retrying in ${wait_s} s"
  sleep "${wait_s}"
  attempt=$((attempt + 1))
done
