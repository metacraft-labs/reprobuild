## The vendor-fetch action a from-source Rust recipe gets.
##
## One action materialises the whole dependency closure. The assertions
## below are about the properties that decide whether a build is genuinely
## offline and genuinely reproducible, each of which has a way of being
## quietly wrong:
##
## * every crate is verified on every run, not only when it was downloaded —
##   a cache entry corrupted in place is exactly what the check is for;
## * the vendor tree is rebuilt rather than updated, so a crate left by a
##   previous closure cannot satisfy a build the manifest no longer names;
## * both crates.io spellings are redirected, because leaving one live makes
##   an offline build into an offline build with an intermittent failure;
## * the manifest is an INPUT, so changing a pinned dependency re-runs the
##   step;
## * a missing manifest is refused at emission time, naming the file,
##   instead of producing an action that fails later inside cargo.

import std/[os, strutils, tempfiles, unittest]

import repro_core/cargo_lock
import repro_project_dsl
import repro_project_dsl/cargo_vendor

const SampleManifest = """# repro cargo vendor manifest v1
https://static.crates.io/crates/ansi_term/ansi_term-0.12.1.crate	d52a9bb7ec0cf484c551830a7ce27bd20d67eac647e1befb56b0be4ee39a55d2	ansi_term-0.12.1
https://static.crates.io/crates/camino/camino-1.1.9.crate	8b96ec4966b5813e2c0507c1f86115c8c5abaadc3980879c3424042a02fd1ad3	camino-1.1.9
"""

proc withRecipeRoot(manifest: string): string =
  ## A throwaway recipe root carrying `manifest` as its committed closure.
  result = createTempDir("repro-cargo-vendor-", "")
  if manifest.len > 0:
    writeFile(result / CargoVendorManifestName, manifest)

