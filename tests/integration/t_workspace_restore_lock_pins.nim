## Exercises the real CLI, local Git origins, strict TOML readers and atomic
## filesystem publication. No mocks: each origin has two real commits and the
## records pin the first while manifests and branches point at the second.
## Two projects overlap at lib-a and union in lib-b. Checks explicit record,
## commit-addressed record and snapshot restoration, historical metadata,
## detached exact pins, active membership, and source isolation. Negative
## cases cover incomplete records, remote mismatch, symbolic pins, unavailable
## commits, nonempty destinations and cleanup after failed materialization.
## Separate committed record stores exercise conventional discovery, explicit
## URL/revision selection and dirty-record isolation. Root-plus-child checkouts
## test collision and symlink confinement, with external sentinel preservation.
## A separate publication-boundary case deterministically supplies a directory
## populated after preflight and checks that neither side loses its contents.
import std/[os, osproc, strutils, tempfiles, unittest]
import repro_test_support
import repro_workspace_manifests
import repro_cli_support/workspace_restore

proc run(argv: openArray[string]; cwd = ""): tuple[output: string;
    exitCode: int] =
  execCmdEx(quoteShellCommand(@argv), workingDir = cwd)
proc must(argv: openArray[string]; cwd = ""): string =
  let response = run(argv, cwd)
  if response.exitCode != 0:
    raise newException(IOError, (@argv).join(" ") & "\n" & response.output)
  response.output.strip
proc git(path: string; args: varargs[string]): string =
  must(@["git", "-C", path] & @args)
proc init(path: string) =
  createDir(path)
  discard must(["git", "init", "-b", "dev", path])
  discard git(path, "config", "user.email", "restore@example.invalid")
  discard git(path, "config", "user.name", "Restore Test")
proc commit(path, message: string): string =
  discard git(path, "add", ".")
  discard git(path, "commit", "-m", message)
  git(path, "rev-parse", "HEAD")
proc entry(name, revision: string; remote = "local"): string =
  let remoteName = if name == "lib-a" and remote ==
      "local": "mirror" else: remote
  "\n[[repo]]\nname = \"" & name & "\"\npath = \"" & name &
    "\"\nremote = \"" & remoteName & "\"\nrevision = \"" & revision & "\"\n"
proc lock(a, b: string): string =
  "schema = \"reprobuild.workspace.lock.v1\"\n[lock]\nproject = \"one\"\ncreated_at = \"2026-10-18T00:00:00Z\"\n" &
    entry("lib-a", a) & entry("lib-b", b)

