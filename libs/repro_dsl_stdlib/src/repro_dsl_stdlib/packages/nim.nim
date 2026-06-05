## M68 merge note (hand-edited): the auto-generated ``nimCatalog`` body
## sits below the pre-existing ``package nim:`` DSL block. The DSL
## block remains the source of truth for the Nim CLI surface
## (``nim c`` / ``nim js`` flag declarations) and the Nix
## provisioning shape on Nix-capable hosts; the ``nimCatalog`` slice
## is consumed by the M64 ``cakBuiltin`` adapter on Windows.
## Re-harvest emits ONLY the catalog half; re-attach the DSL block
## by hand if you regenerate.
##
## **Known M69 realize-time gap.** The Scoop manifest carries a
## ``post_install`` PowerShell hook that copies ``dist/nimble/src/nimblepkg``
## into ``bin/`` so ``nimble`` can locate its package definitions at
## runtime. The harvester silently drops the hook (per the module's
## "post_install is deliberately discarded" rule), so cakBuiltin's
## realized prefix will ship ``bin/nimble.exe`` but ``nimble``
## invocations may fail to find ``nimblepkg``. The manifest also
## carries an ``installer.script`` (``Add-Path -Path "$env:USERPROFILE\.nimble\bin"``)
## — a USERPROFILE PATH tweak, not a true installer, so M68's
## refined harvester correctly keeps ``install_method = imExtract``.
##
## **M9.5 merge note (hand-edited):** added a ``(pcX86_64, poLinux)``
## platform slice manually (the Nim upstream publishes prebuilts on
## ``nim-lang.org/download/``, NOT on GitHub Releases — so the M7
## gh-releases harvester doesn't apply). URL pattern:
## ``nim-<ver>-linux_x64.tar.xz``; sha256 lifted from upstream's
## ``.sha256`` sidecar. archive_format_override = afTarXz (Windows is
## afZip); bin_relpath_override drops the .exe suffix. Upstream Nim's
## Linux build targets glibc 2.17+ (the prebuilt is statically linked
## against the c runtime where feasible).

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing M21 DSL declaration (CLI surface + Nix provisioning).
# ---------------------------------------------------------------------------

package nim:
  provisioning:
    nixPackage "nixpkgs#nim", executablePath = "bin/nim",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

  executable nim:
    cli:
      dependencyPolicy automaticMonitor

      subcmd "c":
        flag defines is seq[string],
          alias = "-d:",
          format = concat,
          repeated = true
        flag mm is string,
          alias = "--mm:",
          format = concat
        boolFlag threadsOn is bool, alias = "--threads:on"
        boolFlag hintsOff is bool, alias = "--hints:off"
        boolFlag warningsOff is bool, alias = "--warnings:off"
        flag disabledHints is seq[string],
          alias = "--hint[",
          format = concat,
          repeated = true
        flag disabledWarnings is seq[string],
          alias = "--warning[",
          format = concat,
          repeated = true
        boolFlag debugInfo is bool, alias = "--debugInfo"
        boolFlag lineDirOn is bool, alias = "--lineDir:on"
        boolFlag stacktraceOn is bool, alias = "--stacktrace:on"
        boolFlag linetraceOn is bool, alias = "--linetrace:on"
        boolFlag hintsOn is bool, alias = "--hints:on"
        boolFlag warningsOn is bool, alias = "--warnings:on"
        boolFlag boundChecksOn is bool, alias = "--boundChecks:on"
        flag dynlibOverrides is seq[string],
          alias = "--dynlibOverride:",
          format = concat,
          repeated = true
        # Windows: project files (e.g. codetracer/reprobuild.nim) need to pass
        # -I/-L/-Wno-* flags to the C backend so the bundled libzip C sources
        # compile under MinGW UCRT (getpid implicit decl + missing system zlib).
        flag passC is seq[string],
          alias = "--passC:",
          format = concat,
          repeated = true
        flag passL is seq[string],
          alias = "--passL:",
          format = concat,
          repeated = true
        flag nimcache is string,
          alias = "--nimcache:",
          format = concat
        flag output is string,
          alias = "--out:",
          format = concat,
          role = output,
          required = true
        flag paths is seq[string],
          alias = "--path:",
          format = concat,
          repeated = true
        pos source is string,
          role = input,
          position = 0

        # Named-Targets M0: the primary output flag for ``nim c`` is
        # ``--out:`` (the existing typed-tool wrapper exposes it as
        # ``output``). M1 consumes this to derive an implicit target
        # name per build edge.
        outputs output

      subcmd "js":
        flag defines is seq[string],
          alias = "-d:",
          format = concat,
          repeated = true
        flag mm is string,
          alias = "--mm:",
          format = concat
        boolFlag hintsOff is bool, alias = "--hints:off"
        boolFlag warningsOff is bool, alias = "--warnings:off"
        flag disabledHints is seq[string],
          alias = "--hint[",
          format = concat,
          repeated = true
        flag disabledWarnings is seq[string],
          alias = "--warning[",
          format = concat,
          repeated = true
        boolFlag debugInfo is bool, alias = "--debugInfo"
        boolFlag lineDirOn is bool, alias = "--lineDir:on"
        boolFlag stacktraceOn is bool, alias = "--stacktrace:on"
        boolFlag linetraceOn is bool, alias = "--linetrace:on"
        boolFlag debugInfoOn is bool, alias = "--debugInfo:on"
        boolFlag sourcemapOn is bool, alias = "--sourcemap:on"
        boolFlag hotCodeReloadingOn is bool, alias = "--hotCodeReloading:on"
        flag output is string,
          alias = "--out:",
          format = concat,
          role = output,
          required = true
        flag paths is seq[string],
          alias = "--path:",
          format = concat,
          repeated = true
        pos source is string,
          role = input,
          position = 0

        # Named-Targets M0: same convention as ``subcmd "c"`` — the
        # ``--out:`` flag value supplies the implicit target name.
        outputs output

# ---------------------------------------------------------------------------
# M68 bulk-harvest catalog (cakBuiltin adapter consumer on Windows).
# Harvested from bucket: ScoopInstaller/Main
# Versions (newest-first): 2.2.10
# ---------------------------------------------------------------------------

let nimCatalog* = @[
  VersionedProvisioning(
    version: "2.2.10",
    archive_format: afZip,
    install_method: imExtract,
    bin_relpath: @["bin\\atlas.exe", "bin\\nim.exe", "bin\\nimble.exe", "bin\\nimgrab.exe", "bin\\nimgrep.exe", "bin\\nimpretty.exe", "bin\\nimsuggest.exe", "bin\\vccexe.exe", "bin\\testament.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows, url: "https://nim-lang.org/download/nim-2.2.10_x64.zip", sha256: "fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f", sha512: "", extract_path: "nim-2.2.10"),
      # M9.5: Linux x86_64 slice. Upstream nim-lang.org Linux prebuilt;
      # the inner dir is ``nim-<ver>/`` (same convention as Windows);
      # archive_format_override = afTarXz; binaries lack .exe.
      PlatformBinary(cpu: pcX86_64, os: poLinux, url: "https://nim-lang.org/download/nim-2.2.10-linux_x64.tar.xz", sha256: "0a3a38752e97e9d44aa479b3a7b37336dfe0176daf22ee5b5218ad0991ecd211", sha512: "", sha1: "", extract_path: "nim-2.2.10", archive_format_override: afTarXz, has_archive_format_override: true, bin_relpath_override: @["bin/atlas", "bin/nim", "bin/nimble", "bin/nimgrab", "bin/nimgrep", "bin/nimpretty", "bin/nimsuggest", "bin/testament"])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]
