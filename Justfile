set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

REPOMIX_OUT_DIR := env('REPOMIX_OUT_DIR', 'repomix')

default:
    just lint

build:
    mkdir -p test-logs
    bash ./scripts/build_apps.sh 2>&1 | tee test-logs/build.log

# Bootstrap-And-Self-Build B5: materialise ./build/bin/repro from nim
# when not already on disk. Idempotent — no-op when the binary already
# exists; otherwise drives scripts/build_apps.sh to compile every
# entrypoint in apps/entrypoints.txt (including ``repro``) via the
# same path the engine-built ``apps`` collection uses. The ``test``
# recipe + ``scripts/run_tests.sh`` call this first so a fresh checkout
# without a pre-built engine binary still boots.
bootstrap:
    @if [ ! -x ./build/bin/repro ]; then \
        echo "bootstrapping ./build/bin/repro from nim..."; \
        mkdir -p test-logs; \
        bash ./scripts/build_apps.sh 2>&1 | tee test-logs/bootstrap.log; \
    else \
        echo "./build/bin/repro already exists; skipping bootstrap"; \
    fi

test:
    mkdir -p test-logs
    bash ./scripts/run_tests.sh 2>&1 | tee test-logs/test.log

t: test

dev-env-full-regression:
    mkdir -p test-logs
    bash ./scripts/run_tests.sh 2>&1 | tee test-logs/dev-env-full-regression.log

integration-stackable-hooks:
    mkdir -p test-logs
    nim c -r \
        --nimcache:build/nimcache/integration-stackable-hooks \
        --out:build/test-bin/t_stackable_hooks_extracted_process_tree \
        tests/integration/t_stackable_hooks_extracted_process_tree.nim \
        2>&1 | tee test-logs/integration-stackable-hooks.log

# NDE0-A apt-jammy adapter unit tests.
# Exercises spec'd extractAptDeb / installAptDeb / installSystemdUnit
# against pre-fetched jammy .deb fixtures under
# recipes/reproos-mvp-config/vendored-archives/linux/.
unit_nde0a_apt_jammy:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/unit_nde0a_apt_jammy \
        --out:build/test-bin/t_nde0a_apt_jammy \
        libs/repro_dsl_stdlib/tests/t_nde0a_apt_jammy.nim \
        2>&1 | tee test-logs/unit_nde0a_apt_jammy.log

# NDE0-S native systemd-session package unit tests.
# Exercises spec'd materializeSystemdSession + minimal-viable
# fs.configFile / fs.managedBlock helpers (PAM stacks, /etc/passwd +
# /etc/group user blocks, serial-getty autologin drop-in, systemd-logind
# un-mask, user-session graphical-session targets). Configurable-driven
# cache-key invalidation per the spec NDE0-S acceptance criteria.
unit_nde0s_systemd_session:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/unit_nde0s_systemd_session \
        --out:build/test-bin/t_nde0s_systemd_session \
        libs/repro_dsl_stdlib/tests/t_nde0s_systemd_session.nim \
        2>&1 | tee test-logs/unit_nde0s_systemd_session.log

# NDE0-D native dbus-broker package unit tests.
# Exercises spec'd materializeDbusBroker — dbus.socket + dbus.service
# unit files planted at /usr/lib/systemd/system/ (cascade-G fix; R9
# systemd 257.9 dropped /lib/systemd/system/ from UnitPath); messagebus
# system user managed blocks (NDE-spec-block triple-form sentinel);
# /var/lib/dbus spool placeholder; /etc/dbus-1/system.conf default
# policy; belt-and-braces /etc/systemd/system/dbus.socket symlink
# record. Configurable-driven cache-key invalidation
# (busActivationStrategy: broker | daemon) per NDE0-D acceptance.
unit_nde0d_dbus_broker:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/unit_nde0d_dbus_broker \
        --out:build/test-bin/t_nde0d_dbus_broker \
        libs/repro_dsl_stdlib/tests/t_nde0d_dbus_broker.nim \
        2>&1 | tee test-logs/unit_nde0d_dbus_broker.log

# NDE0-G native graphics-stack package unit tests.
# Exercises spec'd materializeGraphicsStack — /etc/ld.so.conf.d/
# 00-reproos-linux.conf libpaths managedBlock contribution (NDE-spec-block
# triple-form sentinel, priority=100 foundation sort key) + the
# /usr/lib/systemd/system/repro-ldconfig.service Type=oneshot linker-
# cascade unit (cascade-G fix; R9 systemd 257.9 dropped /lib/systemd/
# system/ from UnitPath) + belt-and-braces /etc/systemd/system/ record
# + multi-user.target.wants activation symlink record. Configurable-
# driven cache-key invalidation (aptSnapshot, enableHardwareGl,
# fontPackages) per NDE0-G acceptance.
unit_nde0g_graphics_stack:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/unit_nde0g_graphics_stack \
        --out:build/test-bin/t_nde0g_graphics_stack \
        libs/repro_dsl_stdlib/tests/t_nde0g_graphics_stack.nim \
        2>&1 | tee test-logs/unit_nde0g_graphics_stack.log

