## DSL-port M9.K — source fetch action emitter shared across the four
## ``c-cpp-*`` Tier 2b conventions (meson / cmake / autotools / make).
##
## When a recipe declares a ``fetch:`` block (M9.H), the convention's
## ``emitFragment`` looks up the registered spec via
## ``registeredFetchSpec(packageName)``. When the lookup returns a
## non-default row, the convention prepends a fetch action to its
## emitted action list. Every downstream configure / compile / link
## action gains a transitive dep on the fetch action so a cache hit on
## the fetched source still satisfies the build.
##
## ## Action shape
##
## The fetch action is implemented as a shell script that:
##
##   1. Downloads ``<spec.url>`` to ``<projectRoot>/.repro/fetch/<hash>.tar``
##      (or ``.git`` for ``dfkGitArchive``).
##   2. Verifies the downloaded payload's sha256 / blake3 hash against
##      ``<spec.hashHex>``. Mismatch hard-fails the action.
##   3. Extracts the tarball to
##      ``<projectRoot>/<extractedRoot or "src">/`` with
##      ``--strip-components=<spec.extractStrip>``.
##   4. Touches ``<projectRoot>/.repro/fetch/<hash>.stamp`` as the
##      action's declared output (so cache hits short-circuit the
##      network I/O on the second run).
##
## On POSIX hosts the script uses ``curl`` + ``sha256sum`` (or
## ``b2sum`` for blake3) + ``tar``; on Windows the same tools are
## assumed to be on PATH via the dev shell's MSYS2 / system tar +
## CertUtil fallback for hashing. The action falls back to a ``sh -c``
## wrapper when ``sh`` resolves; otherwise it emits a direct ``cmd``
## fallback that is best-effort.
##
## ## Cache key
##
## The action's argv embeds the full spec (URL + hashAlg + hashHex +
## extractStrip + extractedRoot) so the engine's content-addressing
## fingerprints uniquely the fetch operation. A second invocation with
## identical spec hits the cache and skips both the download and the
## extraction.

