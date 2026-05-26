import repro_project_dsl

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