# NDE0-K native kernel package unit tests.
# Exercises spec'd materializeKernel — /build/config-used .config snapshot
# (6 spec'd CONFIG_X knobs: CONFIG_DRM, CONFIG_DRM_HYPERV, CONFIG_FB,
# CONFIG_USER_NS, CONFIG_OVERLAY_FS, CONFIG_VIRTIO_GPU; sorted-key
# emission for byte-stability; deterministic banner records
# kernelVersion + baseConfigVariant) + /build/bzImage v1 STUB (text
# marker recording source pin + configFile hash; deferred binary build)
# + /build/System.map v1 STUB + /build/KERNELRELEASE (resolved release
# string). Configurable-driven cache-key invalidation (all 6 enable*
# knobs + kernelVersion + baseConfigVariant) per NDE0-K acceptance.
# Closure-sharing acceptance #2 demonstrated at the package-output
# granularity: enableHypervDrm toggle re-keys configFile + bzImage +
# systemMap but leaves kernelRelease cached.
unit_nde0k_kernel:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/unit_nde0k_kernel \
        --out:build/test-bin/t_nde0k_kernel \
        libs/repro_dsl_stdlib/tests/t_nde0k_kernel.nim \
        2>&1 | tee test-logs/unit_nde0k_kernel.log

# NDE-H1 native sway compositor package unit tests.
# Exercises spec'd materializeSway — /etc/sway/config with
# configurable bindsym lines (superKey + terminalApp + launcherApp +
# extraModelines propagate to rendered content + content-addressed
# store path) + /etc/ld.so.conf.d/00-reproos-linux.conf libpaths
# managedBlock contribution (NDE-spec-block triple-form sentinel
# scope=system, packageName=sway, blockId=libpaths, priority=500
# compositor sort key) + /usr/lib/systemd/system/sway-session.service
# Type=oneshot user-session unit (cascade-G fix; R9 systemd 257.9
# dropped /lib/systemd/system/ from UnitPath) + /etc/wayland-sessions/
# sway.desktop XDG session entry. Naming decision: packageName="sway"
# (Tier-1 native is true to identity; Hyprland-the-package is the
# future NDE-Hp1 milestone).
unit_nde_h1_sway:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/unit_nde_h1_sway \
        --out:build/test-bin/t_nde_h1_sway \
        libs/repro_dsl_stdlib/tests/t_nde_h1_sway.nim \
        2>&1 | tee test-logs/unit_nde_h1_sway.log

# NDE-G1 native GNOME compositor package unit tests.
# Exercises spec'd materializeGnome — /etc/gdm3/custom.conf INI with
# configurable [daemon] keys (autoLogin + autoLoginUser +
# waylandSession + disableInitialSetup propagate to rendered content
# + content-addressed store path) + /etc/ld.so.conf.d/00-reproos-linux.conf
# libpaths managedBlock contribution (NDE-spec-block triple-form
# sentinel scope=system, packageName=gnome, blockId=libpaths,
# priority=500 compositor sort key) + /usr/lib/systemd/system/gdm.service
# Type=notify display-manager unit (cascade-G fix; R9 systemd 257.9
# dropped /lib/systemd/system/ from UnitPath) + /etc/wayland-sessions/
# gnome.desktop XDG session entry. Naming decision: packageName="gnome"
# (NOT sway / plasma / hyprland — sentinel regression guards
# encoded in the sentinel test).
unit_nde_g1_gnome:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/unit_nde_g1_gnome \
        --out:build/test-bin/t_nde_g1_gnome \
        libs/repro_dsl_stdlib/tests/t_nde_g1_gnome.nim \
        2>&1 | tee test-logs/unit_nde_g1_gnome.log

# NDE-K1 native KDE Plasma compositor package unit tests.
# Exercises spec'd materializePlasma — /etc/sddm.conf INI with
# configurable [Autologin]/[General] keys (sddmAutoLogin +
# sddmAutoLoginUser + waylandSession propagate to rendered content
# + content-addressed store path; spec NDE-K1 acceptance literal:
# sddmAutoLogin toggle re-keys only /etc/sddm.conf) +
# /etc/ld.so.conf.d/00-reproos-linux.conf libpaths managedBlock
# contribution (NDE-spec-block triple-form sentinel scope=system,
# packageName=plasma (NOT sway/gnome/hyprland — sentinel regression
# guards), blockId=libpaths, priority=500 compositor sort key, 5
# bundle pins: kwin + plasma-workspace + plasma-desktop +
# kf5-frameworks + qt5-base) + /usr/lib/systemd/system/sddm.service
# Type=simple display-manager unit at cascade-G path (ExecStart=
# /usr/bin/sddm, WantedBy=graphical.target, Requires=dbus.service)
# + /etc/wayland-sessions/plasma.desktop XDG session entry (Name=
# "Plasma (Wayland)", Exec=/usr/bin/startplasma-wayland,
# Type=Application, DesktopNames=KDE) + /etc/pipewire/pipewire.conf
# daemon config (pipewireEnabled propagates ENABLED/DISABLED
# branches; both re-key the output).
unit_nde_k1_plasma:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/unit_nde_k1_plasma \
        --out:build/test-bin/t_nde_k1_plasma \
        libs/repro_dsl_stdlib/tests/t_nde_k1_plasma.nim \
        2>&1 | tee test-logs/unit_nde_k1_plasma.log

# NDEM1 native reproos-desktop system-level package unit tests.
# MAJOR integration milestone: composes NDE-H1 sway + NDE-G1 gnome +
# NDE-K1 plasma + the 4 foundation packages under a variant +
# configurable scheme. Exercises the spec'd
# materializeReproosDesktop: variant desktopKind (closure-affecting,
# multi-valued seq[DesktopKind]) + configurable activeAtBoot
# (activation-only, DesktopKind) + the validate: activeAtBoot in
# desktopKind constraint (raises EConfigViolation); the multi-
# contributor managedBlock merge on
# /etc/ld.so.conf.d/00-reproos-linux.conf with NDE-spec-block sort
# order (priority, packageName, blockId); the display-manager
# activation symlink intent at
# /etc/systemd/system/display-manager.service; the NixOS-style
# generation manifest content-addressed across BOTH variant and
# configurable. 14 unit tests covering: validate success +
# rejection, materializer rejection via EConfigViolation, variant
# closure differs, configurable swap leaves mergedLdConf identical
# but display-manager target differs, sort order (graphics-stack
# priority 100 first; compositors alphabetical), sentinel
# discipline, removing contributor leaves others byte-identical,
# idempotency, generationId variant + configurable separation,
# per-DesktopKind display-manager target, manifest contents,
# storePaths sorted.
unit_ndem1_reproos_desktop:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/unit_ndem1_reproos_desktop \
        --out:build/test-bin/t_ndem1_reproos_desktop \
        libs/repro_dsl_stdlib/tests/t_ndem1_reproos_desktop.nim \
        2>&1 | tee test-logs/unit_ndem1_reproos_desktop.log

