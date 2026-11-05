## Running the host tools a bundle is made and restored with (`nix`,
## `nix-store`, `git`, `tar`, `zstd`, `curl`). They are resolved from `PATH`
## on purpose: on the restoring side they are what the machine has before any
## repro store exists, and on the creating side `nix` must be the operator's
## own. Every call goes through `uncontrolled*`, so it stays labelled.

import std/[os, osproc, streams, strtabs, strutils, tempfiles]
import repro_core/ambient_execution

type
  BundleError* = object of CatchableError
    ## Every refusal and every failed tool, with the reason.

  ToolResult* = object
    output*: string
    errors*: string
    code*: int

proc bundleFail*(msg: string) {.noreturn.} =
  raise newException(BundleError, msg)

proc requireExe*(name: string): string =
  # Not following links: `nix-store` is a link to the multi-call `nix`,
  # which dispatches on the name it was run by.
  result = uncontrolledFindExe(name, followSymlinks = false)
  if result.len == 0:
    bundleFail("`" & name & "` is not on PATH")

proc shellJoin*(args: openArray[string]): string =
  for i, a in args:
    if i > 0: result.add(' ')
    result.add(quoteShell(a))

proc runShell*(script: string; cwd = ""; stdinData = "";
               env: StringTableRef = nil): ToolResult =
  ## Run `script` with bash (`pipefail` on). stdout is returned; stderr is
  ## collected in a file so a chatty tool cannot block on a full pipe while
  ## stdout is being read.
  let (errFile, errPath) = createTempFile("repro-bundle-", ".stderr")
  errFile.close()
  defer: removeFile(errPath)
  let p = uncontrolledStartProcess(requireExe("bash"), workingDir = cwd,
    args = ["-c", "set -o pipefail; (" & script & ") 2>" & quoteShell(errPath)],
    env = env, options = {})
  if stdinData.len > 0:
    p.inputStream.write(stdinData)
  p.inputStream.close()
  result.output = p.outputStream.readAll()
  result.code = p.waitForExit()
  p.close()
  result.errors = readFile(errPath)

proc runTool*(exe: string; args: openArray[string]; cwd = "";
              stdinData = ""; env: StringTableRef = nil): ToolResult =
  runShell("exec " & shellJoin(@[exe] & @args), cwd, stdinData, env)

proc tail(text: string; lines = 12): string =
  let all = text.strip().splitLines()
  all[max(0, all.len - lines) .. ^1].join("\n")

proc mustRun*(exe: string; args: openArray[string]; cwd = "";
              stdinData = ""; env: StringTableRef = nil): string =
  ## stdout of a tool that must succeed; otherwise a BundleError naming the
  ## command and the end of its stderr.
  let r = runTool(exe, args, cwd, stdinData, env)
  if r.code != 0:
    bundleFail("`" & extractFilename(exe) & " " & args.join(" ") &
      "` failed (exit " & $r.code & "):\n" & tail(r.errors))
  r.output

proc mustRunShell*(script: string; what: string; cwd = "";
                   stdinData = ""): string =
  let r = runShell(script, cwd, stdinData)
  if r.code != 0:
    bundleFail(what & " failed (exit " & $r.code & "):\n" & tail(r.errors))
  r.output
