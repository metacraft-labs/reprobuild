## Shared helpers for the gates that run the INSTALLED Nix package — the
## `nix build` of this very checkout — rather than the checkout's
## `build/bin` binaries: `t_e2e_nix_package_compiles_profile.nim` (GM1) and
## `t_e2e_nix_package_compiles_profile_clean_env.nim` (GM1l).
##
## Every process is spawned from an argv sequence, never through a shell.

import std/[os, osproc, sets, streams, strtabs, strutils]

const ProjectRoot* = currentSourcePath().parentDir().parentDir().parentDir()
  .parentDir()
  ## The reprobuild checkout these tests belong to.

type RunResult* = tuple[exitCode: int; output: string]

proc run*(exe: string; args: openArray[string]; cwd: string;
          env: StringTableRef = nil): RunResult =
  ## Run `exe` with `args` in `cwd`, stderr merged into stdout. `env`, when
  ## given, is the child's WHOLE environment.
  let p = startProcess(exe, workingDir = cwd, args = @args, env = env,
    options = {poStdErrToStdOut, poUsePath})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (exitCode: code, output: output)

proc buildNixPackage*(): string =
  ## `nix build` of this checkout's `#default`, returning the store path.
  ## The flake is a git tree, so nix builds the working tree's tracked (and
  ## staged) files — the code under test, not a pinned release.
  let res = run("nix", ["build", "--no-link", "--print-out-paths",
    ProjectRoot & "#default"], ProjectRoot)
  doAssert res.exitCode == 0, "nix build failed:\n" & res.output
  for line in res.output.splitLines:
    if line.strip().startsWith("/nix/store/"):
      result = line.strip()
  doAssert result.len > 0, "nix build printed no store path:\n" & res.output

proc packageClosure*(storePath: string): HashSet[string] =
  ## Every store path in `storePath`'s runtime closure
  ## (`nix path-info --recursive`).
  let res = run("nix", ["path-info", "--recursive", storePath], ProjectRoot)
  doAssert res.exitCode == 0, "nix path-info failed:\n" & res.output
  for line in res.output.splitLines:
    if line.strip().startsWith("/nix/store/"):
      result.incl line.strip()
  doAssert storePath in result, "closure of " & storePath & " lacks itself"

proc storePathOf*(path: string): string =
  ## The `/nix/store/<hash>-<name>` prefix of a path inside the store, or ""
  ## for a path outside it.
  const store = "/nix/store/"
  if not path.startsWith(store):
    return ""
  let rest = path[store.len .. ^1]
  let slash = rest.find('/')
  store & (if slash < 0: rest else: rest[0 ..< slash])

proc wrapperDefault*(wrapper, name: string): string =
  ## The value a makeWrapper `--set-default` line gives `name`:
  ##   export NAME=${NAME-'value'}
  let prefix = "export " & name & "=${" & name & "-'"
  for line in readFile(wrapper).splitLines:
    if line.startsWith(prefix) and line.endsWith("'}"):
      return line[prefix.len ..< line.len - 2]
  doAssert false, wrapper & " sets no default for " & name