# NDEM2 native generation-log persistence + rollback unit tests.
# Exercises the spec'd manifest-level acceptance for NixOS-style
# generation switching (NDE-H2/G2/K2 boot-level tests remain blocked
# on .deb extraction + activation runtime). Validates: empty-log
# active() failure path, addGeneration entry + idempotency,
# activeGeneration newest-wins, rollback returns prior generation,
# single-entry rollback failure path, VARIANT switch produces
# different closure (storePaths differ), CONFIGURABLE switch produces
# identical closure but different activation (displayManagerSymlink
# target differs), lookupGeneration historical query,
# serializeGenerationLog determinism (byte-identity),
# deserializeGenerationLog round-trip + version-mismatch rejection,
# no-in-place-mutation byte-identity of historical manifest after
# subsequent appends, sortedByTimestamp sibling read view. 14 unit
# tests.
unit_ndem2_generation_log:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/unit_ndem2_generation_log \
        --out:build/test-bin/t_ndem2_generation_log \
        libs/repro_dsl_stdlib/tests/t_ndem2_generation_log.nim \
        2>&1 | tee test-logs/unit_ndem2_generation_log.log

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

# Peer-Cache-BearSSL M5: opt-in 200-peer in-process simulation under
# tmTls with the real BearSSL TLS 1.2 record-layer pump engaged. The
# default sim run (no --tls-enabled) short-circuits the TLS wrap and
# still exercises real ECDSA-P256 sign + verify on the seeded
# AdvertiseV2 payload; this target is the explicit opt-in that pays
# the TLS-on-self-talk cost so the wrap is verified end-to-end.
bench-peer-cache-bearssl-tls:
    mkdir -p bench-results test-logs build/test-bin build/nimcache
    BEARSSL_SRC="${BEARSSL_SRC:-/tmp/m0-bearssl/nim-bearssl}" \
    nim c -r -d:release --hints:off \
        --nimcache:build/nimcache/repro-peer-cache-bearssl-tls \
        --out:build/test-bin/repro_peer_cache_sim_bearssl_tls \
        apps/repro-peer-cache-sim/repro_peer_cache_sim.nim \
        --trust-mode=tmTls --tls-enabled=true \
        --out=bench-results/peer-cache-bearssl-tls-demonstration.md \
        2>&1 | tee test-logs/bench-peer-cache-bearssl-tls.log

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

local-daemons-m0:
    mkdir -p test-logs build/test-bin build/nimcache
    just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/local-daemons-m0 \
        --out:build/test-bin/local_daemons_m0 \
        tests/integration/t_local_daemons_control_plane_m0.nim \
        2>&1 | tee test-logs/local-daemons-m0.log

local-daemons-m1:
    mkdir -p test-logs build/test-bin build/nimcache
    just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/local-daemons-m1 \
        --out:build/test-bin/local_daemons_m1 \
        tests/integration/t_local_daemons_control_plane_m1.nim \
        2>&1 | tee test-logs/local-daemons-m1.log

local-daemons-m2:
    mkdir -p test-logs build/test-bin build/nimcache
    just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/local-daemons-m2 \
        --out:build/test-bin/local_daemons_m2 \
        tests/integration/t_local_daemons_control_plane_m2.nim \
        2>&1 | tee test-logs/local-daemons-m2.log

local-daemons-m3:
    mkdir -p test-logs build/test-bin build/nimcache
    just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/local-daemons-m3 \
        --out:build/test-bin/local_daemons_m3 \
        tests/integration/t_local_daemons_control_plane_m3.nim \
        2>&1 | tee test-logs/local-daemons-m3.log

local-daemons-m4:
    mkdir -p test-logs build/test-bin build/nimcache
    just build
    cd ../runquota && just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/local-daemons-m4 \
        --out:build/test-bin/local_daemons_m4 \
        tests/integration/t_local_daemons_control_plane_m4.nim \
        2>&1 | tee test-logs/local-daemons-m4.log

local-daemons-m5:
    mkdir -p test-logs build/test-bin build/nimcache
    just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/local-daemons-m5 \
        --out:build/test-bin/local_daemons_m5 \
        tests/integration/t_local_daemons_control_plane_m5.nim \
        2>&1 | tee test-logs/local-daemons-m5.log

local-daemons-m6:
    mkdir -p test-logs build/test-bin build/nimcache
    just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/local-daemons-m6 \
        --out:build/test-bin/local_daemons_m6 \
        tests/integration/t_local_daemons_control_plane_m6.nim \
        2>&1 | tee test-logs/local-daemons-m6.log

local-daemons-m7:
    mkdir -p test-logs build/test-bin build/nimcache
    just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/local-daemons-m7 \
        --out:build/test-bin/local_daemons_m7 \
        tests/integration/t_local_daemons_control_plane_m7.nim \
        2>&1 | tee test-logs/local-daemons-m7.log

