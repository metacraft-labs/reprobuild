## M21 — deterministic generator that regenerates CodeTracer's vendored copy of
## the incremental-testing engine from THIS repo's canonical source.
##
## Single source of truth: `reprobuild/libs/repro_ct_incremental` is CANONICAL.
## CodeTracer ships a *generated*, drift-guarded copy under
## `src/ct_test/incremental/`. This tool produces that copy by applying ONLY
## mechanical, deterministic, idempotent transforms — never a hand edit — so the
## two copies cannot silently diverge (the drift-check test `t_ct_test_vendor_sync`
## enforces byte-identity of `sync(canonical)` against the committed copy).
##
## ## The transform (exactly what it does — nothing else)
##
## For each of the six vendored modules the transform is:
##
##   vendored = <provenance banner for that module> & "\n" & T(canonical body)
##
## where the banner is read from `tools/banners/` (`standard.txt` for the four
## self-contained modules, `backends.txt`, `engine.txt`) with the single token
## `{{PROVENANCE}}` replaced by the canonical module's absolute path, and `T` is:
##
##   * for `backends`, `catalog`, `ctfs_trace`, `extractors`, `trace_reader`:
##     the IDENTITY — the body is vendored byte-for-byte.
##
##   * for `engine`: the documented "interpreted-only" trim, expressed entirely
##     by inert `#@ctvendor` marker comments living in the canonical source (so
##     the canonical file still compiles + tests unchanged):
##       - `#@ctvendor strip` … `#@ctvendor end`  — drop the enclosed lines
##         (the native imports/exports, the native shallow hasher, the native
##         trace-dir probe — all of which need the `native_*` modules that are
##         deliberately NOT vendored into codetracer).
##       - `#@ctvendor replace` … `#@ctvendor with` … `#@ctvendor end` — replace
##         the first block (real canonical code) with the second. In the second
##         block every line is prefixed `#@| ` in the canonical source so it is
##         INERT there; the generator strips that prefix to activate it. This
##         expresses the three case-arm MERGES the trim needs (native folded into
##         the nil/fail-safe arm) without leaving canonical non-compiling.
##     plus one global literal substitution applied to the body:
##       `.repro-ct-incremental` → `.ct-incremental` (the codetracer-facing cache
##       dir name). Declared here, in one place, so it is auditable.
##
## Markers are matched by a leading-`#@ctvendor`/`#@|` token after optional
## indentation, so they nest naturally with Nim's indentation and survive
## reformatting of surrounding code. Running the tool on an already-in-sync tree
## produces NO diff (idempotent).
##
## Usage:
##   sync_ct_test_vendor [--check] [codetracerCheckout]
##     codetracerCheckout  default: the workspace sibling /Users/zahary/m/dev/codetracer
##                         (overridable by arg or $CODETRACER_CHECKOUT).
##     --check             do not write; exit non-zero and print a unified-style
##                         report if any vendored file differs from sync(canonical).
##
## The canonical root is this file's `../src/repro_ct_incremental` (resolved from
## `currentSourcePath`), so the tool is independent of the cwd.

import std/[os, strutils, sequtils]

const
  ThisFile = currentSourcePath()
  ToolsDir = ThisFile.parentDir
  BannersDir = ToolsDir / "banners"
  CanonicalSrcDir = ToolsDir.parentDir / "src" / "repro_ct_incremental"
  DefaultCodetracerCheckout = "/Users/zahary/m/dev/codetracer"
  VendorRelDir = "src/ct_test/incremental"

  # The six modules and their banner template. `engine` additionally takes the
  # marker-driven trim; the rest are identity bodies.
  StandardModules = ["catalog", "ctfs_trace", "extractors", "trace_reader"]

  # The single global literal substitution applied to the engine body (the
  # codetracer-facing cache-dir name). Kept here so it is the ONE auditable place.
  EngineSubs = [(".repro-ct-incremental", ".ct-incremental")]

  MarkerStrip = "#@ctvendor strip"
  MarkerReplace = "#@ctvendor replace"
  MarkerWith = "#@ctvendor with"
  MarkerEnd = "#@ctvendor end"
  WithPrefix = "#@| "       # commented "replacement" lines in canonical
  WithPrefixTrim = "#@|"    # a "#@|" line with no trailing content/space

type SyncError = object of CatchableError

proc tokenAfterIndent(line: string): string =
  ## The non-whitespace remainder of `line` (used to recognise marker lines
  ## regardless of their indentation).
  line.strip(leading = true, trailing = false)

proc isMarker(line, marker: string): bool =
  tokenAfterIndent(line).startsWith(marker)

