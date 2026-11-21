## GM4b: every archive realization of ``git`` is a ``tarball`` statement
## in the ``provisioning:`` block below. The M68 ``gitCatalog``
## (``VersionedProvisioning``) copy that once sat beside it was merged
## into these statements and removed, so a home profile and a recipe's
## ``uses:`` select from one set of records. The catalog harvester
## emits ``tarball`` statements to merge here.
##
## **M3 update (Realize-Closure-And-Catalog-Expansion spec).** The
## previously-documented M69 realize-time gap for git closed via M3:
## the harvester classifies git's ``PortableGit-X-64-bit.7z.exe``
## URL as ``archiveType = "7z-sfx"`` and the home archive realizer
## dispatches through the same 7z extractor (which transparently handles
## SFX-wrapped 7z streams). The ``pre_install`` block (restore persisted
## etc/gitconfig from ``$persist_dir``) is rejected by the realizer's
## allowlist — Scoop's ``$persist_dir`` is a Scoop-specific layout that
## does not map to reprobuild's store. The full pre_install body lands
## in ``preInstallUnrecognized`` and the realize loop emits a
## ``WPreInstallUnrecognized`` warning per line at apply time so the
## operator sees the gap. A freshly-realized git prefix carries
## ``bin/git.exe`` + the full PortableGit tree WITHOUT the persisted
## system-level config — fine for reprobuild's CI/dev use cases (the
## tools that need system git config can pin a per-user gitconfig via
## ``repro home apply`` env bindings). The ``post_install``
## install-context.reg writes (Windows system-state mutation) remain
## deferred per the campaign's system-vs-home boundary.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing M21 Nix provisioning (preserved across the M68 harvest).
# ---------------------------------------------------------------------------

