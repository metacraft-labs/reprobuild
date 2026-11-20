## A bundle's `contents` list confines what import may write: every entry,
## record directory and restamp must lie inside the declared roots and in the
## declared selection (docs/store-bundles.md §2.1, §5 step 2), and a
## `contents` list that names no producer is refused (§4.1). These are the
## checks import runs before it writes anything, so a crafted list must fail
## them, not the unpack.
##
## The checks are pure functions of the parsed list (`checkEntryPlacement`,
## `inSelection`, `parseContents`), so this test drives them directly with
## hand-written lists: an excluded checkout, a member re-included inside it,
## and paths that try to leave them (`..`, a relative path, a path beside a
## root that shares its prefix). The last case checks that the in-memory read
## of `contents` (`feedParts` with a capture) keeps exactly its limit, which
## import sets just above `MaxContentsBytes`, so a bundle whose first member
## is huge cannot exhaust memory before its SHA-256 is compared.
##
## No mocks: real functions over real values, and a real `/bin/sh` pipeline
## for the capture.

import std/[os, strutils, tempfiles, unittest]

import nimcrypto/sha2
import repro_local_store/store_bundle
import repro_test_support/reasoned_skip

const
  Ws = "/w"
  Store = "/s"
  Ac = "/c"

proc selected(): BundleSelection =
  BundleSelection(excluded: @["/w/gamma"], included: @["/w/gamma/sub"])

proc closureWith(entryPath: string; sel = selected()): BundleClosure =
  result.roots = BundleRoots(storeRoot: Store, actionCacheRoot: Ac,
    workspaceRoots: @[Ws])
  result.selection = sel
  result.producer = BundleProducer(version: "1.2.3", revision: "abc")
  if entryPath.len > 0:
    result.entries.add(BundleEntry(kind: bekFile, mode: 0o644, size: 1,
      mtimeNs: 1, digest: "00", path: entryPath))

proc refusal(c: BundleClosure): string =
  try:
    checkEntryPlacement(c, Store / "bundles" / "0" / "contents")
  except StoreBundleError as e:
    return e.msg
  ""