suite "workspace restore at recorded pins":
  test "restores a union independently of manifest and source HEADs":
    let scratch = createTempDir("repro-restore-test-", "")
    defer: removeDir(scratch)
    let binary = requireBinary(getEnv("REPRO_RESTORE_TEST_BINARY",
      currentSourcePath().parentDir.parentDir.parentDir / "build" / "bin" /
          "repro"),
      "reprobuild.apps.repro")
    let metadata = scratch / "metadata"
    init(metadata)
    createDir(metadata / "projects")
    createDir(metadata / "repos")
    createDir(metadata / "snapshots")
    var first, tips: seq[string]
    for name in ["lib-a", "lib-b"]:
      let origin = scratch / name
      init(origin)
      writeFile(origin / "content", "pinned\n")
      first.add(commit(origin, "pinned"))
      writeFile(origin / "content", "new manifest tip\n")
      tips.add(commit(origin, "tip"))
      writeFile(metadata / "repos" / (name & ".toml"),
        "schema = \"reprobuild.workspace.repo.v2\"\n[repo]\nname = \"" & name &
        "\"\npath = \"" & name & "\"\nremote = \"local\"\nmainline = \"dev\"\n")
      if name == "lib-a":
        let fragment = metadata / "repos" / (name & ".toml")
        writeFile(fragment, readFile(fragment).replace("remote = \"local\"",
          "remote = \"mirror\"\nremotes = [{ name = \"mirror\", remote = \"local\" }]"))
    for project in ["one", "two"]:
      let includes = if project == "one": "[\"repos/lib-a.toml\"]"
                     else: "[\"repos/lib-a.toml\", \"repos/lib-b.toml\"]"
      writeFile(metadata / "projects" / (project & ".toml"),
        "schema = \"reprobuild.workspace.project.v1\"\nincludes = " & includes &
        "\n[project]\nname = \"" & project &
            "\"\n" &
        "[[remote]]\nname = \"local\"\nfetch = \"file://" & scratch & "\"\n")
    let record = scratch / "record.toml"
    writeFile(record, lock(first[0], first[1]))
    let records = metadata / ".repro" / "records"
    init(records)
    writeFile(metadata / ".gitignore", ".repro/\n")
    let keyPath = records / lockRecordRelPath("one", "lib-a", first[0])
    createDir(keyPath.parentDir)
    writeFile(keyPath, readFile(record))
    let storeCommit = commit(records, "record store")
    writeFile(keyPath, "uncommitted record bytes must be ignored\n")
    let storeStatus = git(records, "status", "--porcelain")
    writeFile(metadata / "snapshots" / "release.toml",
      readFile(record).replace("workspace.lock.v1",
          "workspace.snapshot.v1").replace(
        "[lock]", "[snapshot]\nname = \"release\""))
    writeFile(metadata / "guide", "committed link target\n")
    createSymlink("guide", metadata / "internal-link")
    let metadataCommit = commit(metadata, "metadata and records")
    discard git(metadata, "branch", "selected", metadataCommit)
    # Later metadata deliberately cannot resolve the selection. --at must
    # actually load the old tree, rather than simply report the requested ref.
    writeFile(metadata / "projects" / "one.toml", "broken later metadata\n")
    let later = commit(metadata, "later metadata")
    writeFile(metadata / "uncommitted", "source work must survive\n")
    let sourceStatus = git(metadata, "status", "--porcelain")
    var successful: seq[string]
    for selector in ["--record=" & record,
        "--record=one/lib-a@" & first[0], "--snapshot=release"]:
      let destination = scratch / ("restored-" & $successful.len)
      let metadataRef = if successful.len == 1: "selected" else: metadataCommit
      let response = run([binary, "ws", "restore", metadata, destination,
        "--projects=one,two", "--at=" & metadataRef, selector])
      checkpoint(response.output)
      require response.exitCode == 0
      successful.add(destination)
      check readWorkspaceProjects(destination) == @["one", "two"]
      check git(destination / ".repro" / "manifests", "rev-parse", "HEAD") == metadataCommit
      for idx, name in ["lib-a", "lib-b"]:
        check git(destination / name, "rev-parse", "HEAD") == first[idx]
        check readFile(destination / name / "content") == "pinned\n"
        let remoteName = if name == "lib-a": "mirror" else: "origin"
        check git(destination / name, "remote", "get-url", remoteName) ==
            "file://" & scratch / name
        check run(["git", "-C", destination / name, "symbolic-ref", "-q",
            "HEAD"]).exitCode != 0
        check response.output.contains(name & " " & first[idx])
    # URL metadata source, an empty destination and a relative external path.
    let emptyDestination = scratch / "empty"
    createDir(emptyDestination)
    let urlResponse = run([binary, "workspace", "restore", "file://" & metadata,
      emptyDestination, "--projects=one,two", "--at=" & metadataCommit,
      "--record=record.toml"], scratch)
    checkpoint(urlResponse.output)
    require urlResponse.exitCode == 0
    check git(emptyDestination / "lib-b", "rev-parse", "HEAD") == first[1]
    check git(metadata, "rev-parse", "HEAD") == later
    check git(metadata, "status", "--porcelain") == sourceStatus
    check git(records, "status", "--porcelain") == storeStatus
    for idx, name in ["lib-a", "lib-b"]:
      check git(scratch / name, "rev-parse", "HEAD") == tips[idx]
    let badRecords = @[
      ("missing", "schema = \"reprobuild.workspace.lock.v1\"\n[lock]\nproject = \"one\"\ncreated_at = \"2026-10-18T00:00:00Z\"\n" &
          entry("lib-a", first[0]), "does not pin"),
      ("remote", lock(first[0], first[1]).replace("remote = \"local\"",
          "remote = \"wrong\""), "identity differs"),
      ("schema", lock(first[0], first[1]).replace("workspace.lock.v1",
          "workspace.lock.v2"), "schema"),
      ("duplicate", lock(first[0], first[1]) & entry("lib-a", first[0]),
          "duplicate"),
      ("symbolic", lock("dev", first[1]), "full commit"),
      ("unavailable", lock(repeat('a', 40), first[1]), "git"),
      ("unsafe", lock(first[0], first[1]).replace("path = \"lib-a\"",
          "path = \"../escape\""), "path")]
    for bad in badRecords:
      let badRecord = scratch / (bad[0] & ".toml")
      writeFile(badRecord, bad[1])
      let destination = scratch / ("refused-" & bad[0])
      createDir(destination)
      let response = run([binary, "ws", "restore", metadata, destination,
        "--projects=one,two", "--at=" & metadataCommit, "--record=" & badRecord])
      checkpoint(response.output)
      check response.exitCode != 0
      check bad[2] in response.output
      check dirExists(destination)
      var count = 0
      for unused in walkDir(destination): inc count
      check count == 0
    let occupied = scratch / "occupied"
    createDir(occupied)
    writeFile(occupied / "keep", "preserve")
    check run([binary, "ws", "restore", metadata, occupied,
      "--projects=one,two", "--at=" & metadataCommit, "--record=" &
      record]).exitCode != 0
    check readFile(occupied / "keep") == "preserve"
    for kind, path in walkDir(scratch):
      check not path.lastPathPart.startsWith(".repro-restore-")
    let nested = metadata / "nested-destination"
    let nestedResponse = run([binary, "ws", "restore", metadata, nested,
      "--projects=one,two", "--at=" & metadataCommit, "--record=" & record])
    check nestedResponse.exitCode != 0
    check not dirExists(nested)
    let noRevision = scratch / "no-metadata-revision"
    let noRevisionResponse = run([binary, "ws", "restore", "file://" & metadata,
      noRevision, "--projects=one,two", "--record=" & record])
    check noRevisionResponse.exitCode != 0
    check "requires --at" in noRevisionResponse.output
    check not dirExists(noRevision)
    # Metadata-specific preflight must reject unsupported/mutually destructive
    # declarations even when the record itself is a valid, complete lock.
    writeFile(metadata / "projects" / "one.toml",
      git(metadata, "show", metadataCommit & ":projects/one.toml") & "\n")
    let originalB = readFile(metadata / "repos" / "lib-b.toml")
    for bad in [("overlap", "lib-a/nested", "", "paths overlap"),
                ("metadata", ".repro/shadow", "",
                    "overlaps workspace metadata"),
                ("vcs", "lib-b", "hg", "does not support VCS")]:
      var fragment = originalB.replace("path = \"lib-b\"", "path = \"" & bad[
          1] & "\"")
      if bad[2].len > 0: fragment.add("vcs = \"" & bad[2] & "\"\n")
      writeFile(metadata / "repos" / "lib-b.toml", fragment)
      let variant = commit(metadata, "invalid restore declaration " & bad[0])
      let changedRecord = scratch / (bad[0] & "-record.toml")
      writeFile(changedRecord, lock(first[0], first[1]).replace(
        "path = \"lib-b\"", "path = \"" & bad[1] & "\""))
      let destination = scratch / ("refused-declaration-" & bad[0])
      let response = run([binary, "ws", "restore", metadata, destination,
        "--projects=one,two", "--at=" & variant, "--record=" & changedRecord])
      checkpoint(response.output)
      check response.exitCode != 0
      check bad[3] in response.output
      check not dirExists(destination)
    writeFile(metadata / "repos" / "lib-b.toml", originalB)
    for bad in [("header", lock(first[0], first[1]).replace("project = \"one\"", "project = \"other\""), "project differs"),
                ("trigger", lock(tips[0], first[1]),
                    "does not pin its trigger")]:
      writeFile(keyPath, bad[1])
      let storeVariant = commit(records, "invalid store key " & bad[0])
      let destination = scratch / ("refused-key-" & bad[0])
      let response = run([binary, "ws", "restore", metadata, destination,
        "--projects=one,two", "--at=" & metadataCommit, "--record-store-at=" &
        storeVariant,
        "--record=one/lib-a@" & first[0]])
      checkpoint(response.output)
      check response.exitCode != 0
      check bad[2] in response.output
      check not dirExists(destination)
    let rootOrigin = scratch / "root"
    init(rootOrigin)
    writeFile(rootOrigin / "root-file", "root pinned\n")
    let rootCommit = commit(rootOrigin, "root pinned")
    let originalA = readFile(metadata / "repos" / "lib-a.toml")
    writeFile(metadata / "repos" / "root.toml",
      "schema = \"reprobuild.workspace.repo.v2\"\n[repo]\nname = \"root\"\npath = \".\"\nremote = \"local\"\nmainline = \"dev\"\n")
    writeFile(metadata / "projects" / "root.toml",
      "schema = \"reprobuild.workspace.project.v1\"\nincludes = [\"repos/lib-a.toml\", \"repos/root.toml\"]\n" &
      "[project]\nname = \"root\"\n" &
      "[[remote]]\nname = \"local\"\nfetch = \"file://" & scratch & "\"\n")
    # Put the root member after its child in the manifest to prove execution
    # reorders checkouts safely while preserving membership.
    let rootMetadata = commit(metadata, "root and child selection")
    let rootRecord = scratch / "root-record.toml"
    proc rootLock(revision: string; childPath = "lib-a"): string =
      result = lock(first[0], first[1]).replace(entry("lib-b", first[1]),
        entry("root", revision).replace("path = \"root\"", "path = \".\""))
      result = result.replace("path = \"lib-a\"", "path = \"" & childPath & "\"")
    writeFile(rootRecord, rootLock(rootCommit))
    let rootDestination = scratch / "root-restored"
    let rootResponse = run([binary, "ws", "restore", metadata, rootDestination,
      "--projects=root", "--at=" & rootMetadata, "--record=" & rootRecord])
    checkpoint(rootResponse.output)
    require rootResponse.exitCode == 0
    check git(rootDestination, "rev-parse", "HEAD") == rootCommit
    check git(rootDestination / "lib-a", "rev-parse", "HEAD") == first[0]
    check git(rootDestination / ".repro" / "manifests", "rev-parse", "HEAD") == rootMetadata
    check readFile(rootDestination / "root-file") == "root pinned\n"
    writeFile(keyPath, rootLock(rootCommit))
    let rootStoreCommit = commit(records, "root pins")
    let rootKeyDestination = scratch / "root-key-restored"
    let rootKeyResponse = run([binary, "ws", "restore", metadata,
      rootKeyDestination,
      "--projects=root", "--at=" & rootMetadata, "--record=one/lib-a@" & first[0]])
    checkpoint(rootKeyResponse.output)
    require rootKeyResponse.exitCode == 0
    check git(rootKeyDestination, "rev-parse", "HEAD") == rootCommit
    check git(rootKeyDestination / ".repro" / "records", "rev-parse", "HEAD") == rootStoreCommit
    let outside = scratch / "outside"
    createDir(outside)
    writeFile(outside / "sentinel", "untouched\n")
    for bad in ["metadata", "content", "symlink", "projects"]:
      discard git(rootOrigin, "checkout", "--detach", rootCommit)
      discard git(rootOrigin, "clean", "-fdx")
      var childPath = "lib-a"
      var diagnostic = "overlaps root-tree content"
      if bad == "metadata":
        createDir(rootOrigin / ".repro")
        writeFile(rootOrigin / ".repro" / "tracked", "collision\n")
        diagnostic = "overlaps workspace metadata"
      elif bad == "content":
        createDir(rootOrigin / "lib-a")
        writeFile(rootOrigin / "lib-a" / "tracked", "collision\n")
      elif bad == "projects":
        createDir(rootOrigin / "projects")
        writeFile(rootOrigin / "projects" / "root.toml", "conflicting metadata\n")
        diagnostic = "shadows selected metadata"
      else:
        createSymlink(outside, rootOrigin / "nested")
        childPath = "nested/member"
        diagnostic = "symlink"
      let badRoot = commit(rootOrigin, "root collision " & bad)
      writeFile(metadata / "repos" / "lib-a.toml", originalA.replace(
        "path = \"lib-a\"", "path = \"" & childPath & "\""))
      # Force a distinct metadata commit even when this variant leaves A at its
      # original path, keeping the fixture's changes explicit.
      writeFile(metadata / "variant", bad & "\n")
      let variant = commit(metadata, "root collision metadata " & bad)
      writeFile(rootRecord, rootLock(badRoot, childPath))
      let destination = scratch / ("refused-root-" & bad)
      createDir(destination)
      let response = run([binary, "ws", "restore", metadata, destination,
        "--projects=root", "--at=" & variant, "--record=" & rootRecord])
      checkpoint(response.output)
      check response.exitCode != 0
      check diagnostic in response.output
      check dirExists(destination)
      var count = 0
      for unused in walkDir(destination): inc count
      check count == 0
      check readFile(outside / "sentinel") == "untouched\n"
      check not dirExists(outside / "member")
    for kind, path in walkDir(scratch):
      check not path.lastPathPart.startsWith(".repro-restore-")
    # A chosen metadata commit cannot delegate its inputs to mutable external
    # files through a committed symlink. Ordinary internal links were included
    # in the initial positive metadata fixture above.
    for kind in ["project", "fragment", "snapshot", "key"]:
      let relative = case kind
        of "project": "projects/one.toml"
        of "fragment": "repos/lib-a.toml"
        of "snapshot": "snapshots/release.toml"
        else: relativePath(keyPath, records)
      let original = if kind == "key": git(records, "show", storeCommit & ":" &
          relative) & "\n"
                     else: git(metadata, "show", metadataCommit & ":" &
                         relative) & "\n"
      let external = outside / (kind & ".toml")
      writeFile(external, original)
      let linked = (if kind == "key": records else: metadata) / relative
      removeFile(linked)
      createSymlink(external, linked)
      let variant = if kind == "key":
          discard commit(records, "external record link")
          git(metadata, "rev-parse", "HEAD")
        else: commit(metadata, "external metadata link " & kind)
      let destination = scratch / ("refused-metadata-link-" & kind)
      let selector = case kind
        of "snapshot": "--snapshot=release"
        of "key": "--record=one/lib-a@" & first[0]
        else: "--record=" & record
      let response = run([binary, "ws", "restore", metadata, destination,
        "--projects=one,two", "--at=" & variant, selector])
      checkpoint(response.output)
      check response.exitCode != 0
      check "metadata symlink" in response.output
      check not dirExists(destination)
      check readFile(external) == original
      removeFile(linked)
      writeFile(linked, original)
    let remoteStoreDestination = scratch / "url-key-restored"
    let remoteStoreResponse = run([binary, "ws", "restore", "file://" &
      metadata,
      remoteStoreDestination, "--projects=one,two", "--at=" & metadataCommit,
      "--record=one/lib-a@" & first[0], "--record-store=file://" & records,
      "--record-store-at=" & storeCommit])
    checkpoint(remoteStoreResponse.output)
    require remoteStoreResponse.exitCode == 0
    check git(remoteStoreDestination / "lib-b", "rev-parse", "HEAD") == first[1]
    check git(remoteStoreDestination / ".repro" / "records", "rev-parse",
        "HEAD") == storeCommit
    check storeCommit in remoteStoreResponse.output
    for storeSource in [records, "file://" & records]:
      let nestedDestination = records / "nested-destination"
      let response = run([binary, "ws", "restore", metadata, nestedDestination,
        "--projects=one,two", "--at=" & metadataCommit,
        "--record=one/lib-a@" & first[0], "--record-store=" & storeSource,
        "--record-store-at=" & storeCommit])
      checkpoint(response.output)
      check response.exitCode != 0
      check "outside its source" in response.output
      check not dirExists(nestedDestination)
    for extra in ["--record-store=" & records, "--record-store-at=" & storeCommit]:
      let response = run([binary, "ws", "restore", metadata, scratch /
        "invalid-store-option",
        "--projects=one,two", "--at=" & metadataCommit, "--record=" & record, extra])
      check response.exitCode != 0
      check "record-store options require" in response.output
    let noStoreRevision = run([binary, "ws", "restore", metadata, scratch /
      "no-store-revision",
      "--projects=one,two", "--at=" & metadataCommit,
      "--record=one/lib-a@" & first[0], "--record-store=file://" & records])
    check noStoreRevision.exitCode != 0
    check "requires --record-store-at" in noStoreRevision.output
    let metadataAsStore = run([binary, "ws", "restore", metadata, scratch /
      "metadata-is-not-store",
      "--projects=one,two", "--at=" & metadataCommit,
      "--record=one/lib-a@" & first[0], "--record-store=" & metadata,
      "--record-store-at=" & metadataCommit])
    check metadataAsStore.exitCode != 0
    check "separate record store" in metadataAsStore.output
    let externalRecords = scratch / "external-record-store"
    discard must(["git", "clone", "--no-local", records, externalRecords])
    let externalRecordStatus = git(externalRecords, "status", "--porcelain")
    for storeSource in [externalRecords, "file://" & externalRecords]:
      let destination = externalRecords / "nested-destination"
      let response = run([binary, "ws", "restore", metadata, destination,
        "--projects=one,two", "--at=" & metadataCommit,
        "--record=one/lib-a@" & first[0], "--record-store=" & storeSource,
        "--record-store-at=" & storeCommit])
      check response.exitCode != 0
      check "outside its source" in response.output
      check not dirExists(destination)
      check git(externalRecords, "status", "--porcelain") == externalRecordStatus
    let proxy = scratch / "proxy-workspace"
    createDir(proxy / ".repro")
    createSymlink(metadata, proxy / ".repro" / "manifests")
    let proxyDestination = metadata / "proxy-nested-destination"
    let proxyResponse = run([binary, "ws", "restore", proxy, proxyDestination,
      "--projects=one,two", "--at=" & metadataCommit, "--record=" & record])
    check proxyResponse.exitCode != 0
    check "outside its source" in proxyResponse.output
    check not dirExists(proxyDestination)

  test "publication preserves a destination populated after preflight":
    let scratch = createTempDir("repro-restore-publish-", "")
    defer: removeDir(scratch)
    let staging = scratch / "staging"
    let destination = scratch / "destination"
    createDir(staging)
    writeFile(staging / "verified", "staged workspace\n")
    createDir(destination)
    # The caller has already checked this directory as empty. Populate it at
    # the publication boundary, without timing, fake Git or production hooks.
    writeFile(destination / "arrived", "concurrent caller data\n")
    var refused = false
    try:
      publishRestoredWorkspace(staging, destination)
    except CatchableError:
      refused = true
    check refused
    check readFile(destination / "arrived") == "concurrent caller data\n"
    check readFile(staging / "verified") == "staged workspace\n"
    removeFile(destination / "arrived")
    publishRestoredWorkspace(staging, destination)
    check readFile(destination / "verified") == "staged workspace\n"
    check not dirExists(staging)
    let second = scratch / "second-stage"
    createDir(second)
    writeFile(second / "verified", "absent destination\n")
    publishRestoredWorkspace(second, scratch / "absent")
    check readFile(scratch / "absent" / "verified") == "absent destination\n"