package git:
  provisioning:
    nixPackage "nixpkgs#git", executablePath = "bin/git",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows / non-Nix Linux: PortableGit via ScoopInstaller/Main.
    scoopApp(bucket = "main", app = "git",
      preferredVersion = ">=2", executablePath = "bin/git.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: Git for Windows ships PortableGit as a 7z self-
    # extracting EXE (`.7z.exe`). Our `7z.exe` archiveType handles SFX
    # envelopes transparently; the archive expands flat to a tree whose
    # `bin/git.exe` we expose at the prefix root (no stripComponents
    # needed — the PortableGit layout already sits at the root).
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe",
      sha256 = "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      archiveType = "7z.exe",
      executablePath = "bin/git.exe",
      packageId = "git@2.54.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      version = "2.54.0",
      # GM4b: the retired catalog record realized this SAME file (its URL
      # carried Scoop's `#/dl.7z` rename hint) at the same version; its
      # extra executables, `GIT_INSTALL_ROOT` binding and the Scoop
      # pre_install lines it could not replay are folded in here instead of
      # keeping a second, fully shadowed record. Its primary executable was
      # `bin\sh.exe`, which made a home profile's `git` launcher start sh.
      extraExecutable = "bin\\sh.exe",
      extraExecutable = "git-bash.exe",
      extraExecutable = "usr\\bin\\gpg.exe",
      extraExecutable = "usr\\bin\\gpg-agent.exe",
      extraExecutable = "usr\\bin\\gpgconf.exe",
      extraExecutable = "usr\\bin\\gpg-connect-agent.exe",
      extraExecutable = "usr\\bin\\pinentry.exe",
      env = "GIT_INSTALL_ROOT=${prefix}",
      preInstallUnrecognized = "$config_path = Join-Path -Path $dir -ChildPath 'etc\\gitconfig'",
      preInstallUnrecognized = "$config_path_persisted = Join-Path -Path $persist_dir -ChildPath 'etc\\gitconfig'",
      preInstallUnrecognized = "if (Test-Path -LiteralPath $config_path_persisted -PathType Leaf) {",
      preInstallUnrecognized = "    info \"Restoring system-level config from $config_path_persisted...\"",
      preInstallUnrecognized = "    Copy-Item -Path $config_path_persisted -Destination $config_path -Force",
      preInstallUnrecognized = "    info \"Adjusting paths in $config_path...\"",
      preInstallUnrecognized = "    (Get-Content -Path $config_path -Encoding UTF8) -replace '(?<=git/)[\\d.]+(?=/)', $version | Set-Content -Path $config_path -Encoding UTF8",
      preInstallUnrecognized = "}"
    # GM4b: the aarch64 archive realization formerly held by the retired
    # catalog record. Its executable list is reordered so `bin\git.exe` is
    # the primary (the record named `bin\sh.exe` first; see above).
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-arm64.7z.exe#/dl.7z",
      sha256 = "f8e92cd3359fcbb96998cfd606a536ccc6dbfb23c04e12b29042f9ba45b6b0c7",
      archiveType = "7z-sfx",
      executablePath = "bin\\git.exe",
      extraExecutable = "bin\\sh.exe",
      extraExecutable = "git-bash.exe",
      extraExecutable = "usr\\bin\\gpg.exe",
      extraExecutable = "usr\\bin\\gpg-agent.exe",
      extraExecutable = "usr\\bin\\gpgconf.exe",
      extraExecutable = "usr\\bin\\gpg-connect-agent.exe",
      extraExecutable = "usr\\bin\\pinentry.exe",
      version = "2.54.0",
      packageId = "git@2.54.0",
      env = "GIT_INSTALL_ROOT=${prefix}",
      preInstallUnrecognized = "$config_path = Join-Path -Path $dir -ChildPath 'etc\\gitconfig'",
      preInstallUnrecognized = "$config_path_persisted = Join-Path -Path $persist_dir -ChildPath 'etc\\gitconfig'",
      preInstallUnrecognized = "if (Test-Path -LiteralPath $config_path_persisted -PathType Leaf) {",
      preInstallUnrecognized = "    info \"Restoring system-level config from $config_path_persisted...\"",
      preInstallUnrecognized = "    Copy-Item -Path $config_path_persisted -Destination $config_path -Force",
      preInstallUnrecognized = "    info \"Adjusting paths in $config_path...\"",
      preInstallUnrecognized = "    (Get-Content -Path $config_path -Encoding UTF8) -replace '(?<=git/)[\\d.]+(?=/)', $version | Set-Content -Path $config_path -Encoding UTF8",
      preInstallUnrecognized = "}",
      cpu = "aarch64",
      os = "windows"

  executable git:
    cli:
      # DA-6 -- THE CAPTURE-BREADTH DECLARATION for git: FULL CAPTURE, and this
      # is the BLESSED NON-DETERMINISTIC case the milestone singles out.
      #
      # THE CLAIM: a git action asks io-mon for EVERY event category, and the
      # two categories it could not drop under any circumstances are the two
      # this tool's blessing is built out of.
      #
      # WHY `ecEntropy` IS NON-NEGOTIABLE HERE. The blessing below is not a
      # statement the engine reads on its own; it is applied by
      # `applyEntropyBlessingPolicy` to the `mrNonDeterministic` RECORDS a
      # capture carries, resolved per-image against the capture's own
      # `mrProcessExec` records. Narrow this category away and the blessing has
      # nothing to be applied to: the observations are empty,
      # `entropyObservability` still says `entObserved` (the backend-profile
      # record is META and is never gated), and the gate sees "observable, and
      # nothing observed" -- which is exactly the false clean it exists to
      # refuse. Note the DIRECTION: the failure is not a lost blessing, it is a
      # gate whose input was deleted, and the same missing records would then
      # also stop withholding publication from a gate that ran `uuidgen`. The
      # per-image mechanism -- the whole point of which is to tell a blessed
      # `mktemp` record apart from an unblessed `uuidgen` one -- needs BOTH
      # `ecEntropy` and `ecProcessTree` present to work at all.
      #
      # WHY `ecAmbientReads` IS KEPT, on this tool of all tools. The blessing is
      # scoped to entropy and its justification names the exception out loud: a
      # commit object's hash depends on its author and committer TIMESTAMPS,
      # which is a clock read. `mrTimeRead` is the only record that witnesses
      # the part of git's non-determinism that is explicitly NOT blessed.
      # Dropping the category would delete the evidence of the exception while
      # keeping the waiver -- which is how a narrowly-scoped blessing turns into
      # a broad one without anybody editing the blessing. Reprobuild has no
      # consumer for the record today (`interestConsumer` in the engine says so,
      # and both ambient kinds land on `foldOneMonitorRecord`'s `else: discard`);
      # this is the fail-closed choice, taken at a measured 2.2% of records.
      #
      # The remaining categories are kept for the ordinary reasons: git is a
      # content-addressed store on a filesystem, so `ecFileReads` /
      # `ecPathProbes` / `ecFileWrites` ARE its behaviour; `ecEnvReads` carries
      # `GIT_DIR`, `GIT_CONFIG_GLOBAL`, `GIT_AUTHOR_DATE` and `HOME`, none of
      # which are in the argv and all of which `cacheEnvInputs` keys on; and
      # `mrIpcConnect` / `mrExternalContent` are ungate-able after DA-5.
      dependencyPolicy automaticMonitor,
        captureBreadth = fullCapture

      # THE ENTROPY BLESSING, declared here, on the tool, once -- the shape
      # `packages/nim.nim` established. Until this block existed `package
      # git:` was provisioning-only, so there was no CLI spec to put it in
      # and no build edge to carry it; that is the state `packages/bash.nim`
      # is still in, and the reason a blessing written THERE would reach
      # nothing.
      #
      # WHY IT IS DECLARED AT ALL, given that hardly any recipe calls `git`
      # through this wrapper. The blessing's consumer is not the wrapper. It
      # is `repro_core/entropy_blessings.EntropyBlessedTools`, which the
      # engine reads when it attributes an `mrNonDeterministic` record to the
      # image that emitted it -- and the records in question come from `git`
      # processes a SHELL SCRIPT started, in actions whose invoked tool is
      # `sh`. This declaration is the authority that table mirrors;
      # `libs/repro_dsl_stdlib/tests/t_entropy_image_blessings.nim` asserts
      # the two carry the same text, so the table cannot bless a tool whose
      # own spec does not.
      #
      # SCOPED TO ENTROPY, and for git the scope is the whole point: a commit
      # object's hash depends on its author and committer TIMESTAMPS, which
      # is a clock read (`mrTimeRead`) and a signal this engine does not
      # grade for any tool. Nothing here waives that, and nothing here should
      # be read as saying `git commit` is reproducible.
      nonDeterminism entropyBlessed,
        justification = "git draws randomness only to name files it is " &
          "about to rename away. Measured with io-mon @87143d62 on the " &
          "linux-preload-hooks backend: `git init`, `git rev-parse HEAD`, " &
          "`git log --oneline -1`, `git status --porcelain` and `git clone` " &
          "draw NONE; `git add` draws one record and `git add` + `git " &
          "commit` two, and each record sits in the same pid as the " &
          "creation of .git/index.lock, .git/refs/heads/<branch>.lock and " &
          ".git/objects/XX/tmp_obj_XXXXXX -- lock files and loose-object " &
          "temporaries. Every one of those is renamed or hard-linked to a " &
          "name git computes from CONTENT (the object hash) or fixes by " &
          "convention (index, refs/heads/<branch>), so no random byte " &
          "survives into an object, a ref or the working tree; that git's " &
          "whole object store is content-addressed is what makes the claim " &
          "checkable rather than a promise. Across CodeTracer's ten shell " &
          "gates at 996f9b12 git accounts for 22 of the 45 records, all " &
          "path=getrandom, all in `git add` / `git commit` pids. This " &
          "blesses ENTROPY only, and the exception is worth naming because " &
          "it is the one people reach for: a commit object's hash depends " &
          "on its author and committer TIMESTAMPS. That is a clock read " &
          "(mrTimeRead), a separate signal this engine does not grade for " &
          "any tool, and nothing here waives it."

      call:
        # A deliberately minimal surface. Typed subcommands for git are a
        # separate piece of work; what this edge exists to do is give the
        # blessing above somewhere to attach and a shape the correspondence
        # test can read it off.
        pos args is seq[string],
          position = 0,
          required = false
