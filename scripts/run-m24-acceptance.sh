#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

mkdir -p test-logs

summary="test-logs/reprobuild-mvp-acceptance.json"
acceptance_dir="test-logs/reprobuild-mvp-acceptance"
subgates_json="${acceptance_dir}/subgates.json"
session_id="$(date -u '+%Y%m%dT%H%M%SZ')"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

rm -rf "${acceptance_dir}"
mkdir -p "${acceptance_dir}"
: > "${subgates_json}"

repo_revision() {
  local path="$1"
  git -C "${path}" rev-parse HEAD 2>/dev/null || printf 'unknown'
}

repo_dirty() {
  local path="$1"
  if ! git -C "${path}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'true'
    return
  fi
  if git -C "${path}" diff --quiet &&
     git -C "${path}" diff --cached --quiet &&
     [ -z "$(git -C "${path}" ls-files --others --exclude-standard)" ]; then
    printf 'false'
  else
    printf 'true'
  fi
}

append_subgate() {
  local name="$1"
  local command="$2"
  local status="$3"
  local exit_code="$4"
  local log_path="$5"
  local started="$6"
  local ended="$7"
  local duration_seconds="$8"

  if [ -s "${subgates_json}" ]; then
    printf ',\n' >> "${subgates_json}"
  fi

  cat >> "${subgates_json}" <<JSON
    {
      "name": "${name}",
      "command": "${command}",
      "status": "${status}",
      "exitCode": ${exit_code},
      "logPath": "${log_path}",
      "startedAt": "${started}",
      "endedAt": "${ended}",
      "durationSeconds": ${duration_seconds}
    }
JSON
}

overall_exit=0

run_gate() {
  local name="$1"
  local command="$2"
  local log_path="${acceptance_dir}/${name}.log"
  local gate_started_at
  local gate_ended_at
  local start_seconds
  local end_seconds
  local exit_code
  local status

  gate_started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  start_seconds="$(date '+%s')"

  echo "M24 acceptance: running ${command}" >&2
  set +e
  bash -lc "${command}" 2>&1 | tee "${log_path}"
  exit_code="${PIPESTATUS[0]}"
  set -e

  gate_ended_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  end_seconds="$(date '+%s')"

  if [ "${exit_code}" -eq 0 ]; then
    status="pass"
  else
    status="fail"
    overall_exit=1
  fi

  append_subgate \
    "${name}" \
    "${command}" \
    "${status}" \
    "${exit_code}" \
    "${log_path}" \
    "${gate_started_at}" \
    "${gate_ended_at}" \
    "$((end_seconds - start_seconds))"
}

run_gate "m20_codetracer_build_subset" "just e2e_codetracer_build_subset_without_tup"
run_gate "m21_codetracer_dev_environment_slice" "just e2e_codetracer_dev_environment_slice"
run_gate "m22_shared_runquota_sessions" "just integration_reprobuild_sessions_share_runquota"
run_gate "m23_core_mvp_performance" "just bench_reprobuild_core_mvp_performance"

ended_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
if [ "${overall_exit}" -eq 0 ]; then
  overall_status="pass"
else
  overall_status="fail"
fi

cat > "${summary}" <<JSON
{
  "format": "reprobuild-mvp-acceptance-v1",
  "milestone": "M24",
  "status": "${overall_status}",
  "session": {
    "id": "${session_id}",
    "startedAt": "${started_at}",
    "endedAt": "${ended_at}",
    "logDir": "${acceptance_dir}"
  },
  "codeTracerRelativePath": "../codetracer",
  "repositories": {
    "reprobuild": {
      "relativePath": ".",
      "revision": "$(repo_revision ".")",
      "dirty": $(repo_dirty ".")
    },
    "runquota": {
      "relativePath": "../runquota",
      "revision": "$(repo_revision "../runquota")",
      "dirty": $(repo_dirty "../runquota")
    },
    "codetracer": {
      "relativePath": "../codetracer",
      "revision": "$(repo_revision "../codetracer")",
      "dirty": $(repo_dirty "../codetracer")
    },
    "reprobuildSpecs": {
      "relativePath": "../reprobuild-specs",
      "revision": "$(repo_revision "../reprobuild-specs")",
      "dirty": $(repo_dirty "../reprobuild-specs")
    }
  },
  "acceptedScope": [
    "macOS MVP repository acceptance slice",
    "selected CodeTracer build subset copied from ../codetracer",
    "selected CodeTracer development-environment slice with Nix-backed tool profiles",
    "two concurrent repro build sessions sharing one real RunQuota daemon",
    "core MVP benchmark gate using real Reprobuild and RunQuota components"
  ],
  "deferredScope": [
    "full CodeTracer repository build replacement",
    "in-place CodeTracer repository integration and daily-use switch",
    "Windows DIY development-environment replacement",
    "Linux live tup comparison gate",
    "repro watch sharing",
    "distributed execution",
    "broad HCR direct-patching functionality"
  ],
  "subgates": [
$(cat "${subgates_json}")
  ]
}
JSON

cp "${summary}" "${acceptance_dir}/summary.json"
echo "M24 acceptance summary: ${summary}" >&2

exit "${overall_exit}"
