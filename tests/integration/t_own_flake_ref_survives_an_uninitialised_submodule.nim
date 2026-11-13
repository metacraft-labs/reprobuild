## NF-4 — **the project's OWN flake is named to nix by the same submodule rule
## as a sibling override, so a declared-but-uninitialised submodule does not
## break dev-env activation, and an initialised one is still included.**
##
## ## The defect this pins shut
##
## `useFlakeDevShell()` named the project's own flake as `DefaultFlakeRef`,
## `.?submodules=1`, UNCONDITIONALLY. With a submodule declared in
## `.gitmodules` and not initialised — the state of any clone made without
## `--recurse-submodules` — nix tries to fetch the submodule as part of the
## flake source and aborts (`…/vendor/sub' does not appear to be a git
## repository`), so `repro exec <repo>` could not enter the shell at all.
## Observed on `codetracer-visual-replay`, whose
## `third_party/sascha-willems-vulkan` is uninitialised in every workspace
## checkout.
##
## `flake.nim` had already measured exactly this failure for SIBLING overrides
## and made `?submodules=1` conditional there (`flakeSiblingKind`). The own
## flake simply never went through that classifier.
##
## ## Asserts
##
##   1. a project whose `.gitmodules` declares an UNINITIALISED submodule
##      activates through `flakeDevShellOps` with the DEFAULT flake ref, and
##      the shell sees the submodule as absent;
##   2. once that submodule is initialised, the same call still includes the
##      submodule's content in the flake source — `?submodules=1` is kept
##      where it is warranted, and the fix is not "drop the flag";
##   3. the own-ref selection only ever touches a LOCAL ref that asks for
##      submodules, preserves any other query parameter and the fragment,
##      and leaves remote refs and refs without the flag alone.
##
## ## Mutations
##
##   a. revert to the unconditional `.?submodules=1` ⇒ (1) RED: `nix
##      print-dev-env` fails and `flakeDevShellOps` raises;
##   b. always strip `?submodules=1` from the own ref ⇒ (2) RED: the shell
##      reports the submodule's payload as absent;
##   c. strip the fragment or other query parameters ⇒ (3) RED.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## Real bare git origins, a real `git submodule add`, a real clone WITHOUT
## submodules (the exact state under test), a real `git submodule update
## --init`, and a real `nix print-dev-env` run through the production
## `flakeDevShellOps`. The fixture flake's `nixpkgs` is the host's own registry
## entry resolved to a store path, so nothing here needs the network. The
## behaviour under test is what nix's git fetcher does with the emitted ref, so
## a fake fetcher would only check the test's own model of nix.
##
## Skip: `git` or `nix` missing, or no resolvable `nixpkgs` registry entry —
## a reasoned skip naming which, never silent.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_dsl_stdlib/foreign_env/env_capture
import repro_dsl_stdlib/foreign_env/flake
import repro_test_support/reasoned_skip

const NixSystem =
  when defined(macosx):
    when defined(arm64): "aarch64-darwin" else: "x86_64-darwin"
  else:
    when defined(arm64): "aarch64-linux" else: "x86_64-linux"

