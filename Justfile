set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

REPOMIX_OUT_DIR := env('REPOMIX_OUT_DIR', 'repomix')

default:
    just lint

build:
    mkdir -p test-logs
    ./scripts/build_apps.sh 2>&1 | tee test-logs/build.log

test:
    mkdir -p test-logs
    ./scripts/run_tests.sh 2>&1 | tee test-logs/test.log

t: test

integration-stackable-hooks:
    mkdir -p test-logs
    nim c -r \
        --nimcache:build/nimcache/integration-stackable-hooks \
        --out:build/test-bin/t_stackable_hooks_extracted_process_tree \
        tests/integration/t_stackable_hooks_extracted_process_tree.nim \
        2>&1 | tee test-logs/integration-stackable-hooks.log
    cd /Users/zahary/metacraft/ct_interpose && direnv exec /Users/zahary/metacraft/codetracer-native-recorder nimble test \
        2>&1 | tee -a /Users/zahary/metacraft/reprobuild/test-logs/integration-stackable-hooks.log

e2e-debug-fs-snoop:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --nimcache:build/nimcache/e2e-debug-fs-snoop \
        --out:build/test-bin/e2e_debug_fs_snoop_reads_monitor_depfile \
        tests/e2e/fs-snoop/t_debug_fs_snoop_reads_monitor_depfile.nim \
        2>&1 | tee test-logs/e2e-debug-fs-snoop.log

e2e-macos-monitor-shim-event-taxonomy:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e-macos-monitor-shim-event-taxonomy \
        --out:build/test-bin/e2e_macos_monitor_shim_event_taxonomy \
        tests/e2e/macos-monitor/t_macos_monitor_shim_event_taxonomy.nim \
        2>&1 | tee test-logs/e2e-macos-monitor-shim-event-taxonomy.log

lint:
    mkdir -p test-logs
    ./scripts/check_repo_requirements.sh 2>&1 | tee test-logs/lint.log
    ./scripts/check_nim_sources.sh 2>&1 | tee -a test-logs/lint.log

format:
    ./scripts/format_sources.sh

fmt: format

bump-version version:
    ./scripts/bump_version.sh {{version}}

bench *args:
    mkdir -p bench-results test-logs
    ./scripts/collect-benchmark-metrics.sh {{args}} > bench-results/benchmark_results.json 2> >(tee test-logs/bench.log >&2)

bench-quick:
    just bench --quick

integration-build-engine-api:
    mkdir -p test-logs build/test-bin build/nimcache
    cd ../runquota && just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration-build-engine-api \
        --out:build/test-bin/integration_build_engine_api_ready_queue \
        tests/integration/t_integration_build_engine_api_ready_queue.nim \
        2>&1 | tee test-logs/integration-build-engine-api.log

integration-dependency-reports:
    mkdir -p test-logs build/test-bin build/nimcache
    cd ../runquota && just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration-dependency-reports \
        --out:build/test-bin/integration_dependency_report_and_converter_paths \
        tests/integration/t_dependency_report_and_converter_paths.nim \
        2>&1 | tee test-logs/integration-dependency-reports.log

repomix *args:
    mkdir -p {{REPOMIX_OUT_DIR}}
    repomix \
        . \
        --output {{REPOMIX_OUT_DIR}}/Reprobuild.md \
        --style markdown \
        --header-text "Reprobuild public repository" \
        --ignore "repomix/**,bench-results/**,build/**,references/**" \
        {{args}}

check-repo-requirements:
    ./scripts/check_repo_requirements.sh