proc applyEngineTrim(body: string): string =
  ## Apply the marker-driven engine trim to the canonical body. Deterministic and
  ## idempotent: a body containing no markers is returned unchanged (modulo the
  ## literal substitutions).
  var outLines: seq[string]
  let lines = body.splitLines()
  var i = 0
  while i < lines.len:
    let line = lines[i]
    if isMarker(line, MarkerStrip):
      # Drop everything up to and including the matching `#@ctvendor end`.
      inc i
      while i < lines.len and not isMarker(lines[i], MarkerEnd):
        inc i
      if i >= lines.len:
        raise newException(SyncError, "unterminated " & MarkerStrip)
      inc i  # consume the `end` marker line
    elif isMarker(line, MarkerReplace):
      # Skip the real (canonical) block up to `#@ctvendor with`.
      inc i
      while i < lines.len and not isMarker(lines[i], MarkerWith):
        inc i
      if i >= lines.len:
        raise newException(SyncError, MarkerReplace & " without " & MarkerWith)
      inc i  # consume the `with` marker
      # Emit the `#@|`-prefixed replacement lines. The text the generator emits
      # is whatever follows the `#@|` token, with exactly ONE separator space
      # removed — so a canonical line `<indent>#@| <TARGET>` yields `<TARGET>`
      # verbatim (the target carries its OWN indentation; the marker line's own
      # leading indent is cosmetic in canonical and is discarded).
      while i < lines.len and not isMarker(lines[i], MarkerEnd):
        let raw = lines[i]
        let t = raw.strip(leading = true, trailing = false)
        if t == WithPrefixTrim:
          outLines.add ""
        elif t.startsWith(WithPrefix):
          outLines.add t[WithPrefix.len .. ^1]
        else:
          raise newException(SyncError,
            "replacement line missing '" & WithPrefixTrim & "' prefix: " & raw)
        inc i
      if i >= lines.len:
        raise newException(SyncError, "unterminated " & MarkerReplace)
      inc i  # consume the `end` marker
    else:
      outLines.add line
      inc i
  result = outLines.join("\n")
  for (a, b) in EngineSubs:
    result = result.replace(a, b)

proc bannerFor(module: string; canonicalPath: string): string =
  ## The provenance banner block for `module`, with `{{PROVENANCE}}` bound to the
  ## canonical module path. Returns the banner WITHOUT a trailing newline; the
  ## caller joins it to the body with a single "\n".
  let tplName =
    if module == "backends": "backends.txt"
    elif module == "engine": "engine.txt"
    else: "standard.txt"
  let tpl = readFile(BannersDir / tplName)
  # The banner files are stored with a trailing newline; drop it so we control
  # the join precisely.
  var banner = tpl
  if banner.endsWith("\n"): banner = banner[0 ..< ^1]
  banner.replace("{{PROVENANCE}}", canonicalPath)

proc renderModule(module: string): string =
  ## The full generated text for `module`: banner + transformed canonical body.
  let canonicalPath = CanonicalSrcDir / (module & ".nim")
  if not fileExists(canonicalPath):
    raise newException(SyncError, "canonical module missing: " & canonicalPath)
  let body = readFile(canonicalPath)
  let transformed =
    if module == "engine": applyEngineTrim(body)
    else: body
  bannerFor(module, canonicalPath) & "\n" & transformed

proc allModules(): seq[string] =
  @["backends", "engine"] & StandardModules.toSeq

proc main() =
  var checkOnly = false
  var checkout = getEnv("CODETRACER_CHECKOUT", DefaultCodetracerCheckout)
  for arg in commandLineParams():
    if arg == "--check": checkOnly = true
    elif arg.startsWith("--"):
      stderr.writeLine "unknown flag: " & arg
      quit(2)
    else:
      checkout = arg

  let vendorDir = checkout / VendorRelDir
  if not dirExists(vendorDir):
    stderr.writeLine "ERROR: codetracer vendored dir not found: " & vendorDir
    stderr.writeLine "       pass the codetracer checkout path as an argument or " &
      "set $CODETRACER_CHECKOUT."
    quit(3)

  var drifted: seq[string]
  for module in allModules():
    let generated = renderModule(module)
    let dest = vendorDir / (module & ".nim")
    let current = if fileExists(dest): readFile(dest) else: ""
    if checkOnly:
      if current != generated:
        drifted.add module & ".nim"
    else:
      if current != generated:
        writeFile(dest, generated)
        echo "regenerated: " & dest
      else:
        echo "unchanged:   " & dest

  if checkOnly:
    if drifted.len > 0:
      stderr.writeLine "DRIFT: the following codetracer vendored files differ " &
        "from sync(canonical):"
      for d in drifted: stderr.writeLine "  - " & d
      stderr.writeLine "Run tools/sync_ct_test_vendor.sh to regenerate."
      quit(1)
    echo "in sync: all " & $allModules().len & " vendored modules match sync(canonical)"

when isMainModule:
  main()
