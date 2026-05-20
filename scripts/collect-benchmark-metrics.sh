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

mkdir -p bench-results build/nimcache test-logs
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/reprobuild-bench.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT

results_jsonl="${tmp_dir}/benchmark-results.jsonl"
rows_html="${tmp_dir}/benchmark-rows.html"
: >"${results_jsonl}"
: >"${rows_html}"

benchmark_suites="${REPROBUILD_BENCH_SUITES:-m0,m23,cmake}"

suite_enabled() {
  local suite="$1"
  case ",${benchmark_suites}," in
    *",${suite},"*) return 0 ;;
    *) return 1 ;;
  esac
}

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
  printf '{"name":"%s","unit":"%s","value":%s,"extra":"%s"}\n' \
    "${escaped_name}" "${escaped_unit}" "${value}" "${escaped_extra}" >>"${results_jsonl}"
  printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
    "$(html_escape "${name}")" "${value}" "$(html_escape "${unit}")" "$(html_escape "${extra}")" >>"${rows_html}"
}

measure_ms() {
  local name="$1"
  local extra="$2"
  shift 2
  local index
  local log_file
  local time_file
  local seconds
  local millis
  local status
  index="$(wc -l <"${results_jsonl}" | tr -d '[:space:]')"
  log_file="${tmp_dir}/bench-${index}.log"
  time_file="${tmp_dir}/bench-${index}.time"

  echo "benchmark: ${name}" >&2
  if { TIMEFORMAT=%R; time ( "$@" >"${log_file}" 2>&1 ); } 2>"${time_file}"; then
    status=0
  else
    status=$?
  fi

  if [ "${status}" -ne 0 ]; then
    echo "benchmark failed: ${name}" >&2
    sed -n '1,160p' "${log_file}" >&2
    exit "${status}"
  fi

  seconds="$(tail -n 1 "${time_file}" | tr -d '[:space:]')"
  millis="$(awk -v seconds="${seconds}" 'BEGIN { printf "%.3f", seconds * 1000 }')"
  add_result "${name}" "ms" "${millis}" "${extra}"
}

append_benchmark_metrics() {
  local source_json="$1"
  local kind="$2"
  local mode="$3"

  python3 - "${source_json}" "${kind}" "${mode}" "${results_jsonl}" "${rows_html}" <<'PY'
import html
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
kind = sys.argv[2]
mode = sys.argv[3]
results_jsonl = Path(sys.argv[4])
rows_html = Path(sys.argv[5])


def as_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def format_value(value):
    numeric = as_float(value)
    if numeric is None:
        return None
    return round(numeric, 6)


def append_metric(name, unit, value, extra):
    formatted = format_value(value)
    if formatted is None:
        return
    record = {
        "name": name,
        "unit": unit,
        "value": formatted,
        "extra": extra,
    }
    with results_jsonl.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, separators=(",", ":")) + "\n")
    with rows_html.open("a", encoding="utf-8") as handle:
        handle.write(
            "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>\n".format(
                html.escape(name),
                formatted,
                html.escape(unit),
                html.escape(extra),
            )
        )


data = json.loads(source.read_text(encoding="utf-8"))
source_name = source.name

if kind == "m23":
    metadata = data.get("metadata", {})
    quick_value = metadata.get("quick", mode == "quick")
    quick = str(quick_value).lower() if isinstance(quick_value, bool) else str(quick_value)
    for metric in data.get("metrics", []):
        direction = metric.get("direction", "")
        unit = metric.get("unit", "count")
        suite = metric.get("suite", "unknown-suite")
        metric_name = metric.get("name", "unnamed metric")
        value = as_float(metric.get("value"))
        if value is None:
            continue
        extra = (
            f"quick={quick}; suite={suite}; direction={direction}; "
            f"status={metric.get('status', 'unknown')}; source={source_name}"
        )
        if direction == "lower-is-better":
            append_metric(f"Reprobuild {suite}: {metric_name}", unit, value, extra)
        elif direction == "higher-is-better" and unit == "actions/sec" and value > 0:
            append_metric(
                f"Reprobuild {suite}: generated action latency",
                "ms/action",
                1000.0 / value,
                extra + f"; original={value} actions/sec",
            )
