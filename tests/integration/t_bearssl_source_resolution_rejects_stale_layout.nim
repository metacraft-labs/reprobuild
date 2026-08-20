## `scripts/source_paths.sh` resolves nim-bearssl by the module the build
## imports, not by the package's root file.
##
## `repro_deploy_agent/secrets.nim` imports `bearssl/abi/consttypes`. That
## module tree does not exist in older revisions of nim-bearssl, but
## `bearssl.nim` — which sits at the package root — exists in ALL of them. A
## probe testing only for the root file therefore accepts a checkout that
## cannot satisfy the import, and the failure surfaces as
## `cannot open file: bearssl/abi/consttypes` several layers down, naming the
## module rather than the wrong checkout that lacks it.
##
## This is not hypothetical: the previous probe scanned `/nix/store` for
## anything matching `*nim-bearssl-*`, took the FIRST match, and accepted it on
## the strength of `bearssl.nim`. On any host where an unrelated derivation had
## left an older nim-bearssl behind, `just build` selected it and died on the
## missing module — while the revision the flake pins, carrying the module, sat
## in the same store.
##
## Asserted, by driving the REAL shell function against real directories:
##   1. A checkout carrying only `bearssl.nim` — the stale layout — is REJECTED
##      when named explicitly. This is the case the old marker accepted, so it
##      is the assertion that fails if the marker is ever loosened back.
##   2. It is rejected LOUDLY: nonzero exit, and a message naming the offending
##      path and the missing file. The whole point is to beat a compile error
##      three layers down, so a silent skip would not be an improvement.
##   3. An explicitly named STALE checkout is not silently replaced by a good
##      one that is also reachable. Substituting a different checkout for the
##      one the caller named is what hides a stale pin in whatever set the
##      variable.
##   4. A checkout carrying the full module tree is accepted and echoed back.
##   5. With no value set, a sibling `../nim-bearssl` carrying the module tree
##      is found.
##   6. With nothing reachable at all, the failure names the dev shell as the
##      remedy rather than failing silently.
##
## Falsifiability: (1) and (3) fail if the marker regresses to `bearssl.nim` or
## if a stale explicit value falls through to another candidate; (4) and (5)
## fail if the stricter marker rejects a VALID checkout, which is the way a
## tightened guard breaks a working build.
##
## No mocks: real fixture directories on disk and the real `source_paths.sh`
## driven through a real bash. The fixtures contain empty files because the
## function under test asks only whether the module is THERE — it never reads
## them, and a fixture carrying real bearssl source would test nim's compiler
## rather than this probe.
##
## Skip rule: only when `bash` is missing from PATH (Windows hosts without it).

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc sourcePathsScript(): string =
  repoRoot() / "scripts" / "source_paths.sh"

proc makeCheckout(root: string; withModuleTree: bool): string =
  ## A nim-bearssl checkout fixture. `bearssl.nim` is always present — that is
  ## precisely why it cannot serve as the marker. The `bearssl/abi/` tree is
  ## what distinguishes a usable checkout from a stale one.
  result = root
  createDir(result)
  writeFile(result / "bearssl.nim", "")
  if withModuleTree:
    createDir(result / "bearssl" / "abi")
    writeFile(result / "bearssl" / "abi" / "consttypes.nim", "")

proc runResolve(bashBin, cwd: string; bearsslSrc: string;
                setVar: bool): tuple[code: int; output: string] =
  ## Drive the real function in a real shell. `cwd` matters: the resolver
  ## consults `libs/nim-bearssl`, `../nim-bearssl` and `flake.nix` relative to
  ## it, so every case runs from a scratch directory rather than from the repo,
  ## where the repo's own flake would answer for it.
  let script = sourcePathsScript()
  let cmd = "source " & quoteShell(script) & "; resolve_bearssl_src"
  let argv = @[bashBin, "-c", cmd]
  # A pruned environment, deliberately: inheriting the caller's BEARSSL_SRC
  # would make the "no value set" cases pass or fail depending on whether the
  # test itself was launched from the dev shell.
  var env = newStringTable({"PATH": getEnv("PATH"), "HOME": getEnv("HOME")})
  if setVar:
    env["BEARSSL_SRC"] = bearsslSrc
  let res = execCmdEx(quoteShellCommand(argv), workingDir = cwd, env = env)
  (code: res.exitCode, output: res.output)

