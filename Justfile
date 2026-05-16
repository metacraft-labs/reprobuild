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

e2e_local_reprobuild_project_build:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_local_reprobuild_project_build \
        --out:build/test-bin/e2e_local_reprobuild_project_build \
        tests/e2e/local-build-engine/t_e2e_local_reprobuild_project_build.nim \
        2>&1 | tee test-logs/e2e_local_reprobuild_project_build.log

e2e_codetracer_build_subset_without_tup:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_codetracer_build_subset_without_tup \
        --out:build/test-bin/e2e_codetracer_build_subset_without_tup \
        tests/e2e/codetracer-subset/t_e2e_codetracer_build_subset_without_tup.nim \
        2>&1 | tee test-logs/e2e_codetracer_build_subset_without_tup.log

e2e_codetracer_in_place_project_file:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_codetracer_in_place_project_file \
        --out:build/test-bin/e2e_codetracer_in_place_project_file \
        tests/e2e/codetracer-subset/t_e2e_codetracer_in_place_project_file.nim \
        2>&1 | tee test-logs/e2e_codetracer_in_place_project_file.log

e2e_repro_watch:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_repro_watch \
        --out:build/test-bin/e2e_repro_watch \
        tests/e2e/watch/t_e2e_repro_watch.nim \
        2>&1 | tee test-logs/e2e_repro_watch.log

e2e_codetracer_dev_environment_slice:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_codetracer_dev_environment_slice \
        --out:build/test-bin/e2e_codetracer_dev_environment_slice \
        tests/e2e/codetracer-subset/t_e2e_codetracer_dev_environment_slice.nim \
        2>&1 | tee test-logs/e2e_codetracer_dev_environment_slice.log

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

bench_reprobuild_core_mvp_performance *args:
    mkdir -p bench-results test-logs
    ./scripts/run-m23-benchmark.sh {{args}} 2> >(tee test-logs/bench_reprobuild_core_mvp_performance.log >&2)

e2e_reprobuild_mvp_acceptance:
    mkdir -p test-logs
    bash ./scripts/run-m24-acceptance.sh 2>&1 | tee test-logs/e2e_reprobuild_mvp_acceptance.log

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

integration_scheduler_dependency_gathering_policies:
    mkdir -p test-logs build/test-bin build/nimcache
    cd ../runquota && just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_scheduler_dependency_gathering_policies \
        --out:build/test-bin/integration_scheduler_dependency_gathering_policies \
        tests/integration/t_integration_scheduler_dependency_gathering_policies.nim \
        2>&1 | tee test-logs/integration_scheduler_dependency_gathering_policies.log

integration_reprobuild_sessions_share_runquota:
    mkdir -p test-logs build/test-bin build/nimcache
    cd ../runquota && just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_reprobuild_sessions_share_runquota \
        --out:build/test-bin/integration_reprobuild_sessions_share_runquota \
        tests/integration/t_integration_reprobuild_sessions_share_runquota.nim \
        2>&1 | tee test-logs/integration_reprobuild_sessions_share_runquota.log

integration_hcr_reference_corpus_and_object_inputs:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_hcr_reference_corpus_and_object_inputs \
        --out:build/test-bin/integration_hcr_reference_corpus_and_object_inputs \
        tests/integration/t_integration_hcr_reference_corpus_and_object_inputs.nim \
        2>&1 | tee test-logs/integration_hcr_reference_corpus_and_object_inputs.log

integration_hcr_linkgraph_relocation_classification:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_hcr_linkgraph_relocation_classification \
        --out:build/test-bin/integration_hcr_linkgraph_relocation_classification \
        tests/integration/t_integration_hcr_linkgraph_relocation_classification.nim \
        2>&1 | tee test-logs/integration_hcr_linkgraph_relocation_classification.log

e2e_hcr_in_target_link_and_trampoline:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_hcr_in_target_link_and_trampoline \
        --out:build/test-bin/e2e_hcr_in_target_link_and_trampoline \
        tests/e2e/hcr-direct-linker/t_e2e_hcr_in_target_link_and_trampoline.nim \
        2>&1 | tee test-logs/e2e_hcr_in_target_link_and_trampoline.log

e2e_hcr_direct_patch_debug_unwind_replay:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_hcr_direct_patch_debug_unwind_replay \
        --out:build/test-bin/e2e_hcr_direct_patch_debug_unwind_replay \
        tests/e2e/hcr-debug-unwind/t_e2e_hcr_direct_patch_debug_unwind_replay.nim \
        2>&1 | tee test-logs/e2e_hcr_direct_patch_debug_unwind_replay.log

integration_provider_fragment_refresh_and_pruning:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_provider_fragment_refresh_and_pruning \
        --out:build/test-bin/integration_provider_fragment_refresh_and_pruning \
        tests/integration/t_integration_provider_fragment_refresh_and_pruning.nim \
        2>&1 | tee test-logs/integration_provider_fragment_refresh_and_pruning.log

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