local-daemons-m8:
    mkdir -p test-logs build/test-bin build/nimcache
    just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/local-daemons-m8 \
        --out:build/test-bin/local_daemons_m8 \
        tests/integration/t_local_daemons_control_plane_m8.nim \
        2>&1 | tee test-logs/local-daemons-m8.log

local-daemons-m10:
    mkdir -p test-logs build/test-bin build/nimcache
    just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/local-daemons-m10 \
        --out:build/test-bin/local_daemons_m10 \
        tests/integration/t_local_daemons_control_plane_m10.nim \
        2>&1 | tee test-logs/local-daemons-m10.log

local-daemons-m11:
    mkdir -p test-logs build/test-bin build/nimcache
    just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/local-daemons-m11 \
        --out:build/test-bin/local_daemons_m11 \
        tests/integration/t_local_daemons_control_plane_m11.nim \
        2>&1 | tee test-logs/local-daemons-m11.log

store-daemon-m66-dev:
    mkdir -p test-logs build/test-bin build/nimcache
    just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/store-daemon-m66-dev \
        --out:build/test-bin/store_daemon_m66_dev \
        tests/integration/t_store_daemon_m66_dev.nim \
        2>&1 | tee test-logs/store-daemon-m66-dev.log

integration_daemon_nix_and_tarball_realize:
    mkdir -p test-logs build/test-bin build/nimcache
    just build
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_daemon_nix_and_tarball_realize \
        --out:build/test-bin/integration_daemon_nix_and_tarball_realize \
        tests/integration/t_integration_daemon_nix_and_tarball_realize.nim \
        2>&1 | tee test-logs/integration_daemon_nix_and_tarball_realize.log

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

e2e_generated_config_file_block_macro:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_generated_config_file_block_macro \
        --out:build/test-bin/e2e_generated_config_file_block_macro \
        tests/e2e/generated-config/t_e2e_generated_config_file_block_macro.nim \
        2>&1 | tee test-logs/e2e_generated_config_file_block_macro.log

e2e_generated_config_file_json_value:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_generated_config_file_json_value \
        --out:build/test-bin/e2e_generated_config_file_json_value \
        tests/e2e/generated-config/t_e2e_generated_config_file_json_value.nim \
        2>&1 | tee test-logs/e2e_generated_config_file_json_value.log

e2e_generated_config_file_external_template:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_generated_config_file_external_template \
        --out:build/test-bin/e2e_generated_config_file_external_template \
        tests/e2e/generated-config/t_e2e_generated_config_file_external_template.nim \
        2>&1 | tee test-logs/e2e_generated_config_file_external_template.log

e2e_generated_config_file_managed_block:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_generated_config_file_managed_block \
        --out:build/test-bin/e2e_generated_config_file_managed_block \
        tests/e2e/generated-config/t_e2e_generated_config_file_managed_block.nim \
        2>&1 | tee test-logs/e2e_generated_config_file_managed_block.log

e2e_managed_block_cache_key_isolation:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_managed_block_cache_key_isolation \
        --out:build/test-bin/e2e_managed_block_cache_key_isolation \
        tests/e2e/generated-config/t_e2e_managed_block_cache_key_isolation.nim \
        2>&1 | tee test-logs/e2e_managed_block_cache_key_isolation.log

smoke_repro_profile:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/smoke_repro_profile \
        --out:build/test-bin/smoke_repro_profile \
        libs/repro_profile/tests/t_smoke_repro_profile.nim \
        2>&1 | tee test-logs/smoke_repro_profile.log

smoke_repro_profile_intent:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/smoke_repro_profile_intent \
        --out:build/test-bin/smoke_repro_profile_intent \
        libs/repro_profile_intent/tests/t_smoke_repro_profile_intent.nim \
        2>&1 | tee test-logs/smoke_repro_profile_intent.log

e2e_repro_profile_compile:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/e2e_repro_profile_compile \
        --out:build/test-bin/e2e_repro_profile_compile \
        tests/e2e/m83/t_e2e_repro_profile_compile.nim \
        2>&1 | tee test-logs/e2e_repro_profile_compile.log

smoke_repro_profile_compile:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/smoke_repro_profile_compile \
        --out:build/test-bin/smoke_repro_profile_compile \
        libs/repro_profile_compile/tests/t_smoke_repro_profile_compile.nim \
        2>&1 | tee test-logs/smoke_repro_profile_compile.log

e2e_repro_profile_compile_via_action:
    mkdir -p test-logs build/test-bin build/nimcache build/bin
    bash ./scripts/build_apps.sh
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/e2e_repro_profile_compile_via_action \
        --out:build/test-bin/e2e_repro_profile_compile_via_action \
        tests/e2e/m83/t_e2e_repro_profile_compile_via_action.nim \
        2>&1 | tee test-logs/e2e_repro_profile_compile_via_action.log

smoke_module_imports:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/smoke_module_imports \
        --out:build/test-bin/smoke_module_imports \
        libs/repro_profile_compile/tests/t_smoke_module_imports.nim \
        2>&1 | tee test-logs/smoke_module_imports.log

e2e_profile_modules:
    mkdir -p test-logs build/test-bin build/nimcache build/bin
    bash ./scripts/build_apps.sh
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/e2e_profile_modules \
        --out:build/test-bin/e2e_profile_modules \
        tests/e2e/m83/t_e2e_profile_modules.nim \
        2>&1 | tee test-logs/e2e_profile_modules.log

