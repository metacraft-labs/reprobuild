## Test support (not a test): NPC-M7's build interface end to end.
##
## A world (`nimble_m6_fixtures`) holds a Nimble index repository read
## through a private shared-clone root, and the HTTPS fixture
## (`fetch_fixtures`) serves the packages' sources -- their git origins,
## their forge archives and directory mirrors. Every file the build reads
## or writes is under the world's private root: `HOME`, the XDG
## directories, the source store, the user's and the system's Reprobuild
## configuration (named by `REPROBUILD_USER_CONFIG` /
## `REPROBUILD_SYSTEM_CONFIG`). Nothing here reads or writes the real
## `$HOME/.nimble`, `/etc` or `~/.config`, and nothing contacts the
## internet: a mirror an out-of-process `repro` reaches is
## `https://127.0.0.1:<port>/...`, trusted through the fixture's
## certificate (`SSL_CERT_FILE`).
##
## The CLI tests drive the built `build/bin/repro` as a black box: `repro
## lock refresh --provisioning` writes the lock (from the project's
## `repro.solver` sidecar, the solver inputs the provider would emit), and
## `repro build` builds a small Nim program that imports the locked
## packages.

import std/[options, os, osproc, streams, strtabs, strutils, tables, tempfiles]

import ./nimble_m6_fixtures
from repro_core/process_streams import drainStream
import ../../repro_nimble_fetch/tests/fetch_fixtures

export nimble_m6_fixtures, fetch_fixtures, options

const
  ReprobuildRoot* = currentSourcePath().parentDir().parentDir().parentDir().
    parentDir()
  ReproBin* = ReprobuildRoot / "build" / "bin" / addFileExt("repro", ExeExt)

proc hexBytes(hex: string): seq[byte] =
  for i in countup(0, hex.len - 2, 2):
    result.add byte(parseHexInt(hex[i .. i + 1]))

proc recordOf*(f: Fixture; name: string; s: PublishedSource; tag: string;
               requires: seq[RequirementEntry] = @[]; srcDir = "src";
               nim = ""): VersionRecord =
  ## The index record of a served source, with its real digests.
  result = record(name, tag, requires, nim)
  result.commit = s.commit
  let t = hexBytes(s.tree)
  for i in 0 ..< 32: result.tree[i] = t[i]
  let a = hexBytes(s.archiveSha256)
  for i in 0 ..< 32: result.archiveSha256[i] = a[i]
  result.size = uint64(s.archive.len)
  result.layout.srcDir = srcDir

proc ipMirrorUrl*(f: Fixture; prefix: string): string =
  ## A mirror location an out-of-process client reaches without a test
  ## resolver: the listener's address. TLS still verifies the fixture's
  ## certificate chain; Nim checks no name against an IP literal.
  "https://127.0.0.1:" & $f.port & prefix

proc envelope*(f: Fixture; name: string; versions: seq[VersionRecord];
               s: PublishedSource): PackageEnvelope =
  result = package(name, versions)
  result.origins = @[PackageOrigin(url: f.url(s.path), vcs: ovGit)]

proc sourceSetText*(mirrors: seq[string]; natives = ""): string =
  ## A `nimble-sources.toml` declaring ``mirrors`` (and ``natives``, the
  ## text of `[[native]]` tables), as an index repository publishes it.
  result = "schema = \"reprobuild.nimble-source-set.v1\"\n\n[[extra]]\n" &
    "name = \"placeholder\"\norigin = \"https://example.invalid/x\"\n"
  for m in mirrors:
    result.add "\n[[mirror]]\nurl = \"" & m & "\"\n"
  if natives.len > 0:
    result.add "\n" & natives

type
  CliEnv* = object
    ## The environment of an out-of-process `repro`, all under the world.
    vars*: seq[(string, string)]

proc trustBundle(w: World; f: Fixture): string =
  ## The host's trust anchors plus the fixture's certificate, so the
  ## out-of-process `repro` trusts the loopback mirror and still every
  ## anchor the host trusts.
  result = w.root / "trust.pem"
  var text = ""
  let host = defaultCaFile()
  if host.len > 0: text = readFile(host) & "\n"
  writeFile(result, text & readFile(f.cert))

const BuildArgs* = @["build", ".", "--daemon=off", "--tool-provisioning=path"]
  ## `repro build` as the CLI tests run it: in this process (no per-user
  ## daemon outlives the test) and with the host's tools on `PATH`.

proc cliEnv*(w: World; f: Fixture; extra: seq[(string, string)] = @[]):
    CliEnv =
  let home = w.root / "home"
  result.vars = @[
    ("HOME", home),
    ("XDG_CACHE_HOME", home / ".cache"),
    ("XDG_CONFIG_HOME", home / ".config"),
    ("XDG_DATA_HOME", home / ".local" / "share"),
    ("XDG_STATE_HOME", home / ".local" / "state"),
    ("REPRO_WORKSPACE_CLONES", w.clones),
    ("REPRO_CACHE_DISABLE", "1"),
    ("REPROBUILD_NO_RUNQUOTA", "1"),
    ("REPROBUILD_USER_CONFIG", w.root / "etc-user" / "config.toml"),
    ("REPROBUILD_SYSTEM_CONFIG", w.root / "etc-system" / "config.toml"),
    ("SSL_CERT_FILE", trustBundle(w, f))]
  # The C compiler that compiles the project's recipe: the host's, so a
  # build under a fresh HOME does not provision one (through Nix).
  let cc = getEnv("REPRO_BOOTSTRAP_CC", findExe("cc", followSymlinks = false))
  if cc.len > 0: result.vars.add ("REPRO_BOOTSTRAP_CC", cc)
  result.vars.add extra