suite "bearssl source resolution — the marker is the module, not the root file":

  test "t_stale_layout_is_rejected_loudly_when_named_explicitly":
    let bashBin = findExe("bash")
    if bashBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-bearssl-stale-", "")
      defer: removeDir(scratch)
      let workdir = scratch / "work"
      createDir(workdir)
      # The exact shape the old probe accepted: root file present, module tree
      # absent.
      let stale = makeCheckout(scratch / "stale-bearssl", withModuleTree = false)
      check fileExists(stale / "bearssl.nim")
      check not fileExists(stale / "bearssl" / "abi" / "consttypes.nim")

      let res = runResolve(bashBin, workdir, stale, setVar = true)
      check res.code != 0
      # Names the offending path AND the file it lacks — the two facts that
      # turn this from "something is wrong" into an actionable diagnosis.
      check res.output.contains(stale)
      check res.output.contains("bearssl/abi/consttypes.nim")

  test "t_stale_explicit_value_is_not_silently_replaced":
    let bashBin = findExe("bash")
    if bashBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-bearssl-nosub-", "")
      defer: removeDir(scratch)
      let workdir = scratch / "work"
      createDir(workdir)
      # A PERFECTLY GOOD checkout sits at the sibling location the resolver
      # would otherwise fall back to...
      discard makeCheckout(scratch / "nim-bearssl", withModuleTree = true)
      let stale = makeCheckout(scratch / "stale-bearssl", withModuleTree = false)

      # ...and the run still fails, because the caller NAMED the stale one.
      # Falling back here would paper over a stale pin in whatever set the
      # variable, and the operator would never learn their value was ignored.
      let res = runResolve(bashBin, workdir, stale, setVar = true)
      check res.code != 0
      check res.output.contains(stale)

  test "t_checkout_with_the_module_tree_is_accepted":
    let bashBin = findExe("bash")
    if bashBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-bearssl-good-", "")
      defer: removeDir(scratch)
      let workdir = scratch / "work"
      createDir(workdir)
      let good = makeCheckout(scratch / "good-bearssl", withModuleTree = true)

      let res = runResolve(bashBin, workdir, good, setVar = true)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0
      check res.output.strip() == good

  test "t_sibling_checkout_is_found_with_no_value_set":
    let bashBin = findExe("bash")
    if bashBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-bearssl-sibling-", "")
      defer: removeDir(scratch)
      let workdir = scratch / "work"
      createDir(workdir)
      # `../nim-bearssl` relative to the working directory.
      discard makeCheckout(scratch / "nim-bearssl", withModuleTree = true)

      let res = runResolve(bashBin, workdir, "", setVar = false)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0
      check res.output.strip() == "../nim-bearssl"

  test "t_nothing_reachable_fails_naming_the_dev_shell":
    let bashBin = findExe("bash")
    if bashBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-bearssl-none-", "")
      defer: removeDir(scratch)
      let workdir = scratch / "work"
      createDir(workdir)
      # No env value, no sibling, and no `flake.nix` in the working directory,
      # so the dev-shell branch cannot answer either.
      let res = runResolve(bashBin, workdir, "", setVar = false)
      check res.code != 0
      check res.output.contains("bearssl/abi/consttypes.nim")
      # The remedy is named. A build that stops here has to say what to do, or
      # it has only moved the confusion earlier.
      check res.output.contains("dev shell")
      check res.output.contains("BEARSSL_SRC")