const SubPayload = "OWN-FLAKE-SUBMODULE-PAYLOAD"

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc must(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    raise newException(OSError, "fixture command failed: " & command)
  res.output

proc gitIn(gitBin, dir, args: string): string =
  # A fixed identity so the fixture does not depend on the host's git config,
  # and file-protocol submodules enabled per invocation (refused by default
  # since CVE-2022-39253) rather than in the tester's global config.
  must(q(gitBin) & " -C " & q(dir) &
    " -c user.email=tester@example.invalid -c user.name=OwnFlakeTester" &
    " -c protocol.file.allow=always " & args)

proc nixpkgsStorePath(nixBin: string): string =
  ## The host's `nixpkgs` registry entry, resolved to the store path it
  ## already points at; empty when there is none.
  let res = run(q(nixBin) & " --extra-experimental-features " &
    q("nix-command flakes") & " flake metadata nixpkgs --json 2>/dev/null")
  if res.code != 0:
    return ""
  let marker = "\"path\":\""
  let at = res.output.find(marker)
  if at < 0:
    return ""
  let rest = res.output[at + marker.len .. ^1]
  let closing = rest.find('"')
  if closing <= 0: "" else: rest[0 ..< closing]

proc flakeText(nixpkgs: string): string =
  ## `SUB_STATE` is the submodule's payload when the flake SOURCE nix fetched
  ## contains it, and `absent` otherwise — so the variable reports what the
  ## fetcher actually included, not what is on disk.
  "{\n" &
  "  inputs.nixpkgs.url = \"path:" & nixpkgs & "\";\n" &
  "  outputs = { self, nixpkgs }:\n" &
  "    let\n" &
  "      pkgs = import nixpkgs { system = \"" & NixSystem & "\"; };\n" &
  "      payload = ./vendor/sub/payload.txt;\n" &
  "    in {\n" &
  "      devShells." & NixSystem & ".default = pkgs.mkShellNoCC {\n" &
  "        SUB_STATE = if builtins.pathExists payload\n" &
  "          then pkgs.lib.removeSuffix \"\\n\" (builtins.readFile payload)\n" &
  "          else \"absent\";\n" &
  "      };\n" &
  "    };\n" &
  "}\n"

proc valueOf(ops: openArray[ForeignEnvOp]; name: string): string =
  for op in ops:
    if op.name == name and op.kind == feoSet:
      return op.value
  "<unset>"

suite "NF-4: the own flake ref follows the submodule rule":

  test "own_ref_selection_touches_only_a_local_submodules_request":
    # (3) Pure apart from classification. A directory with no `.git` anywhere
    # above it cannot be classified, so the ref is left exactly as written.
    let scratch = createTempDir("own-flake-ref-pure-", "")
    defer: removeDir(scratch)
    check flakeProjectRef(scratch, "github:o/r?submodules=1") ==
      "github:o/r?submodules=1"
    check flakeProjectRef(scratch, ".") == "."
    check flakeProjectRef(scratch, ".#ci") == ".#ci"
    check flakeProjectRef(scratch, "path:.?submodules=1") ==
      "path:.?submodules=1"

  test "t_own_flake_ref_survives_an_uninitialised_submodule":
    let gitBin = findExe("git")
    let nixBin = findExe("nix")
    let nixpkgs = if nixBin.len > 0: nixpkgsStorePath(nixBin) else: ""
    if gitBin.len == 0 or nixBin.len == 0 or nixpkgs.len == 0:
      skip("this case activates a real flake and needs `git`, `nix` and a " &
        "resolvable `nixpkgs` registry entry; git=" &
        (if gitBin.len == 0: "MISSING" else: gitBin) &
        " nix=" & (if nixBin.len == 0: "MISSING" else: nixBin) &
        " nixpkgs=" & (if nixpkgs.len == 0: "UNRESOLVED" else: nixpkgs))
    else:
      let scratch = createTempDir("own-flake-ref-", "")
      defer: removeDir(scratch)

      # ---- the submodule's origin ------------------------------------------
      let subOrigin = scratch / "origin-sub.git"
      discard must(q(gitBin) & " init -q --bare -b main " & q(subOrigin))
      let subSeed = scratch / "seed-sub"
      discard must(q(gitBin) & " init -q -b main " & q(subSeed))
      writeFile(subSeed / "payload.txt", SubPayload & "\n")
      discard gitIn(gitBin, subSeed, "add -A")
      discard gitIn(gitBin, subSeed, "commit -q -m sub")
      discard gitIn(gitBin, subSeed, "push -q " & q(subOrigin) & " main")

      # ---- the project, published WITH a submodule declared ----------------
      let origin = scratch / "origin-project.git"
      discard must(q(gitBin) & " init -q --bare -b main " & q(origin))
      let seed = scratch / "seed-project"
      discard must(q(gitBin) & " init -q -b main " & q(seed))
      writeFile(seed / "flake.nix", flakeText(nixpkgs))
      # `.repro/` holds the activation's own profile and scratch; ignoring it
      # is what `getting-started.md` asks of every adopter.
      writeFile(seed / ".gitignore", ".repro/\n")
      discard gitIn(gitBin, seed, "submodule add -q " &
        q("file://" & subOrigin) & " vendor/sub")
      discard gitIn(gitBin, seed, "add -A")
      let locked = run(q(nixBin) & " --extra-experimental-features " &
        q("nix-command flakes") & " flake lock", seed)
      if locked.code != 0:
        checkpoint("nix flake lock failed:\n" & locked.output)
      check locked.code == 0
      discard gitIn(gitBin, seed, "add -A")
      discard gitIn(gitBin, seed, "commit -q -m project")
      discard gitIn(gitBin, seed, "push -q " & q(origin) & " main")

      # ---- (1) a clone that declares the submodule but never initialised it
      let project = scratch / "project"
      discard must(q(gitBin) & " clone -q " & q("file://" & origin) & " " &
        q(project))
      check fileExists(project / ".gitmodules")
      # The fixture really is in the state under test: declared, not present.
      check gitIn(gitBin, project, "submodule status --recursive")
        .strip().startsWith("-")

      check flakeProjectRef(project) == "."
      var uninitOps: seq[ForeignEnvOp]
      var uninitError = ""
      try:
        uninitOps = flakeDevShellOps(project, nixExe = nixBin)
      except CatchableError as err:
        uninitError = err.msg
      if uninitError.len > 0:
        checkpoint("activation with an uninitialised submodule failed:\n" &
          uninitError)
      check uninitError.len == 0
      check uninitOps.valueOf("SUB_STATE") == "absent"

      # ---- (2) initialised: the submodule's content is in the flake source -
      discard gitIn(gitBin, project, "submodule update -q --init --recursive")
      check fileExists(project / "vendor" / "sub" / "payload.txt")
      check flakeProjectRef(project) == DefaultFlakeRef
      var initOps: seq[ForeignEnvOp]
      var initError = ""
      try:
        initOps = flakeDevShellOps(project, nixExe = nixBin)
      except CatchableError as err:
        initError = err.msg
      if initError.len > 0:
        checkpoint("activation with an initialised submodule failed:\n" &
          initError)
      check initError.len == 0
      check initOps.valueOf("SUB_STATE") == SubPayload

      # ---- (3) on a real checkout: other parameters and the fragment stay --
      check flakeProjectRef(project, ".?submodules=1#ci") == ".?submodules=1#ci"
      discard gitIn(gitBin, project, "submodule deinit -q --all --force")
      check flakeProjectRef(project, ".?submodules=1#ci") == ".#ci"
      check flakeProjectRef(project, ".?submodules=1&dir=nix#ci") ==
        ".?dir=nix#ci"
      check flakeProjectRef(project, "./sub/dir?submodules=1") == "./sub/dir"