e2e_compile_fail_is_hard_error:
    # M83 Phase F3 gate: profile compile failure is a HARD error
    # across `repro home apply`, `repro home apply --plan`, and
    # `repro home plan` (no legacy-parser auto-fallback).
    mkdir -p test-logs build/test-bin build/nimcache build/bin
    bash ./scripts/build_apps.sh
    nim c -r \
        --threads:on \
        --hints:off \
        --warnings:off \
        --nimcache:build/nimcache/e2e_compile_fail_is_hard_error \
        --out:build/test-bin/e2e_compile_fail_is_hard_error \
        tests/e2e/m83/t_e2e_compile_fail_is_hard_error.nim \
        2>&1 | tee test-logs/e2e_compile_fail_is_hard_error.log

integration_intent_layer_round_trip:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_intent_layer_round_trip \
        --out:build/test-bin/integration_intent_layer_round_trip \
        tests/e2e/home-intent/t_integration_intent_layer_round_trip.nim \
        2>&1 | tee test-logs/integration_intent_layer_round_trip.log

integration_intent_layer_config_section:
    mkdir -p test-logs build/test-bin build/nimcache
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_intent_layer_config_section \
        --out:build/test-bin/integration_intent_layer_config_section \
        tests/e2e/home-intent/t_integration_intent_layer_config_section.nim \
        2>&1 | tee test-logs/integration_intent_layer_config_section.log

e2e_repro_home_intent_commands:
    mkdir -p test-logs build/bin build/test-bin build/nimcache
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_repro_home_intent_commands.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_repro_home_intent_commands \
        --out:build/test-bin/e2e_repro_home_intent_commands \
        tests/e2e/home-intent/t_e2e_repro_home_intent_commands.nim \
        2>&1 | tee test-logs/e2e_repro_home_intent_commands.log

integration_pointer_envelope_and_history_enumeration:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/integration_pointer_envelope_and_history_enumeration.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_pointer_envelope_and_history_enumeration \
        --out:build/test-bin/integration_pointer_envelope_and_history_enumeration \
        tests/e2e/home-generations/t_integration_pointer_envelope_and_history_enumeration.nim \
        2>&1 | tee test-logs/integration_pointer_envelope_and_history_enumeration.log

integration_activation_manifest_dedup_in_cas:
    mkdir -p test-logs build/test-bin build/nimcache build/test-tmp
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_activation_manifest_dedup_in_cas \
        --out:build/test-bin/integration_activation_manifest_dedup_in_cas \
        tests/e2e/home-generations/t_integration_activation_manifest_dedup_in_cas.nim \
        2>&1 | tee test-logs/integration_activation_manifest_dedup_in_cas.log

integration_apply_lock_serializes:
    mkdir -p test-logs build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/harness_apply_lock_holder \
        --out:build/test-bin/harness_apply_lock_holder \
        tests/e2e/home-generations/harness_apply_lock_holder.nim \
        2>&1 | tee test-logs/integration_apply_lock_serializes.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_apply_lock_serializes \
        --out:build/test-bin/integration_apply_lock_serializes \
        tests/e2e/home-generations/t_integration_apply_lock_serializes.nim \
        2>&1 | tee test-logs/integration_apply_lock_serializes.log

integration_remote_apply_activation_bundle_phase_a:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/integration_remote_apply_activation_bundle_phase_a.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_remote_apply_activation_bundle_phase_a \
        --out:build/test-bin/integration_remote_apply_activation_bundle_phase_a \
        tests/e2e/m71/t_integration_remote_apply_activation_bundle_phase_a.nim \
        2>&1 | tee test-logs/integration_remote_apply_activation_bundle_phase_a.log

integration_remote_apply_cross_host_evaluation_phase_b:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/integration_remote_apply_cross_host_evaluation_phase_b.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_remote_apply_cross_host_evaluation_phase_b \
        --out:build/test-bin/integration_remote_apply_cross_host_evaluation_phase_b \
        tests/e2e/m71/t_integration_remote_apply_cross_host_evaluation_phase_b.nim \
        2>&1 | tee test-logs/integration_remote_apply_cross_host_evaluation_phase_b.log

integration_remote_apply_ssh_transfer_phase_c:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/integration_remote_apply_ssh_transfer_phase_c.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_remote_apply_ssh_transfer_phase_c \
        --out:build/test-bin/integration_remote_apply_ssh_transfer_phase_c \
        tests/e2e/m71/t_integration_remote_apply_ssh_transfer_phase_c.nim \
        2>&1 | tee test-logs/integration_remote_apply_ssh_transfer_phase_c.log

integration_remote_apply_remote_activation_phase_d:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/integration_remote_apply_remote_activation_phase_d.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/integration_remote_apply_remote_activation_phase_d \
        --out:build/test-bin/integration_remote_apply_remote_activation_phase_d \
        tests/e2e/m71/t_integration_remote_apply_remote_activation_phase_d.nim \
        2>&1 | tee test-logs/integration_remote_apply_remote_activation_phase_d.log

e2e_remote_apply_home_profile_phase_e:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_remote_apply_home_profile_phase_e.build.log
    nim c \
        --hints:off \
        --nimcache:build/nimcache/reprostored \
        --out:build/bin/reprostored \
        apps/reprostored/reprostored.nim \
        2>&1 | tee -a test-logs/e2e_remote_apply_home_profile_phase_e.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_remote_apply_home_profile_phase_e \
        --out:build/test-bin/e2e_remote_apply_home_profile_phase_e \
        tests/e2e/m71/t_e2e_remote_apply_home_profile_phase_e.nim \
        2>&1 | tee test-logs/e2e_remote_apply_home_profile_phase_e.log

e2e_repro_home_apply_fresh_install:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_repro_home_apply_fresh_install.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_repro_home_apply_fresh_install \
        --out:build/test-bin/e2e_repro_home_apply_fresh_install \
        tests/e2e/home-apply/t_e2e_repro_home_apply_fresh_install.nim \
        2>&1 | tee test-logs/e2e_repro_home_apply_fresh_install.log

