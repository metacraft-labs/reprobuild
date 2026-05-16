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