import std/[os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl

const
  FetchScratchSubdir* = ".repro/fetch"
    ## Sub-directory under the project root that holds the downloaded
    ## tarballs + stamp files. Lives alongside ``.repro/build/``
    ## (each Tier 2b convention's scratch root) so a ``repro clean``
    ## wipes both consistently.

proc fetchScratchPath*(projectRoot: string): string =
  projectRoot / FetchScratchSubdir

proc fetchStampPath*(projectRoot, hashHex: string): string =
  fetchScratchPath(projectRoot) / (hashHex & ".stamp")

proc fetchTarballPath*(projectRoot, hashHex: string): string =
  fetchScratchPath(projectRoot) / (hashHex & ".tar")

proc fetchExtractedRoot*(projectRoot: string; spec: DslFetchSpec): string =
  ## Resolve the on-disk path to the extracted source tree. Defaults to
  ## ``<projectRoot>/src`` when the spec omits ``extractedRoot``.
  let rel =
    if spec.extractedRoot.len > 0: spec.extractedRoot
    else: "src"
  projectRoot / rel

proc fetchActionId*(packageName: string): string =
  ## Stable per-package fetch action id. Each c-cpp convention uses the
  ## same id so cross-convention test scaffolding can predict the dep
  ## name. The packageName is sanitised so non-ident chars don't break
  ## action-id collisions.
  var sanitized = ""
  for ch in packageName:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      sanitized.add(ch)
    else:
      sanitized.add('_')
  if sanitized.len == 0:
    sanitized = "x"
  "ccpp-fetch-" & sanitized

proc emitFetchAction*(projectRoot, packageName: string;
                     spec: DslFetchSpec): BuildActionDef =
  ## Build the fetch action for ``spec``. Caller is responsible for
  ## checking that ``spec.url`` (or ``spec.url`` + ``spec.gitRevision``
  ## for git kind) is non-empty — an empty-URL spec means "no fetch
  ## declared" and the action MUST NOT be emitted.
  let scratch = fetchScratchPath(projectRoot)
  createDir(extendedPath(scratch))
  let stamp = fetchStampPath(projectRoot, spec.hashHex)
  let extracted = fetchExtractedRoot(projectRoot, spec)
  createDir(extendedPath(parentDir(extracted)))
  let tarball = fetchTarballPath(projectRoot, spec.hashHex)
  let hashAlgTag = case spec.hashAlg
    of dshaSha256: "sha256"
    of dshaBlake3: "blake3"
  let kindTag = case spec.kind
    of dfkTarball: "tarball"
    of dfkGitArchive: "git"
  let shExe = findExe("sh")
  let escapedUrl = spec.url.replace("\"", "\\\"")
  let escapedHash = spec.hashHex.replace("\"", "\\\"")
  let escapedTarball =
    tarball.replace("\\", "/").replace("\"", "\\\"")
  let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
  let escapedExtracted =
    extracted.replace("\\", "/").replace("\"", "\\\"")
  let escapedRev = spec.gitRevision.replace("\"", "\\\"")
  var argv: seq[string]
  if shExe.len > 0:
    var script = "set -e; "
    script.add("mkdir -p \"")
    script.add(escapedExtracted)
    script.add("\"; ")
    case spec.kind
    of dfkTarball:
      # Download (curl) → hash-verify → extract → touch stamp. Local
      # ``file://`` URLs are handled by curl natively.
      script.add("if [ ! -f \"" & escapedTarball & "\" ]; then ")
      script.add("curl -fsSL -o \"" & escapedTarball & "\" \"" &
        escapedUrl & "\"; fi; ")
      case spec.hashAlg
      of dshaSha256:
        script.add("echo \"" & escapedHash & "  " & escapedTarball &
          "\" | sha256sum -c -; ")
      of dshaBlake3:
        # b2sum -a blake3 is GNU coreutils' shape; some hosts ship
        # ``blake3sum`` instead. Try the GNU spelling first.
        script.add("echo \"" & escapedHash & "  " & escapedTarball &
          "\" | b2sum -a blake3 -c - || ")
        script.add("echo \"" & escapedHash & "  " & escapedTarball &
          "\" | blake3sum -c -; ")
      script.add("tar -xf \"" & escapedTarball & "\" -C \"" &
        escapedExtracted & "\" --strip-components=" & $spec.extractStrip &
        "; ")
    of dfkGitArchive:
      # Shallow clone + archive. The git rev is verified by extracting
      # archive contents and then hashing the resulting tarball — the
      # archive's deterministic output makes the hash stable.
      script.add("rm -rf \"" & escapedTarball & ".git\"; ")
      script.add("git clone --depth 1 ")
      if escapedRev.len > 0:
        script.add("--branch \"" & escapedRev & "\" ")
      script.add("\"" & escapedUrl & "\" \"" & escapedTarball &
        ".git\"; ")
      script.add("(cd \"" & escapedTarball & ".git\" && git archive --format=tar HEAD > \"" &
        escapedTarball & "\"); ")
      case spec.hashAlg
      of dshaSha256:
        script.add("echo \"" & escapedHash & "  " & escapedTarball &
          "\" | sha256sum -c -; ")
      of dshaBlake3:
        script.add("echo \"" & escapedHash & "  " & escapedTarball &
          "\" | b2sum -a blake3 -c - || ")
        script.add("echo \"" & escapedHash & "  " & escapedTarball &
          "\" | blake3sum -c -; ")
      script.add("tar -xf \"" & escapedTarball & "\" -C \"" &
        escapedExtracted & "\" --strip-components=" & $spec.extractStrip &
        "; ")
    script.add("touch \"" & escapedStamp & "\"")
    argv = @[shExe, "-c", script]
  else:
    # No sh on PATH — emit a best-effort direct argv. Caller can detect
    # the missing sh and surface a clearer diagnostic at recognition
    # time; here we still produce a syntactically valid action so the
    # graph stays consistent.
    argv = @["repro-fetch",
      "--url", spec.url,
      "--hash-alg", hashAlgTag,
      "--hash", spec.hashHex,
      "--strip", $spec.extractStrip,
      "--dest", extracted,
      "--kind", kindTag,
      "--stamp", stamp]
    if spec.gitRevision.len > 0:
      argv.add("--rev")
      argv.add(spec.gitRevision)
  result = buildAction(
    id = fetchActionId(packageName),
    call = inlineExecCall(argv, projectRoot),
    inputs = @[],
    outputs = @[stamp],
    pool = "fetch",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ccpp-fetch." & kindTag & "." & hashAlgTag)
