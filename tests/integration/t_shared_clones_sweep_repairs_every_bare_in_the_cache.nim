## Every shared bare in the clone cache can be brought to the required
## config, not only the ones an enabled project happens to refresh.
##
## ``prepareSharedBare`` (the fetch refspec plus the borrower-safety config)
## runs lazily, on the bares a refresh touches, so a bare that no enabled
## project declares is never visited: it stays frozen at its clone-time tips,
## or unprotected. ``repro workspace shared-clones gc`` and ``rewire`` sweep the
## whole cache root and report each bare's verdict as found, before repairing
## it, so a repair never hides the evidence that a second tool is writing the
## cache.
##
## Cases:
##
##   - ``eager_sweep_repairs_a_bare_no_project_declares`` -- a cache root holds
##     two bares no project declares: one as an old build left it (neither
##     refspec nor safety config) and one carrying the refspec WITHOUT the
##     safety config. The sweep reports each one's verdict as found, then both
##     carry the refspec and every safety key, and a second sweep repairs
##     nothing. A non-bare checkout in the cache is not a pool and is skipped.
##   - ``gc_sweeps_the_cache_and_list_reports_last_fetch`` -- through the CLI:
##     ``repro workspace shared-clones gc`` repairs a bare no project declares
##     and names the refspec-without-safety one as such, and ``list`` reports
##     the declared pool's verdict and when it last fetched.
##
## Test doubles: none. Every case drives the real ``git`` (and, in the CLI
## case, the real ``repro`` binary) against real repositories.
##
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import shared_clones

proc q(value: string): string = quoteShell(value)

proc sh(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output.strip())

