## A split esbuild bundle built in two checkouts is byte-identical, file names
## included, when the bundle step runs in a canonical work tree.
##
## The regression test of reprobuild-pm issue
## `2026-10-10-bundle-chunk-names-encode-the-checkout-path` (spec:
## `Hermetic-Builds-And-Path-Independence.md` §"Canonical work trees").
## esbuild names a split chunk by a hash of its content. A module that embeds
## its own absolute path -- gemini-cli's wasm plugin writes
## `// wasm-embedded:<path>` comments -- therefore gets a different chunk NAME
## in every checkout, and every importer changes with it. Rewriting the path
## after the bundler ran (node_package's `DeliveredPathRewriter`, reproduced
## here) makes the bytes path-free but cannot change the names.
##
## The fixture is the minimal form of that: a generated module whose legal
## comment names its own absolute path, imported dynamically so esbuild splits
## it into `lazy-<hash>.js`, bundled with the real esbuild in two checkouts at
## different paths, the path rewritten afterwards, and the bundle delivered to
## a declared output in each checkout. Run through `runBuild` with no cache.
##
## The CONTROL is the same action without a canonical work key, building in a
## per-checkout scratch directory -- what `node_package` did before. Its
## chunk names must DIFFER between the checkouts: if they did not, this
## fixture could not detect the defect and the keyed case would prove nothing.
##
## Needs `sh`, `node` and esbuild. esbuild is taken from `$REPRO_TEST_ESBUILD`
## (the esbuild executable) or `esbuild` on `PATH`; the case is skipped, with
## the reason, when any is missing.

import std/[algorithm, os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_build_engine
import repro_core/canonical_work_dir
import repro_core/path_identity
import repro_hash

const
  GenJs = """
const fs = require("fs"), path = require("path");
const p = path.resolve("lazy.js");
fs.writeFileSync(p, "//! module source: " + p + "\nexport const where = 'lazy';\n");
"""
  EntryJs = """
export async function load() { return (await import("./lazy.js")).where; }
"""
  # node_package's DeliveredPathRewriter, verbatim in behaviour.
  RewriteJs = """
const fs = require("fs"), path = require("path");
const work = process.argv[2], dist = process.argv[3];
const spellings = [...new Set([work, work.replace(/\\/g, "/"),
  work.replace(/\//g, "\\")])].sort((a, b) => b.length - a.length);
const walk = (dir) => {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { walk(p); continue; }
    if (!/\.(m?js|cjs|map)$/.test(e.name)) continue;
    const before = fs.readFileSync(p, "latin1");
    let after = before;
    for (const s of spellings) after = after.split(s).join(".");
    if (after !== before) fs.writeFileSync(p, after, "latin1");
  }
};
walk(dist);
"""

proc shq(path: string): string =
  "\"" & path.replace("\\", "/") & "\""

proc esbuildExe(): string =
  result = getEnv("REPRO_TEST_ESBUILD")
  if result.len == 0:
    result = findExe("esbuild")

proc makeCheckout(root: string) =
  createDir(root / "src")
  writeFile(root / "src" / "gen.js", GenJs)
  writeFile(root / "src" / "entry.js", EntryJs)
  writeFile(root / "src" / "rewrite.js", RewriteJs)
  createDir(root / "out")

proc bundleAction(sh, esbuild, root, key: string): BuildAction =
  ## The bundle step, shaped like node_package's: copy the sources into the
  ## work tree, generate, bundle, rewrite, deliver to a declared output.
  let work =
    if key.len > 0: "\"$" & CanonicalWorkDirEnv & "\""
    else: shq(root / "scratch")
  var script = "set -e; "
  if key.len > 0:
    script.add(": \"${" & CanonicalWorkDirEnv & ":?no canonical tree}\"; ")
  script.add("mkdir -p " & work & "/src; cp -R src/. " & work & "/src/; " &
    "cd " & work & "/src; node gen.js; " &
    shq(esbuild) & " entry.js --bundle --splitting --format=esm " &
    "--outdir=dist --legal-comments=inline --log-level=warning; " &
    "node rewrite.js " & work & "/src dist; " &
    "rm -rf " & shq(root / "out" / "dist") & "; mkdir -p " &
    shq(root / "out" / "dist") & "; cp -R dist/. " &
    shq(root / "out" / "dist") & "/")
  result = action("bundle/split", [sh, "-c", script], cwd = root,
    outputs = ["out/dist"],
    cacheable = false,
    weakFingerprint = weakFingerprintFromText("bundle.split"),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  if key.len > 0:
    result.canonicalWorkKey = key
  else:
    result.scratchDirs = @["scratch"]

proc run(root: string; a: BuildAction): BuildRunResult =
  var config = defaultBuildEngineConfig(root / "cache")
  config.bypassRunQuota = true
  config.maxParallelism = 1'u32
  runBuild(graph([a]), config)

proc bundleFiles(root: string): seq[(string, string)] =
  ## (relative name, bytes) of every delivered file, sorted by name.
  let dist = root / "out" / "dist"
  for path in walkDirRec(dist):
    result.add((relativePath(path, dist).replace("\\", "/"), readFile(path)))
  result.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))

