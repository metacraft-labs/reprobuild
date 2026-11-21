## The Nix half of a workspace bundle (Workspace-Bundles.md §2): every
## member's dev-shell closure, its `nix-store --dump-db` registration, and a
## normalised `nix print-dev-env` per shell, so a session enters a shell with
## no evaluation.

import std/[algorithm, json, os, sets, strutils, tempfiles]
import nimcrypto/sha2
import repro_core/ambient_execution
import repro_local_store/store_bundle
import ./exec
import ./select

type
  BundleShell* = object
    name*: string        ## `<member>:<shell>`
    input*: string       ## `inputDerivation` output
    env*: string         ## store path of the normalised environment script

  NixHalf* = object
    id*: string
    system*: string
    nixVersion*: string
    zstd*: string        ## store path whose `bin/zstd` the bootstrap realises
    repro*: string       ## store path whose `bin/repro` restores the rest, or ""
    paths*: seq[string]
    unpackedBytes*: int64
    compressedBytes*: int64
    parts*: seq[BundlePart]
    registration*: BundlePart
    shells*: seq[BundleShell]
    primary*: string

  NixHalfOptions* = object
    allShells*: bool
    primary*: string
    zstd*: string
    repro*: string
    level*: int
    partSize*: int64
    checkStable*: bool

const
  NixHalfDir* = "nix"
  NixManifestName* = "nix.json"
  NixIdDomain = "reprobuild.workspace-bundle.nix.v1"

proc sha256Hex*(text: string): string =
  lowerHex(sha256.digest(text).data)

proc currentSystem*(): string =
  mustRun(requireExe("nix"), ["eval", "--impure", "--raw", "--expr",
    "builtins.currentSystem"]).strip()

proc storePathOf*(path: string): string =
  ## `/nix/store/<hash>-<name>` for a path inside the store, else "".
  let p = normalizedPath(path)
  if not p.startsWith("/nix/store/"): return ""
  let rest = p["/nix/store/".len .. ^1]
  let slash = rest.find('/')
  "/nix/store/" & (if slash < 0: rest else: rest[0 ..< slash])

proc normaliseDevEnv*(text: string): string =
  ## §2.1. `NIX_BUILD_CORES` names the building machine's cores; the
  ## shellHook installs git hooks, which repro owns. The working-directory
  ## dependence is removed by running `print-dev-env` in the member's
  ## checkout, not here.
  for line in text.splitLines(keepEol = true):
    let s = line.strip()
    if s.startsWith("eval \"${shellHook") or s.startsWith("eval \"$shellHook"):
      continue
    if line.startsWith("NIX_BUILD_CORES='"):
      result.add("NIX_BUILD_CORES=\"$(nproc 2>/dev/null || echo 1)\"\n")
      continue
    result.add(line)

proc devenvArgs(dir: string): seq[string] =
  ## devenv flakes evaluate only when told their checkout directory, the way
  ## their `.envrc` tells them.
  let flake = dir / "flake.nix"
  if fileExists(flake) and "devenv-root" in readFile(flake):
    createDir(dir / ".devenv")
    writeFile(dir / ".devenv" / "root", dir)
    @["--override-input", "devenv-root",
      "file+file://" & dir / ".devenv" / "root", "--accept-flake-config"]
  else:
    @[]

proc safeName(text: string): string =
  for ch in text:
    result.add(if ch.isAlphaNumeric or ch in {'-', '_', '.'}: ch else: '-')

proc captureEnv(nix: string; m: BundleMember; attr: string;
                fargs: seq[string]): string =
  normaliseDevEnv(mustRun(nix, @["print-dev-env"] & fargs & @[attr],
    cwd = m.absPath))

proc collectShells(members: seq[BundleMember]; system: string;
                   opts: NixHalfOptions): seq[BundleShell] =
  let nix = requireExe("nix")
  let scratch = createTempDir("repro-bundle-env-", "")
  defer: removeDir(scratch)
  for m in members:
    if not m.checkedOut or not fileExists(m.absPath / "flake.nix"):
      continue
    let fargs = devenvArgs(m.absPath)
    let namesJson = runTool(nix, @["eval"] & fargs & @["--json",
      m.absPath & "#devShells." & system, "--apply", "builtins.attrNames"])
    if namesJson.code != 0:
      stderr.writeLine("repro bundle: " & m.name & ": no devShells." & system &
        "; skipped")
      continue
    var names: seq[string]
    for n in parseJson(namesJson.output): names.add(n.getStr())
    if not opts.allShells:
      names = (if "default" in names: @["default"]
               elif names.len > 0: @[names[0]] else: @[])
    let member = (if m.relPath == ".": "workspace" else: m.name)
    for shell in names:
      let attr = m.absPath & "#devShells." & system & "." & shell
      # Built, not only evaluated: a shell whose evaluation downloads
      # archives cannot be re-evaluated in a session.
      let input = mustRun(nix, @["build"] & fargs & @["--no-link",
        "--print-out-paths", attr & ".inputDerivation"]).strip().splitLines()[0]
      let env = captureEnv(nix, m, attr, fargs)
      if opts.checkStable and captureEnv(nix, m, attr, fargs) != env:
        bundleFail("the environment of " & member & ":" & shell &
          " differs between two captures; its id would not be stable")
      let file = scratch / ("repro-bundle-" & safeName(member) & "-" &
        safeName(shell) & "-env.sh")
      writeFile(file, env)
      let envPath = mustRun(nix, ["store", "add-file", file]).strip()
      result.add(BundleShell(name: member & ":" & shell, input: input,
        env: envPath))
      stderr.writeLine("repro bundle:   " & member & ":" & shell)