suite "cargo vendor action":
  test "a committed manifest is read back as the closure":
    let root = withRecipeRoot(SampleManifest)
    defer:
      try: removeDir(root) except CatchableError: discard
    let plan = readVendorManifest(root)
    check plan.len == 2
    check plan[0].name == "ansi_term"
    check plan[1].directoryName == "camino-1.1.9"

  test "a missing manifest is refused at emission time, by name":
    # The alternative is an action that runs, finds nothing to vendor, and
    # hands cargo an empty directory — which fails much later with a
    # message about a missing crate rather than about a missing pin.
    let root = withRecipeRoot("")
    defer:
      try: removeDir(root) except CatchableError: discard
    var message = ""
    try:
      discard readVendorManifest(root)
    except CargoLockError as err:
      message = err.msg
    check message.contains(CargoVendorManifestName)
    check message.contains("pinned")

  test "the emitted action is one action for the whole closure":
    # Not one per crate: a five-hundred-crate closure would otherwise be
    # five hundred graph nodes whose only purpose is to land files in one
    # directory.
    let root = withRecipeRoot(SampleManifest)
    defer:
      try: removeDir(root) except CatchableError: discard
    let plan = readVendorManifest(root)
    let act = emitCargoVendorAction(root, "justSource", plan,
      "ccpp-fetch-justSource", root / ".repro/fetch/abc.stamp")
    check act.id == "cargo-vendor-justSource"
    check act.pool == "fetch"
    # Non-cacheable for the reason the source fetch is: it reaches the
    # network and has no monitorable file-dependency evidence.
    check (not act.cacheable)
    check act.outputs == @[cargoVendorStampPath(root)]

  test "the action depends on the source fetch and on the manifest":
    let root = withRecipeRoot(SampleManifest)
    defer:
      try: removeDir(root) except CatchableError: discard
    let plan = readVendorManifest(root)
    let fetchStamp = root / ".repro/fetch/abc.stamp"
    let act = emitCargoVendorAction(root, "justSource", plan,
      "ccpp-fetch-justSource", fetchStamp)
    # The fetch, because `.cargo/config.toml` is written into the extracted
    # source tree, which does not exist until the source is unpacked.
    check act.deps == @["ccpp-fetch-justSource"]
    # The manifest, because a changed pin has to re-run the step. Without
    # this the closure could move and the vendored tree would not.
    check cargoVendorManifestPath(root) in act.inputs
    check fetchStamp in act.inputs

  test "shell resolution is deferred to the declared tool identity":
    let root = withRecipeRoot(SampleManifest)
    defer: removeDir(root)
    let plan = readVendorManifest(root)
    let withHostPath = emitCargoVendorAction(root, "justSource", plan, "", "")
    let hadPath = existsEnv("PATH")
    let originalPath = getEnv("PATH")
    defer:
      if hadPath: putEnv("PATH", originalPath)
      else: delEnv("PATH")
    putEnv("PATH", "")
    let withoutHostPath = emitCargoVendorAction(root, "justSource", plan, "", "")
    check "sh" in withoutHostPath.toolIdentityRefs
    check withoutHostPath.call.arguments == withHostPath.call.arguments

  proc scriptOf(act: BuildActionDef): string =
    ## The shell body out of the action's encoded argv.
    ##
    ## ``inlineExecCall`` stores argv as one ``cliArgSeq`` positional whose
    ## encoded value carries the elements, so the script is found by looking
    ## for the loop rather than by indexing a plain seq.
    for argument in act.call.arguments:
      if argument.encodedValue.contains("while IFS="):
        return argument.encodedValue
    ""

  test "every crate is verified on every run":
    let root = withRecipeRoot(SampleManifest)
    defer:
      try: removeDir(root) except CatchableError: discard
    let plan = readVendorManifest(root)
    let script = scriptOf(emitCargoVendorAction(root, "justSource", plan,
      "", ""))
    check script.len > 0
    # `sha256sum -c -` sits after the download-if-missing branch closes,
    # so a cached crate is checked too.
    let downloadEnd = script.find("fi; ")
    let verify = script.find("sha256sum -c -")
    check verify > downloadEnd
    check downloadEnd > 0

  test "the vendor tree is rebuilt, not updated":
    # A crate directory left by a previous closure would still satisfy
    # cargo, and the build would succeed against a dependency the manifest
    # no longer names.
    let root = withRecipeRoot(SampleManifest)
    defer:
      try: removeDir(root) except CatchableError: discard
    let plan = readVendorManifest(root)
    let script = scriptOf(emitCargoVendorAction(root, "justSource", plan,
      "", ""))
    check script.contains("rm -rf \"" &
      cargoVendorDir(root).replace('\\', '/') & "\"")

  test "the download cache survives a rebuild of the tree":
    # Wiping the unpacked tree must not mean re-downloading a closure the
    # machine already has; the two live in separate directories.
    let root = withRecipeRoot(SampleManifest)
    defer:
      try: removeDir(root) except CatchableError: discard
    check not cargoVendorCacheDir(root).startsWith(cargoVendorDir(root))
    let plan = readVendorManifest(root)
    let script = scriptOf(emitCargoVendorAction(root, "justSource", plan,
      "", ""))
    check not script.contains("rm -rf \"" &
      cargoVendorCacheDir(root).replace('\\', '/') & "\"")

  test "the emitted cargo config redirects crates-io":
    let root = withRecipeRoot(SampleManifest)
    defer:
      try: removeDir(root) except CatchableError: discard
    let plan = readVendorManifest(root)
    let script = scriptOf(emitCargoVendorAction(root, "justSource", plan,
      "", ""))
    check script.contains("[source.crates-io]")
    check script.contains("vendored-sources")
    # And NOT a second table keyed by the sparse-index URL: cargo refuses
    # a URL-keyed source table with no location of its own, so writing one
    # makes every build fail before it starts.
    check not script.contains("sparse+https://index.crates.io/")
    # Written beside the extracted source, because cargo searches upward
    # from the manifest directory it is building and the recipe root is
    # not on that path.
    check script.contains(cargoConfigDir(root).replace('\\', '/'))

  test "the loop reads the manifest from disk rather than carrying it":
    # The script has to stay a few hundred bytes whatever the closure's
    # size — a five-hundred-crate closure embedded in an argv exceeds what
    # CreateProcess accepts.
    let root = withRecipeRoot(SampleManifest)
    defer:
      try: removeDir(root) except CatchableError: discard
    let plan = readVendorManifest(root)
    let script = scriptOf(emitCargoVendorAction(root, "justSource", plan,
      "", ""))
    check not script.contains("ansi_term-0.12.1")
    check script.contains("done < \"" &
      cargoVendorManifestPath(root).replace('\\', '/') & "\"")
