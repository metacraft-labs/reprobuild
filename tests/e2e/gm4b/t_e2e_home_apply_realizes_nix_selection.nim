## GM4b: a home profile whose selection is a `nixPackage` realization is
## REALIZED by apply, through the realizer a recipe's `uses:` in nix mode
## runs (`resolveNixTool`).
##
## Before GM4b the home side could not realize nix at all: the adapter chain
## skipped its `cakNix` step as "not yet wired", so on Linux and macOS every
## package resolved from PATH or not at all, whatever its definition
## declared. Now a `nix` selection reaches `realizeNixSelection`, which runs
## the same `resolveNixTool` as `uses:` and records the pointer prefix the
## unified store gets for a Nix store path.
##
## The fixture package is registered in this test process (which stands in
## for the engine's linked definitions) and names `nixpkgs#hello`; the
## profile's selection policy is `[nix]`, so the selection cannot be
## anything else. The apply runs against scratch HOME / state / store
## directories.
##
## Vacuity guard: the generation's launcher for the package must run and
## print hello's greeting (nothing else on the machine is named
## `gm4bnixhello`, so only the realized Nix store path can), and the home-profile
## lock must record the nix selection with the lock identity the `uses:`
## acquisition plan computes for the same record.
##
## Falsifying mutation: routing `rkNix` in `realizeResolution` back to the
## pre-GM4b "not yet wired" refusal fails the apply with `EApplyRealizeFailed`.
##
## Requires Nix (Linux / macOS). Mocks: none.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_project_dsl
import repro_tool_profiles
import repro_home_apply
import repro_home_intent
import repro_test_support

package gm4bnixhello:
  provisioning:
    nixPackage "nixpkgs#hello", executablePath = "bin/hello",
      packageId = "gm4bnixhello.hello"

proc hostKey(): string =
  case detectHostOs()
  of poWindows: "windows"
  of poMacos: "darwin"
  else: "linux"

when isNixSupported:
  suite "GM4b: home apply realizes a nix selection":
    test "a [nix] selection policy realizes nixpkgs#hello through " &
        "resolveNixTool and locks it":
      let root = createTempDir("repro-gm4b-nix-apply-", "")
      let savedRc = getEnv("REPRO_HOME_POSIX_PATH_RC")
      putEnv("REPRO_HOME_POSIX_PATH_RC", root / "home" / ".path-rc")
      defer:
        if savedRc.len > 0: putEnv("REPRO_HOME_POSIX_PATH_RC", savedRc)
        else: delEnv("REPRO_HOME_POSIX_PATH_RC")
        removeDir(root)
      for d in ["profile", "state", "store", "home"]:
        createDir(root / d)
      writeFile(root / "profile" / "home.nim",
        "import repro/profile\n\nprofile \"gm4bNix\":\n" &
        "  adapterPreference:\n    " & hostKey() & ": [nix]\n\n" &
        "  activity default:\n    gm4bnixhello\n")
      var opts: ApplyOptions
      opts.profileDir = root / "profile"
      opts.profilePath = root / "profile" / "home.nim"
      opts.stateDir = root / "state"
      opts.storeRoot = root / "store"
      opts.homeDir = root / "home"
      opts.host = currentHost()

      let preview = resolveProfileSelections(opts)
      check preview.previews.len == 1
      check preview.previews[0].resolved
      let selection = preview.previews[0].resolution.selection
      check selection.kind == rkNix
      check selection.nix.selector == "nixpkgs#hello"

      let applied = runApply(opts)
      check applied.kind == aokFreshApplied

      # The generation's launcher for the package runs the Nix store
      # executable.
      let launcher = opts.stateDir / "current" / "bin" / "gm4bnixhello"
      checkpoint("launcher: " & launcher)
      check fileExists(launcher) or symlinkExists(launcher)
      let run = execCmdEx(quoteShell(launcher))
      checkpoint(run.output)
      check run.exitCode == 0
      check "Hello, world!" in run.output

      # The lock records the nix selection with the identity `uses:` uses.
      let lock = parseHomeProfileLock(readFile(
        homeProfileLockPath(opts.profileDir)))
      check lock.targets.len == 1
      check lock.targets[0].policy == @[rkNix]
      check lock.targets[0].packages.len == 1
      let locked = lock.targets[0].packages[0]
      check locked.kind == rkNix
      check not locked.ambient
      let useDef = preview.previews[0].resolution.useDef
      check locked.lockIdentity == nixAcquisitionPlan(useDef).lockIdentity
