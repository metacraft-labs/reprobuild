{
  description = "Reprobuild development environment";

  inputs = {
    # Keep the shipped SIP replacements available when a child has an empty PATH.
    stackable-hooks-macos-tools = {
      url = "github:metacraft-labs/stackable-hooks-macos-tools/1ad378d58776ec9b6cc73e1c27b8e53c15676f03";
    };
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    # This module input supplies the toolchain, not another Repro release.
    # Follow this flake itself so consumers retain one Reprobuild pin while
    # the module and Nixpkgs revisions remain independently pinned.
    nixos-modules.inputs.reprobuild.follows = "";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
    # `bundlers` is the official NixOS bundler collection (the same set
    # `nix bundle --bundler github:NixOS/bundlers#toArx` reaches for). We
    # only consume its `toArx` bundler (nix-community/nix-bundle under the
    # hood) to package the full `reprobuild` store closure into ONE
    # self-extracting, relocatable executable (see `packages.repro-portable`
    # below). Follow our nixpkgs so the bundler's arx/nix-user-chroot helper
    # tools share the fleet's package set rather than pulling a second one.
    bundlers = {
      url = "github:NixOS/bundlers";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    runquota-src = {
      # runquota's mainline is ``dev``; ``main`` is stale and lacks the
      # bounded grant-stream API (``pollNextGrantBounded`` / ``GrantPollResult``)
      # that repro_runquota now compiles against. The ``test`` CI job already
      # overrides this to the ``dev`` sibling clone; pin the default here so the
      # override-free ``lint`` and ``nix-build`` jobs resolve the same source.
      url = "github:metacraft-labs/runquota/dev";
      # A FLAKE INPUT, NOT A BARE SOURCE TREE. Both uses are served by the one
      # pin: ``${runquota-src}`` still coerces to the fetched source root (so
      # ``RUNQUOTA_SRC`` and every ``--path:`` into ``libs/*/src`` are
      # unchanged), and ``runquota-src.packages.<system>.default`` gives us the
      # daemon+CLI built by runquota's OWN package derivation instead of a copy
      # of it maintained here.
      #
      # Why that matters: runquota's ``runquotad`` / ``runquota`` binaries have
      # their own dependency closure, and it grows. M13b's published aggregate
      # table made ``runquota_daemon`` and ``runquota_cli_support`` import
      # ``shm_lease/*``, which runquota's package derivation feeds itself from
      # its own ``nim-shm-lease`` input. A mirrored derivation here would have
      # to re-learn that input — and the next one — even though reprobuild
      # imports none of those modules; it compiles only
      # ``runquota_client``/``_codec``/``_core``/``_ipc``/``_process``/``_protocol``
      # from the source tree, and none of them reach ``shm_lease``.
      # Delegating the build keeps runquota's transitive dependencies
      # runquota's business.
      #
      # ``nixos-modules`` follows ours so runquota's package set is this
      # flake's package set — one nixpkgs evaluation, not two.
      inputs.nixos-modules.follows = "nixos-modules";
      # runquota's release dev shell takes reprobuild's packaging sources as
      # ``release-packaging-src``, pinned to SOME reprobuild revision. Inside
      # this flake that is a second, competing reprobuild pin (and an identity
      # with no recorded visibility); point it at this flake itself instead.
      inputs.release-packaging-src.follows = "";
    };
    io-mon-src = {
      # io-mon ships the ``io_mon`` Nim package (the byte-identical wire-format
      # + ABI relocation of the former repro_monitor_depfile / shim / hooks
      # stack). The build engine, CLI io-monitor driver and monitor tests import
      # it; config.nims reads IO_MON_SRC (then falls back to a ``../io-mon``
      # sibling). Like the other source inputs, the sandboxed package build and
      # the override-free CI jobs have no sibling, so seed it from this input.
      #
      # Pinned to the hardened io-mon revision validated for this retirement
      # campaign.
      #
      # Bumped to the Lossless-Event-Capture dev tip: io-mon's Linux dependency
      # channel is now the grow-only shared-memory set ``nim-shm-gset`` (Candidate
      # C — dedup-at-source, no orphan spill), NOT the ``shm_queue`` ring, which
      # io-mon no longer imports at all. fs_snoop.nim / writer.nim now
      # ``import shm_gset`` + ``shm_gset/transport``, so this pin requires the
      # nim-shm-gset-src input below and its SHM_GSET_SRC wiring.
      #
      # In-Process-Monitor-Hosting HM-4 — bumped to the IoMon-Decomposed-Host-API
      # DH-4 tip. The engine hosts io-mon's consumer IN-PROCESS now, and the
      # decomposed lifecycle it calls (``startMonitor`` / ``pollMonitor`` /
      # ``finishMonitor``, plus ``FsSnoopRequest.env`` / ``.cwd``) does not exist
      # at all in the previous pin: at ``3a7c15cd`` ``fs_snoop`` exports only
      # ``findShimLibrary`` / ``completeness`` / ``records`` / ``runMonitored`` /
      # ``runFsSnoopCli``, and ``FsSnoopRequest`` has neither ``env`` nor ``cwd``.
      # THIS PIN IS THE PREREQUISITE, not a refresh — io-mon's source having the
      # API is not the same thing as reprobuild's BUILD having it. Note that a
      # developer shell entered through ``.envrc`` sets NIX_FLAKE_OVERRIDE_AUTO=1
      # and therefore resolves ``IO_MON_SRC`` from a ``../io-mon`` sibling when one
      # exists; this pin is what the sandboxed package build and the override-free
      # CI jobs use, and it is the revision the two must agree on.
      #
      # Bumped again to the sweep-cost fix: ``finishMonitor``'s §4.1 descendant
      # sweep no longer walks all of /proc per call (~105 ms → ~6 ms), which is
      # what makes in-process hosting a throughput WIN rather than a regression,
      # and the same commit closes a false-complete hole in which an ``opendir`` /
      # ``readdir`` fault during the sweep was silently reported as "no
      # descendants" instead of as an incomplete observation.
      #
      # Bumped to the depfile-format rename tip, which also includes the
      # memory-frugal ``streamMonitorDepFileRecords`` API consumed directly by
      # repro_build_engine. Keeping the sandbox pin behind that API makes the
      # release build fail even when a newer sibling checkout masks the skew.
      #
      # Bumped to the per-request event-interest API used by the engine to avoid
      # collecting categories an edge does not depend on. The enum, request
      # field, and environment codec are all introduced by this revision.
      #
      # Workspace locks pin sibling checkouts. This declaration and flake.lock
      # pin the standalone Nix input, which must also parse the CLI's --interest
      # flag when no sibling checkout overrides it.
      #
      # Bumped to the revision that stops the Linux shim referencing
      # nim-stackable-hooks' amd64-only raw-syscall substrate. This input is
      # what `librepro_monitor_shim.so` is actually compiled from (the sandboxed
      # package build and CI have no io-mon sibling), so the previous pin
      # produced a shim with five undefined `stackable_linux_*` symbols on
      # aarch64. LD_PRELOAD binds eagerly, so every `eph-linux-arm64` lane in
      # the fleet died on the first monitored process with
      # `undefined symbol: stackable_linux_chain_sigtrap` — surfacing as
      # `repro build: error: interface extraction edge asFailed`.
      # The engine also uses EvidenceScope and the scoped depfile format.
      #
      # Bumped to 3ec0223, which is the revision this repo's flake.lock already
      # builds. The two had silently diverged: a `repro flake refresh-lock` run
      # moved `locked.rev` here without touching this url, and nix reuses a lock
      # entry on its ORIGINAL ref alone — it never compares `locked` against
      # `original` — so the pin below read as ac3e5b97 while every build fetched
      # 3ec0223, with no warning. The engine now declines to move a pin stated
      # here, so this class of divergence cannot recur; this line repairs the
      # instance that already existed.
      #
      # Everything the paragraphs above justify still holds: ac3e5b97 is an
      # ANCESTOR of 3ec0223, so the aarch64 `stackable_linux_*` fix, the
      # event-interest API and the scoped depfile format are all carried
      # forward. 3ec0223 is published on `dev` and is the revision the workspace
      # has actually been building and testing against.
      #
      # Bumped to 1c41ba8: `ci: name the shared modules repo by the name it has
      # now`. ONE commit, and it changes no source at all — it retargets
      # io-mon's own `nixos-modules` input from `metacraft-labs/nixos-modules`
      # to `metacraft-labs/devops-modules`, the repo's current name, which is
      # the url THIS flake already uses for that input. So the bump carries no
      # behaviour with it; it makes the sibling and the pin agree again (they
      # had drifted by exactly this commit) and makes io-mon name the shared
      # modules repo the way the rest of the workspace does. 1c41ba8 is the tip
      # of io-mon's `dev`.
      #
      # Bumped to b5c7990: `shim: build with -d:useMalloc, because the shim does
      # not own its threads`. This input is what `librepro_monitor_shim.*` is
      # compiled from in the sandboxed package build and in CI, and the
      # previous pin builds a shim whose Nim allocator owns one heap PER THREAD.
      # Injected into a host whose threads exit on the host's schedule, a cell
      # freed on a thread other than its allocator's is handed back through a
      # pointer into a TLS block the loader has already discarded. Measured on
      # Windows as a 0xC0000005 in `addToSharedFreeList` on .NET's finalizer
      # thread in every `powershell.exe` that hosted a large `nim c` -- the
      # wrapper reprobuild itself uses for a compiler argv longer than cmd.exe
      # accepts -- which surfaced for days as `__repro_provider_compile
      # asFailed` blamed on the compiler. The pin carries the fix into every
      # build that has no io-mon sibling; the sibling-overridden developer
      # shells already have it. b5c7990 is the tip of io-mon's `dev`.
      # Keep shim allocations out of rustc's replacement allocator: its clock
      # reads can run under the allocator lock. b72fb8d preserves time evidence
      # while fixing native flake activation of rustc-based environments.
      # 0c312f2 also drops unused glibc companion libraries from the shim.
      # Bumped to a3edfab (io-mon#34): the Windows shim no longer installs a
      # Nim signal handler in the processes it is injected into, and a spawn
      # whose child had to be terminated during injection now fails cleanly.
      # Requires nim-stackable-hooks 72f5782 (below).
      # Bumped to 279a17b, io-mon's `dev` tip. `src/` is BYTE-IDENTICAL to
      # a3edfab (`git diff a3edfab origin/dev -- src/` is empty), so this
      # changes no compiled byte; it moves the pin off a mid-history commit and
      # onto the revision the rest of the workspace builds against, which is
      # what keeps the four channels that name io-mon from drifting apart again.
      # Bumped to 07cc4af (io-mon#39), io-mon's `dev` tip. This one DOES change
      # compiled bytes, and it is the first bump since 279a17b that does:
      # `git diff 279a17b 07cc4af -- src/` was empty for every intervening
      # revision, and io-mon#39 is the first `src/` change since the pin. It
      # gives the `.iomon-frag` merge path the observation-identity fold, which
      # macOS and Windows captures never had. Leaving the pin behind would build
      # a merge path WITHOUT the fold while io-mon's capability declaration --
      # which this same revision moves into the supported set -- says the fold
      # is there, i.e. an over-claim in the depfile this engine reads.
      # Preserve child exec identities and the resumed parent guard across vfork.
      # Bumped to 31b05a5 (io-mon#41): IPC connect records carry the socket
      # path and the peer uid (endpoint-keyed daemon trust), and
      # `FsSnoopRequest.isolateEnv` launches a child from its declared
      # environment alone (Dev-Env-Warm-Entry.md).
      # Keep this, the lock, sibling clone and package fallback on one revision.
        # Bumped to e750199 (2026-09-30), io-mon's `agents` tip: it contains
        # 53994c0 (dev's observation-identity fold + agents' vfork repairs) and
        # 31b05a5 (io-mon#41: endpoint + peer-uid IPC records, isolated launch).
        # Bumped to b464ce1 (2026-10-03), io-mon's `agents` tip; e750199 is an
        # ancestor.
        # Bumped to 0b0476a (2026-10-11), io-mon's `agents` tip; 1053102 is an
        # ancestor and `git diff 1053102 0b0476a -- src/` is empty.
        # Bumped to ca28cce (2026-10-13), io-mon's `agents` tip; 0b0476a is an
        # ancestor. 142f658 carries capture controls into explicit Linux child
        # environments and hands nested Linux evidence back to the parent; the
        # macOS and Windows capture paths are unchanged.
        # Bumped to f72ee0e (2026-10-14), io-mon's `agents` tip; ca28cce is an
        # ancestor. 41c114f resolves connect forwarding before application
        # constructors and b364626 keeps capture complete across cooperating
        # shim images, both in the Linux preload runtime. `fs_snoop` now keeps
        # a nested child's public evidence scope and carries the enclosing
        # run's full collection in a separate, host-owned variable.
        # Bumped to 295a2e5 (2026-10-14), io-mon's `agents` tip; f72ee0e is an
        # ancestor. The batched fragment writer checks the descriptor's
        # identity where it touches the descriptor instead of once per record,
        # and the Linux close hook lets a tracee's close of a replaced
        # descriptor number reach the kernel.
        # Bumped to 51228b5 (2026-10-15), io-mon's `agents` tip; 6e7d2cf is an
        # ancestor. 51228b5 lets small-stack threads start and run under the
        # Linux shim; the macOS and Windows capture paths are unchanged.
        # Bumped to 6453936 (2026-10-15), io-mon's `agents` tip; 51228b5 is an
        # ancestor. Under full action monitoring Node 24 started (51228b5) but
        # Chromium 143 headless still hung: recording a call the host made
        # under its allocator lock allocated from that same allocator.
        # cb1db14 moved the shim's private heap to glibc's allocator, which
        # broke every nixpkgs gcc-wrapper (bash 5.2's bundled sbrk malloc and
        # glibc's main arena both moved the program break, and the exec hooks
        # handed bash an `environ` from the shim's heap), so it is not pinned
        # on its own. 6453936 gives the shim its own mmap-backed allocator that
        # touches neither the break nor `environ`, makes execvp search PATH only
        # (never `./name`), and keeps raw-clone children of multi-threaded
        # hosts off shim locks. cb1db14 also adds the probe/enumeration entry
        # points Node and Chromium call and per-architecture raw-syscall
        # numbers.
        # Bumped to 9576b79 (2026-10-15), io-mon's `agents` tip; 6453936 is an
        # ancestor. On macOS, re-propagates capture seed variables across
        # clean-env spawns, keeps only the last co-loaded shim image active
        # while routing internal forwarders and raw syscalls past sibling shim
        # wrappers, and reads `syscall(2)` variadic arguments from the stack per
        # the arm64 Apple Darwin ABI.
        # Bumped to 3ccdd4b (2026-10-15), io-mon's `agents` tip; 9576b79 is an
        # ancestor. On Linux, children of an inline `syscall` clone and of
        # glibc's clone(3) reclaim inherited shim locks; a vfork child's
        # successful exec no longer leaks the prepared environment into the
        # parent; and realpath, canonicalize_file_name and the readlink family
        # record every symbolic link they follow and the path they end at.
        # Bumped to 414a3de (2026-10-15), io-mon's `agents` tip; 3ccdd4b is an
        # ancestor. On Linux, that replay also records each directory it walks
        # through, the first absent component, and the link the readlink
        # family reads with its target, so a directory replaced by a link and
        # a retargeted link change a recorded input.
        # Bumped to 527368e (2026-10-16), io-mon's `agents` tip; 414a3de is an
        # ancestor. Test-only: the macOS nesting fixtures give their second
        # shim its own install name, so they run two distinct shim images.
      url = "github:metacraft-labs/io-mon/527368ee896b58263085a116f8fffb9b3ee2d82e";
      flake = false;
    };
    nim-shm-gset-src = {
      # nim-shm-gset ships the ``shm_gset`` package: a lock-free grow-only set
      # (G-Set / join-semilattice CRDT over opaque byte blobs — idempotent
      # slot-claim CAS, no deletion, file-backed shards, app-id-scoped reaper).
      # It is io-mon's PRIMARY Linux dependency-capture transport (Candidate C of
      # the Lossless Event Capture campaign): dedup-at-source so ``configure`` /
      # ``cmake`` probe storms collapse to the *distinct* dependency set. io-mon's
      # config.nims reads SHM_GSET_SRC (then falls back to a ``../nim-shm-gset``
      # sibling); the sandboxed package build + override-free CI jobs have no
      # sibling, so seed it from here — exactly like nim-shm-queue-src.
      # Pin c9048e9: it retains AttachFailure and uses a boot-stable Darwin
      # identity instead of a wall-clock second. Writer liveness requires this
      # stability; its authoritative probe additionally rejects OS errors
      # because shard warm-up tolerates uncertainty but live-writer reclamation
      # does not. Keep this URL, flake.lock, and .github/sibling-repos aligned.
      url = "github:metacraft-labs/nim-shm-gset/c9048e9a7e0ba2b11c1ec137acc5fc2c0bcfec27";
      flake = false;
    };
    nim-shm-queue-src = {
      # nim-shm-queue ships the ``shm_queue`` package: the extracted, single
      # lock-free MPSC ring (Layer 1 ``shm_queue/ring`` + ``segment``, over
      # byte blobs; Layer 2 ``typed_queue``). repro_shm_index's action-cache
      # submission ring and io-mon's dependency queue BOTH sit on it, so exactly
      # one MPSC implementation exists. config.nims reads SHM_QUEUE_SRC (then
      # falls back to a ``../nim-shm-queue`` sibling); the sandboxed package
      # build + override-free CI jobs have no sibling, so seed it from here.
      # repro_shm_index consumes ONLY Layer 1 (pure std/posix, no serialization).
      #
      # Pinned to the nim-shm-queue rev that adds the Layer-1 EmbeddedRing
      # (repro_shm_index's action-cache ring embeds it in the control region).
      url = "github:metacraft-labs/nim-shm-queue/5a8e43b52fa202859658692c9f8432967f3971ea";
      flake = false;
    };
    nimcrypto-src = {
      url = "github:cheatfate/nimcrypto/69eec0375dd146aede41f920c702c531bfe89c6b";
      flake = false;
    };
    bearssl-src = {
      # Submodules=1 pulls bearssl/csources (the upstream BearSSL C tree
      # nim-bearssl wraps); without it the bindings compile but link-fail.
      # The git+https URL form preserves the submodule flag through the lock
      # (the github: + ?submodules=1 form drops it on lock).
      url = "git+https://github.com/status-im/nim-bearssl?submodules=1&rev=9a4eed052abbded2d94feaf3f5bbd95a30ec4671";
      flake = false;
    };
    # nim-stackable-hooks (the framework the macOS monitor shim migrated to in
    # 86cb1bf). The package build compiles repro_monitor_hooks against it, so —
    # like bearssl-src — it must be supplied as a source input; the dev shell
    # resolves it from the sibling checkout, but the sandboxed package build has
    # no sibling and otherwise fails with "cannot open file: stackable_hooks/…".
    #
    # THE INPUT NAME IS LOAD-BEARING, and it is why this was called
    # ``stackable-hooks-src`` until 2026-08-26 and is not any more. `.envrc`
    # sets ``NIX_FLAKE_OVERRIDE_AUTO=1`` with
    # ``NIX_FLAKE_OVERRIDE_AUTO_STRIP_SUFFIXES=-src``: the auto arm strips the
    # suffix off each input name and overrides the input when a sibling
    # DIRECTORY OF THAT EXACT NAME exists. ``stackable-hooks-src`` stripped to
    # ``stackable-hooks``; the checkout is ``../nim-stackable-hooks``, so the
    # auto arm matched nothing and this was the ONLY sibling-backed input in
    # the flake still resolving to its lock pin while every other one tracked
    # the working tree. The pin then sat 30 commits behind the sibling, across
    # ``6a53408`` ("Windows injector: an explicit child environment"), which
    # added ``runWithMonitorShim``'s ``env`` parameter and
    # ``WindowsInjectionResult.rootPid`` / ``.monitoringSkipped`` /
    # ``.skipReason`` — all four read by io-mon's Windows arm
    # (``fs_snoop.nim`` ~1439 and ~1965). So reprobuild's Windows arm compiled
    # io-mon against a stackable_hooks that did not have the fields io-mon
    # names, and nothing said so: ``scripts/check_dev_shell_env.sh``
    # reconciled only inputs that WERE overridden, which is precisely the set
    # this one was missing from. That blind spot is now closed by the
    # sibling-vs-override check in that script, but the name is the fix —
    # match the directory convention every other input follows and the auto
    # arm reaches it without anyone having to remember.
    nim-stackable-hooks-src = {
      # Pinned to the rev that carries ``platform/linux_preload`` (and the rest
      # of io-mon's stackable surface); the older lock lacked it, so
      # io-mon's ``linux_preload_runtime.nim`` failed with "cannot open file:
      # stackable_hooks/platform/linux_preload" in both the sandboxed package
      # build and ``just bootstrap``.
      #
      # Bumped to the rev that additionally carries the Linux x86_64
      # syscall-scanner rel32 guard (``looksLikeLinuxX8664Syscall`` /
      # ``visitLinuxX8664SyscallMemory`` reject a ``0f 05`` sitting inside a
      # ``call``/``jmp rel32`` displacement). Without it the monitor shim's
      # INT3 syscall-trap patcher corrupted the ``call rmdir@plt`` displacement
      # in glibc/Nim ``removeDir`` (``e8 0f 05 fa ff``) and SIGILL'd every test
      # that removes a directory (e.g. isonim-tui
      # ``test_snapshot_six_formats_recorded``). The dev shell exports this
      # source as ``STACKABLE_HOOKS_SRC`` and ``build_shim.sh`` honors it, so
      # the store pin — not the sibling — is what ``just build`` (and CI)
      # actually compiles the shim from; the old pin therefore produced a
      # crashing shim even though the local sibling was already hardened.
      #
      # Bumped from 30f69b6 to the ``dev`` tip 41ab1b9. The override reaching
      # the sibling does NOT make this pin cosmetic: the sandboxed package
      # build, the override-free ``lint`` / ``nix-build`` CI jobs and any
      # non-workspace consumer resolve the source from here and from nowhere
      # else, so the pin and the sibling have to agree or the two builds are
      # different builds. 41ab1b9 is the revision that carries the explicit
      # Windows child environment (``6a53408``) io-mon's ``fs_snoop`` Windows
      # arm compiles against; 30f69b6 predates it.
      #
      # Bumped to 49006c3 for the reason the paragraph above gives: the pin and
      # the sibling HAD stopped agreeing, which is the exact condition that
      # makes them two different builds. A `repro flake refresh-lock` run moved
      # `locked.rev` to 49006c3 without touching this url, and nix matches a
      # lock entry on its ORIGINAL ref alone, so this line read as 41ab1b9 while
      # every build fetched 49006c3 — silently, with no warning. The engine now
      # declines to move a pin stated here; this repairs the existing instance.
      #
      # 41ab1b9 is an ANCESTOR of 49006c3, so the explicit Windows child
      # environment (``6a53408``) this pin was chosen for is carried forward.
      #
      # Bumped to 72f5782 (nim-stackable-hooks#8): the Windows injector no
      # longer resumes a slow child mid-injection. It waits while the child
      # lives, and past a hard deadline terminates it and fails the spawn
      # instead. 5125869 is an ancestor.
      #
      # Bumped to 3b99d26 (2026-10-03), the published `agents`/`dev` tip; 72f5782
      # is an ancestor.
      #
      # Bumped to 4aa8892 (2026-10-11), the published `agents`/`dev` tip;
      # 2a7c5f7 is an ancestor and only `flake.lock` differs.
      #
      # Bumped to c6602ce (2026-10-14), the published `agents`/`dev` tip;
      # 4aa8892 is an ancestor. Windows entry parking borrows a parked thread
      # with a real call, so a CET shadow stack accepts it, and stays within
      # the declared x86 child architecture. Only `windows_entry_park.nim`
      # changes under `src/`.
      #
      # f51e0ab advances the workspace pin with Windows injection diagnostics;
      # the Darwin source is unchanged.
      # 600f2a8 additionally carries caller/target Windows injection diagnostics.
      # Keep this pin aligned with the synced, published workspace dependency;
      # the pre-push gate rejects a pin that lags that checkout.
      url = "github:metacraft-labs/nim-stackable-hooks/3af63afc5c0b55a27fc5e0a26f3a32833caf8873";
      flake = false;
    };
    reprobuild-ct-test-runner-src = {
      # The run-side ``ct_test_runner_adapter`` — the in-process
      # ``TestRunner`` adapter reprobuild installs (it depends only on the
      # ``repro_test_adapters`` contract, not the engine). config.nims
      # reads REPRO_CT_TEST_RUNNER_SRC to thread it onto Nim's --path.
      # (The build-side typed-tool — ct_test_interface / ct_test_nim_unittest
      # / ct_test_unittest_parallel — now lives in-tree under libs/.)
      url = "github:metacraft-labs/reprobuild-ct-test-runner";
      flake = false;
    };
    reprobuild-test-adapters-src = {
      # The ``TestRunner`` cross-cutting contract (Nim package
      # ``repro_test_adapters``). config.nims reads
      # REPRO_TEST_ADAPTERS_SRC to thread it onto Nim's --path; the dev
      # shell resolves it from the sibling checkout, but the sandboxed
      # package build has no sibling so we seed it from this input.
      url = "github:metacraft-labs/reprobuild-test-adapters";
      flake = false;
    };
    # A source-only input was removed from this set, and this note is where
    # a future reader finds out why rather than re-deriving it -- it names
    # no repository on purpose, because the removal was about a dependency
    # that did not exist rather than about any particular tree.
    # The variable that threaded it onto Nim's ``--path``
    # lost its last reader at ``86cb1bf6`` (the migration onto
    # ``nim-stackable-hooks``), and the wrapper set, the dev-shell export,
    # the lint hook and both derivation attributes followed it out. What
    # kept the input alive after that was a single line in the
    # package-closure assertion below -- an assertion the package could not
    # satisfy, because nothing threaded the source into the package either.
    # Measured before removal: the store path appeared ZERO times in
    # ``nix derivation show .#packages.<system>.reprobuild``, so no output
    # closure could ever contain it, and the check that required it is run
    # by nothing in CI or the Justfile. Adding a source input that no
    # derivation consumes costs every downstream lock a node -- see the gate
    # in ``tests/unit`` that walks this file's lock.
    codetracer-src = {
      # CodeTracer owns the cross-language test driver ``ct-test``
      # (``src/ct_test/ct_test.nim``): TestCatalog v1 discovery over the
      # provider registry plus the partitioned parallel runner, declared as
      # the ``ct-test`` target in codetracer's ``repro.nim``. ``ctTestTools``
      # below builds that binary from this input and the dev shell puts it on
      # PATH, exactly as ``runquotaTools`` does for ``runquota-src`` — so the
      # shipped tool tracks a pinned/overridable source instead of whatever
      # someone hand-compiled into a sibling checkout.
      #
      # Pinned to an exact revision, like ``ct-trace-format-src`` below, and
      # moved together with it: the incremental-test seam this input supplies
      # is compiled against that trace-format source, so the two must name a
      # CodeTracer revision built against the same trace-format revision. A
      # branch ref would let either side move alone.
      #
      # ``flake = false`` — we want the source tree only. CodeTracer's own
      # flake drags in the Electron/frontend/db-backend toolchain, none of
      # which ``ct-test`` needs (its only non-stdlib dependency is runquota;
      # see ctTestTools). The ``.envrc`` auto-override
      # (NIX_FLAKE_OVERRIDE_AUTO + the ``-src`` suffix convention) names this
      # input for a ``../codetracer`` sibling when one exists. Be aware of what
      # that costs before leaning on it: overriding a source input to a plain
      # path copies the whole directory into the store, and a working
      # CodeTracer checkout is several gigabytes. An override-free shell builds
      # the pin, which is the cheap and reproducible default — and cheap is
      # meant literally. Measured at the current pin: 25 MB on disk, 47 MiB of
      # store closure with no dependencies, against 6.1 GiB for the override
      # copy. The gigabytes belong to the override, not to the input.
      #
      # CodeTracer also owns ``src/ct_incremental_adapter.nim``, the process
      # seam ``config.nims`` puts on Nim's ``--path``, and this input is what
      # every build here offers as the DEFAULT source for it, exported as
      # ``CODETRACER_PINNED_SRC`` from the dev shell, the lint hook, the
      # packaged build and the installed-runtime wrapper defaults.
      #
      # THE NAME IS DELIBERATELY NOT ``CODETRACER_SRC``. That variable is a
      # user override and has to stay one: ``config.nims`` reads it first, a
      # detected ``../codetracer`` sibling second, and this pin only third, so
      # that a developer editing the seam in a workspace checkout sees the edit
      # immediately and an unset variable still means unset. Exporting the pin
      # as ``CODETRACER_SRC`` would put it permanently ahead of both.
      #
      # At f8781d4b5 (CTC-3i, `ct-test` ships beside `ct`) CodeTracer's
      # ``repro.lock`` builds against trace-format 7b8b587c, so
      # ``ct-trace-format-src`` moves to that revision in the same step.
      #
      # At 17c111fb2 (2026-10-13, the published `agents` tip; f8781d4b5 is an
      # ancestor and ``src/ct_incremental_adapter.nim`` is unchanged) the
      # ``repro.lock`` names trace-format 808ffdb4, so ``ct-trace-format-src``
      # moves again with it.
      #
      # At 222a4a009 (2026-10-14, the published `agents` tip; 17c111fb2 is an
      # ancestor) ``repro.nim``, ``config.nims``, ``src/Tuprules.tup`` and
      # ``src/ct_incremental_adapter.nim`` are unchanged and the ``repro.lock``
      # still names trace-format 808ffdb4, so ``ct-trace-format-src`` stays.
      # 7662d329 carries replay-option forwarding and its regression test;
      # the incremental adapter and trace-format resolution are unchanged.
      # 47eda1fd adds native recording navigation; ct-test and the incremental
      # adapter are unchanged. Align the pin with the published workspace.
      # At 272a09ad5 (2026-10-15, the published `agents` tip; 47eda1fd is an
      # ancestor) ``repro.nim``, ``config.nims``, ``src/Tuprules.tup`` and
      # ``src/ct_incremental_adapter.nim`` are unchanged; the ``repro.lock``
      # now names trace-format 5b32588b, so ``ct-trace-format-src`` moves
      # with it.
      #
      # At 23d5af70f (2026-10-15, the published `agents` tip; 272a09ad5 is an
      # ancestor) ``config.nims``, ``src/Tuprules.tup``, ``src/ct_test/ct_test.nim``
      # and ``src/ct_incremental_adapter.nim`` are unchanged. ``repro.nim`` does
      # change -- it declares the Zstandard headers through the new ``zstd-dev``
      # selector -- and that revision's ``repro.lock`` names trace-format d8cd2ed5,
      # so ``ct-trace-format-src`` moves to it in the same step.
      url = "github:metacraft-labs/codetracer/23d5af70f74765e0717e57aefaa453e3a1c18717";
      flake = false;
    };

    # ── reprobuild Nim toolchain: the metacraft-labs/nim fork ──────────────
    # The fork (codetracer-nim, Nim 2.3.1 devel) replaces nixpkgs'
    # nim-unwrapped-2.2.4. It carries a compiler effect-inference fix (so
    # `std/streams`/`std/json` compile under `--mm:orc -d:useNimRtl`, which stock
    # 2.2.x rejects) plus CodeTracer's column-aware tracer. Built koch-boot-free
    # by nix/pkgs/by-name/re/reprobuild/nim-fork.nix. The fork uses the
    # ``git+https`` clone form (the git wire protocol) rather than the
    # ``github:`` form, because its codeload tarball endpoint 404s even for
    # anonymous callers while the anonymous clone works and produces a
    # byte-identical narHash; the
    # compiler itself imports the three vendored deps below (trace/stew/results).
    #
    # This revision also renders the source location that `check` / `require` /
    # `expect` / `assert` plant into the expanded body as a package-anchored
    # canonical path (`tests/a/t.nim`, `std/tables`) instead of an absolute one.
    # Those literals are hashed verbatim into every test's `--list-json`
    # `bodyHash`, so before it the catalog changed with the checkout directory
    # and the stdlib install path, and two hosts building the same commit
    # agreed about nothing. The rendering is anchored on the PACKAGE ROOT, which
    # this repository supplies twice over — see the notes beside
    # `switch("path", ".")` in `config.nims` and at the top of
    # `reprobuild.nimble`, and the guard in
    # `tests/unit/test_package_root_anchor.py`.
    #
    # Advanced from 4e93a8a4 to the `codetracer` tip. That is eight commits,
    # revCount 23089 -> 23097: three changes and their three merges, plus a
    # documentation commit and its merge that add `doc/intern.md` and touch no
    # compiler or stdlib source. Nothing else rides along:
    #
    #   * The five per-case metadata fields the protocol advertises can now
    #     take a second value. `xfail`, `tags`, `group`, `threadsRequired` and
    #     `deterministic` were literals in the emitter, so a consumer could
    #     carry all five, assert that it had carried them, and be asserting on
    #     something no input could change. They now have a source — the test
    #     author — every default is what the field held before, and the module
    #     gained a written conformance contract for the other producers a
    #     project may put behind these flags. Before this commit the syntax did
    #     not compile at all (`unknown named parameter: xfail`).
    #
    #   * A body hash no longer depends on the bodies above it. A hygienic
    #     template local was identified by its gensym name, whose counter
    #     records how many template expansions preceded it IN THE MODULE, so
    #     adding an assertion above a test moved that test's `bodyHash`.
    #     `check`, `require` and `expect` all reach such a local by way of
    #     `fail`, so this bump rehashes every test body that uses an assertion
    #     macro, and only those. The hash is the incremental runner's re-run
    #     signal, so the movement costs one full re-run and then stops costing:
    #     what it buys is that an edit above a test no longer re-runs it.
    #
    #   * The three stdout-bearing protocol modes own descriptor 1. `--list`,
    #     `--list-json` and `--catalog -` write their document to the same
    #     channel the program prints on, and a suite body runs during
    #     REGISTRATION in every mode — so an ordinary `echo` in one could make
    #     the document unparseable, and on `--list`, which has no framing at
    #     all, a partial write fused onto the front of a real case name where
    #     no consumer could undo it. The module now dups the real stdout aside
    #     at initialisation and points fd 1 at stderr, emitting the document to
    #     the saved descriptor; the author's output stays readable on stderr.
    #     Both of this repository's consumers already keep the two streams
    #     apart, so they see a clean document rather than a merged one.
    #
    # Advanced again from 5c77edb2 to 0b5b5ec5. The fork now runs its stdlib
    # Testament category in CI and fixes std/unittest under the JavaScript
    # hot-code-reloading transform. The latter is required by CodeTracer's
    # monitored import/restore path: an initialized local could make the JS HCR
    # transform absorb the following try and emit an orphaned finally.
    #
    # Advanced from f902ddcb to 1e19cf26 for a compiler crash: after a
    # term-rewriting template fires (`warnExecCmdEx` and its siblings in
    # repro_core/ambient_execution.nim), the compiler folded constants over the
    # rewritten statement including its type sections and declared types, and
    # crashed (SIGSEGV, no position) on the untyped `typeOfIter` symbol that
    # `mapIt` leaves there. That is why
    # t_repro_test_runner_process_group_cleanup.nim could not import the whole
    # `repro_daemon_core` facade; it does again. Riding along: a cgen fix that
    # passes a raising call's temporary to its destructor the way the
    # destructor takes it, and VM/NimScript trace recording changes (exact I/O
    # event kinds, one value-carrying step per recorded position).
    nim-fork-src = {
      url = "git+https://github.com/metacraft-labs/nim?ref=codetracer&rev=1e19cf261413667ef69123a3ef221e239d1f8897";
      flake = false;
    };
    nim-csources-src = {
      url = "github:nim-lang/csources_v3/eeab3ac46e93f10efda8e58c4db02b9438319d71";
      flake = false;
    };
    ct-trace-format-src = {
      # CodeTracer 632fdceed imports codetracer_trace_writer/span_stream. Keep
      # this past the span-stream writer, cumulative-index, and encoder fixes;
      # the older c2f3dfc3 pin does not contain that module at all.
      # Moved with ``codetracer-src`` to 7b8b587c, the revision CodeTracer
      # f8781d4b5's ``repro.lock`` names (051efd22 is an ancestor; adds the
      # --mm:none/refc build and the GC-safe reader entry points).
      # Moved with ``codetracer-src`` to 808ffdb4, the revision CodeTracer
      # 17c111fb2's ``repro.lock`` names (7b8b587c is an ancestor; adds the ten
      # exact I/O event kinds of trace format version 7 and a step count that
      # counts step records only).
      # Moved with ``codetracer-src`` to 5b32588b, the revision CodeTracer
      # 272a09ad5's ``repro.lock`` names (808ffdb4 is an ancestor; refuses a
      # container that carries only some of the interning tables).
      # Moved with ``codetracer-src`` to d8cd2ed5, the revision CodeTracer
      # 23d5af70f's ``repro.lock`` names (5b32588b is an ancestor; extends the
      # partial-interning-table refusal to every container writer and reads a
      # MaxRootEntries of 0 as the auto-filled root in every reader).
      url = "github:metacraft-labs/codetracer-trace-format-nim/d8cd2ed542b9cdd990eef8a1cda5c89b539f8d4e";
      flake = false;
    };
    nim-stew-src = {
      url = "github:status-im/nim-stew/83eb1157963b7f49351dbdd858355fa990bbe23c";
      flake = false;
    };
    nim-results-src = {
      url = "github:metacraft-labs/nim-result/df8113dda4c2d74d460a8fa98252b0b771bf1f27";
      flake = false;
    };
    # nim devel bundles `checksums` (md5/sha1, split out of the stdlib) into
    # dist/; the compiler imports it. Pinned to koch's ChecksumsStableCommit.
    nim-checksums-src = {
      url = "github:nim-lang/checksums/0b8e46379c5bc1bf73d8b3011908389c60fb9b98";
      flake = false;
    };
    # nim devel's compiler imports nimony/src/lib/treemangler; koch bundles it
    # into dist/ non-recursively. Pinned to koch's NimonyStableCommit.
    nim-nimony-src = {
      url = "github:nim-lang/nimony/bbfb21529845567c55b67d176354daef0e7d6c29";
      flake = false;
    };
    # The Nix provisioning contribution catalog. `reprobuild.lib`
    # (nix/lib/realizations.nix, `nixRealizationOf`) reads the contribution
    # records it publishes as data -- `provisioning-contributions.json`,
    # generated from its `repro.nim` and kept current by its own tests -- so a
    # Nix module consuming a profile's intent maps canonical package names to
    # nixpkgs attributes from ONE pinned catalog (reprobuild-pm spec
    # Gradual-Nix-To-Reprobuild-Migration.md §The Nix helper library).
    #
    # A flake input of THIS flake, not of each consumer: the library is what
    # reads the catalog, and the catalog revision is part of what
    # `reprobuild.lib` means, so consumers inherit one pin through the one
    # reprobuild pin they already have (devops-modules -> reprobuild), and
    # `follows` it only to test a catalog change. It is not a second
    # reprobuild pin -- the catalog is a separate repository, which pins no
    # reprobuild in any flake (it has no flake.nix). `flake = false`: only the
    # published JSON is read, nothing is built from it. Because the catalog has
    # no flake.nix, `.envrc`'s auto-override arm does not reach a
    # `../reprobuild-nix-packages` sibling (declared in
    # scripts/dev-shell-pinned-siblings.tsv); try a catalog change with
    # `--override-input reprobuild-nix-packages-src git+file:<checkout>`.
    # Move the pin when the catalog's records change.
    reprobuild-nix-packages-src = {
      url = "github:metacraft-labs/reprobuild-nix-packages/8eaa8520008e3cc3da6d081a1547c51c6f632632";
      flake = false;
    };

    # The Homebrew contribution catalog `reprobuild.lib.brewRealizationOf`
    # reads (milestone GM5b): which Homebrew cask or formula installs a
    # canonical package, for hosts whose Home Manager still installs macOS
    # applications through Homebrew, and the reverse map the equivalence
    # report needs. Same arrangement as `reprobuild-nix-packages-src` above,
    # for the same reasons: the library's pin, inherited by consumers through
    # their one reprobuild pin; `flake = false` (only the published
    # `provisioning-contributions.json` is read); the catalog is flake-free,
    # so a sibling checkout is tried with `--override-input
    # reprobuild-brew-packages-src git+file:<checkout>` (declared in
    # scripts/dev-shell-pinned-siblings.tsv). Reprobuild never realizes a
    # Homebrew record (Provisioning-Contributions.md §"Homebrew bridge
    # records"). Move the pin when the catalog's records change.
    reprobuild-brew-packages-src = {
      url = "github:metacraft-labs/reprobuild-brew-packages/49f4057f05b2ebd69d764208279ad5c8b1379fab";
      flake = false;
    };
  };

  outputs =
    inputs@{
      flake-parts,
      git-hooks,
      nimcrypto-src,
      bearssl-src,
      nim-stackable-hooks-src,
      reprobuild-ct-test-runner-src,
      reprobuild-test-adapters-src,
      codetracer-src,
      runquota-src,
      io-mon-src,
      nim-shm-gset-src,
      nim-shm-queue-src,
      nim-fork-src,
      nim-csources-src,
      ct-trace-format-src,
      nim-stew-src,
      nim-results-src,
      nim-checksums-src,
      nim-nimony-src,
      reprobuild-nix-packages-src,
      reprobuild-brew-packages-src,
      bundlers,
      ...
    }:
    let
      # The Nix helper library (milestone GM5; docs/user-guide/nix-helper-library.md),
      # exported as `lib` and tested by the `lib-*` checks below.
      # System-independent: the IFD derivation of `readIntent` is built for
      # whichever system the CALLER names as the evaluator (`buildSystem`),
      # with that system's nixpkgs and `packages.<system>.repro`.
      reprobuildLibFor =
        catalogs:
        import ./nix/lib {
          inherit catalogs;
          pkgsFor = system: inputs.nixpkgs.legacyPackages.${system};
          reproFor = system: inputs.self.packages.${system}.repro;
        };
      nixCatalog = {
        name = "reprobuild-nix-packages";
        records = "${reprobuild-nix-packages-src}/provisioning-contributions.json";
      };
      reprobuildLib = reprobuildLibFor [
        nixCatalog
        {
          name = "reprobuild-brew-packages";
          records = "${reprobuild-brew-packages-src}/provisioning-contributions.json";
        }
      ];
      intentHomeManagerModule = import ./nix/modules/home-manager-intent.nix { inherit reprobuildLib; };
      # The same module over the Nix catalog plus a fixture Homebrew catalog
      # whose records claim packages of the neutral export fixture
      # (tests/fixtures/brew-catalog), so `lib-home-manager` sees the module's
      # DEFAULT `homebrew.realizationOf` hook move them into the token lists.
      brewFixtureHomeManagerModule = import ./nix/modules/home-manager-intent.nix {
        reprobuildLib = reprobuildLibFor [
          nixCatalog
          {
            name = "gm5b-brew-fixture";
            records = ./tests/fixtures/brew-catalog/provisioning-contributions.json;
          }
        ];
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      # No x86_64-darwin: the pinned nixpkgs (26.11) dropped it, so no package,
      # dev shell or check can be built or even evaluated there ("Nixpkgs 26.11
      # has dropped support for x86_64-darwin";
      # https://nixos.org/manual/nixpkgs/unstable/release-notes#x86_64-darwin-26.11),
      # and the macOS fleet is Apple-silicon only. Profiles may still TARGET
      # x86_64-darwin: the Nix helper library (nix/lib/platforms.nix) and
      # `repro home export --target` describe it without nixpkgs.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # ── Distribution-And-Packaging M4 (§9): module exports ──────────────────
      #
      # The NixOS / nix-darwin / home-manager modules that configure reprobuild
      # are DEFINED here, in `nix/modules/`, and exported from this flake. They
      # used to live only in `metacraft-labs/nixos-modules`
      # (`modules/mcl-reprobuild`, `modules/mcl-repro-binary-cache`), which meant
      # an external Nix user could get the PACKAGE from this flake but had to
      # take a dependency on our org's module repo to get the SERVICES.
      #
      # nixos-modules now re-exports these; it holds no copy of the option
      # schema, the caches.conf renderer, or the unit wiring. That direction —
      # reprobuild owns, nixos-modules re-exports — is what keeps the two from
      # drifting, and it is the direction the input graph already allows:
      # nixos-modules pins `reprobuild`, so reprobuild must not need
      # nixos-modules for its modules. (It keeps a `nixos-modules` input for
      # `nixpkgs.follows` only, which is a lock-time pin and not an import.)
      #
      # `inputs.self.packages.<system>` is the module's default package. This is
      # a self-reference through the flake's own outputs, which is lazy and fine
      # so long as nothing inside `perSystem` forces `flake.*` — see the note in
      # nix/modules/reprobuild.nix about the perSystem->flake->perSystem cycle.
      flake =
        let
          reprobuildModules = import ./nix/modules/reprobuild.nix {
            defaultPackageFor = system: inputs.self.packages.${system}.reprobuild;
          };
          reproBinaryCacheModule = import ./nix/modules/repro-binary-cache.nix {
            defaultPackageFor = system: inputs.self.packages.${system}.repro-binary-cache;
          };
        in
        {
          lib = reprobuildLib;

          nixosModules = {
            reprobuild = reprobuildModules.nixos;
            repro-binary-cache = reproBinaryCacheModule;
            # Opt-in compatibility with the historical `programs.reprobuild`
            # option path. External consumers never need it; the metacraft-labs
            # fleet imports it alongside the canonical module so already-deployed
            # `programs.reprobuild.* = …` configuration keeps evaluating.
            reprobuild-legacy-option-names = reprobuildModules.legacyOptionNames;
            default = reprobuildModules.nixos;
          };

          darwinModules = {
            reprobuild = reprobuildModules.darwin;
            reprobuild-legacy-option-names = reprobuildModules.legacyOptionNames;
            default = reprobuildModules.darwin;
          };

          homeManagerModules = {
            # Applies a profile's evaluated intent (`repro home export`)
            # through Home Manager, one category at a time.
            intent = intentHomeManagerModule;
            reprobuild = reprobuildModules.homeManager;
            reprobuild-legacy-option-names = reprobuildModules.legacyOptionNames;
            default = reprobuildModules.homeManager;
          };
        };

      perSystem =
        { pkgs, system, ... }:
        let
          # The `version = "..."` line of a reprobuild.nimble (this tree's, and
          # in `nixpkgs-package-src-sync` the one of package.nix's `src`).
          nimbleVersionOf =
            nimbleFile:
            let
              versionMatches = builtins.filter (match: match != null) (
                map (line: builtins.match ''version = "([^"]+)"'' line) (
                  pkgs.lib.splitString "\n" (builtins.readFile nimbleFile)
                )
              );
            in
            builtins.elemAt (builtins.head versionMatches) 0;
          version = nimbleVersionOf ./reprobuild.nimble;
          # libblake3 has split `out`/`dev` outputs (dev has include/blake3.h,
          # out has lib/libblake3.so). config.nims's prefix-lookup expects a
          # single tree containing both, so they are joined with symlinkJoin —
          # ONCE, in the package derivation, and read back here through
          # `passthru`. The dev shell, the pre-commit hooks and the packaged
          # runtime-compile check all need the same prefix the package was built
          # against, and a second symlinkJoin spelled out here is exactly how
          # they would come to differ.
          blake3Prefix = reprobuild.blake3Prefix;
          # The reprobuild Nim toolchain: the metacraft-labs/nim fork (Nim 2.3.1
          # devel), built from source. Used everywhere the flake previously used
          # `pkgs.nim2` (nixpkgs nim-unwrapped-2.2.4).
          #
          # The derivation lives in the NIXPKGS-FORMAT package directory and is
          # `callPackage`d from here with this flake's source inputs overriding
          # its `fetchFromGitHub` defaults. One derivation serves both entry
          # points: `nix build .#nim-fork` here, and the nixpkgs fork's
          # `pkgs/by-name/re/reprobuild/nim-fork.nix` there. There is no second
          # copy of the bootstrap to drift against.
          nimFork = pkgs.callPackage ./nix/pkgs/by-name/re/reprobuild/nim-fork.nix {
            forkSrc = nim-fork-src;
            csourcesSrc = nim-csources-src;
            traceFormatSrc = ct-trace-format-src;
            stewSrc = nim-stew-src;
            resultsSrc = nim-results-src;
            checksumsSrc = nim-checksums-src;
            nimonySrc = nim-nimony-src;
          };
          # CodeTracer's top-level ct entry point imports the span-stream
          # writer, and the derivation fails Nix EVALUATION if a future pin
          # regression silently points at a pre-span trace-format tree
          # (otherwise the first symptom is a slow, opaque native compile
          # failure). The guard and the `/src` suffix are stated ONCE, in
          # package.nix, and read back here through `passthru` so the dev shell
          # and the packaged-runtime-compile table cannot end up pointing at a
          # different tree than the package was built against.
          codeTracerTraceFormatNimSrc = reprobuild.codeTracerTraceFormatNimSrc;

          # SIBLING SOURCE VARIABLES NAME THE CHECKOUT, NOT ITS STORE COPY.
          #
          # The attributes of `devShells.default` below export each sibling
          # source as `${<input>}/src`, a CONTENT-HASHED store path. These
          # variables reach every compile: `repro.nim` puts them on each test
          # compile's `--path:` and declared environment (the weak
          # fingerprint), and `config.nims` reads them in every compile. So
          # any change to that store path — a commit to an overridden sibling,
          # or a `flake.lock` bump that moves the pin — made all ~1,866
          # `.#test-builds` compiles miss, including those that never import
          # the sibling (reprobuild-specs issue
          # 2026-09-24-sibling-bump-invalidates-every-test-compile).
          #
          # The shell hook re-points the variable at the sibling checkout
          # `../<input without -src>` — a path that is the same at every
          # revision — and `repro.nim` spells it relative to the repository
          # (`../io-mon/src`) on command lines. What a sibling change then
          # invalidates is decided by what each compile actually read from it.
          #
          # THE CONDITION IS "THE CHECKOUT HOLDS WHAT THE INPUT HOLDS", in
          # either of the two ways nix can tell us:
          #
          #   * the input has a clean `rev` (the pinned revision, or a clean
          #     checkout given as an override): the checkout's HEAD is that
          #     revision AND the checkout has no uncommitted or untracked
          #     changes. At the pin OR off it — the pin is not consulted, so a
          #     lock bump that moves the pin does not move the spelling. A
          #     checkout that is dirty here keeps the store path: without an
          #     override the input is the PINNED content, and with a clean
          #     override the dirt arrived after the shell was evaluated, so in
          #     both cases the working tree is not what the input holds.
          #   * the input has a `dirtyRev` (`<rev>-dirty`): it IS a dirty
          #     checkout given as an override, and nix copied its working tree,
          #     dirt included. The checkout's HEAD must be `<rev>`; its dirt is
          #     the content the input already carries.
          #
          # Anything else — no checkout at `../<name>` (CI), a checkout at
          # another revision with no override, an override from elsewhere —
          # keeps the store path, which is stable per pin.
          siblingCheckoutSources =
            let
              row = var: name: sub: {
                inherit var name sub;
                rev = inputs.${name}.rev or "";
                dirtyRev = inputs.${name}.dirtyRev or "";
              };
            in
            [
              (row "IO_MON_SRC" "io-mon-src" "/src")
              (row "RUNQUOTA_SRC" "runquota-src" "")
              (row "STACKABLE_HOOKS_SRC" "nim-stackable-hooks-src" "/src")
              (row "SHM_GSET_SRC" "nim-shm-gset-src" "/src")
              (row "SHM_QUEUE_SRC" "nim-shm-queue-src" "/src")
              (row "REPRO_CT_TEST_RUNNER_SRC" "reprobuild-ct-test-runner-src" "")
              (row "REPRO_TEST_ADAPTERS_SRC" "reprobuild-test-adapters-src" "/src")
              (row "CODETRACER_PINNED_SRC" "codetracer-src" "/src")
            ];
          siblingCheckoutSourcesHook = ''
            _repro_sib_top="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || true)"
            if [ -n "$_repro_sib_top" ]; then
              _repro_sib_ws="$(cd "$_repro_sib_top/.." && pwd -P)"
              _repro_sib_rebind() {
                # $1 variable, $2 input, $3 suffix, $4 clean rev, $5 dirty rev
                local want dirty_ok dir head
                if [ -n "$4" ]; then
                  want="$4"; dirty_ok=0
                elif [ -n "$5" ]; then
                  want="''${5%-dirty}"; dirty_ok=1
                else
                  return 0
                fi
                dir="$_repro_sib_ws/''${2%-src}"
                [ -e "$dir/.git" ] && [ -d "$dir$3" ] || return 0
                head="$(${pkgs.git}/bin/git -C "$dir" rev-parse HEAD 2>/dev/null)" || return 0
                [ "$head" = "$want" ] || return 0
                if [ "$dirty_ok" = 0 ] && \
                    [ -n "$(${pkgs.git}/bin/git -C "$dir" status --porcelain 2>/dev/null)" ]; then
                  return 0
                fi
                export "$1=$dir$3"
              }
          ''
          + pkgs.lib.concatMapStrings (r: ''
            _repro_sib_rebind ${r.var} ${r.name} "${r.sub}" "${r.rev}" "${r.dirtyRev}"
          '') siblingCheckoutSources
          + ''
              unset -f _repro_sib_rebind
              unset _repro_sib_ws
            fi
            unset _repro_sib_top
          '';
          # The RunQuota daemon (and CLI), built from the ``runquota-src``
          # input — the same source the reprobuild client compiles against
          # (``RUNQUOTA_SRC``). Putting this on the dev-shell PATH means the
          # auto-started ``runquotad`` tracks the pinned/overridable source
          # rather than a separately-installed binary, so
          # ``--override-input runquota-src path:../runquota`` yields a daemon
          # built from the local sibling — no ``RUNQUOTAD_BIN`` and no push
          # needed to iterate.
          #
          # RUNQUOTA'S OWN PACKAGE, NOT A COPY OF IT. This used to be a
          # hand-maintained ``mkDerivation`` that re-ran runquota's
          # ``scripts/build_apps.sh`` here — a mirror of runquota's
          # ``packages.default``, and mirrors rot. runquota's binaries have a
          # dependency closure that reprobuild does not share: M13b's published
          # aggregate table made ``runquota_daemon`` / ``runquota_cli_support``
          # import ``shm_lease/*`` from ``nim-shm-lease``, wired through
          # ``SHM_LEASE_SRC`` in runquota's own dev shell and package
          # derivation. The mirror had no such wiring, so bumping the pin to a
          # post-M13b revision broke every ``nix develop`` here with
          # ``cannot open file: shm_lease/anchor`` — in a module reprobuild
          # never imports. Delegating to ``packages.default`` means this flake
          # states no opinion about runquota's dependencies, now or next time.
          runquotaTools = runquota-src.packages.${system}.default;
          # Build CodeTracer's standalone cross-language test driver ``ct-test``
          # from the ``codetracer-src`` input and put it on the dev-shell PATH.
          # Same shape and same motivation as ``runquotaTools`` above: the tool
          # tracks a pinned, overridable source rather than a hand-built binary
          # in someone's sibling checkout, so
          # ``--override-input codetracer-src path:../codetracer`` (which the
          # ``.envrc`` auto-override does for you when the sibling exists)
          # yields a ``ct-test`` built from the local tree with no push.
          #
          # Dependency surface: ``ct-test`` compiles from ``src/ct_test/**``,
          # the Nim stdlib, and runquota's ``runquota_process`` /
          # ``runquota_core`` / ``runquota_host*`` packages — and nothing else.
          # (Verified against the Nim compilation cache of a full build: no
          # vendored ``libs/`` tree, no Electron/frontend stack, no db-backend,
          # no io-mon, no codetracer-trace-format-nim.) That is why this
          # derivation is cheap despite CodeTracer being a large repo, why a
          # submodule-less source input suffices, and why ``RUNQUOTA_SRC`` is
          # the only source path it has to thread through: codetracer's
          # repo-root ``config.nims`` reads that variable and adds the runquota
          # library paths, the sandbox having no ``../runquota`` sibling.
          ctTestTools = pkgs.stdenv.mkDerivation {
            pname = "ct-test";
            version = "0.1.0";
            src = codetracer-src;
            strictDeps = true;
            dontConfigure = true;
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              nimFork
            ];
            RUNQUOTA_SRC = runquota-src;
            # The compile is spelled out here rather than delegated to a script
            # in the codetracer checkout (which is how ``runquotaTools`` calls
            # ``scripts/build_apps.sh``) for one concrete reason: codetracer has
            # no such script, and adding one would make this derivation
            # unbuildable at the pinned revision until that script is pushed —
            # i.e. an override-free ``nix develop`` would break. Keeping the
            # invocation self-contained means this input can be pinned to any
            # codetracer revision that carries ``src/ct_test``.
            #
            # It intentionally mirrors the ``ct-test`` target in codetracer's
            # ``repro.nim``, which stays the graph's declaration of this binary.
            # The two are not flag-identical — the graph target additionally
            # asks for debug info, line/stack traces and bound checks, and this
            # one does not — so treat the graph as authoritative for the shipped
            # product and this as the dev-shell convenience build.
            #
            # They do agree on the one flag that changes what the binary can do:
            # ``--mm:orc``. It is spelled out below rather than left to the
            # compiler's default because ``test run`` drives a worker pool whose
            # threads share the discovered sequences, which refc's per-thread
            # heaps cannot support; a refc build of these sources therefore
            # either refuses ``run`` outright (newer sources, which carry an
            # explicit guard) or crashes in the worker loop (older ones). Either
            # way, silently inheriting a changed default would turn this from a
            # runner into a discover-only tool, so the flag is stated.
            buildPhase = ''
              runHook preBuild
              mkdir -p build/bin build/nimcache
              nim c \
                --threads:on \
                --mm:orc \
                --nimcache:build/nimcache/ct-test \
                --out:build/bin/ct-test \
                src/ct_test/ct_test.nim
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin"
              install -m755 build/bin/ct-test "$out/bin/ct-test"
              runHook postInstall
            '';
          };
          pre-commit-check = git-hooks.lib.${system}.run {
            src = ./.;
            hooks.just-lint = {
              enable = true;
              name = "just lint";
              # The tool list is the hook's CONTRACT, not a convenience: a
              # commit-time gate that reaches past it into the ambient PATH
              # passes or fails depending on which shell the contributor
              # happened to commit from. `just lint` grew a workflow check
              # (actionlint, which shells out to shellcheck) and a suite
              # case-count check (python3) without them being declared here,
              # so committing from anywhere but the dev shell failed with
              # "actionlint not found on PATH" on an unmodified checkout.
              # Everything `just lint` runs must be named below.
              entry = "${pkgs.writeShellScript "reprobuild-just-lint" ''
                export PATH=${
                  pkgs.lib.makeBinPath [
                    pkgs.actionlint
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.gnugrep
                    # The text tools every check here scans with. They were
                    # absent, and absence did not present as absence: with
                    # only this PATH, `check_dev_shell_env.sh` reported nine
                    # failures — no parseable flake input, and five declared
                    # rows excusing inputs "flake.nix does not declare" —
                    # because `awk` and `sed` were not there to parse either
                    # file. Nothing in that report was true and nothing in it
                    # could be fixed by editing the repository. `find` is the
                    # quieter one: without it the override-source fingerprint
                    # falls back to `mtime:none` for any source that is not a
                    # git checkout, which never drifts and so never fails.
                    # coreutils supplies neither `awk`, `sed`, nor `find`.
                    pkgs.gawk
                    pkgs.gnused
                    pkgs.findutils
                    pkgs.just
                    pkgs.python3
                    pkgs.shellcheck
                    # `check_dev_shell_env.sh`'s one-glibc check reads ELF
                    # headers: `patchelf` for PT_INTERP and DT_RUNPATH,
                    # `readelf` (binutils, last in this list) for the
                    # `.gnu.version_d` / `.gnu.version_r` tables. It REFUSES
                    # rather than skips when they are absent — an environment
                    # that injects loader state but cannot be inspected is the
                    # state the check exists for — so they are part of this
                    # hook's contract, not something to find on the ambient
                    # PATH.
                    pkgs.patchelf
                    # …and git, for the same reason: the check asks whether
                    # the git this environment resolves runs on the same glibc
                    # as the libraries it injects. Left to the ambient PATH,
                    # that question would be answered by whichever git the
                    # contributor's profile happens to carry, and the hook
                    # would pass or fail on something the repository does not
                    # control.
                    pkgs.git
                    nimFork
                    # LAST on purpose. binutils is here only for `readelf`,
                    # but it also ships `ld` / `as` / `ar` / `nm`, and this
                    # list is prepended to PATH. Ahead of `nimFork` it would
                    # shadow the toolchain any future compiling step in
                    # `just lint` resolves; behind it, `readelf` is still
                    # found (nothing else in the list provides one) and
                    # nothing else moves.
                    pkgs.binutils
                  ]
                }:$PATH
                export BLAKE3_PREFIX=${blake3Prefix}
                export NIMCRYPTO_SRC=${nimcrypto-src}
                export BEARSSL_SRC=${bearssl-src}
                export STACKABLE_HOOKS_SRC=${nim-stackable-hooks-src}/src
                export CODETRACER_TRACE_FORMAT_NIM_SRC=${codeTracerTraceFormatNimSrc}
                export IO_MON_SRC=${io-mon-src}/src
                export SHM_GSET_SRC=${nim-shm-gset-src}/src
                export SHM_QUEUE_SRC=${nim-shm-queue-src}/src
                export CODETRACER_PINNED_SRC=${codetracer-src}/src
                export REPRO_CT_TEST_RUNNER_SRC=${reprobuild-ct-test-runner-src}
                export REPRO_TEST_ADAPTERS_SRC=${reprobuild-test-adapters-src}/src
                export REPROBUILD_USE_SYSTEM_HASH_LIBS=1
                export RUNQUOTA_SRC=${runquota-src}
                export XXHASH_PREFIX=${pkgs.xxHash}
                exec ${pkgs.just}/bin/just lint
              ''}";
              language = "system";
              pass_filenames = false;
            };
            # The suite case-count baseline gate, at the PUSH boundary.
            #
            # `just lint` already runs this check, but `just lint` is a
            # multi-minute whole-tree compile, so it sits at the pre-commit
            # stage where it is routinely bypassed -- and in CI it only
            # answers after the commit has already reached the branch. A
            # stale baseline therefore reached `dev` twice, and each
            # subsequent branch had to carry someone else's regeneration.
            #
            # This hook is a source scan: no compiler, no built binaries,
            # ~5s on the full tree. That is what makes it affordable at
            # every push, and an affordable gate is one nobody has a reason
            # to bypass.
            hooks.suite-case-counts = {
              enable = true;
              name = "suite case-count baseline";
              stages = [ "pre-push" ];
              entry = "${pkgs.writeShellScript "reprobuild-check-suite-case-counts" ''
                export PATH=${
                  pkgs.lib.makeBinPath [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.git
                    pkgs.gnugrep
                    pkgs.python3
                  ]
                }:$PATH
                exec ${pkgs.bash}/bin/bash scripts/check_suite_case_counts.sh
              ''}";
              language = "system";
              pass_filenames = false;
              always_run = true;
            };
            # The vacuous-case gate, at the same PUSH boundary and for the
            # same reasons as the case-count baseline above.
            #
            # A test case whose only assertion is `check true` reports [OK]
            # and increments the pass count, so it is invisible to every
            # downstream signal -- the suite, the summary, the coverage
            # numbers. It is strictly worse than a skip, which this repo
            # already refuses, because a skip is at least counted. Running
            # the suite cannot find one; only a source scan can, and this
            # one costs seconds.
            hooks.vacuous-test-cases = {
              enable = true;
              name = "no test case asserts only `check true`";
              stages = [ "pre-push" ];
              entry = "${pkgs.writeShellScript "reprobuild-check-vacuous-test-cases" ''
                export PATH=${
                  pkgs.lib.makeBinPath [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.git
                    pkgs.gnugrep
                    pkgs.python3
                  ]
                }:$PATH
                exec ${pkgs.python3}/bin/python3 scripts/check_vacuous_test_cases.py
              ''}";
              language = "system";
              pass_filenames = false;
              always_run = true;
            };
          };
          reprobuildSource = ./.;
          # ── The reprobuild package ────────────────────────────────────────
          #
          # The derivation is DEFINED ONCE, in nixpkgs `pkgs/by-name/` form at
          # nix/pkgs/by-name/re/reprobuild/package.nix, and `callPackage`d here
          # with this flake's inputs overriding its `fetchFromGitHub` defaults.
          # That is what makes `--override-input io-mon-src path:../io-mon` (and
          # the `.envrc` sibling auto-overrides) still work while the very same
          # file, copied verbatim into metacraft-labs/nixpkgs, builds with no
          # flake plumbing at all.
          #
          # It replaced a hand-maintained second copy of this derivation that
          # sat alongside the flake's. The copies HAD drifted: the nixpkgs one
          # was still on version 0.1.0, used `nim2` instead of the fork, pinned
          # `rev = "main"` (a retired branch — and a moving ref inside a
          # fixed-output fetch), and named three of the thirteen source inputs
          # the build actually needs. Two derivations for one package do not
          # stay in step; one derivation with overridable source arguments does,
          # by construction.
          #
          # `version` is parsed from reprobuild.nimble here and passed in.
          # package.nix cannot parse it itself — reading `${src}/…` would be
          # import-from-derivation, which nixpkgs forbids — so it carries a
          # literal default, and `checks.nixpkgs-package-version-sync` fails if
          # that literal and the manifest disagree.
          #
          # `xxhash` is passed explicitly because nixpkgs renamed the attribute:
          # this flake's nixpkgs pin still spells it `xxHash`, while current
          # nixpkgs (and the fork) spell it `xxhash`. package.nix names the
          # current spelling, as an upstream submission must.
          reprobuild =
            (pkgs.callPackage ./nix/pkgs/by-name/re/reprobuild/package.nix {
              inherit nimFork;
              xxhash = pkgs.xxHash;
              nimcryptoSrc = nimcrypto-src;
              bearsslSrc = bearssl-src;
              stackableHooksSrc = nim-stackable-hooks-src;
              macosTools =
                if pkgs.stdenv.isDarwin then
                  inputs.stackable-hooks-macos-tools.packages.${system}.default
                else
                  null;
              ctTraceFormatSrc = ct-trace-format-src;
              ioMonSrc = io-mon-src;
              shmGsetSrc = nim-shm-gset-src;
              shmQueueSrc = nim-shm-queue-src;
              codetracerSrc = codetracer-src;
              ctTestRunnerSrc = reprobuild-ct-test-runner-src;
              testAdaptersSrc = reprobuild-test-adapters-src;
              runquotaSrc = runquota-src;
            }).overrideAttrs
              (old: {
                # `src` and `version` go through overrideAttrs, not through
                # callPackage arguments: callPackage fills an argument from the
                # package set whenever the set has that name, and nixpkgs has a
                # `src` attribute, so a `src ? …` argument is unusable. See the
                # note at the top of package.nix.
                inherit version;
                src = reprobuildSource;
                # The commit the binaries are built from, embedded as
                # `ReprobuildSourceRevision` by scripts/build_apps.sh, which
                # asks scripts/source_revision.sh (the one derivation; the
                # variable wins over git there). The sandbox has no .git, so
                # the flake supplies it; a dirty tree reports `dirtyRev`
                # (`<sha>-dirty`).
                env = old.env // {
                  REPROBUILD_SOURCE_REVISION = inputs.self.rev or inputs.self.dirtyRev or "";
                };
              });
          # Read back from the package so the dev shell, the pre-commit hooks
          # and the packaged runtime-compile check all use the same library set
          # the package itself was fixed up against.
          runtimeLibraries = reprobuild.runtimeLibraries;
          runtimeLibraryPath = reprobuild.runtimeLibraryPath;
          reprobuildClosure = pkgs.closureInfo {
            rootPaths = [ reprobuild ];
          };
          packagedRuntimeCompileCheck =
            pkgs.runCommand "reprobuild-packaged-runtime-compile"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gcc
                  pkgs.gnugrep
                ]
                ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf ]
                ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
                  pkgs.binutils
                  pkgs.cctools
                ];
              }
              ''
                                    export HOME="$TMPDIR/home"
                                    export TMPDIR="$TMPDIR/tmp"
                                    mkdir -p "$HOME" "$TMPDIR" "$TMPDIR/direct/project"

                                    daemonEndpoint="$TMPDIR/packaged-repro-daemon.sock"
                                    daemonState="$TMPDIR/packaged-daemon-state"
                                    daemonRuntime="$TMPDIR/packaged-daemon-runtime"
                                    runtimePath=${
                                      pkgs.lib.makeBinPath [
                                        pkgs.bash
                                        pkgs.coreutils
                                        pkgs.gcc
                                        pkgs.gnugrep
                                      ]
                                    }

                                    runDaemonControl() {
                                      ${pkgs.coreutils}/bin/env -i \
                                        HOME="$HOME" TMPDIR="$TMPDIR" PATH="$runtimePath" \
                                        REPRO_DAEMON_RUNTIME_DIR="$daemonRuntime" \
                                        ${reprobuild}/bin/repro daemon "$1" \
                                          --endpoint "$daemonEndpoint" \
                                          --state-dir "$daemonState" \
                                          --log "$daemonState/logs/repro-daemon.log"
                                    }
                                    cleanupDaemon() {
                                      runDaemonControl stop >/dev/null 2>&1 || true
                                      rm -f "$daemonEndpoint"
                                    }
                                    showFailureLogs() {
                                      status=$?
                                      for log in \
                                        "$TMPDIR/direct-build.log" \
                                        "$TMPDIR/daemon-build.log" \
                                        "$TMPDIR/daemon-status.log" \
                                        "$TMPDIR/explicit-override.log"; do
                                        if test -f "$log"; then
                                          echo "--- tail of $log ---" >&2
                                          tail -n 200 "$log" >&2
                                        fi
                                      done
                                      exit "$status"
                                    }
                                    trap cleanupDaemon EXIT
                                    trap showFailureLogs ERR
                                    # Let the ERR trap fire inside shell functions too: a
                                    # failed `test` in assertColdActionLog used to end the
                                    # build with no output at all.
                                    set -o errtrace

                                    assertColdActionLog() {
                                      log="$1"
                                      test "$(grep -Ec '^providerCompileAction: ' "$log")" -eq 1
                                      test "$(grep -Ec '^action: ' "$log")" -eq 3
                                      # The provider compile edge is consulted more than once
                                      # per invocation and only the LAST consultation is
                                      # logged; after a real compile that one reads
                                      # `asUpToDate ... reason=outputs-present`. Whether THIS
                                      # invocation compiled the provider is `compiled=`
                                      # (repro_cli_support `providerCompileInvocationSummary`),
                                      # so a cold build must say `compiled=true`.
                                      test "$(grep -Ec '^providerCompileAction: __repro_provider_compile status=(asSucceeded launched=true|asUpToDate launched=false .*reason=outputs-present) .*compiled=true( |$)' "$log")" -eq 1
                                      for actionName in build-dir compile-hello run-hello; do
                                        test "$(grep -Ec "^action: $actionName status=asSucceeded launched=true( |$)" "$log")" -eq 1
                                      done
                                      if grep -Eq '^action: .*status=(asFailed|asBlocked|asSkipped|asUpToDate|asCacheHit)' "$log" ||
                                        grep -Eq '^providerCompileAction: .*status=(asFailed|asBlocked|asSkipped|asCacheHit)' "$log"; then
                                        echo "cold package gate accepted a non-launched action" >&2
                                        return 1
                                      fi
                                    }

                                    # Every public entry point must be a wrapper paired with one
                                    # hidden target. Enumerate rather than hard-code the current
                                    # binaries so newly installed helpers (including scripts)
                                    # cannot bypass the packaged defaults.
                                    wrapperCount=0
                                    for wrapper in ${reprobuild}/bin/*; do
                                      name=$(basename "$wrapper")
                                      hidden=${reprobuild}/bin/.$name-wrapped
                                      if test ! -x "$wrapper"; then
                                        echo "unexpected non-executable bin artifact: $wrapper" >&2
                                        exit 1
                                      fi
                                      test -f "$hidden"
                                      grep -Fq "$hidden" "$wrapper"
                                      if grep -Eq 'LD_LIBRARY_PATH|DYLD_(LIBRARY_PATH|FALLBACK_LIBRARY_PATH)' "$wrapper"; then
                                        echo "loader search path leaked through wrapper: $wrapper" >&2
                                        exit 1
                                      fi
                                      while IFS='|' read -r variable expected; do
                                        grep -Fq "$variable" "$wrapper"
                                        grep -Fq "$expected" "$wrapper"
                                      done <<DEFAULTS
                REPROBUILD_RUNTIME_LIBRARY_PATH|${runtimeLibraryPath}
                REPROBUILD_SOURCE_ROOT|${reprobuildSource}
                BLAKE3_PREFIX|${blake3Prefix}
                NIMCRYPTO_SRC|${nimcrypto-src}
                BEARSSL_SRC|${bearssl-src}
                STACKABLE_HOOKS_SRC|${nim-stackable-hooks-src}/src
                CODETRACER_TRACE_FORMAT_NIM_SRC|${codeTracerTraceFormatNimSrc}
                IO_MON_SRC|${io-mon-src}/src
                SHM_GSET_SRC|${nim-shm-gset-src}/src
                SHM_QUEUE_SRC|${nim-shm-queue-src}/src
                CODETRACER_PINNED_SRC|${codetracer-src}/src
                REPRO_CT_TEST_RUNNER_SRC|${reprobuild-ct-test-runner-src}
                REPRO_TEST_ADAPTERS_SRC|${reprobuild-test-adapters-src}/src
                REPROBUILD_USE_SYSTEM_HASH_LIBS|1
                RUNQUOTA_SRC|${runquota-src}
                SQLITE_PREFIX|${pkgs.sqlite.out}
                XXHASH_PREFIX|${pkgs.xxHash}
                CLINGO_PREFIX|${pkgs.clingo}
                REPRO_NIM_COMPILER|${nimFork}/bin/nim
                DEFAULTS
                                      wrapperCount=$((wrapperCount + 1))
                                    done
                                    test "$wrapperCount" -gt 0
                                    for hidden in ${reprobuild}/bin/.*-wrapped; do
                                      name=$(basename "$hidden")
                                      publicName=$(printf '%s' "$name" | sed -e 's/^\.//' -e 's/-wrapped$//')
                                      test -f "${reprobuild}/bin/$publicName"
                                    done

                                    ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
                                      # Every installed ELF role, including hidden wrapper
                                      # targets and .old libraries, carries all six package
                                      # runtime dirs as distinct DT_RPATH entries.
                                      elfCount=0
                                      for candidate in ${reprobuild}/bin/* ${reprobuild}/bin/.*-wrapped ${reprobuild}/lib/*; do
                                        if rpath=$(${pkgs.patchelf}/bin/patchelf --print-rpath "$candidate" 2>/dev/null); then
                                          elfCount=$((elfCount + 1))
                                          for requiredRpath in \
                                            ${blake3Prefix}/lib \
                                            ${pkgs.xxHash}/lib \
                                            ${pkgs.sqlite.out}/lib \
                                            ${pkgs.openssl.out}/lib \
                                            ${pkgs.zstd.out}/lib \
                                            ${pkgs.clingo}/lib; do
                                            case ":$rpath:" in
                                              *":$requiredRpath:"*) ;;
                                              *) echo "incomplete RPATH on $candidate: $rpath" >&2; exit 1 ;;
                                            esac
                                          done
                                        else
                                          case "$candidate" in
                                            ${reprobuild}/bin/.*-wrapped)
                                              # A wrapper target may be an interpreter
                                              # script (`reprobuild-nix-daemon` is Python):
                                              # it has no RPATH to carry, but its
                                              # interpreter must be an executable in the
                                              # store, never one found on the host.
                                              interpreter=$(head -n 1 "$candidate" | sed -n 's|^#! *\([^ ]*\).*|\1|p')
                                              case "$interpreter" in
                                                /nix/store/*)
                                                  if test ! -x "$interpreter"; then
                                                    echo "wrapper target's interpreter is not executable: $candidate -> $interpreter" >&2
                                                    exit 1
                                                  fi
                                                  ;;
                                                *)
                                                  echo "non-ELF wrapper target without a store interpreter: $candidate" >&2
                                                  exit 1
                                                  ;;
                                              esac
                                              ;;
                                            ${reprobuild}/lib/*)
                                              echo "non-ELF installed binary/library role: $candidate" >&2
                                              exit 1
                                              ;;
                                          esac
                                        fi
                                      done
                                      test "$elfCount" -gt 0
                                    ''}

                                    ${pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
                                      # Use the same strict per-slice audit exercised by the
                                      # Linux-hosted behavioral fixture. It resolves dependency
                                      # tokens against each architecture's own LC_RPATH list and
                                      # verifies final arm signatures after postFixup mutation.
                                      # nixpkgs' sigtool only implements signing, so use Apple's
                                      # verifier explicitly rather than whichever `codesign`
                                      # happens to occur first on the build PATH.
                                      CODESIGN=/usr/bin/codesign \
                                        ${pkgs.bash}/bin/bash ${./scripts/audit_macho_runtime.sh} \
                                        ${reprobuild} \
                                        ${blake3Prefix}/lib \
                                        ${pkgs.xxHash}/lib \
                                        ${pkgs.sqlite.out}/lib \
                                        ${pkgs.openssl.out}/lib \
                                        ${pkgs.zstd.out}/lib \
                                        ${pkgs.clingo}/lib

                                      # Prove the installed program bytes contain the exact
                                      # LC_RPATH-aware dlopen names. The pure target helper tests
                                      # reject bare Darwin constants on Linux; the isolated runtime
                                      # exercises below then load clingo through the installed image.
                                      zstdLoaderCount=0
                                      clingoLoaderCount=0
                                      for candidate in ${reprobuild}/bin/.*-wrapped ${reprobuild}/lib/*; do
                                        if lipo -archs "$candidate" >/dev/null 2>&1; then
                                          # Nim's emitted string objects expose one printable
                                          # metadata byte (`@`) immediately before their text to
                                          # GNU strings. Remove that byte before comparing the
                                          # exact loader constant.
                                          loaderStrings=$(strings "$candidate" | sed -e 's/^@//')
                                          if grep -Fxq '@rpath/libzstd.1.dylib' <<< "$loaderStrings"; then
                                            zstdLoaderCount=$((zstdLoaderCount + 1))
                                          fi
                                          if grep -Fxq '@rpath/libclingo.dylib' <<< "$loaderStrings"; then
                                            clingoLoaderCount=$((clingoLoaderCount + 1))
                                          fi
                                          if grep -Fxq 'libzstd.1.dylib' <<< "$loaderStrings"; then
                                            echo "bare zstd Darwin loader name in $candidate" >&2
                                            exit 1
                                          fi
                                        fi
                                      done
                                      test "$zstdLoaderCount" -gt 0
                                      test "$clingoLoaderCount" -gt 0
                                    ''}

                                    cp -R ${./tests/fixtures/packaged-runtime-compile}/. \
                                      "$TMPDIR/direct/project/"
                                    chmod -R u+w "$TMPDIR/direct/project"

                                    # A source-looking sibling must not shadow the package's pinned
                                    # adapter. The file is intentionally uncompilable: reaching it
                                    # makes the positive real-execution gate fail hard.
                                    hostile="$TMPDIR/direct/reprobuild-test-adapters/src/repro_test_adapters"
                                    mkdir -p "$hostile"
                                    printf '%s\n' '{.error: "HOSTILE_SIBLING_ADAPTER_WAS_USED".}' \
                                      > "$hostile/test_runner.nim"

                                    # Direct cold build: env -i deliberately omits the source root
                                    # and every package prefix so the wrapper defaults are exercised.
                                    (
                                      cd "$TMPDIR/direct/project"
                                      ${pkgs.coreutils}/bin/env -i \
                                        HOME="$HOME" TMPDIR="$TMPDIR" PATH="$runtimePath" \
                                        REPROBUILD_STORE_ROOT="$TMPDIR/direct-store" \
                                        REPROBUILD_ACTION_CACHE_ROOT="$TMPDIR/direct-action-cache" \
                                        ${reprobuild}/bin/repro build . \
                                          --daemon=off --no-runquota \
                                          --tool-provisioning=path --progress=none --log=actions
                                    ) > "$TMPDIR/direct-build.log" 2>&1
                                    assertColdActionLog "$TMPDIR/direct-build.log"
                                    test "$(cat "$TMPDIR/direct/project/build/hello-output.txt")" = \
                                      "reprobuild packaged runtime: hello"
                                    if grep -Fq HOSTILE_SIBLING_ADAPTER_WAS_USED "$TMPDIR/direct-build.log"; then
                                      echo "packaged build selected the hostile sibling adapter" >&2
                                      exit 1
                                    fi

                                    # CodeTracer-style positive override: a writable source copy
                                    # with spaces and shell metacharacters, while every external
                                    # source/prefix remains the installed wrapper default. Start a
                                    # real isolated daemon first so --daemon=require cannot fall
                                    # back to direct execution.
                                    sourceOverride="$TMPDIR/CodeTracer source [override] #1;copy"
                                    daemonProject="$TMPDIR/daemon project [override] #1"
                                    mkdir -p "$sourceOverride" "$daemonProject"
                                    cp -R ${reprobuildSource}/. "$sourceOverride/"
                                    cp -R ${./tests/fixtures/packaged-runtime-compile}/. "$daemonProject/"
                                    chmod -R u+w "$sourceOverride" "$daemonProject"
                                    runDaemonControl start > "$TMPDIR/daemon-start.log" 2>&1
                                    runDaemonControl status > "$TMPDIR/daemon-status.log" 2>&1
                                    grep -Fq 'repro daemon: running' "$TMPDIR/daemon-status.log"
                                    (
                                      cd "$daemonProject"
                                      ${pkgs.coreutils}/bin/env -i \
                                        HOME="$HOME" TMPDIR="$TMPDIR" PATH="$runtimePath" \
                                        REPRO_DAEMON_ENDPOINT="$daemonEndpoint" \
                                        REPRO_DAEMON_STATE_DIR="$daemonState" \
                                        REPRO_DAEMON_RUNTIME_DIR="$daemonRuntime" \
                                        REPROBUILD_SOURCE_ROOT="$sourceOverride" \
                                        REPROBUILD_STORE_ROOT="$TMPDIR/daemon-store" \
                                        REPROBUILD_ACTION_CACHE_ROOT="$TMPDIR/daemon-action-cache" \
                                        ${reprobuild}/bin/repro build . \
                                          --daemon=require --no-runquota \
                                          --tool-provisioning=path --progress=none --log=actions
                                    ) > "$TMPDIR/daemon-build.log" 2>&1
                                    assertColdActionLog "$TMPDIR/daemon-build.log"
                                    test "$(cat "$daemonProject/build/hello-output.txt")" = \
                                      "reprobuild packaged runtime: hello"
                                    runDaemonControl status > "$TMPDIR/daemon-status.log" 2>&1
                                    grep -Fq 'active-sessions: 0' "$TMPDIR/daemon-status.log"
                                    runDaemonControl stop > "$TMPDIR/daemon-stop.log" 2>&1
                                    runDaemonControl status > "$TMPDIR/daemon-after-stop.log" 2>&1
                                    grep -Fq 'repro daemon: not-running' "$TMPDIR/daemon-after-stop.log"
                                    test ! -e "$daemonEndpoint"

                                    # makeWrapper defaults must preserve explicit overrides. A
                                    # deliberately broken adapter must be selected, not masked.
                                    mkdir -p "$TMPDIR/explicit-adapter/src/repro_test_adapters" \
                                      "$TMPDIR/override-project"
                                    cp -R ${./tests/fixtures/packaged-runtime-compile}/. \
                                      "$TMPDIR/override-project/"
                                    chmod -R u+w "$TMPDIR/override-project"
                                    printf '%s\n' '{.error: "EXPLICIT_ADAPTER_OVERRIDE_WAS_USED".}' \
                                      > "$TMPDIR/explicit-adapter/src/repro_test_adapters/test_runner.nim"
                                    if (
                                      cd "$TMPDIR/override-project"
                                      ${pkgs.coreutils}/bin/env -i \
                                        HOME="$HOME" TMPDIR="$TMPDIR" PATH="$runtimePath" \
                                        REPRO_TEST_ADAPTERS_SRC="$TMPDIR/explicit-adapter/src" \
                                        REPROBUILD_STORE_ROOT="$TMPDIR/override-store" \
                                        REPROBUILD_ACTION_CACHE_ROOT="$TMPDIR/override-action-cache" \
                                        ${reprobuild}/bin/repro build . \
                                          --daemon=off --no-runquota \
                                          --tool-provisioning=path --progress=none --log=actions
                                    ) > "$TMPDIR/explicit-override.log" 2>&1; then
                                      echo "packaged wrapper masked an explicit adapter override" >&2
                                      exit 1
                                    fi
                                    grep -Fq EXPLICIT_ADAPTER_OVERRIDE_WAS_USED \
                                      "$TMPDIR/explicit-override.log"

                                    # Every source/prefix used as an installed-runtime default must be
                                    # a real member of the package closure, not an ambient store path.
                                    cp ${reprobuildClosure}/store-paths "$TMPDIR/package-closure"
                                    for required in \
                                      ${reprobuildSource} \
                                      ${nimcrypto-src} \
                                      ${bearssl-src} \
                                      ${nim-stackable-hooks-src} \
                                      ${ct-trace-format-src} \
                                      ${io-mon-src} \
                                      ${nim-shm-gset-src} \
                                      ${nim-shm-queue-src} \
                                      ${codetracer-src} \
                                      ${reprobuild-ct-test-runner-src} \
                                      ${reprobuild-test-adapters-src} \
                                      ${runquota-src} \
                                      ${blake3Prefix} \
                                      ${pkgs.sqlite.out} \
                                      ${pkgs.xxHash} \
                                      ${pkgs.openssl.out} \
                                      ${pkgs.zstd.out} \
                                      ${pkgs.clingo}; do
                                      if ! grep -Fxq "$required" "$TMPDIR/package-closure"; then
                                        echo "missing packaged runtime closure path: $required" >&2
                                        exit 1
                                      fi
                                    done

                                    mkdir -p "$out"
                                    cp "$TMPDIR/direct-build.log" "$out/"
                                    cp "$TMPDIR/daemon-build.log" "$out/"
                                    cp "$TMPDIR/package-closure" "$out/"
              '';
          reproApp = {
            type = "app";
            program = "${reprobuild}/bin/repro";
          };
          # Windows-Runner-Binary-Cache-Deploy M1 — expose the binary-cache
          # HTTP daemon as its own package so the nixos-modules
          # `services.mcl-repro-binary-cache` systemd unit has a runnable
          # artifact to reference. It is the same `just build` closure as
          # `reprobuild` (which installs every build/bin/* entrypoint,
          # including the newly-added build/bin/repro-binary-cache); we only
          # retarget `meta.mainProgram` so `lib.getExe` resolves the daemon.
          reproBinaryCache = reprobuild.overrideAttrs (old: {
            pname = "repro-binary-cache";
            meta = (old.meta or { }) // {
              description = "Reprobuild binary-cache HTTP server daemon";
              mainProgram = "repro-binary-cache";
            };
          });
          reproBinaryCacheApp = {
            type = "app";
            program = "${reproBinaryCache}/bin/repro-binary-cache";
          };
          # Binary-Caches.md §"Client CLI Surface (`repro cache`)" — the
          # standalone `repro-binary-cache-client` package/app was RETIRED. Its
          # toolset (publish/substitute/lookup/derive-key/gen-key) was folded
          # into the `repro cache <subcommand>` dispatch shipped by the main
          # `reprobuild` package (`bin/repro`). Callers that used
          # `packages.repro-binary-cache-client` now use `packages.reprobuild`
          # and invoke `repro cache …`.
          # Portable/self-contained `repro`: package the ENTIRE `reprobuild`
          # store closure into one self-extracting, relocatable executable so
          # the CLI runs on a plain host (e.g. an im2-debian-cloud GitHub
          # Actions runner image, or a developer workstation) that has NO
          # /nix/store present.
          #
          # Why a bundle and NOT a static (musl/`--passL:-static`) build:
          #  * The single `repro` CLI links OpenSSL (`--define:ssl`) and, at
          #    MODULE-INIT time (Nim `{.dynlib.}`
          #    `DatInit`, before `main`), dlopens `libclingo.so` by the
          #    absolute path the Nim compiler baked into `.rodata`
          #    (libs/repro_solver/.../clingo_bindings.nim documents this eager
          #    load). A dlopen-by-baked-abs-path solver cannot be statically
          #    linked, and clingo/openssl/blake3/sqlite would all have to be
          #    static too. So a true static binary is infeasible here.
          #  * The `toArx` bundler embeds the whole closure and, at run time,
          #    uses `nix-user-chroot` to expose the extracted store at the
          #    real `/nix/store` inside a user namespace. That makes every
          #    baked `/nix/store/...` rpath, PT_INTERP, and the clingo dlopen
          #    path resolve WITHOUT a real `/nix/store` on the host. It
          #    requires unprivileged user namespaces (default on the target
          #    Debian image).
          #
          # This is the same machinery as `nix bundle --bundler
          # github:NixOS/bundlers#toArx .#reprobuild`, wired as a first-class
          # package output so callers can just `nix build .#repro-portable`.
          # The bundler keys off `meta.mainProgram` ("repro"), so the produced
          # executable launches the single `repro` image from the extracted
          # closure. It ADDS to — and does not
          # disturb — `packages.default`/`packages.reprobuild` or `just build`.
          reproPortable = bundlers.bundlers.${system}.toArx reprobuild;

          # The language toolchains the Mode 2/3 convention tests drive --
          # `libs/repro_standard_provider/tests/test_<lang>_*_convention` and
          # the `mixed/*` cross-language cases -- for `devShells.default`.
          # Each case probes PATH and SKIPS without its toolchain; before
          # these were in the dev shell, every one of those cases skipped on
          # Linux, so the conventions were never exercised on the platform
          # the suite runs on.
          #
          # They are part of the DEFAULT shell, not a separate test shell: the
          # dev shell a project declares is the one its tests run in. The cost
          # is closure size -- they add 12.4 GiB to the shell's 4.9 GiB
          # (x86_64-linux, measured 2026-09-27) -- a one-time store cost per
          # pin, not a per-entry one.
          #
          # Pins mirror `repro.nim`'s Windows fixture constants where nixpkgs
          # carries the pinned line: Zig 0.13 (pre-1.0; the M44 fixtures were
          # audited against it), the .NET 8.0 SDK band, JDK 21, Gradle 8,
          # FPC 3.2.2 and Swift 5.10.1 (the nixpkgs defaults happen to be
          # those exact versions). Go is the exception: nixpkgs has removed
          # the end-of-life 1.23 line, so it is nixpkgs' current Go.
          #
          # ONE bin directory, and a curated one, rather than the packages
          # themselves. GNAT and gfortran are cc-wrappers whose `bin/` also
          # carries `gcc`, `g++`, `cc`, `ld`, `as`, ...; putting them in
          # `packages` would put GCC 13 (GNAT's) ahead of the shell's own
          # compiler for every `nim c`. Only names the C toolchain does not
          # own are linked. gnatmake does not need the shadowed names: its
          # wrapper passes `-B<its own bin>` to the compiler driver (verified:
          # builds and runs an Ada hello with GCC 15 first on PATH).
          # Packages unavailable on the current platform are dropped rather
          # than failing the shell, so a missing one is a SKIP there too.
          #
          # `repro.nim`'s `devEnv:` names the same set for the repro-native
          # (non-flake) activation; keep the two lists in step.
          conventionTestToolchains =
            let
              # `availableOn` checks meta.platforms only; a package nixpkgs
              # marks broken on this platform (fpc on x86_64-darwin) is just as
              # unusable, and evaluating it refuses the whole dev shell.
              available = pkgs.lib.filter (
                p: pkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform p && !(p.meta.broken or false)
              );
              toolchains = available (
                [
                  pkgs.go
                  pkgs.rustc
                  pkgs.cargo
                  pkgs.gfortran
                  pkgs.fpc
                  pkgs.ldc
                  pkgs.zig_0_13
                  pkgs.meson
                  pkgs.crystal
                  pkgs.shards
                  pkgs.dotnet-sdk_8
                  pkgs.elixir
                  pkgs.erlang
                  pkgs.rebar3
                  pkgs.jdk21
                  pkgs.maven
                  pkgs.gradle_8
                  pkgs.ghc
                  pkgs.cabal-install
                  pkgs.ocaml
                  pkgs.dune_3
                  pkgs.php
                  pkgs.php.packages.composer
                  pkgs.ruby
                  pkgs.bundler
                  pkgs.swift
                  pkgs.swiftpm
                ]
                # GNAT's bootstrap binary exists only for x86_64 Linux at
                # this pin. Its broad meta.platforms passes availableOn, but
                # forcing the dependency on ARM64 throws during evaluation.
                ++ pkgs.lib.optionals (pkgs.stdenv.isLinux && pkgs.stdenv.hostPlatform.isx86_64) [
                  pkgs.gnat
                ]
              );
              # Names the dev shell's C toolchain owns. A link under one of
              # these would shadow it (see above).
              shadowed = [
                "addr2line"
                "ar"
                "as"
                "c++"
                "c++filt"
                "cc"
                "cpp"
                "dwp"
                "elfedit"
                "g++"
                "gcc"
                "gprof"
                "ld"
                "ld.bfd"
                "ld.gold"
                "ld.lld"
                "lld"
                "nm"
                "objcopy"
                "objdump"
                "ranlib"
                "readelf"
                "size"
                "strings"
                "strip"
                "clang"
                "clang++"
                "clang-cpp"
              ];
            in
            pkgs.runCommand "reprobuild-convention-test-toolchains" { } ''
              mkdir -p $out/bin
              for pkg in ${pkgs.lib.escapeShellArgs toolchains}; do
                [ -d "$pkg/bin" ] || continue
                for exe in "$pkg"/bin/*; do
                  name=$(basename "$exe")
                  case " ${toString shadowed} " in *" $name "*) continue ;; esac
                  # First package wins, so the list order above is priority.
                  [ -e "$out/bin/$name" ] || ln -s "$exe" "$out/bin/$name"
                done
              done
            '';
        in
        {
          apps.default = reproApp;
          apps.repro = reproApp;
          apps.repro-binary-cache = reproBinaryCacheApp;

          packages.default = reprobuild;
          packages.reprobuild = reprobuild;
          # The name the Nix helper library and its consumers use
          # (`reprobuild.packages.<system>.repro`, spec §The Nix helper
          # library): the same package, whose wrapper already makes the
          # installed `repro` compile profiles with no checkout and no
          # consumer-side environment (GM1/GM1l). `readIntent`'s IFD derivation
          # runs it in the build sandbox as is; `checks.lib-intent-ifd` is
          # the proof.
          packages.repro = reprobuild;
          # The Nim fork toolchain, exposed for standalone build/verification.
          packages.nim-fork = nimFork;
          packages.repro-binary-cache = reproBinaryCache;
          # Self-contained, /nix/store-free `repro` (see `reproPortable`).
          # Linux only: the bundle runs the closure in a user-namespace chroot
          # (`nix-user-chroot`, whose meta.platforms is Linux), so on darwin
          # the output could not even be evaluated, and `nix flake check
          # --all-systems` stopped there. A dynamic attribute whose name is
          # `null` is omitted, which keeps the output out of the darwin
          # package sets instead of declaring one that throws.
          packages.${if pkgs.stdenv.hostPlatform.isLinux then "repro-portable" else null} = reproPortable;

          checks = {
            inherit pre-commit-check;
            package-build = reprobuild;
            # The nixpkgs-format package cannot parse reprobuild.nimble for its
            # own version -- reading `${src}/reprobuild.nimble` at eval time is
            # import-from-derivation, which nixpkgs forbids -- so it carries a
            # literal default and this check is what keeps the literal honest.
            # Without it the fork would happily ship a `reprobuild-0.1.0`
            # derivation built from 0.1.3 sources.
            #
            # The grep is COUNTED, not merely run: a `version ? "..."` line that
            # stops matching (renamed argument, reformatted file) makes the
            # count 0 and fails here, rather than passing vacuously on an empty
            # match the way a bare `grep | sed` pipeline would.
            nixpkgs-package-version-sync =
              pkgs.runCommand "reprobuild-nixpkgs-package-version-sync"
                {
                  packageNix = ./nix/pkgs/by-name/re/reprobuild/package.nix;
                  nimbleVersion = version;
                }
                ''
                  set -eu
                  matches=$(grep -c '^  version = "' "$packageNix" || true)
                  if [ "$matches" != 1 ]; then
                    echo "package.nix: expected exactly 1 version-default line, found $matches"
                    exit 1
                  fi
                  literal=$(sed -n 's/^  version = "\(.*\)";$/\1/p' "$packageNix")
                  if [ -z "$literal" ]; then
                    echo "package.nix: could not extract the version literal"
                    exit 1
                  fi
                  if [ "$literal" != "$nimbleVersion" ]; then
                    echo "package.nix version literal ($literal) != reprobuild.nimble version ($nimbleVersion)"
                    exit 1
                  fi
                  echo "package.nix and reprobuild.nimble agree on version $literal"
                  mkdir -p "$out"
                '';
            # The sibling of the version check for the source arguments.
            # package.nix's defaults are one coherent snapshot of a PUBLISHED
            # reprobuild commit: `src` names it, its `reprobuild.nimble`
            # carries the `version` literal, and its `flake.lock` pins every
            # `*Src` default of package.nix and nim-fork.nix. That snapshot is
            # what a nixpkgs consumer builds with -- it has no flake plumbing
            # to override them -- and before this check six defaults had
            # drifted from any lock, one of them (io-mon) by 46 commits.
            #
            # It compares against the lock OF THE `src` COMMIT, not this
            # tree's: this tree's lock moves with every sibling pin refresh
            # (dozens a month), and a default cannot name the commit that
            # contains it, so "mirror this tree's lock" could only be kept
            # green by editing package.nix on every refresh. The snapshot
            # moves only when someone moves `src` (with `version` and the
            # defaults, together). The `src` tree is fetched at evaluation
            # time by its rev and its own hash (a locked, pure fetch), so a
            # wrong `src` hash fails here too. Each default's rev must equal
            # the lock node's, and its hash the node's `narHash` where the
            # lock records one. Decided at evaluation time, like `lib-tests`,
            # so it builds nothing.
            nixpkgs-package-src-sync =
              let
                defaultSrc = defaultPackage.src;
                srcTree = builtins.fetchTree {
                  type = "github";
                  owner = "metacraft-labs";
                  repo = "reprobuild";
                  inherit (defaultSrc) rev;
                  narHash = defaultSrc.outputHash;
                };
                lock = builtins.fromJSON (builtins.readFile "${srcTree}/flake.lock");
                rootInputs = lock.nodes.${lock.root}.inputs;
                srcNimbleVersion = nimbleVersionOf "${srcTree}/reprobuild.nimble";
                lockedOf = input: lock.nodes.${rootInputs.${input}}.locked;
                defaultNimFork = pkgs.callPackage ./nix/pkgs/by-name/re/reprobuild/nim-fork.nix { };
                defaultPackage = pkgs.callPackage ./nix/pkgs/by-name/re/reprobuild/package.nix {
                  # Same as the flake's own call: the pinned nixpkgs spells it
                  # `xxHash`. Not a source argument.
                  xxhash = pkgs.xxHash;
                };
                # argument -> the flake input passed for it (see the
                # `callPackage` calls of package.nix and nim-fork.nix above).
                packageArgs = {
                  nimcryptoSrc = "nimcrypto-src";
                  bearsslSrc = "bearssl-src";
                  stackableHooksSrc = "nim-stackable-hooks-src";
                  ctTraceFormatSrc = "ct-trace-format-src";
                  ioMonSrc = "io-mon-src";
                  shmGsetSrc = "nim-shm-gset-src";
                  shmQueueSrc = "nim-shm-queue-src";
                  codetracerSrc = "codetracer-src";
                  ctTestRunnerSrc = "reprobuild-ct-test-runner-src";
                  testAdaptersSrc = "reprobuild-test-adapters-src";
                  runquotaSrc = "runquota-src";
                };
                nimForkArgs = {
                  forkSrc = "nim-fork-src";
                  csourcesSrc = "nim-csources-src";
                  traceFormatSrc = "ct-trace-format-src";
                  stewSrc = "nim-stew-src";
                  resultsSrc = "nim-results-src";
                  checksumsSrc = "nim-checksums-src";
                  nimonySrc = "nim-nimony-src";
                };
                problems =
                  file: sources: args:
                  pkgs.lib.concatLists (
                    pkgs.lib.mapAttrsToList (
                      arg: input:
                      let
                        src = sources.${arg};
                        locked = lockedOf input;
                      in
                      if !(sources ? ${arg}) then
                        [ "${file}: `${arg}` is not in passthru.sources" ]
                      else if !(rootInputs ? ${input}) then
                        [
                          "${file}: `${arg}`: the `src` commit's flake.lock has no input `${input}`"
                        ]
                      else if (src.rev or null) != locked.rev then
                        [
                          "${file}: `${arg}` defaults to rev ${toString (src.rev or null)}, the `src` commit's flake.lock pins `${input}` at ${locked.rev}"
                        ]
                      else if locked ? narHash && (src.outputHash or null) != locked.narHash then
                        [
                          "${file}: `${arg}` hash ${toString (src.outputHash or null)} != the `src` commit's flake.lock `${input}` narHash ${locked.narHash}"
                        ]
                      else
                        [ ]
                    ) args
                  );
                # Vacuity guard: the two tables cover every source argument
                # each file exposes, so a new `*Src` argument cannot escape.
                coverage =
                  file: sources: args:
                  pkgs.lib.optional (builtins.attrNames sources != builtins.attrNames args)
                    "${file}: passthru.sources (${toString (builtins.attrNames sources)}) and this check's table (${toString (builtins.attrNames args)}) name different arguments";
                versionProblem = pkgs.lib.optional (srcNimbleVersion != defaultPackage.version) "package.nix: `version` is ${defaultPackage.version}, but the `src` commit (${defaultSrc.rev}) has reprobuild.nimble version ${srcNimbleVersion}";
                found =
                  versionProblem
                  ++ coverage "package.nix" defaultPackage.sources packageArgs
                  ++ coverage "nim-fork.nix" defaultNimFork.sources nimForkArgs
                  ++ problems "package.nix" defaultPackage.sources packageArgs
                  ++ problems "nim-fork.nix" defaultNimFork.sources nimForkArgs;
              in
              if found == [ ] then
                pkgs.writeText "reprobuild-nixpkgs-package-src-sync" (
                  builtins.toJSON {
                    checked =
                      builtins.length (builtins.attrNames packageArgs)
                      + builtins.length (builtins.attrNames nimForkArgs);
                  }
                )
              else
                throw "reprobuild nixpkgs-package-src-sync: package.nix defaults are not the snapshot of their `src` commit ${defaultSrc.rev}:\n${builtins.concatStringsSep "\n" found}";
            packaged-runtime-compile = packagedRuntimeCompileCheck;

            # ── The Nix helper library (GM5) ──────────────────────────────
            # `lib-tests` and `lib-home-manager` are decided at EVALUATION
            # time (the derivation exists only when every case passes), so
            # `nix flake check --all-systems` checks them for every system,
            # darwin included, from a Linux evaluator and vice versa.
            lib-tests =
              let
                result = import ./nix/tests/lib.nix {
                  inherit (pkgs) lib;
                  inherit reprobuildLib;
                  libFor = reprobuildLibFor;
                  root = ./.;
                };
              in
              if result.failures == [ ] then
                pkgs.writeText "reprobuild-lib-tests" (builtins.toJSON result.counts)
              else
                throw "reprobuild lib-tests: ${toString (builtins.length result.failures)} failure(s):\n${builtins.toJSON result.failures}";
            lib-home-manager = import ./nix/tests/home-manager.nix {
              inherit pkgs system;
              inherit (pkgs) lib;
              homeManager = inputs.nixos-modules.inputs.home-manager-unstable;
              intentModule = intentHomeManagerModule;
              brewIntentModule = brewFixtureHomeManagerModule;
              root = ./.;
            };
            # readIntent's IFD mode: the packaged `repro` exports the fixture
            # profiles inside the build sandbox, on the EVALUATOR's system
            # (`builtins.currentSystem` under `--impure`, else this check's
            # own system), and the result must say what the committed
            # snapshots say, evaluated for this check's target system. Under
            # `nix flake check --impure --all-systems` on Linux the darwin
            # checks therefore evaluate an export Linux produced -- the
            # non-native evaluator case.
            lib-intent-ifd = import ./nix/tests/intent-ifd.nix {
              inherit pkgs system reprobuildLib;
              buildSystem = builtins.currentSystem or system;
              root = ./.;
            };
            # ── Host facts (GM6) ──────────────────────────────────────────
            # `homeManagerFacts` over a real Home Manager configuration:
            # its evaluated half is decided at evaluation time, its
            # digests when built on this check's system.
            lib-host-facts = import ./nix/tests/host-facts.nix {
              inherit pkgs system reprobuildLib;
              inherit (pkgs) lib;
              homeManager = inputs.nixos-modules.inputs.home-manager-unstable;
              root = ./.;
            };
            # `homeEquivalenceCheck` end to end: the packaged `repro home
            # facts` / `repro home compare` against `homeManagerFacts`, an
            # equivalent pair that must pass and a diverged one that must
            # fail.
            lib-home-equivalence = import ./nix/tests/home-equivalence.nix {
              inherit pkgs system reprobuildLib;
              inherit (pkgs) lib;
              homeManager = inputs.nixos-modules.inputs.home-manager-unstable;
              root = ./.;
            };
            repo-requirements =
              pkgs.runCommand "reprobuild-repo-requirements" { nativeBuildInputs = [ pkgs.just ]; }
                ''
                  cp -R ${./.} source
                  chmod -R u+w source
                  cd source
                  ${pkgs.bash}/bin/bash scripts/check_repo_requirements.sh
                  mkdir -p $out
                '';
          };

          devShells.default = pkgs.mkShell {
            STACKABLE_HOOKS_BUILT_TOOLS_DIR =
              if pkgs.stdenv.isDarwin then
                "${inputs.stackable-hooks-macos-tools.packages.${system}.default}"
              else
                "";
            # Framework regression uses a real GCC without putting its cc ahead
            # of the shell's clang. /usr/bin/gcc on Darwin is Apple clang.
            REPRO_TEST_DARWIN_GCC = if pkgs.stdenv.isDarwin
              then pkgs.lib.getExe pkgs.gcc else "";
            inputsFrom = [ pkgs.nix ];
            # repro_solver's clingo bindings dlopen libclingo.so at module init.
            # build_apps.sh clears NIX_LDFLAGS + LD_LIBRARY_PATH for every `nim c`
            # (the .rodata-bake guard) so the binaries carry a bare
            # `dlopen("libclingo.so")` with no rpath and rely on a runtime
            # LD_LIBRARY_PATH (as build_apps.sh documents). Provide it so `repro`
            # and the test binaries resolve clingo under `dev-exec`/CI `just test`.
            # zstd is the same story: the binary-cache client dlopen()s
            # libzstd.so.1 at runtime (its DT_RPATH is only patched into the Nix
            # package build's binaries, not the `just bootstrap` binaries the
            # ct build and `just test` run), so add it here too — otherwise a
            # bootstrapped `repro` aborts with "could not load: libzstd.so.1".
            # openssl is likewise dlopen'd: binaries built `--define:ssl` (e.g.
            # repro-harvest-apt's HTTPS fetch via std/net) carry a bare
            # `dlopen("libcrypto.so.3")`, so a bootstrapped `repro` aborts with
            # "could not load: libcrypto.so" in the bare dev shell without it.
            #
            # pcre is here for a DIFFERENT reason, and the distinction matters
            # for anyone tempted to "fix" it in the nim-fork derivation
            # (`nix/pkgs/by-name/re/reprobuild/nim-fork.nix`) instead. The
            # Nim toolchain IS self-contained: that derivation already lists
            # pcre in `buildInputs` and patchelfs the pcre lib dir into
            # `bin/nim`'s RUNPATH, and a bare `nim --version` loads
            # `libpcre.so.1` fine. What breaks is monitored execution. The
            # provider-compile edge runs `nim c` under automatic monitoring,
            # which LD_PRELOADs `librepro_monitor_shim.so`; the shim interposes
            # `dlopen`, so the forwarded call is issued from the shim's own DSO
            # and the monitored binary's DT_RUNPATH stops governing the lookup:
            # `LD_PRELOAD=<shim> nim --version` fails with "could not load:
            # libpcre.so(.3|.1|)" while the identical command without the shim
            # succeeds. LD_LIBRARY_PATH is process-global — consulted before
            # any DT_RUNPATH and independent of which DSO issued the call — so
            # listing pcre here restores resolution under interposition. The
            # durable fix is in io-mon's dlopen hook, which should resolve
            # against the calling binary's link map; that lives in io-mon's
            # repo, not this one. `scripts/check_toolchain_dlopen.sh` guards
            # this whole class (see `just check-toolchain-dlopen`).
            #
            # THE INVARIANT THIS VARIABLE PUTS EVERY SHELL SUBPROCESS UNDER:
            # one glibc reaches a process. `LD_LIBRARY_PATH` is process-global
            # and is consulted BEFORE any DT_RUNPATH, so every directory listed
            # here is offered to binaries this shell did not build — and the
            # glibc those libraries were built against comes with them. A
            # program on PATH that runs on a DIFFERENT glibc then has two in
            # its address space and dies before `main` if the older `libc.so.6`
            # is missing a symbol version the newer one requires. The remedy is
            # never to trim this list (see `pkgs.git` in `packages` below for
            # why that does not work): it is for the shell to PROVIDE the
            # programs it does this to, so they come from the same nixpkgs.
            # `scripts/check_dev_shell_env.sh` holds that invariant.
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
              pkgs.clingo
              pkgs.zstd
              pkgs.openssl
              pkgs.pcre
            ];
            BLAKE3_PREFIX = blake3Prefix;
            NIMCRYPTO_SRC = nimcrypto-src;
            BEARSSL_SRC = bearssl-src;
            STACKABLE_HOOKS_SRC = "${nim-stackable-hooks-src}/src";
            CODETRACER_TRACE_FORMAT_NIM_SRC = codeTracerTraceFormatNimSrc;
            IO_MON_SRC = "${io-mon-src}/src";
            SHM_GSET_SRC = "${nim-shm-gset-src}/src";
            SHM_QUEUE_SRC = "${nim-shm-queue-src}/src";
            CODETRACER_PINNED_SRC = "${codetracer-src}/src";
            REPRO_CT_TEST_RUNNER_SRC = reprobuild-ct-test-runner-src;
            REPRO_TEST_ADAPTERS_SRC = "${reprobuild-test-adapters-src}/src";
            REPROBUILD_USE_SYSTEM_HASH_LIBS = "1";
            RUNQUOTA_SRC = runquota-src;
            # Read by RUNQUOTA'S ``config.nims``, not by ours.
            #
            # ``RUNQUOTA_SRC`` above serves the compile reprobuild does itself,
            # which reaches only runquota's client-side libraries. But several
            # entry points in this shell build runquota's DAEMON, in runquota's
            # own checkout, with runquota's own build files:
            # ``scripts/run-m23-benchmark.sh`` and ``scripts/run_tests.sh`` both
            # run ``just build`` there when ``build/bin/runquotad`` is absent,
            # and the Justfile's runquota-facing integration recipes do the same.
            # That build compiles ``runquota_stats_table``, which imports
            # ``shm_lease/anchor``, and runquota's ``config.nims`` resolves it
            # from this variable (falling back to a ``../nim-shm-lease``
            # sibling, which no CI layout of ours provides). Without it the
            # daemon build stops at ``cannot open file: shm_lease/anchor`` and
            # takes the benchmark suite down with it.
            #
            # THE VALUE IS RUNQUOTA'S OWN PIN, reached through its flake rather
            # than restated here, for the same reason ``runquotaTools`` delegates
            # to ``runquota-src.packages.<system>.default``: a second pin of the
            # same dependency is a second thing to bump, and the two would
            # eventually disagree about which revision runquota builds against.
            # Nothing here needs updating when runquota moves its pin.
            SHM_LEASE_SRC = "${runquota-src.inputs.nim-shm-lease}/src";
            SQLITE_PREFIX = pkgs.sqlite.out;
            XXHASH_PREFIX = pkgs.xxHash;
            # Same contract as SQLITE_PREFIX/XXHASH_PREFIX above, and the same
            # value the installed wrapper already `--set-default`s: it is how
            # `reproLibPathFlags` (libs/repro_interface_artifacts) finds the
            # clingo lib dir for the `-L` + `-Wl,-rpath` it puts on the
            # interface-extract / provider compile.
            #
            # It was the ONLY one of that family missing from this shell, and
            # LD_LIBRARY_PATH above does not stand in for it: on darwin dyld
            # ignores LD_LIBRARY_PATH entirely, and `repro_solver` names its
            # dynlib `@rpath/libclingo.dylib` precisely so LC_RPATH is what
            # resolves the module-init dlopen. Without the rpath the extract
            # runner reprobuild compiles for a project aborts before `main`
            # with `could not load: @rpath/libclingo.dylib`, failing every
            # build that extracts an interface — `t_ext_repro_action_rows`
            # (M17) and `t_stats_reads_shared_store` (M18) among them, which
            # left two milestone gates unrunnable in the sanctioned shell.
            # The store-wide `*-clingo-*` scan in `nixPrefix` is a last-resort
            # fallback for hosts with no prefix at all; it is not a substitute
            # for naming the clingo this shell actually provides.
            CLINGO_PREFIX = pkgs.clingo;
            # LLVM's libunwind, beside the libgcc that the C toolchain already
            # supplies — the SECOND unwinder the HLX-OQ-4 gate needs.
            #
            # `__register_frame` exists in both and they disagree about its
            # argument (measured 2026-09-17: libgcc accepts both a whole
            # `.eh_frame` and a bare FDE; LLVM libunwind accepts only the FDE
            # and refuses a section start with "FDE is really a CIE"). Proving
            # the provider's runtime detection therefore needs a process linked
            # EACH way, and `tests/e2e/hcr-linux-unwind/` builds both from this
            # prefix.
            #
            # It is a named prefix rather than an entry in `packages` below on
            # purpose, and the reason is not style. Adding it to `packages`
            # would put its `dev` output on NIX_CFLAGS_COMPILE, and that output
            # ships its own `unwind.h` — which would then be `-isystem`'d ahead
            # of GCC's for EVERY compile in this shell. One gate's link input is
            # not worth changing what the whole shell's `#include <unwind.h>`
            # resolves to. Same contract as SQLITE_PREFIX / CLINGO_PREFIX above.
            REPRO_HCR_LLVM_LIBUNWIND = pkgs.llvmPackages.libunwind;
            # For the JVM convention fixtures (Maven / Gradle / bare javac), as
            # the Windows `devEnv:` sets it for the same fixtures.
            JAVA_HOME = pkgs.jdk21.home;
            packages = [
              # See `conventionTestToolchains` above.
              conventionTestToolchains
              runquotaTools
              # ``ct-test`` — CodeTracer's cross-language test driver. On PATH
              # so `ct-test test discover|run` is available in the dev shell
              # without a hand build. Nothing in reprobuild's own build or test
              # path consumes it yet; wiring it into scripts/run_tests.sh is a
              # separate, later step. One thing to know before relying on it:
              # it is whatever ``codetracer-src`` is pinned to, not whatever is
              # in a sibling checkout. Changes made in a local codetracer tree
              # reach this binary only once they are pushed and the pin is
              # bumped (or the input is overridden for the session).
              #
              # ``test run`` is safe at any ``--threads`` value on this pin. An
              # earlier pin aborted during teardown once a run used 21 or more
              # workers — a heap-lifetime bug in CodeTracer's
              # ``run_orchestration.runUnits``, where worker-allocated results
              # were freed after their threads had exited. It is fixed at the
              # source by that module's ``ResultHandoff``, and the pin is now
              # past the fix. Any ``--threads`` cap set because of it can go;
              # such a cap never made anything safe in the first place.
              ctTestTools
              pkgs.just
              nimFork
              # Used by the ct-build CI step to bake reprobuild's runtime library
              # dirs (clingo + zstd) into the bootstrapped `repro`'s RPATH, so it
              # resolves its dlopen()s when run inside CodeTracer's dev shell.
              pkgs.patchelf
              pkgs.cmake
              pkgs.pkg-config
              pkgs.nix
              # git, from THIS flake's nixpkgs — the same evaluation the
              # libraries below and `LD_LIBRARY_PATH` above come from.
              #
              # Not a convenience. Every developer machine already has a `git`
              # somewhere on PATH, and that is exactly the problem: this shell
              # hands its subprocesses process-global LOADER STATE, and a `git`
              # the shell does not provide is a binary that state was never
              # meant for. Two independent channels carry it — the exported
              # `LD_LIBRARY_PATH` (consulted before any DT_RUNPATH, so a shell
              # library shadows the copy a foreign binary was linked against)
              # and the `LD_PRELOAD` of `build/lib/librepro_monitor_shim.so`
              # that automatic monitoring injects into every process a build
              # action starts. Both put this nixpkgs' glibc into whatever git
              # is on PATH.
              #
              # Measured on the host that motivated this: an ambient
              # `~/.nix-profile` git on glibc-2.40-66 against this shell's
              # glibc-2.42-61. The older `libc.so.6` does not define
              # `GLIBC_ABI_DT_X86_64_PLT`, which the newer `libdl.so.2` /
              # `libpthread.so.0` / `libm.so.6` / `librt.so.1` require, so:
              #
              #   * `git-remote-https` aborted on every https fetch, clone and
              #     PUSH from this shell (channel: LD_LIBRARY_PATH), and
              #   * `git` itself would not start inside a `test_execute` action
              #     (channel: LD_PRELOAD), which took away
              #     `repro build '.#test#<name>'` for every git-using test —
              #     the loop for iterating on one test at a time.
              #
              # Reprobuild shells out to git for its own work (`repro sync`,
              # `repro workspace pull`, the clone pass of `repro workspace init`
              # and `repro branch`, the publication probe the pre-push gate
              # runs), so a shell that injects loader state and does NOT supply
              # git is a shell that has broken its own tooling and cannot see
              # that it did. `scripts/check_dev_shell_env.sh` refuses that
              # state; this line is what satisfies it.
              #
              # Do not "fix" the same class by trimming LD_LIBRARY_PATH: the
              # entries there serve `dlopen`s by bare soname that the
              # `.rodata`-bake guard in `config.nims` deliberately leaves
              # unresolved (a hand `nim c -d:ssl` in this shell aborts with
              # `could not load: libcrypto.so(...)` the moment openssl leaves
              # the path), and it would not touch the LD_PRELOAD channel at all.
              pkgs.git
              pkgs.libsodium
              pkgs.boost
              pkgs.libgit2
              pkgs.libarchive
              pkgs.nlohmann_json
              pkgs.pcre2
              # pcre (v1), and it is NOT a duplicate of pcre2 above. The two
              # are different libraries with different sonames, and this shell
              # needs both for different consumers.
              #
              # The LINK requirement comes from vm-harness, whose serial-console
              # matcher (src/vm_harness/serial.nim) is built on Nim's `std/re`
              # — a PCRE **1** binding — and pins the dependency into the ELF
              # with `{.passL: "-Wl,--no-as-needed -lpcre -Wl,--as-needed".}`.
              # reprobuild's R2/R9 boot gates
              # (tests/integration/t_r2_iso_boot.nim and t_r9_systemd_boot.nim)
              # `import vm_harness` whenever the optional sibling checkout is
              # present (config.nims' `vmHarnessAvailable`), so their `nim c`
              # link line carries `-lpcre`. vm-harness supplies the matching
              # `-L` from ITS OWN config.nims via `pcre-config --libs`, and that
              # file governs builds rooted in vm-harness only — a build rooted
              # here reads reprobuild's config.nims instead and never sees it.
              # The `-L` therefore has to come from this shell's NIX_LDFLAGS,
              # exactly as the OpenSSL `-L` does for the `-d:ssl` test edges
              # (see scripts/generate_test_edges.nim's `needsSslDefine`).
              # Without this line `repro build .#test-builds` ends with
              # `ld: cannot find -lpcre` on precisely those two binaries and
              # `just test` cannot reach its execution phase at all.
              #
              # Note that `pkgs.pcre` already appears in LD_LIBRARY_PATH above,
              # and that entry does NOT stand in for this one: LD_LIBRARY_PATH
              # is consulted by the loader at run time and never by `ld` at
              # link time. Both are needed, for the two different phases.
              #
              # This mirrors vm-harness's own flake, which lists `pkgs.pcre` in
              # `buildInputs` (and `pkgs.pcre.dev`, for `pcre-config`, on the
              # lint hook's PATH) for the same library. Listing it here also
              # puts `pcre-config` on PATH, which is what vm-harness's
              # config.nims hard-fails without.
              pkgs.pcre
              pkgs.ninja
              pkgs.clang
              # Real debuggers. These are test INPUTS for the HCR Linux
              # provider's unwinding/debugger gates
              # (tests/e2e/hcr-linux-unwind/), not developer convenience — and
              # before this line neither existed on any developer host, in this
              # flake, or in CI.
              #
              # The provider registers a relocated `.eh_frame` with the process
              # unwinder and an ELF `ET_REL` symfile with the GDB JIT
              # interface. The only way to show that either worked is to ask a
              # real debugger for a backtrace through a patched function and
              # read what it says. `allowed_mocks: none` on all three gates, so
              # a harness that greps a fabricated backtrace would prove
              # nothing, and a harness that skips on a missing debugger is a
              # silent self-pass. Both debuggers are listed because they read
              # the SAME registrations through different code: GDB parses the
              # JIT symfile itself and is the strict one about a malformed ELF,
              # while LLDB reaches it through its JITLoaderGDB plugin.
              pkgs.gdb
              pkgs.lldb
              pkgs.curl
              pkgs.libblake3
              pkgs.openssl
              pkgs.p7zip
              pkgs.sqlite
              pkgs.xxHash
              pkgs.zip
              # The read side of `zip`. Tool provisioning extracts `.zip` and
              # `.conda` archives with `unzip` on POSIX (`resolveZipExtractor`),
              # and the tests that WRITE such an archive with `zip` above then
              # need it to read it back; with only the writer present they fail
              # with "no zip extractor available" instead of skipping.
              pkgs.unzip
              pkgs.zlib
              pkgs.nixfmt-rfc-style
              pkgs.repomix
              pkgs.pre-commit
              # The other hook manager the workspace's dev shells install
              # with; the hooks-ensure integration tests drive the real
              # tool rather than a stand-in.
              pkgs.prek
              pkgs.shellcheck
              # Validates .github/workflows/ the way GitHub does, via
              # scripts/check_workflows.sh in `just lint`. Actions expression
              # syntax lives inside YAML scalars, so a YAML parser cannot see a
              # malformed expression -- and a workflow GitHub rejects at load
              # time produces a failure run with no jobs and no annotation.
              pkgs.actionlint
              pkgs.shfmt
              pkgs.typos
              # Spec-Implementation M2a: clingo for the repro_solver
              # ASP bindings. Ships the `clingo` CLI tool and the
              # libclingo.so shared library + <clingo/clingo.h> headers
              # the Nim bindings dlopen and pass to the compiler.
              pkgs.clingo
              # Test-suite runtime tools: the M6 native-shell-hook gate
              # (tests/e2e/dev-env/t_e2e_native_shell_hooks.nim) requires real
              # zsh + fish binaries on PATH (their `nix build nixpkgs#…`
              # fallback can't resolve the registry in the pure-flake CI shell),
              # and the codetracer-subset build gate
              # (tests/e2e/codetracer-subset/t_e2e_codetracer_build_subset_without_tup.nim)
              # shells out to node. (Safe now that the test runner isolates git
              # config — adding shells no longer perturbs the gpg-signing tests.)
              pkgs.nodejs
              pkgs.zsh
              pkgs.fish
            ]
            # libbpf for the codetracer-subset `ct` build: CodeTracer's
            # native monitor under src/ct/bpf_monitor_native.nim and
            # src/ct/libbpf_wrapper.nim include <bpf/libbpf.h>, which is
            # gated by Linux. macOS doesn't ship libbpf, so don't drag
            # it into the dev shell there.
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              pkgs.libbpf
              # M9.R.54: the reproos-image recipe's ``runtimeDeps`` list
              # (recipes/reproos-image/repro.nim) enumerates 35 host
              # tools the build-reproos-image.sh driver invokes.  Under
              # ``defaultToolProvisioning "path"`` the M9.N Batch B
              # resolver probes each name against the host PATH at
              # build-plan time and hard-fails on the first miss with
              # ``tool-resolution failed: <name> requested by uses ...``.
              # A typical NixOS interactive PATH already carries
              # coreutils / util-linux / rsync / mkfs.* etc., but is
              # missing qemu-{img,nbd}, grub-install / grub-mkconfig
              # (grub2), and modprobe / rmmod / lsmod (kmod).  Wiring
              # them into the dev shell makes ``nix develop`` /
              # ``.envrc``-loaded shells sufficient for
              # ``./build/bin/repro build recipes/reproos-image`` with
              # no ad-hoc ``nix-shell -p qemu grub2 kmod`` wrap.
              #
              # These are Linux-only: qemu-nbd is a Linux kernel-module
              # bridge, grub-install writes MBR/EFI blocks, and modprobe
              # /rmmod /lsmod talk to the Linux kmod interface.  macOS
              # /Windows operators don't build reproos-image so the
              # cost of pulling these in there wouldn't buy anything.
              #
              # ``grub2_efi`` (not plain ``grub2``): the reproos-image
              # target is an EFI-bootable qcow2 (``grub-install
              # --target=x86_64-efi``), and nixpkgs splits the grub
              # module output — ``pkgs.grub2`` ships only the
              # ``i386-pc`` (BIOS) modules, so ``grub-install
              # --target=x86_64-efi`` fails with ``modinfo.sh doesn't
              # exist``.  ``pkgs.grub2_efi`` carries the ``x86_64-efi``
              # module tree; validated end-to-end in the M9.R.54 Phase
              # B build (grub-install reached ``modinfo.sh`` search
              # only after the switch to ``grub2_efi``).
              pkgs.qemu
              pkgs.grub2_efi
              pkgs.kmod
              # ReproOS attestation boot gates: they boot a
              # disk image under QEMU through vm-harness's
              # QemuBootBackend and assert on its serial console.  The
              # gates themselves live in their owning repositories --
              # vm-harness (tests/integration/t_boot_smoke_harness_*.nim)
              # and reproos (tests/test_reproos_image_boot_smoke.nim) --
              # but this is the shell much of the campaign's tooling runs
              # in, so it must be able to host a boot.  Two host inputs
              # were missing:
              #
              #   * ``OVMF.fd`` -- the edk2 firmware pair.  The image
              #     under test is UEFI (``uefi-ext4``), so a Gen-2 boot
              #     needs an OVMF_CODE.fd loader plus an OVMF_VARS.fd
              #     NVRAM template.  It carries no binaries; it is here
              #     so the pair is realised in the store, and the
              #     shellHook below names it through VMH_OVMF_CODE /
              #     VMH_OVMF_VARS rather than leaving the harness to
              #     glob /nix/store for whatever it finds.
              #   * ``swtpm`` -- the software TPM 2.0 emulator that
              #     backs QEMU's ``-tpmdev emulator``.  Attaching a
              #     vTPM to the libvirt backend is what lets the
              #     attestation gates read PCRs out of the guest;
              #     without swtpm on PATH those gates cannot run at
              #     all.
              pkgs.OVMF.fd
              pkgs.swtpm
            ];
            shellHook = siblingCheckoutSourcesHook + ''
              # Consumers may borrow this toolchain with `nix develop PATH`.
              # Its repository checks belong only to a Reprobuild checkout.
              if PATH=${pkgs.git}/bin:$PATH ${pkgs.bash}/bin/bash \
                  ${./scripts/is_reprobuild_checkout.sh}; then
              # The committed .pre-commit-config.yaml is the pre-commit hook,
              # run by the flake's pre-commit: the flake provides the tools, the
              # committed config provides the rules. git-hooks.nix's own
              # installer cannot be used here: it refuses to replace a
              # committed config and then installs nothing, so commits would
              # skip the repository's checks without a word. Under a Reprobuild
              # dispatcher the script chains the hook as `<hook>.repro-local`
              # and never touches the dispatcher itself.
              #
              # Never fails the shell: a dev shell that refuses to open
              # because a hook could not be written is worse than the drift.
              # It does, however, say so loudly.
              PATH=${pkgs.git}/bin:$PATH ${pkgs.bash}/bin/bash \
                ${./scripts/install-git-hooks.sh} ${pkgs.lib.getExe pre-commit-check.config.package} || \
                echo "warning: the pre-commit hook was not installed; run 'bash scripts/install-git-hooks.sh <pre-commit>' by hand and read its diagnostic." >&2
              # Assert the Reprobuild-managed hooks on every entry, so the
              # pre-push publication gate is in place in a fresh clone too and
              # a hook another tool displaced (`pre-commit install`, `prek
              # install`) is put back in the same shell entry rather than at
              # the next commit. `repro health` reports the same gap with a
              # remedy.
              _repro_hook_bin=""
              if [ -x "$PWD/build/bin/repro" ]; then
                _repro_hook_bin="$PWD/build/bin/repro"
              elif command -v repro >/dev/null 2>&1; then
                _repro_hook_bin="$(command -v repro)"
              fi
              if [ -n "$_repro_hook_bin" ]; then
                "$_repro_hook_bin" hooks ensure --vcs "$PWD" >/dev/null || \
                  echo "warning: 'repro hooks ensure --vcs $PWD' failed; the pre-push publication gate may be uninstalled. Run it by hand and read its diagnostic." >&2
              else
                echo "warning: no 'repro' binary found; the pre-push publication gate cannot be asserted. Build it with 'just build' and re-enter the shell." >&2
              fi
              unset _repro_hook_bin
              fi
            ''
            + pkgs.lib.optionalString pkgs.stdenv.isLinux ''
              # ReproOS attestation: name the exact edk2 firmware pair the
              # boot gates should use. vm-harness's firmware resolver
              # (src/vm_harness/firmware.nim) reads these two variables ahead
              # of any conventional path, and its last-resort fallback is a
              # /nix/store glob whose winner is the lexically greatest store
              # hash -- i.e. not a stable choice. Pinning the pair to this
              # shell's own OVMF means a boot gate asserts against the
              # firmware the flake pins rather than whatever a prior GC root
              # happened to leave behind. Respects an operator override.
              export VMH_OVMF_CODE="''${VMH_OVMF_CODE:-${pkgs.OVMF.fd}/FV/OVMF_CODE.fd}"
              export VMH_OVMF_VARS="''${VMH_OVMF_VARS:-${pkgs.OVMF.fd}/FV/OVMF_VARS.fd}"
            '';
          };

          # Minimal CI shell for the get.reprobuild.com static-site deploy
          # (.github/workflows/deploy-get.yml). It provides FLAKE-PINNED wrangler
          # — resolved through this flake's nixpkgs (flake.lock), not an ad-hoc
          # `npx wrangler` download or an uncached `nix run nixpkgs#wrangler` —
          # plus the POSIX tools get/build-get.sh needs to assemble get/dist/.
          #
          # It deliberately does NOT inherit the heavy default toolchain shell
          # above: the deploy only copies static files and runs `wrangler pages
          # deploy`, so pulling in the Nim/Rust/clingo closure would make the
          # deploy job slower and more fragile for no benefit. The self-hosted
          # eph-linux-x64 runners ship no node/npx, which is exactly why the
          # deploy runs wrangler from here rather than via cloudflare/*-action.
          devShells.ci = pkgs.mkShell {
            packages = [
              pkgs.wrangler
              pkgs.bash
              pkgs.coreutils
              pkgs.git
            ];
          };
        };
    };
}