proc closureOf(roots: seq[string]): seq[string] =
  if roots.len == 0: return
  var seen = initHashSet[string]()
  for line in mustRun(requireExe("nix-store"), @["-qR"] & roots).splitLines():
    let p = line.strip()
    if p.len > 0 and p notin seen:
      seen.incl(p)
      result.add(p)
  result.sort()

proc nixHalfId*(paths: seq[string]): string =
  ## A function of the sorted store-path list alone (§2.1).
  var sorted = paths
  sorted.sort()
  sha256Hex(NixIdDomain & "\n" & sorted.join("\n") & "\n")[0 ..< 32]

proc unpackedSize(paths: seq[string]): int64 =
  let node = parseJson(mustRun(requireExe("nix"),
    @["path-info", "--json"] & paths))
  if node.kind == JObject:
    for _, v in node:
      if v.kind == JObject: result += v{"narSize"}.getBiggestInt()
  else:
    for v in node: result += v{"narSize"}.getBiggestInt()

proc toJson*(h: NixHalf): JsonNode =
  var shells = newJObject()
  for s in h.shells:
    shells[s.name] = %*{"input": s.input, "env": s.env}
  %*{
    "id": h.id, "system": h.system, "nix": h.nixVersion, "zstd": h.zstd,
    "repro": h.repro, "paths": h.paths, "unpacked_bytes": h.unpackedBytes,
    "compressed_bytes": h.compressedBytes, "parts": partsJson(h.parts),
    "registration": {"file": h.registration.file,
      "bytes": h.registration.bytes, "sha256": h.registration.sha256},
    "shells": shells, "primary": h.primary}

proc parseNixHalf*(node: JsonNode): NixHalf =
  try:
    result.id = node["id"].getStr()
    result.system = node["system"].getStr()
    result.nixVersion = node{"nix"}.getStr()
    result.zstd = node["zstd"].getStr()
    result.repro = node{"repro"}.getStr()
    for p in node["paths"]: result.paths.add(p.getStr())
    result.unpackedBytes = node["unpacked_bytes"].getBiggestInt()
    result.compressedBytes = node{"compressed_bytes"}.getBiggestInt()
    result.parts = parsePartsJson(node["parts"])
    result.registration = parsePartsJson(%[node["registration"]])[0]
    for name, s in node["shells"]:
      result.shells.add(BundleShell(name: name, input: s["input"].getStr(),
        env: s["env"].getStr()))
    result.primary = node{"primary"}.getStr()
  except KeyError as e:
    bundleFail("malformed Nix half manifest: " & e.msg)

proc findZstd(paths: seq[string]): string =
  for p in paths:
    if "-zstd-" in p and fileExists(p / "bin" / "zstd"):
      return p

