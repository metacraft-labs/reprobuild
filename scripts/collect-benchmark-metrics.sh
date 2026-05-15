#!/usr/bin/env bash
set -euo pipefail

quick=false
for arg in "$@"; do
  case "${arg}" in
    --quick) quick=true ;;
    *) echo "unknown benchmark argument: ${arg}" >&2; exit 2 ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

mkdir -p bench-results build/nimcache
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/reprobuild-bench.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT

results=()
rows=()

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "${value}"
}

html_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  printf '%s' "${value}"
}

add_result() {
  local name="$1"
  local unit="$2"
  local value="$3"
  local extra="$4"
  local escaped_name
  local escaped_unit
  local escaped_extra
  escaped_name="$(json_escape "${name}")"
  escaped_unit="$(json_escape "${unit}")"
  escaped_extra="$(json_escape "${extra}")"
  results+=("{\"name\":\"${escaped_name}\",\"unit\":\"${escaped_unit}\",\"value\":${value},\"extra\":\"${escaped_extra}\"}")
  rows+=("<tr><td>$(html_escape "${name}")</td><td>${value}</td><td>$(html_escape "${unit}")</td><td>$(html_escape "${extra}")</td></tr>")
}

measure_ms() {
  local name="$1"
  local extra="$2"
  shift 2
  local index="${#results[@]}"
  local log_file="${tmp_dir}/bench-${index}.log"
  local time_file="${tmp_dir}/bench-${index}.time"
  local seconds
  local millis
  local status

  echo "benchmark: ${name}" >&2
  if { TIMEFORMAT=%R; time ( "$@" >"${log_file}" 2>&1 ); } 2>"${time_file}"; then
    status=0
  else
    status=$?
  fi

  if [ "${status}" -ne 0 ]; then
    echo "benchmark failed: ${name}" >&2
    sed -n '1,120p' "${log_file}" >&2
    exit "${status}"
  fi

  seconds="$(tail -n 1 "${time_file}" | tr -d '[:space:]')"
  millis="$(awk -v seconds="${seconds}" 'BEGIN { printf "%.3f", seconds * 1000 }')"
  add_result "${name}" "ms" "${millis}" "${extra}"
}

emit_json() {
  local first=true
  printf '['
  for result in "${results[@]}"; do
    if [ "${first}" = true ]; then
      first=false
    else
      printf ','
    fi
    printf '%s' "${result}"
  done
  printf ']\n'
}

write_report() {
  local json_results="$1"
  local generated_at
  local commit
  local host
  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  commit="$(git rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
  host="$(uname -sm 2>/dev/null || printf 'unknown')"

  {
    cat <<HTML
<!doctype html>
<meta charset="utf-8">
<title>Reprobuild M0 Benchmark Report</title>
<style>
body { font-family: system-ui, sans-serif; margin: 2rem; color: #202124; }
table { border-collapse: collapse; width: 100%; margin-top: 1rem; }
th, td { border: 1px solid #d0d7de; padding: 0.5rem; text-align: left; }
th { background: #f6f8fa; }
code { background: #f6f8fa; padding: 0.1rem 0.25rem; }
</style>
<h1>Reprobuild M0 Benchmark Report</h1>
<p>Generated: <code>$(html_escape "${generated_at}")</code></p>
<p>Commit: <code>$(html_escape "${commit}")</code></p>
<p>Host: <code>$(html_escape "${host}")</code></p>
<p>Mode: <code>quick=$(html_escape "${quick}")</code></p>
<table>
<thead><tr><th>Metric</th><th>Value</th><th>Unit</th><th>Context</th></tr></thead>
<tbody>
HTML
    for row in "${rows[@]}"; do
      printf '%s\n' "${row}"
    done
    cat <<HTML
</tbody>
</table>
<script type="application/json" id="benchmark-results">
${json_results}
</script>
HTML
  } > bench-results/report.html
}

nim_sources="$(find libs apps tests examples -type f -name '*.nim' | wc -l | tr -d '[:space:]')"
c_sources="$(find examples -type f \( -name '*.c' -o -name '*.h' \) | wc -l | tr -d '[:space:]')"
example_projects="$(find examples -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')"

echo "running Reprobuild M0 benchmark suite (quick=${quick})" >&2

measure_ms \
  "Reprobuild M0 source enumeration" \
  "quick=${quick}; nim_sources=${nim_sources}; c_sources=${c_sources}; example_projects=${example_projects}" \
  bash -c 'find libs apps tests examples -type f \( -name "*.nim" -o -name "*.c" -o -name "*.h" -o -name "README.md" \) | sort >/dev/null'

measure_ms \
  "Reprobuild M0 core library nim check" \
  "quick=${quick}; target=libs/repro_core/src/repro_core.nim" \
  nim check --nimcache:build/nimcache/bench-repro-core libs/repro_core/src/repro_core.nim

measure_ms \
  "Reprobuild M0 entrypoint manifest nim check" \
  "quick=${quick}; target=tests/integration/t_entrypoints.nim" \
  nim check --nimcache:build/nimcache/bench-t-entrypoints tests/integration/t_entrypoints.nim

if [ "${quick}" = false ]; then
  measure_ms \
    "Reprobuild M0 all Nim source checks" \
    "quick=${quick}; command=scripts/check_nim_sources.sh" \
    bash scripts/check_nim_sources.sh

  measure_ms \
    "Reprobuild M0 repository requirements gate" \
    "quick=${quick}; command=scripts/check_repo_requirements.sh" \
    bash scripts/check_repo_requirements.sh

  measure_ms \
    "Reprobuild M0 test compile and run" \
    "quick=${quick}; command=scripts/run_tests.sh" \
    bash scripts/run_tests.sh
fi

json_results="$(emit_json)"
write_report "${json_results}"
printf '%s\n' "${json_results}"
