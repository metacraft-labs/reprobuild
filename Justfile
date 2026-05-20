set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

REPOMIX_OUT_DIR := env('REPOMIX_OUT_DIR', 'repomix')

default:
    just lint

build:
    mkdir -p test-logs
    bash ./scripts/build_apps.sh 2>&1 | tee test-logs/build.log

test:
    mkdir -p test-logs
    bash ./scripts/run_tests.sh 2>&1 | tee test-logs/test.log

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

e2e_repro_develop_cmake_configure_and_build:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_repro_develop_cmake_configure_and_build \
        --out:build/test-bin/e2e_repro_develop_cmake_configure_and_build \
        tests/e2e/cmake-develop/t_e2e_repro_develop_cmake.nim \
        2>&1 | tee test-logs/e2e_repro_develop_cmake_configure_and_build.log

e2e_repro_develop_cmake_tool_identity_changes_cache_key:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_repro_develop_cmake_tool_identity_changes_cache_key \
        --out:build/test-bin/e2e_repro_develop_cmake_tool_identity_changes_cache_key \
        tests/e2e/cmake-develop/t_e2e_repro_develop_cmake.nim \
        2>&1 | tee test-logs/e2e_repro_develop_cmake_tool_identity_changes_cache_key.log

e2e_repro_develop_cmake_path_vs_nix_portability:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_repro_develop_cmake_path_vs_nix_portability \
        --out:build/test-bin/e2e_repro_develop_cmake_path_vs_nix_portability \
        tests/e2e/cmake-develop/t_e2e_repro_develop_cmake.nim \
        2>&1 | tee test-logs/e2e_repro_develop_cmake_path_vs_nix_portability.log

e2e_reprobuild_generated_cmake_provider_suite:
    mkdir -p test-logs
    log="$(pwd)/test-logs/e2e_reprobuild_generated_cmake_provider_suite.log" && \
    cd ../reprobuild-cmake/build && \
        ctest --output-on-failure -R '^e2e_cmake_reprobuild_generated_feature_matrix$' \
        2>&1 | tee "$log"

e2e_reprobuild_cmake_m11_coverage_default:
    mkdir -p test-logs
    log="$(pwd)/test-logs/e2e_reprobuild_cmake_m11_coverage_default.log" && \
    cd ../reprobuild-cmake/build && \
        ctest --output-on-failure -R '^e2e_cmake_reprobuild_(compatibility_suite|generated_feature_matrix|real_project_matrix)$' \
        2>&1 | tee "$log"

e2e_reprobuild_cmake_m11_coverage_medium:
    mkdir -p test-logs
    log="$(pwd)/test-logs/e2e_reprobuild_cmake_m11_coverage_medium.log" && \
    cd ../reprobuild-cmake && \
        build/bin/cmake \
          -DCMAKE_COMMAND="$(pwd)/build/bin/cmake" \
          -DTEST_MODE=real_project_matrix \
          -DTEST_REAL_PROJECT_PROFILE=medium \
          -DTEST_BINARY_ROOT="$(pwd)/build/Tests/RunCMake/ReprobuildGenerator/m11-real-project-matrix-medium-just" \
          -DTEST_C_COMPILER="$$(cd build && bin/cmake -LA -N . | sed -n 's/^CMAKE_C_COMPILER:[^=]*=//p')" \
          -DTEST_CXX_COMPILER="$$(cd build && bin/cmake -LA -N . | sed -n 's/^CMAKE_CXX_COMPILER:[^=]*=//p')" \
          -DTEST_REPROBUILD_SOURCE_ROOT="$(cd ../reprobuild && pwd)" \
          -DTEST_REPROBUILD_REPO="$(cd ../reprobuild && pwd)" \
          -DTEST_REPROBUILD_REPRO="$(cd ../reprobuild && pwd)/build/bin/repro" \
          -DTEST_RUNQUOTAD="$(cd ../runquota && pwd)/build/bin/runquotad" \
          -P Tests/RunCMake/ReprobuildGenerator/e2e.cmake \
        2>&1 | tee "$log"