elif kind == "cmake":
    profile = data.get("profile", mode)
    metadata = data.get("metadata", {})
    parallel = metadata.get("parallel", "unknown")
    noop_runs = metadata.get("noopRuns", "unknown")
    for ratio in data.get("ratioSummary", []):
        project = ratio.get("project", "unknown-project")
        scenario = ratio.get("scenario", "unknown-scenario")
        execution_mode = ratio.get("executionMode", "unknown-mode")
        base = f"CMake {profile} {project} {execution_mode} {scenario}"
        extra = (
            f"profile={profile}; parallel={parallel}; noop_runs={noop_runs}; "
            f"status={ratio.get('status', 'unknown')}; source={source_name}"
        )
        append_metric(
            f"{base}: reprobuild/ninja wall ratio",
            "ratio",
            ratio.get("ratioReprobuildToNinja"),
            extra,
        )
        append_metric(
            f"{base}: reprobuild wall",
            "ms",
            ratio.get("reprobuildWallMs"),
            extra,
        )
        append_metric(
            f"{base}: ninja wall",
            "ms",
            ratio.get("ninjaWallMs"),
            extra,
        )
else:
    raise SystemExit(f"unknown benchmark json kind: {kind}")
PY
}

emit_json() {
  python3 - "${results_jsonl}" <<'PY'
import json
import sys
from pathlib import Path

records = []
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if line.strip():
        records.append(json.loads(line))
print(json.dumps(records, separators=(",", ":")))
PY
}

write_report() {
  local json_results="$1"
  local generated_at
  local commit
  local host
  local cpu
  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  commit="$(git rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
  host="$(uname -sm 2>/dev/null || printf 'unknown')"
  cpu="$(uname -p 2>/dev/null || printf 'unknown')"

  {
    cat <<HTML
<!doctype html>
<meta charset="utf-8">
<title>Reprobuild Benchmark Report</title>
<style>
body { font-family: system-ui, sans-serif; margin: 2rem; color: #202124; }
table { border-collapse: collapse; width: 100%; margin-top: 1rem; }
th, td { border: 1px solid #d0d7de; padding: 0.5rem; text-align: left; vertical-align: top; }
th { background: #f6f8fa; }
code { background: #f6f8fa; padding: 0.1rem 0.25rem; }
</style>
<h1>Reprobuild Benchmark Report</h1>
<p>Generated: <code>$(html_escape "${generated_at}")</code></p>
<p>Commit: <code>$(html_escape "${commit}")</code></p>
<p>Host: <code>$(html_escape "${host}")</code></p>
<p>CPU: <code>$(html_escape "${cpu}")</code></p>
<p>Mode: <code>quick=$(html_escape "${quick}")</code></p>
<p>Suites: <code>$(html_escape "${benchmark_suites}")</code></p>
<table>
<thead><tr><th>Metric</th><th>Value</th><th>Unit</th><th>Context</th></tr></thead>
<tbody>
HTML
    cat "${rows_html}"
    cat <<HTML
</tbody>
</table>
<script type="application/json" id="benchmark-results">
${json_results}
</script>
HTML
  } > bench-results/report.html
}

run_m0_suite() {
  local nim_sources
  local c_sources
  local example_projects
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
}

run_m23_suite() {
  local args=()
  if [ "${quick}" = true ]; then
    args+=(--quick)
  fi

  echo "running Reprobuild M23 production benchmark suite (quick=${quick})" >&2
  REPROBUILD_BUILD_MODE=release ./scripts/run-m23-benchmark.sh "${args[@]}" >&2
  append_benchmark_metrics bench-results/reprobuild-core-mvp-performance.json m23 "${quick}"
}

run_cmake_suite() {
  local profile="default"
  local output="bench-results/cmake-reprobuild-vs-ninja-policy-default.json"
  local args=()

  if [ "${quick}" = true ]; then
    profile="quick"
    output="bench-results/cmake-reprobuild-vs-ninja-policy-quick.json"
  fi

  if [ ! -x ../reprobuild-cmake/build/bin/cmake ]; then
    if [ "${quick}" = true ]; then
      echo "skipping CMake competitiveness benchmark: missing ../reprobuild-cmake/build/bin/cmake" >&2
      return 0
    fi
    echo "missing ../reprobuild-cmake/build/bin/cmake; build the CMake fork before full benchmarks" >&2
    exit 2
  fi

  args+=(--profile "${profile}")
  args+=(--output "${output}")
  args+=(--execution-mode both)

  echo "running CMake Reprobuild vs Ninja benchmark suite (profile=${profile})" >&2
  ./scripts/run-cmake-generator-competitiveness-benchmark.sh "${args[@]}" >&2
  append_benchmark_metrics "${output}" cmake "${profile}"
}

if suite_enabled m0; then
  run_m0_suite
fi

if suite_enabled m23; then
  run_m23_suite
fi

if suite_enabled cmake; then
  run_cmake_suite
fi

json_results="$(emit_json)"
write_report "${json_results}"
printf '%s\n' "${json_results}"