e2e_repro_home_apply_noop:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_repro_home_apply_noop.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_repro_home_apply_noop \
        --out:build/test-bin/e2e_repro_home_apply_noop \
        tests/e2e/home-apply/t_e2e_repro_home_apply_noop.nim \
        2>&1 | tee test-logs/e2e_repro_home_apply_noop.log

e2e_repro_home_apply_partial_recovery:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_repro_home_apply_partial_recovery.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_repro_home_apply_partial_recovery \
        --out:build/test-bin/e2e_repro_home_apply_partial_recovery \
        tests/e2e/home-apply/t_e2e_repro_home_apply_partial_recovery.nim \
        2>&1 | tee test-logs/e2e_repro_home_apply_partial_recovery.log

e2e_repro_home_add_remove_immediate:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_repro_home_add_remove_immediate.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_repro_home_add_remove_immediate \
        --out:build/test-bin/e2e_repro_home_add_remove_immediate \
        tests/e2e/home-apply/t_e2e_repro_home_add_remove_immediate.nim \
        2>&1 | tee test-logs/e2e_repro_home_add_remove_immediate.log

e2e_stow_auto_discovery_and_materialization:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_stow_auto_discovery_and_materialization.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_stow_auto_discovery_and_materialization \
        --out:build/test-bin/e2e_stow_auto_discovery_and_materialization \
        tests/e2e/home-apply/t_e2e_stow_auto_discovery_and_materialization.nim \
        2>&1 | tee test-logs/e2e_stow_auto_discovery_and_materialization.log

e2e_stow_suppression_and_warnings:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_stow_suppression_and_warnings.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_stow_suppression_and_warnings \
        --out:build/test-bin/e2e_stow_suppression_and_warnings \
        tests/e2e/home-apply/t_e2e_stow_suppression_and_warnings.nim \
        2>&1 | tee test-logs/e2e_stow_suppression_and_warnings.log

e2e_repro_home_rollback_round_trip:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_repro_home_rollback_round_trip.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_repro_home_rollback_round_trip \
        --out:build/test-bin/e2e_repro_home_rollback_round_trip \
        tests/e2e/home-rollback/t_e2e_repro_home_rollback_round_trip.nim \
        2>&1 | tee test-logs/e2e_repro_home_rollback_round_trip.log

e2e_repro_home_rollback_user_edit_protection:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_repro_home_rollback_user_edit_protection.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_repro_home_rollback_user_edit_protection \
        --out:build/test-bin/e2e_repro_home_rollback_user_edit_protection \
        tests/e2e/home-rollback/t_e2e_repro_home_rollback_user_edit_protection.nim \
        2>&1 | tee test-logs/e2e_repro_home_rollback_user_edit_protection.log

e2e_repro_home_set_triggers_focused_rebuild:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_repro_home_set_triggers_focused_rebuild.build.log
    nim c -r \
        --threads:on \
        --nimcache:build/nimcache/e2e_repro_home_set_triggers_focused_rebuild \
        --out:build/test-bin/e2e_repro_home_set_triggers_focused_rebuild \
        tests/e2e/home-set-get/t_e2e_repro_home_set_triggers_focused_rebuild.nim \
        2>&1 | tee test-logs/e2e_repro_home_set_triggers_focused_rebuild.log

e2e_home_resource_lifecycle_create_update_destroy:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_home_resource_lifecycle_create_update_destroy.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_home_resource_lifecycle_create_update_destroy \
        --out:build/test-bin/e2e_home_resource_lifecycle_create_update_destroy \
        tests/e2e/home-resources/t_e2e_home_resource_lifecycle.nim \
        2>&1 | tee test-logs/e2e_home_resource_lifecycle_create_update_destroy.log

e2e_home_registry_typed_value_kinds:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_home_registry_typed_value_kinds.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_home_registry_typed_value_kinds \
        --out:build/test-bin/e2e_home_registry_typed_value_kinds \
        tests/e2e/home-resources/t_e2e_home_registry_typed_value_kinds.nim \
        2>&1 | tee test-logs/e2e_home_registry_typed_value_kinds.log

e2e_home_resource_rollback_preserves_unrelated:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_home_resource_rollback_preserves_unrelated.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_home_resource_rollback_preserves_unrelated \
        --out:build/test-bin/e2e_home_resource_rollback_preserves_unrelated \
        tests/e2e/home-resources/t_e2e_home_resource_rollback_preserves_unrelated.nim \
        2>&1 | tee test-logs/e2e_home_resource_rollback_preserves_unrelated.log

e2e_macos_user_default_restart_target:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_macos_user_default_restart_target.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_macos_user_default_restart_target \
        --out:build/test-bin/e2e_macos_user_default_restart_target \
        tests/e2e/home-resources/t_e2e_macos_user_default_restart_target.nim \
        2>&1 | tee test-logs/e2e_macos_user_default_restart_target.log

integration_resource_move:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/integration_resource_move.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/integration_resource_move \
        --out:build/test-bin/integration_resource_move \
        tests/e2e/home-resources/t_integration_resource_move.nim \
        2>&1 | tee test-logs/integration_resource_move.log

integration_prevent_destroy:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/integration_prevent_destroy.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/integration_prevent_destroy \
        --out:build/test-bin/integration_prevent_destroy \
        tests/e2e/home-resources/t_integration_prevent_destroy.nim \
        2>&1 | tee test-logs/integration_prevent_destroy.log