e2e_reprobuild_cmake_m11_coverage_nightly:
    mkdir -p test-logs
    log="$(pwd)/test-logs/e2e_reprobuild_cmake_m11_coverage_nightly.log" && \
    cd ../reprobuild-cmake && \
        build/bin/cmake \
          -DCMAKE_COMMAND="$(pwd)/build/bin/cmake" \
          -DTEST_MODE=real_project_matrix \
          -DTEST_REAL_PROJECT_PROFILE=nightly \
          -DTEST_BINARY_ROOT="$(pwd)/build/Tests/RunCMake/ReprobuildGenerator/m11-real-project-matrix-nightly-just" \
          -DTEST_C_COMPILER="$$(cd build && bin/cmake -LA -N . | sed -n 's/^CMAKE_C_COMPILER:[^=]*=//p')" \
          -DTEST_CXX_COMPILER="$$(cd build && bin/cmake -LA -N . | sed -n 's/^CMAKE_CXX_COMPILER:[^=]*=//p')" \
          -DTEST_REPROBUILD_SOURCE_ROOT="$(cd ../reprobuild && pwd)" \
          -DTEST_REPROBUILD_REPO="$(cd ../reprobuild && pwd)" \
          -DTEST_REPROBUILD_REPRO="$(cd ../reprobuild && pwd)/build/bin/repro" \
          -DTEST_RUNQUOTAD="$(cd ../runquota && pwd)/build/bin/runquotad" \
          -P Tests/RunCMake/ReprobuildGenerator/e2e.cmake \
        2>&1 | tee "$log"

lint:
    mkdir -p test-logs
    bash ./scripts/check_repo_requirements.sh 2>&1 | tee test-logs/lint.log
    bash ./scripts/check_nim_sources.sh 2>&1 | tee -a test-logs/lint.log

format:
    bash ./scripts/format_sources.sh

fmt: format

bump-version version:
    bash ./scripts/bump_version.sh {{version}}

bench *args:
    mkdir -p bench-results test-logs
    bash ./scripts/collect-benchmark-metrics.sh {{args}} > bench-results/benchmark_results.json 2> >(tee test-logs/bench.log >&2)

bench-quick:
    just bench --quick

bench_reprobuild_core_mvp_performance *args:
    mkdir -p bench-results test-logs
    bash ./scripts/run-m23-benchmark.sh {{args}} 2> >(tee test-logs/bench_reprobuild_core_mvp_performance.log >&2)

bench_cmake_reprobuild_vs_ninja *args:
    mkdir -p bench-results test-logs
    bash ./scripts/run-cmake-generator-competitiveness-benchmark.sh \
        --profile default \
        --output bench-results/cmake-reprobuild-vs-ninja-default.json \
        {{args}} \
        2> >(tee test-logs/bench_cmake_reprobuild_vs_ninja.log >&2)

bench_cmake_reprobuild_vs_ninja_quick *args:
    mkdir -p bench-results test-logs
    bash ./scripts/run-cmake-generator-competitiveness-benchmark.sh \
        --profile quick \
        --output bench-results/cmake-reprobuild-vs-ninja-quick.json \
        {{args}} \
        2> >(tee test-logs/bench_cmake_reprobuild_vs_ninja_quick.log >&2)

bench_cmake_reprobuild_vs_ninja_medium *args:
    mkdir -p bench-results test-logs
    bash ./scripts/run-cmake-generator-competitiveness-benchmark.sh \
        --profile medium \
        --output bench-results/cmake-reprobuild-vs-ninja-medium.json \
        {{args}} \
        2> >(tee test-logs/bench_cmake_reprobuild_vs_ninja_medium.log >&2)

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

e2e_scoop_adapter_realize_and_launch:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_scoop_adapter_realize_and_launch \
        --out:build/test-bin/e2e_scoop_adapter_realize_and_launch \
        tests/e2e/scoop/t_e2e_scoop_adapter_realize_and_launch.nim \
        2>&1 | tee test-logs/e2e_scoop_adapter_realize_and_launch.log

e2e_scoop_adapter_diagnostics:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_scoop_adapter_diagnostics \
        --out:build/test-bin/e2e_scoop_adapter_diagnostics \
        tests/e2e/scoop/t_e2e_scoop_adapter_diagnostics.nim \
        2>&1 | tee test-logs/e2e_scoop_adapter_diagnostics.log

