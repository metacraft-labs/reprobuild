## The Hackage-closure vendor action -- the Haskell sibling of
## `cargo_vendor` and `npm_vendor`.
##
## A from-source Haskell recipe commits `hackage-vendor.manifest` beside
## itself (format and rationale in `repro_core/hackage_closure`). This action
## turns it into a `file+noindex` package repository and the private cabal
## configuration that names it, so the build runs `cabal build` against
## exactly the pinned closure:
##
##   1. every file is downloaded into a cache keyed by its file name (a
##      package id plus `.tar.gz` or `.cabal`, unique by construction),
##      skipping one already there;
##   2. verified against the manifest's SHA-256 on every run, so a cache
##      entry corrupted in place is caught;
##   3. copied into a freshly emptied repository directory -- rebuilt from
##      scratch, because a file left by a previous closure would still be
##      visible to cabal's solver;
##   4. the private `CABAL_DIR/config` is written, naming that repository and
##      no other. With no Hackage repository configured there is no index
##      to resolve against and nothing to download from, which is what keeps
##      the build offline (cabal's own `--offline` refuses to unpack from a
##      `file+noindex` repository, so it cannot be used for this).
##
## Like the other vendor steps it is one action over the whole manifest (the
## script loops over the file rather than carrying it, so it stays small
## whatever the closure's size), it is non-cacheable because it reaches the
## network, and its stamp is what orders the build after it.
##
## Shared by the `from-source-cabal` convention and the `cabal_package`
## constructor, which sit in libraries that cannot see each other; both emit
## it under the same action id so the engine coalesces them.

import std/[os, strutils]

import repro_core/hackage_closure
import repro_core/paths
import repro_project_dsl
import repro_project_dsl/shell_fetch

export hackage_closure

proc hackageVendorActionId*(packageName: string): string =
  var sanitized = ""
  for ch in packageName:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      sanitized.add(ch)
    else:
      sanitized.add('_')
  if sanitized.len == 0:
    sanitized = "x"
  "hackage-vendor-" & sanitized

proc readHackageVendorManifest*(projectRoot: string): seq[HackageVendorEntry] =
  ## Read and validate the committed manifest, refusing by name when it is
  ## absent: a from-source Haskell recipe without a pinned closure is one
  ## that builds only where a warm cabal store happens to exist.
  let path = hackageVendorManifestPath(projectRoot)
  if not fileExists(extendedPath(path)):
    raise newException(HackageClosureError,
      "from-source-cabal: no " & HackageVendorManifestName & " beside the " &
      "recipe at " & projectRoot & ". The Hackage dependency closure has " &
      "to be pinned before the package can build offline; generate it " &
      "from a cabal plan.json (reprobuild-packages " &
      "tools/hackage_closure_manifest.nim).")
  let text =
    try:
      readFile(extendedPath(path))
    except CatchableError as err:
      raise newException(HackageClosureError,
        "from-source-cabal: cannot read " & path & ": " & err.msg)
  parseHackageVendorManifest(text)

proc emitHackageVendorAction*(projectRoot, packageName: string;
                              plan: openArray[HackageVendorEntry];
                              fetchActionId, fetchStamp: string):
                                BuildActionDef =
  ## The single action that materialises the repository and the private
  ## cabal configuration.
  let repoDir = hackageVendorRepoDir(projectRoot)
  let cacheDir = hackageVendorCacheDir(projectRoot)
  let cabalDir = hackageCabalDir(projectRoot)
  let stamp = hackageVendorStampPath(projectRoot)
  let manifest = hackageVendorManifestPath(projectRoot)
  createDir(extendedPath(hackageVendorRoot(projectRoot)))
  discard plan.len

  proc q(value: string): string =
    value.replace("\\", "/").replace("\"", "\\\"")

  var script = "set -e; "
  script.add("mkdir -p \"" & q(cacheDir) & "\"; ")
  script.add("rm -rf \"" & q(repoDir) & "\"; ")
  script.add("mkdir -p \"" & q(repoDir) & "\" \"" & q(cabalDir) & "\"; ")
  # One whitespace-separated triple per line; the header and comments start
  # with `#`.
  script.add("while read -r repro_name repro_sha repro_url; do ")
  script.add("case \"$repro_name\" in ''|'#'*) continue;; esac; ")
  script.add("repro_cached=\"" & q(cacheDir) & "/$repro_name\"; ")
  script.add("if [ ! -f \"$repro_cached\" ]; then ")
  script.add("curl -fsSL " & CurlFetchRetryArgs &
    " -o \"$repro_cached.part\" \"$repro_url\"; ")
  script.add("mv -f \"$repro_cached.part\" \"$repro_cached\"; fi; ")
  script.add("printf '%s  %s\\n' \"$repro_sha\" \"$repro_cached\" | " &
    "sha256sum -c - > /dev/null; ")
  script.add("cp -f \"$repro_cached\" \"" & q(repoDir) & "/$repro_name\"; ")
  script.add("done < \"" & q(manifest) & "\"; ")
  var configText = ""
  for line in hackageCabalConfig(repoDir).splitLines():
    if line.len > 0:
      configText.add(line.replace("'", "'\\''") & "\\n")
  script.add("printf '%b' '" & configText & "' > \"" & q(cabalDir) &
    "/config\"; ")
  script.appendVerifiedFetchStamp(stamp)

  var inputs: seq[string] = @[manifest]
  if fetchStamp.len > 0:
    inputs.insert(fetchStamp, 0)
  buildAction(
    id = hackageVendorActionId(packageName),
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    deps = if fetchActionId.len > 0: @[fetchActionId] else: @[],
    inputs = inputs,
    outputs = @[stamp],
    pool = "fetch",
    cacheable = false,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "hackage-vendor.repository",
    env = shellFetchRuntimeEnv(),
    toolIdentityRefs = @["sh", "rm", "mkdir", "curl", "mv", "sha256sum",
      "printf", "cp"])