e2e_dotfiles_replacement_on_real_host:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_dotfiles_replacement_on_real_host.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_dotfiles_replacement_on_real_host \
        --out:build/test-bin/e2e_dotfiles_replacement_on_real_host \
        tests/e2e/dotfiles-replacement/t_e2e_dotfiles_replacement_on_real_host.nim \
        2>&1 | tee test-logs/e2e_dotfiles_replacement_on_real_host.log

integration_production_package_catalog:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/integration_production_package_catalog.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/integration_production_package_catalog \
        --out:build/test-bin/integration_production_package_catalog \
        tests/e2e/m72/t_integration_production_package_catalog.nim \
        2>&1 | tee test-logs/integration_production_package_catalog.log

e2e_apply_plan_dry_run:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_apply_plan_dry_run.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_apply_plan_dry_run \
        --out:build/test-bin/e2e_apply_plan_dry_run \
        tests/e2e/m72/t_e2e_apply_plan_dry_run.nim \
        2>&1 | tee test-logs/e2e_apply_plan_dry_run.log

integration_stow_non_destructive_over_existing:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/integration_stow_non_destructive_over_existing.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/integration_stow_non_destructive_over_existing \
        --out:build/test-bin/integration_stow_non_destructive_over_existing \
        tests/e2e/m72/t_integration_stow_non_destructive_over_existing.nim \
        2>&1 | tee test-logs/integration_stow_non_destructive_over_existing.log

integration_stow_gnu_package_layout:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/integration_stow_gnu_package_layout.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/integration_stow_gnu_package_layout \
        --out:build/test-bin/integration_stow_gnu_package_layout \
        tests/e2e/m73/t_integration_stow_gnu_package_layout.nim \
        2>&1 | tee test-logs/integration_stow_gnu_package_layout.log

integration_scoop_manifest_bin_resolution:
    mkdir -p test-logs build/test-bin build/nimcache build/test-tmp
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/integration_scoop_manifest_bin_resolution \
        --out:build/test-bin/integration_scoop_manifest_bin_resolution \
        tests/e2e/m74/t_integration_scoop_manifest_bin_resolution.nim \
        2>&1 | tee test-logs/integration_scoop_manifest_bin_resolution.log

integration_scoop_probe_gui_and_timeout:
    mkdir -p test-logs build/test-bin build/nimcache build/test-tmp
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/integration_scoop_probe_gui_and_timeout \
        --out:build/test-bin/integration_scoop_probe_gui_and_timeout \
        tests/e2e/m75/t_integration_scoop_probe_gui_and_timeout.nim \
        2>&1 | tee test-logs/integration_scoop_probe_gui_and_timeout.log

integration_stow_byte_identical_target_is_cache_hit:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/integration_stow_byte_identical_target_is_cache_hit.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/integration_stow_byte_identical_target_is_cache_hit \
        --out:build/test-bin/integration_stow_byte_identical_target_is_cache_hit \
        tests/e2e/m76/t_integration_stow_byte_identical_target_is_cache_hit.nim \
        2>&1 | tee test-logs/integration_stow_byte_identical_target_is_cache_hit.log

integration_scoop_installed_version_survives_bucket_drift:
    mkdir -p test-logs build/test-bin build/nimcache build/test-tmp
    # NOTE: the `--out` binary is deliberately named `m77_scoop_bucket_drift`
    # rather than after the gate. Windows' installer-detection heuristic
    # auto-elevates any executable whose filename contains the substring
    # "install" (the gate name has "installed"), and an elevation prompt
    # fails closed in a non-interactive CI shell with "The requested
    # operation requires elevation." The gate / recipe / log names stay
    # the spec name; only the on-disk binary leaf is detoxed.
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/m77_scoop_bucket_drift \
        --out:build/test-bin/m77_scoop_bucket_drift \
        tests/e2e/m77/t_integration_scoop_installed_version_survives_bucket_drift.nim \
        2>&1 | tee test-logs/integration_scoop_installed_version_survives_bucket_drift.log

e2e_profile_declared_resources_apply:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_profile_declared_resources_apply.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_profile_declared_resources_apply \
        --out:build/test-bin/e2e_profile_declared_resources_apply \
        tests/e2e/m78/t_e2e_profile_declared_resources_apply.nim \
        2>&1 | tee test-logs/e2e_profile_declared_resources_apply.log

integration_shell_integration_replan_idempotent:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/integration_shell_integration_replan_idempotent.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/integration_shell_integration_replan_idempotent \
        --out:build/test-bin/integration_shell_integration_replan_idempotent \
        tests/e2e/m79/t_integration_shell_integration_replan_idempotent.nim \
        2>&1 | tee test-logs/integration_shell_integration_replan_idempotent.log

integration_plan_classifier_bucket_drift_is_cache_hit:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/integration_plan_classifier_bucket_drift_is_cache_hit.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/integration_plan_classifier_bucket_drift_is_cache_hit \
        --out:build/test-bin/integration_plan_classifier_bucket_drift_is_cache_hit \
        tests/e2e/m80/t_integration_plan_classifier_bucket_drift_is_cache_hit.nim \
        2>&1 | tee test-logs/integration_plan_classifier_bucket_drift_is_cache_hit.log

integration_privileged_broker_single_prompt:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/integration_privileged_broker_single_prompt.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/integration_privileged_broker_single_prompt \
        --out:build/test-bin/integration_privileged_broker_single_prompt \
        tests/e2e/m81/t_integration_privileged_broker_single_prompt.nim \
        2>&1 | tee test-logs/integration_privileged_broker_single_prompt.log

e2e_windows_registry_system_scope:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_windows_registry_system_scope.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_windows_registry_system_scope \
        --out:build/test-bin/e2e_windows_registry_system_scope \
        tests/e2e/m69/t_e2e_windows_registry_system_scope.nim \
        2>&1 | tee test-logs/e2e_windows_registry_system_scope.log