e2e_scoop_practical_hardening:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_scoop_practical_hardening \
        --out:build/test-bin/e2e_scoop_practical_hardening \
        tests/e2e/scoop/t_e2e_scoop_practical_hardening.nim \
        2>&1 | tee test-logs/e2e_scoop_practical_hardening.log

integration_local_store_layout_and_atomic_writes:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_local_store_layout_and_atomic_writes \
        --out:build/test-bin/integration_local_store_layout_and_atomic_writes \
        tests/integration/t_integration_local_store_layout_and_atomic_writes.nim \
        2>&1 | tee test-logs/integration_local_store_layout_and_atomic_writes.log

integration_local_store_gc:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_local_store_gc \
        --out:build/test-bin/integration_local_store_gc \
        tests/integration/t_integration_local_store_gc.nim \
        2>&1 | tee test-logs/integration_local_store_gc.log

e2e_local_store_unified_across_adapters:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_local_store_unified_across_adapters \
        --out:build/test-bin/e2e_local_store_unified_across_adapters \
        tests/e2e/external-packages/t_e2e_local_store_unified_across_adapters.nim \
        2>&1 | tee test-logs/e2e_local_store_unified_across_adapters.log

integration_launch_plan_binding_strategies:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_launch_plan_binding_strategies \
        --out:build/test-bin/integration_launch_plan_binding_strategies \
        tests/integration/t_integration_launch_plan_binding_strategies.nim \
        2>&1 | tee test-logs/integration_launch_plan_binding_strategies.log

e2e_windows_launcher_isolation:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_windows_launcher_isolation \
        --out:build/test-bin/e2e_windows_launcher_isolation \
        tests/e2e/launcher-isolation/t_e2e_windows_launcher_isolation.nim \
        2>&1 | tee test-logs/e2e_windows_launcher_isolation.log

repro_launcher_binary:
    mkdir -p test-logs build/nimcache
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro-launcher \
        --out:build/repro-launcher.exe \
        apps/repro-launcher/repro_launcher.nim \
        2>&1 | tee test-logs/repro_launcher_binary.log

integration_provider_fragment_refresh_and_pruning:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_provider_fragment_refresh_and_pruning \
        --out:build/test-bin/integration_provider_fragment_refresh_and_pruning \
        tests/integration/t_integration_provider_fragment_refresh_and_pruning.nim \
        2>&1 | tee test-logs/integration_provider_fragment_refresh_and_pruning.log

integration_configurable_system_basic_resolution:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_configurable_system_basic_resolution \
        --out:build/test-bin/integration_configurable_system_basic_resolution \
        tests/integration/t_integration_configurable_system_basic_resolution.nim \
        2>&1 | tee test-logs/integration_configurable_system_basic_resolution.log

integration_configurable_system_incremental_refinalize:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_configurable_system_incremental_refinalize \
        --out:build/test-bin/integration_configurable_system_incremental_refinalize \
        tests/integration/t_integration_configurable_system_incremental_refinalize.nim \
        2>&1 | tee test-logs/integration_configurable_system_incremental_refinalize.log

integration_configurable_persistent_lookup:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_configurable_persistent_lookup \
        --out:build/test-bin/integration_configurable_persistent_lookup \
        tests/integration/t_integration_configurable_persistent_lookup.nim \
        2>&1 | tee test-logs/integration_configurable_persistent_lookup.log

integration_configurable_staged_field_access:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_configurable_staged_field_access \
        --out:build/test-bin/integration_configurable_staged_field_access \
        tests/integration/t_integration_configurable_staged_field_access.nim \
        2>&1 | tee test-logs/integration_configurable_staged_field_access.log

integration_configurable_doc_comment_directives:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_configurable_doc_comment_directives \
        --out:build/test-bin/integration_configurable_doc_comment_directives \
        tests/integration/t_integration_configurable_doc_comment_directives.nim \
        2>&1 | tee test-logs/integration_configurable_doc_comment_directives.log

e2e_configurable_system_in_dsl:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_configurable_system_in_dsl \
        --out:build/test-bin/e2e_configurable_system_in_dsl \
        tests/e2e/configurable-system/t_e2e_configurable_system_in_dsl.nim \
        2>&1 | tee test-logs/e2e_configurable_system_in_dsl.log

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
    bash ./scripts/check_repo_requirements.sh