proc names(files: seq[(string, string)]): seq[string] =
  for (name, _) in files:
    result.add(name)

proc toolsOrSkipReason(): string =
  if findExe("sh").len == 0: return "no `sh` on PATH"
  if findExe("node").len == 0: return "no `node` on PATH"
  if esbuildExe().len == 0 or not fileExists(esbuildExe()):
    return "no esbuild: set REPRO_TEST_ESBUILD to the esbuild executable " &
      "or put `esbuild` on PATH"
  ""

suite "a canonical work tree makes a split bundle reproducible":

  test "two checkouts deliver byte-identical bundles, names included":
    let why = toolsOrSkipReason()
    if why.len > 0:
      skip(why)
    else:
      let sh = findExe("sh")
      let esbuild = esbuildExe()
      let base = createTempDir("canonical-bundle-", "")
      defer: removeDir(base)
      # The engine's system root, pointed at a private directory so the test
      # never creates the host's real one.
      let savedRoot = getEnv(ExecRootOverrideEnv)
      putEnv(ExecRootOverrideEnv, base / "exec-root")
      defer:
        if savedRoot.len > 0: putEnv(ExecRootOverrideEnv, savedRoot)
        else: delEnv(ExecRootOverrideEnv)
      # Two checkouts at different depths and names.
      let a = base / "checkout-a"
      let b = base / "elsewhere" / "deeper" / "checkout-b"
      makeCheckout(a)
      makeCheckout(b)
      let key = "t-split-bundle-" & $getCurrentProcessId()
      let ra = run(a, bundleAction(sh, esbuild, a, key))
      require ra.results.len == 1
      checkpoint(ra.results[0].stderr)
      require ra.results[0].status == asSucceeded
      let rb = run(b, bundleAction(sh, esbuild, b, key))
      require rb.results.len == 1
      checkpoint(rb.results[0].stderr)
      require rb.results[0].status == asSucceeded
      # Placed under the (private) system root, not the per-user fallback.
      var placed = ""
      for event in ra.trace:
        if event.event == "canonical-work":
          placed = event.detail
      checkpoint("placed at: " & placed)
      check placed.startsWith(base / "exec-root")
      check "fallback" notin placed
      let fa = bundleFiles(a)
      let fb = bundleFiles(b)
      checkpoint("A: " & names(fa).join(", "))
      checkpoint("B: " & names(fb).join(", "))
      var chunks = 0
      for name in names(fa):
        if name.startsWith("lazy-"):
          inc chunks
      check chunks == 1            # the module really was split
      check names(fa) == names(fb)
      check fa == fb
      # Delivered bytes name no host path: neither checkout, nor the tree.
      for (name, bytes) in fa:
        check (base.replace("\\", "/")) notin bytes.replace("\\", "/")
      # The successful run's tree was removed; the key directory stays.
      check not dirExists(base / "exec-root" / key / "work")
      check dirExists(base / "exec-root" / key)

  test "control: without the canonical tree the chunk names differ":
    let why = toolsOrSkipReason()
    if why.len > 0:
      skip(why)
    else:
      let sh = findExe("sh")
      let esbuild = esbuildExe()
      let base = createTempDir("canonical-bundle-control-", "")
      defer: removeDir(base)
      let a = base / "checkout-a"
      let b = base / "elsewhere" / "deeper" / "checkout-b"
      makeCheckout(a)
      makeCheckout(b)
      let ra = run(a, bundleAction(sh, esbuild, a, ""))
      require ra.results.len == 1
      checkpoint(ra.results[0].stderr)
      require ra.results[0].status == asSucceeded
      let rb = run(b, bundleAction(sh, esbuild, b, ""))
      require rb.results.len == 1
      checkpoint(rb.results[0].stderr)
      require rb.results[0].status == asSucceeded
      let fa = bundleFiles(a)
      let fb = bundleFiles(b)
      checkpoint("A: " & names(fa).join(", "))
      checkpoint("B: " & names(fb).join(", "))
      # The defect this fixture exists to catch: path-free bytes, but the
      # names esbuild derived from the path differ.
      check names(fa) != names(fb)
      for (name, bytes) in fa:
        check (base.replace("\\", "/")) notin bytes.replace("\\", "/")