e2e_repro_infra_plan_apply_convergent:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_repro_infra_plan_apply_convergent.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_repro_infra_plan_apply_convergent \
        --out:build/test-bin/e2e_repro_infra_plan_apply_convergent \
        tests/e2e/m69/t_e2e_repro_infra_plan_apply_convergent.nim \
        2>&1 | tee test-logs/e2e_repro_infra_plan_apply_convergent.log

e2e_windows_optional_feature_and_capability:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_windows_optional_feature_and_capability.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_windows_optional_feature_and_capability \
        --out:build/test-bin/e2e_windows_optional_feature_and_capability \
        tests/e2e/m69/t_e2e_windows_optional_feature_and_capability.nim \
        2>&1 | tee test-logs/e2e_windows_optional_feature_and_capability.log

e2e_repro_system_command_family:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_repro_system_command_family.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_repro_system_command_family \
        --out:build/test-bin/e2e_repro_system_command_family \
        tests/e2e/m69/t_e2e_repro_system_command_family.nim \
        2>&1 | tee test-logs/e2e_repro_system_command_family.log

e2e_windows_vs_installer:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_windows_vs_installer.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_windows_vs_installer \
        --out:build/test-bin/e2e_windows_vs_installer \
        tests/e2e/m69/t_e2e_windows_vs_installer.nim \
        2>&1 | tee test-logs/e2e_windows_vs_installer.log

e2e_repro_infra_passwd_user_safe_destroy:
    mkdir -p test-logs build/bin build/test-bin build/nimcache build/test-tmp
    nim c \
        --hints:off \
        --nimcache:build/nimcache/repro \
        --out:build/bin/repro \
        apps/repro/repro.nim \
        2>&1 | tee test-logs/e2e_repro_infra_passwd_user_safe_destroy.build.log
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_repro_infra_passwd_user_safe_destroy \
        --out:build/test-bin/e2e_repro_infra_passwd_user_safe_destroy \
        tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim \
        2>&1 | tee test-logs/e2e_repro_infra_passwd_user_safe_destroy.log

# M82 Phase B verification gate — pure logic, runs on every host. No
# Hyper-V VM / no broker / no real Windows API needed: the gate
# exercises the planner's dependency-graph + topological-sort path
# against fixture profile text. The companion REAL Hyper-V scenario
# (`integration_intra_batch_capability_to_service`) is exercised
# separately via `tools/hyperv-m69-system/`.
e2e_repro_infra_depends_on_topological:
    mkdir -p test-logs build/test-bin build/nimcache build/test-tmp
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_repro_infra_depends_on_topological \
        --out:build/test-bin/e2e_repro_infra_depends_on_topological \
        tests/e2e/m69/t_e2e_repro_infra_depends_on_topological.nim \
        2>&1 | tee test-logs/e2e_repro_infra_depends_on_topological.log

# M82 home-scope follow-up verification gate — pure logic, runs on
# every host. The home-scope analog of
# `e2e_repro_infra_depends_on_topological`: exercises the home
# planner's `dep_graph` module + the `composeDesiredResources`
# topological-sort path against fixture `home.nim` text. Asserts the
# action stream is cycle-refusing, dependency-correct, and
# declaration-stable across runs.
e2e_repro_home_depends_on_topological:
    mkdir -p test-logs build/test-bin build/nimcache build/test-tmp
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_repro_home_depends_on_topological \
        --out:build/test-bin/e2e_repro_home_depends_on_topological \
        tests/e2e/m68/t_e2e_repro_home_depends_on_topological.nim \
        2>&1 | tee test-logs/e2e_repro_home_depends_on_topological.log

# M68 home-scope follow-up verification gate — pure logic, runs on
# every host. End-to-end exercise of the `fs.userFile` driver — the
# home-scope analogue of system-scope `fs.systemFile` (M69 Phase C).
# Verifies fresh write, cache-hit no-op on re-apply, drift overwrite,
# atomic-write recovery, POSIX mode application (POSIX-only), and the
# `${HOME}` prefix expansion. Cross-platform; mode assertions guarded
# by `when not defined(windows)`.
e2e_repro_home_fs_user_file:
    mkdir -p test-logs build/test-bin build/nimcache build/test-tmp
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_repro_home_fs_user_file \
        --out:build/test-bin/e2e_repro_home_fs_user_file \
        tests/e2e/m68/t_e2e_repro_home_fs_user_file.nim \
        2>&1 | tee test-logs/e2e_repro_home_fs_user_file.log

# M82 Phase C verification gate — pure logic, runs on every host. The
# DRIFT HALF of `integration_intra_batch_capability_to_service`: the
# planner's plan-time external-drift detection seen end-to-end across
# a synthesized cycle (apply -> out-of-band mutator -> re-plan). The
# capability/service intra-batch half lives in `tools/hyperv-m69-system/`
# and is run by the reviewer; this gate covers the drift-surface
# regressions on every CI run without a VM.
e2e_repro_infra_plan_time_external_drift:
    mkdir -p test-logs build/test-bin build/nimcache build/test-tmp
    nim c -r \
        --threads:on \
        --warning:UnusedImport:off \
        --warning:CaseTransition:off \
        --nimcache:build/nimcache/e2e_repro_infra_plan_time_external_drift \
        --out:build/test-bin/e2e_repro_infra_plan_time_external_drift \
        tests/e2e/m69/t_e2e_repro_infra_plan_time_external_drift.nim \
        2>&1 | tee test-logs/e2e_repro_infra_plan_time_external_drift.log

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