proc runRepro*(env: CliEnv; cwd: string; args: seq[string];
               offline = false): Ran =
  ## Run the built `repro` with ``args`` in ``cwd`` under ``env``: the
  ## host's `PATH` (the toolchain), and nothing else of the host's that
  ## names a file -- in particular no `NIMBLE_DIR` and no
  ## `REPRO_WORKSPACE_CONFIG`. ``offline`` runs it in a network namespace
  ## of its own with no interface up (`unshare -c -n`): not even the
  ## fixture's loopback listener can be reached.
  doAssert fileExists(ReproBin), "build " & ReproBin & " first (just build)"
  var e = newStringTable(modeCaseSensitive)
  for (k, v) in envPairs():
    if k in ["PATH", "LANG", "TERM", "TMPDIR", "USER", "LOGNAME", "TZ"]:
      e[k] = v
  for (k, v) in env.vars: e[k] = v
  let (exe, argv) =
    if offline: (findExe("unshare"), @["-c", "-n", ReproBin] & args)
    else: (ReproBin, args)
  doAssert exe.len > 0, "offline needs unshare(1)"
  let p = startProcess(exe, workingDir = cwd, args = argv, env = e,
    options = {poStdErrToStdOut})
  result.output = drainStream(p.outputStream)
  result.rc = p.waitForExit()
  p.close()

const AppProject* = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package app:
  defaultToolProvisioning "path"

  uses:
    "nim"
    "gcc"
    "sh"
$USES
  build:
    discard nim.c(
      source = "src/app.nim",
      binary = "build/bin/app",
      parallelBuild = 1)
    discard shell(
      command = "mkdir -p build && ./build/bin/app",
      actionId = "app.run",
      extraInputs = @["build/bin/app"],
      extraOutputs = @["build/app-out.txt"],
      cacheable = false)
"""

proc writeCliProject*(w: World; name: string; requires: seq[(string, string)];
                      appSource: string; projectText = AppProject): string =
  ## A project whose `repro.nim` compiles `src/app.nim` with `nim.c` and
  ## runs it (writing `build/app-out.txt`), whose `uses:` names each
  ## required `nimble:` package, and whose `repro.solver` sidecar holds the
  ## same requirements for `repro lock refresh`.
  result = w.newProject(requires)
  var uses = ""
  for (n, _) in requires: uses.add "    \"nimble:" & n & "\"\n"
  writeFile(result / "repro.nim", projectText.replace("$USES", uses))
  createDir(result / "src")
  writeFile(result / "src" / "app.nim", appSource)
  discard name

proc storeRootOf*(w: World): string =
  ## The user's source store of the world's `HOME`.
  w.root / "home" / ".cache" / "reprobuild" / "store" / "nimble-sources"

proc findFiles*(root, name: string): seq[string] =
  ## Every file called ``name`` under ``root`` (links not followed).
  if not dirExists(root): return
  for p in walkDirRec(root, yieldFilter = {pcFile, pcLinkToFile},
                      followFilter = {pcDir}):
    if extractFilename(p) == name: result.add p

proc hostNimVersion*(): tuple[text: string; major, minor, patch: int] =
  ## The version of the `nim` on `PATH` (the toolchain the CLI builds use).
  let answer = execProcess(findExe("nim"), args = ["--version"],
    options = {poStdErrToStdOut})
  for line in answer.splitLines():
    let at = line.find("Version ")
    if "Nim Compiler" in line and at >= 0:
      var v = line[at + 8 .. ^1].strip()
      let stop = v.find({' ', '['})
      if stop > 0: v = v[0 ..< stop]
      let parts = v.split('.')
      return (v, parseInt(parts[0]), parseInt(parts[1]), parseInt(parts[2]))
  doAssert false, "cannot read the version of nim: " & answer

type
  ServedPackage* = object
    name*: string
    src*: PublishedSource
    record*: VersionRecord

proc servePackage*(f: Fixture; mirror: Mirror; name, module: string;
                   requires: seq[RequirementEntry] = @[]; nim = "";
                   tag = "v1.0.0"): ServedPackage =
  ## A package `owner/<name>.git` whose `src/<name>.nim` is ``module``,
  ## put on ``mirror``, with its index record.
  result.name = name
  result.src = f.package("owner/" & name & ".git", @[nimbleFile(name),
    file("src/" & name & ".nim", module)])
  mirror.putSource(result.src)
  result.record = f.recordOf(name, result.src, tag, requires, nim = nim)

proc envelopes*(f: Fixture; served: seq[ServedPackage]): seq[PackageEnvelope] =
  for s in served:
    result.add f.envelope(s.name, @[s.record], s.src)

type
  CliWorld* = object
    ## A world and the directory its HTTPS fixture serves as `/mirror/`.
    ## The fixture itself is NOT a field: it owns its server thread, which
    ## must not be copied, so each test binds it with `let` (``newFixture``
    ## with ``mirrorRoutes``).
    w*: World
    mirrorDir*: string
    mirror*: Mirror

proc newCliWorld*(tag: string): CliWorld =
  result.w = newWorld(tag)
  result.mirrorDir = result.w.root / "mirror"
  createDir(result.mirrorDir)
  result.mirror = parseMirror(result.mirrorDir)

proc mirrorRoutes*(c: CliWorld): seq[Route] =
  @[Route(prefix: "/mirror/", serveDir: c.mirrorDir)]

proc publishServed*(c: CliWorld; f: Fixture; served: seq[ServedPackage];
                    message = "generation"): string =
  ## Publish a generation holding ``served``, whose source set declares the
  ## HTTPS mirror. Returns the commit.
  c.w.publish(f.envelopes(served), daysAgo(1), message,
    extraFiles = @[("nimble-sources.toml",
      sourceSetText(@[f.ipMirrorUrl("/mirror/")]))]).commit