suite "a bundle's contents confine import to its roots and selection":
  test "a path is in the selection by its deepest root, exclude or include":
    let sel = selected()
    check "/w/alpha/out".inSelection([Ws], sel)
    check "/w".inSelection([Ws], sel)
    check not "/w/gamma".inSelection([Ws], sel)
    check not "/w/gamma/out".inSelection([Ws], sel)
    check "/w/gamma/sub".inSelection([Ws], sel)
    check "/w/gamma/sub/out".inSelection([Ws], sel)
    # A sibling sharing the excluded directory's prefix is not inside it.
    check "/w/gammaray/out".inSelection([Ws], sel)
    # Outside every workspace root nothing is in the selection.
    check not "/x/out".inSelection([Ws], sel)
    check not "/wx/out".inSelection([Ws], sel)
    # No selection: the whole root.
    check "/w/gamma/out".inSelection([Ws], BundleSelection())

  test "entries in the selection and in the store are accepted":
    check refusal(closureWith("/w/alpha/out")).len == 0
    check refusal(closureWith("/w/gamma/sub/out")).len == 0
    # Below the store and action-cache roots only what a closure carries
    # there is accepted; the action cache's blobs are one such area.
    check refusal(closureWith("/c/cas/ab/blob")).len == 0
    check refusal(closureWith("/s/compiler-probes/x")).len == 0
    # A recipe compile's outputs (a compiled provider) are record outputs a
    # bundle carries, so a restored machine need not recompile them.
    check refusal(closureWith("/c/recipe-compiles/provider/id/out/p")).len == 0

  test "below the store and action-cache roots the importer's own state is refused":
    for path in ["/s/index.db", "/s/tmp/x", "/c/action-cache/x",
                 "/c/gc/x"]:
      let msg = refusal(closureWith(path))
      checkpoint(path & ": " & msg)
      check "outside everything a bundle carries there" in msg

  test "an entry outside the roots or the selection is refused":
    for (path, needle) in [
        ("/w/gamma/out", "selection excludes"),
        ("/w/gamma", "selection excludes"),
        ("/w/alpha/../gamma/out", "outside its declared roots"),
        ("/w/../etc/passwd", "outside its declared roots"),
        ("w/alpha/out", "outside its declared roots"),
        ("/wx/out", "outside its declared roots"),
        ("/etc/passwd", "outside its declared roots")]:
      let msg = refusal(closureWith(path))
      checkpoint(path & ": " & msg)
      check needle in msg

  test "a record directory or a restamp in an excluded directory is refused":
    var c = closureWith("")
    c.records.add(BundleRecordRef(edgeDir: "/c/action-cache/e",
      strongHex: "00", outputRoot: "/w/gamma"))
    check "record directory" in refusal(c)
    c = closureWith("")
    c.restamps.add(RestampEntry(size: 1, mtimeNs: 1, digest: "00",
      path: "/w/gamma/src/in.txt"))
    check "restamp" in refusal(c)
    c = closureWith("")
    c.restamps.add(RestampEntry(size: 1, mtimeNs: 1, digest: "00",
      path: "/w/gamma/sub/src/in.txt"))
    check refusal(c).len == 0

  test "a selection directory outside the roots or not normalised is refused":
    for dirs in [@["/x/gamma"], @["/w/alpha/../gamma"], @["gamma"],
                 @["/wx"]]:
      let msg = refusal(closureWith("/w/alpha/out",
        BundleSelection(excluded: dirs)))
      checkpoint($dirs & ": " & msg)
      check "outside its workspace roots" in msg
    let msg = refusal(closureWith("/w/alpha/out",
      BundleSelection(included: @["/x/m"])))
    check "include directory outside" in msg

  test "a devenv line names only its project's frozen script, in the selection":
    # `repro bundle restore --activate` writes `. <script>` into
    # /etc/profile.d, and `repro store import --allow-dev-env` allow-lists the
    # project, so a `devenv` line must name what export writes (§6): a
    # project in the selection and that project's own frozen script, carried
    # as a file. Driven through `parseContents`, as import reads it.
    # (issues/2026-11-17-bundle-devenv-lines-name-any-script-and-any-project-to-activate-and-allow.md)
    proc devenvRefusal(project, script: string;
                       carried: seq[string]): string =
      var text = "reprobuild.store-bundle.contents.v2\n" &
        "producer\t1.2.3\tabc\n" &
        "root\tstore\t/s\nroot\taction-cache\t/c\nroot\tworkspace\t/w\n" &
        "exclude\t/w/gamma\n" &
        "devenv\t" & escapeField(project) & "\t" & escapeField(script) & "\n"
      for path in carried:
        text.add("entry\tf\t644\t1\t1\t00\t" & escapeField(path) & "\n")
      refusal(parseContents(text))
    proc withMode(script, dir: string; mode: int): string =
      let text = "reprobuild.store-bundle.contents.v2\n" &
        "producer\t1.2.3\tabc\n" &
        "root\tstore\t/s\nroot\taction-cache\t/c\nroot\tworkspace\t/w\n" &
        "devenv\t/w/alpha\t" & escapeField(script) & "\n" &
        "entry\td\t" & toOct(mode, 3) & "\t0\t1\t-\t" &
        escapeField(dir) & "\n" &
        "entry\tf\t644\t1\t1\t00\t" & escapeField(script) & "\n"
      refusal(parseContents(text))
    let script = frozenScriptPath(Store, "/w/alpha")
    check script.startsWith("/s/frozen-dev-env/")
    check script.endsWith("/activate.bash")
    # What export writes is accepted.
    check devenvRefusal("/w/alpha", script, @[script]).len == 0
    # A script anywhere else -- a world-writable file a login shell would
    # then source -- is refused, carried or not.
    check "must be" in devenvRefusal("/w/alpha", "/tmp/x.sh", @[])
    check "must be" in devenvRefusal("/w/alpha", "/w/alpha/x.sh",
      @["/w/alpha/x.sh"])
    # Another project's frozen script is not this project's.
    let other = frozenScriptPath(Store, "/w/beta")
    check "must be" in devenvRefusal("/w/alpha", other, @[other])
    # A world-writable directory above the script lets anyone replace it.
    # Every carried directory above it counts, up to the store root itself:
    # a world-writable <store> lets anyone rename frozen-dev-env aside.
    for dir in [script.parentDir, script.parentDir.parentDir, Store]:
      check withMode(script, dir, 0o755).len == 0
      check "world-writable" in withMode(script, dir, 0o777)
    # The right path, but not carried: nothing holds it to the bundle's bytes.
    check "without carrying" in devenvRefusal("/w/alpha", script, @[])
    # A project outside the roots or the selection is not allow-listed.
    for project in ["/etc", "/wx/p", "/w/gamma/p", "/w/alpha/../../etc"]:
      let s2 = frozenScriptPath(Store, project)
      check "not in its workspace roots" in devenvRefusal(project, s2, @[s2])

  test "contents round-trip the producer and the selection, and v1 is refused":
    let c = closureWith("/w/alpha/out")
    let parsed = parseContents(renderContents(c))
    check parsed.producer == c.producer
    check parsed.selection == c.selection
    check bundleIdOf(parsed) == bundleIdOf(c)
    # The selection is part of what the id is derived from.
    check bundleIdOf(closureWith("/w/alpha/out", BundleSelection())) !=
      bundleIdOf(c)
    var msg = ""
    try:
      discard parseContents(renderContents(c).replace(
        "reprobuild.store-bundle.contents.v2",
        "reprobuild.store-bundle.contents.v1"))
    except StoreBundleError as e:
      msg = e.msg
    check "unsupported contents version" in msg
    msg = ""
    var lines: seq[string]
    for line in renderContents(c).splitLines():
      if not line.startsWith("producer\t"): lines.add(line)
    try:
      discard parseContents(lines.join("\n"))
    except StoreBundleError as e:
      msg = e.msg
    check "names no producer" in msg

  test "the in-memory read of a member keeps at most its limit":
    if findExe("head").len == 0:
      skip("`head` is not on PATH; the capture runs it")
    else:
      let dir = createTempDir("repro-bundle-capture-", "")
      defer: removeDir(dir)
      let payload = "0123456789".repeat(1000)
      writeFile(dir / "part-0000", payload)
      let part = BundlePart(file: "part-0000", bytes: int64(payload.len),
        sha256: ($sha256.digest(payload)).toLowerAscii)
      # Ten times the payload reaches the command's stdout; only the limit
      # is kept, and the command still runs to its end.
      var text = ""
      let code = feedParts(dir, @[part],
        "cat >/dev/null; head -c 100000 /dev/zero", stopEarly = true,
        captured = addr text, captureLimit = 4096)
      check code == 0
      check text == '\0'.repeat(4096)
      var whole = ""
      discard feedParts(dir, @[part], "cat", stopEarly = true,
        captured = addr whole)
      check whole == payload
