## M68 merge note (hand-edited): the auto-generated ``gitCatalog`` body
## sits below the pre-existing ``package git:`` Nix block. The Nix
## block remains the source of truth for Nix-capable hosts; the
## ``gitCatalog`` slice below is consumed by the M64 ``cakBuiltin``
## adapter on Windows. Re-harvest emits ONLY the catalog half;
## re-attach the Nix block by hand if you regenerate.
##
## **M3 update (Realize-Closure-And-Catalog-Expansion spec).** The
## previously-documented M69 realize-time gap for git closed via M3:
## the harvester now classifies git's ``PortableGit-X-64-bit.7z.exe``
## URL as ``afSevenZipSfx`` and the realize loop dispatches through
## the same 7z extractor (which transparently handles SFX-wrapped 7z
## streams). The ``pre_install`` block (restore persisted
## etc/gitconfig from ``$persist_dir``) is rejected by the cakBuiltin
## allowlist — Scoop's ``$persist_dir`` is a Scoop-specific layout that
## does not map to reprobuild's store. The full pre_install body lands
## in ``pre_install_unrecognized`` and the realize loop emits a
## ``WPreInstallUnrecognized`` warning per line at apply time so the
## operator sees the gap. A freshly-realized git prefix carries
## ``bin/git.exe`` + the full PortableGit tree WITHOUT the persisted
## system-level config — fine for reprobuild's CI/dev use cases (the
## tools that need system git config can pin a per-user gitconfig via
## ``repro home apply`` env bindings). The ``post_install``
## install-context.reg writes (Windows system-state mutation) remain
## deferred per the campaign's system-vs-home boundary.

import std/tables
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
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"

  executable git:
    cli:
      dependencyPolicy automaticMonitor

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

# ---------------------------------------------------------------------------
# M3-extended bulk-harvest catalog (cakBuiltin adapter consumer on Windows).
# Harvested from bucket: ScoopInstaller/Main
# Versions (newest-first): 2.54.0
# ---------------------------------------------------------------------------

let gitCatalog* = @[
  VersionedProvisioning(
    version: "2.54.0",
    archive_format: afSevenZipSfx,
    install_method: imExtract,
    bin_relpath: @["bin\\sh.exe", "bin\\git.exe", "git-bash.exe", "usr\\bin\\gpg.exe", "usr\\bin\\gpg-agent.exe", "usr\\bin\\gpgconf.exe", "usr\\bin\\gpg-connect-agent.exe", "usr\\bin\\pinentry.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows, url: "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe#/dl.7z", sha256: "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311", sha512: "", sha1: "", extract_path: ""),
      PlatformBinary(cpu: pcAArch64, os: poWindows, url: "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-arm64.7z.exe#/dl.7z", sha256: "f8e92cd3359fcbb96998cfd606a536ccc6dbfb23c04e12b29042f9ba45b6b0c7", sha512: "", sha1: "", extract_path: "")
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: {"GIT_INSTALL_ROOT": "${prefix}"}.toTable(),
    pre_install_unrecognized: @["$config_path = Join-Path -Path $dir -ChildPath 'etc\\gitconfig'", "$config_path_persisted = Join-Path -Path $persist_dir -ChildPath 'etc\\gitconfig'", "if (Test-Path -LiteralPath $config_path_persisted -PathType Leaf) {", "    info \"Restoring system-level config from $config_path_persisted...\"", "    Copy-Item -Path $config_path_persisted -Destination $config_path -Force", "    info \"Adjusting paths in $config_path...\"", "    (Get-Content -Path $config_path -Encoding UTF8) -replace '(?<=git/)[\\d.]+(?=/)', $version | Set-Content -Path $config_path -Encoding UTF8", "}"])
]