proc createNixHalf*(members: seq[BundleMember]; systemDir: string;
                    opts: NixHalfOptions): tuple[half: NixHalf; reused: bool] =
  ## Build the half into `<systemDir>/nix/<id>/`, or reuse it when a complete
  ## half with that id is already there.
  let system = currentSystem()
  let shells = collectShells(members, system, opts)
  if shells.len == 0:
    bundleFail("no member has a dev shell for " & system)
  var roots: seq[string]
  for s in shells:
    roots.add(s.input)
    roots.add(s.env)
  var reproPath = opts.repro
  if reproPath.len == 0:
    let self = getAppFilename()
    reproPath = storePathOf(self)
    if reproPath.len == 0 and symlinkExists(self):
      reproPath = storePathOf(expandSymlink(self))
  if reproPath.len > 0:
    if not fileExists(reproPath / "bin" / "repro"):
      bundleFail("--repro " & reproPath & " has no bin/repro")
    roots.add(reproPath)
  else:
    stderr.writeLine("repro bundle: this repro is not in /nix/store, so the " &
      "bundle's restore.sh will need `repro` on PATH (pass --repro=STORE-PATH)")
  var zstdPath = opts.zstd
  if zstdPath.len == 0:
    zstdPath = findZstd(closureOf(roots))
  if zstdPath.len == 0:
    let r = runTool(requireExe("nix"), ["build", "--no-link",
      "--print-out-paths", "nixpkgs#zstd.bin"])
    if r.code == 0: zstdPath = r.output.strip().splitLines()[0]
  if zstdPath.len == 0 or not fileExists(zstdPath / "bin" / "zstd"):
    bundleFail("no zstd store path for the restore side; pass --zstd=STORE-PATH")
  roots.add(zstdPath)
  let paths = closureOf(roots)
  let id = nixHalfId(paths)
  let dir = systemDir / NixHalfDir / id
  var primary = opts.primary
  if primary.len == 0:
    primary = shells[0].name
    for s in shells:
      if not s.name.startsWith("workspace:"):
        primary = s.name
        break
  if fileExists(dir / NixManifestName):
    var half = parseNixHalf(parseJson(readFile(dir / NixManifestName)))
    return (half, true)
  let partial = dir & ".partial"
  removeDir(partial)
  createDir(partial)
  let listPath = partial / ".paths"
  var list = ""
  for p in paths: list.add(p[1 .. ^1] & "\n")
  writeFile(listPath, list)
  let zstdExe = requireExe("zstd")
  let level = (if opts.level > 0: opts.level else: DefaultZstdLevel)
  discard mustRunShell("nix-store --dump-db $(cat " & quoteShell(listPath) &
    " | sed 's|^|/|') | " & zstdCompressCommand(zstdExe, 19, 0) & " > " &
    quoteShell(partial / "registration"), "nix-store --dump-db")
  let regBytes = readFile(partial / "registration")
  let unpacked = unpackedSize(paths)
  stderr.writeLine("repro bundle: nix half " & id & ": " & $paths.len &
    " paths, " & $(unpacked shr 20) & " MiB unpacked; compressing at -" &
    $level)
  let pipeline = quoteShell(requireExe("tar")) &
    " --format=posix -C / -cf - -T " & quoteShell(listPath) & " | " &
    zstdCompressCommand(zstdExe, level, 0)
  let (parts, total) = writeCompressedParts(pipeline, partial,
    (if opts.partSize > 0: opts.partSize else: DefaultPartSize))
  removeFile(listPath)
  var half = NixHalf(id: id, system: system,
    nixVersion: mustRun(requireExe("nix"), ["--version"]).strip(),
    zstd: zstdPath, repro: reproPath, paths: paths, unpackedBytes: unpacked,
    compressedBytes: total, parts: parts,
    registration: BundlePart(file: "registration", bytes: regBytes.len,
      sha256: sha256Hex(regBytes)),
    shells: shells, primary: primary)
  writeFile(partial / NixManifestName, pretty(half.toJson) & "\n")
  removeDir(dir)
  moveDir(partial, dir)
  (half, false)

proc shellRoots*(h: NixHalf): seq[string] =
  for s in h.shells:
    result.add(s.input)
    result.add(s.env)

proc storeArgs(root: string): seq[string] =
  if root.len > 0 and root != "/": @["--store", root] else: @[]

proc nixHalfPresent*(h: NixHalf; root = "/"): bool =
  let r = runTool(requireExe("nix-store"), storeArgs(root) &
    @["--check-validity"] & h.shellRoots)
  r.code == 0

proc zstdForRestore*(h: NixHalf): string =
  ## The host's zstd, else the half's own (realised by store path: one small
  ## download from the binary cache, no evaluation).
  result = uncontrolledFindExe("zstd")
  if result.len > 0: return
  if not fileExists(h.zstd / "bin" / "zstd"):
    discard mustRun(requireExe("nix-store"), ["--realise", h.zstd])
  result = h.zstd / "bin" / "zstd"

proc restoreNixHalf*(h: NixHalf; partsDir: string; root = "/") =
  ## §7 step 3: verified parts → `zstd -d | tar --skip-old-files -x`, then the
  ## registration, then every shell root must be valid.
  let zstdExe = zstdForRestore(h)
  let target = (if root.len > 0: root else: "/")
  createDir(target)
  let errPath = partsDir / ".unpack.stderr"
  let command = "set -o pipefail; (" & quoteShell(zstdExe) &
    " -q -dc --long=" & $ZstdWindowLog & " - | " &
    quoteShell(requireExe("tar")) & " -C " & quoteShell(target) &
    " --skip-old-files -xf -) >" & quoteShell(errPath) & " 2>&1"
  if feedParts(partsDir, h.parts, command, stopEarly = false) != 0:
    bundleFail("unpacking the Nix half failed: " &
      (if fileExists(errPath): readFile(errPath).strip() else: ""))
  let reg = readVerifiedPart(partsDir, h.registration)
  let db = mustRunShell(quoteShell(zstdExe) & " -q -dc", "decompressing " &
    "the registration", stdinData = reg)
  discard mustRun(requireExe("nix-store"), storeArgs(root) & @["--load-db"],
    stdinData = db)
  if not h.nixHalfPresent(root):
    bundleFail("the Nix half's registration did not make every shell root " &
      "valid")