proc must(command: string; cwd = ""): string =
  let res = sh(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\n" & res.output)
  doAssert res.code == 0, "fixture command failed: " & command
  res.output

proc seedUpstream(gitBin, scratch: string): tuple[bare, work: string] =
  result.bare = scratch / "upstream.git"
  result.work = scratch / "upstream-work"
  discard must(q(gitBin) & " init -q --bare -b main " & q(result.bare))
  discard must(q(gitBin) & " init -q -b main " & q(result.work))
  discard must(q(gitBin) & " -C " & q(result.work) &
    " config user.email t@example.invalid")
  discard must(q(gitBin) & " -C " & q(result.work) & " config user.name T")
  writeFile(result.work / "a.txt", "one\n")
  discard must(q(gitBin) & " -C " & q(result.work) & " add a.txt")
  discard must(q(gitBin) & " -C " & q(result.work) & " commit -q -m one")
  discard must(q(gitBin) & " -C " & q(result.work) & " remote add origin " &
    q(result.bare))
  discard must(q(gitBin) & " -C " & q(result.work) & " push -q origin main")

proc commitUpstream(gitBin, work, body: string): string =
  writeFile(work / "a.txt", body)
  discard must(q(gitBin) & " -C " & q(work) & " commit -q -am " & q(body))
  discard must(q(gitBin) & " -C " & q(work) & " push -q origin main")
  must(q(gitBin) & " -C " & q(work) & " rev-parse HEAD")

proc configGet(gitBin, repo, key: string): string =
  sh(q(gitBin) & " -C " & q(repo) & " config --get " & key).output

proc hasEverySafetyKey(gitBin, bare: string): bool =
  result = true
  for (key, value) in SharedBareSafetyConfig:
    if configGet(gitBin, bare, key).toLowerAscii != value.toLowerAscii:
      checkpoint(bare & ": " & key & " is not " & value)
      result = false

proc plainBare(gitBin, upstream, dest: string) =
  ## A bare exactly as ``git clone --bare`` leaves it: no refspec, no safety.
  createDir(dest.parentDir)
  discard must(q(gitBin) & " clone -q --bare " & q(upstream) & " " & q(dest))

proc reproBinary(): string =
  let root = currentSourcePath().parentDir.parentDir.parentDir
  requireBinary(root / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

suite "shared clone cache sweep":

  test "eager_sweep_repairs_a_bare_no_project_declares":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let scratch = createTempDir("repro-sweep-", "")
      defer: removeDir(scratch)
      let up = seedUpstream(gitBin, scratch)
      let cache = scratch / "cache"
      let old = cache / "example.invalid" / "org" / "old.git"
      let odd = cache / "example.invalid" / "org" / "odd.git"
      plainBare(gitBin, up.bare, old)
      plainBare(gitBin, up.bare, odd)
      # The state no build of this tool writes: refspec, no safety config.
      discard must(q(gitBin) & " -C " & q(odd) &
        " config remote.origin.fetch " & q(SharedBareFetchRefspec))
      discard must(q(gitBin) & " -C " & q(odd) & " config remote.origin.prune true")
      # A non-bare checkout in the cache is not a pool and is left alone.
      discard must(q(gitBin) & " clone -q " & q(up.bare) & " " &
        q(cache / "example.invalid" / "org" / "checkout"))

      check inspectSharedBareVerdict(old) == "unconfigured"
      check inspectSharedBareVerdict(odd) == "refspec-without-safety"

      let swept = sweepSharedBares(gitBin, cache)
      check swept.len == 2
      for e in swept:
        checkpoint(e.path & " " & e.before & " -> " & e.after & " " &
          e.diagnostic)
        check e.repaired
        check e.after == "ok"
        if e.path == old:
          check e.before == "unconfigured"
        elif e.path == odd:
          check e.before == "refspec-without-safety"
        else:
          check false
      for bare in [old, odd]:
        check configGet(gitBin, bare, "remote.origin.fetch") ==
          SharedBareFetchRefspec
        check hasEverySafetyKey(gitBin, bare)
        check configGet(gitBin, bare, "gc.pruneExpire").len > 0
      # Idempotent: a second sweep finds everything complete and repairs none.
      for e in sweepSharedBares(gitBin, cache):
        check e.before == "ok"
        check not e.repaired

  test "gc_sweeps_the_cache_and_list_reports_last_fetch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH")
    else:
      let scratch = createTempDir("repro-sweep-cli-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      let up = seedUpstream(gitBin, scratch)
      let url = fileUrl(up.bare)
      let cache = scratch / "clones-cache"
      let env = @[("REPRO_WORKSPACE_CLONES", cache)]
      let ws = scratch / "ws"
      createDir(ws / "projects")
      createDir(ws / "repos")
      writeFile(ws / "projects" / "pg0proj.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"pg0proj\"\n" &
        "\n" &
        "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & url & "\"\n\n" &
        "includes = [\n  \"repos/lib.toml\",\n]\n")
      writeFile(ws / "repos" / "lib.toml",
        "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
        "name = \"lib\"\npath = \"lib\"\nremote = \"lib-origin\"\n" &
        "mainline = \"main\"\n")
      discard must(q(gitBin) & " clone -q --branch main " & q(url) & " " &
        q(ws / "lib"))
      let stray = cache / "example.invalid" / "org" / "stray.git"
      let odd = cache / "example.invalid" / "org" / "odd.git"
      plainBare(gitBin, up.bare, stray)
      plainBare(gitBin, up.bare, odd)
      discard must(q(gitBin) & " -C " & q(odd) &
        " config remote.origin.fetch " & q(SharedBareFetchRefspec))
      discard must(q(gitBin) & " -C " & q(odd) & " config remote.origin.prune true")

      let gc = runShell(shellCommand(@[reproBin, "workspace", "shared-clones",
        "gc", "pg0proj", "--workspace-root=" & ws, "--json"], env))
      checkpoint("gc output: " & gc.output)
      check gc.code == 0
      let report = parseJson(gc.output)
      var seen = 0
      for e in report["sweep"]:
        let path = e["bare"].getStr()
        if path == stray:
          inc seen
          check e["before"].getStr() == "unconfigured"
        elif path == odd:
          inc seen
          check e["before"].getStr() == "refspec-without-safety"
        check e["after"].getStr() == "ok"
      check seen == 2
      check hasEverySafetyKey(gitBin, stray)
      check configGet(gitBin, stray, "remote.origin.fetch") ==
        SharedBareFetchRefspec

      let text = runShell(shellCommand(@[reproBin, "workspace",
        "shared-clones", "gc", "pg0proj", "--workspace-root=" & ws], env))
      check text.code == 0
      check "sweep bares=" in text.output
      check "refspec-without-safety=0" in text.output

      # ``rewire`` creates and fetches the declared repo's pool; ``list`` then
      # reports its verdict and last fetch.
      let rewire = runShell(shellCommand(@[reproBin, "workspace",
        "shared-clones", "rewire", "pg0proj", "--workspace-root=" & ws,
        "--json"], env))
      checkpoint("rewire output: " & rewire.output)
      check rewire.code == 0
      discard commitUpstream(gitBin, up.work, "two")
      discard runShell(shellCommand(@[reproBin, "workspace", "shared-clones",
        "rewire", "pg0proj", "--workspace-root=" & ws, "--json"], env))
      let listed = runShell(shellCommand(@[reproBin, "workspace",
        "shared-clones", "list", "pg0proj", "--workspace-root=" & ws,
        "--json"], env))
      check listed.code == 0
      let lr = parseJson(listed.output)
      check lr["repos"].len == 1
      check lr["repos"][0]["verdict"].getStr() == "ok"
      check lr["repos"][0]["lastFetch"].getStr().len > 0
