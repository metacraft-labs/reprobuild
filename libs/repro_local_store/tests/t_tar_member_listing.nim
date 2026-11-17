## The member check a bundle import makes before it writes anything
## (`repro_local_store/tar_members`): parsing GNU tar's verbose listing and
## the rules every half applies to it. No mocks: the last suite lists real
## archives, written by GNU tar, through the production listing helper.
##
## Why it exists: the part hashes of a bundle come from the same unsigned
## manifest as the parts, so the importer's own check of the members is the
## only thing that confines extraction. That check reads the listing of the
## very GNU tar that extracts, so the parser must read every name exactly as
## tar will write it. See reprobuild-pm issues/2026-11-12-bundle-extraction-
## writes-every-tar-member-under-before-checking-it-against-the-declared.md.

import std/[os, osproc, sets, strutils, tempfiles, unittest]

import repro_local_store/tar_members
import repro_local_store/store_bundle
import repro_test_support/reasoned_skip

proc member(kind: char; name: string; target = ""): TarMember =
  TarMember(kind: kind, name: name, linkTarget: target)

suite "GNU tar listing lines":
  test "a regular file, a directory, a hard link and a symlink":
    let file = parseListingLine("-rw-r--r-- 1000/100          3 " &
      "2026-11-16 02:15:44.315325752 \"a/b/f\"")
    check file.kind == '-'
    check file.name == "a/b/f"
    check file.linkTarget == ""
    let dir = parseListingLine("drwxr-xr-x 1000/100          0 " &
      "2026-11-16 02:15:44.33432581 \"a/\"")
    check dir.kind == 'd'
    check dir.name == "a/"
    check memberPath(dir) == "a"
    let hard = parseListingLine("hrw-r--r-- 1000/100          0 " &
      "2026-11-16 02:15:44.315325752 \"a/b/hl\" link to \"a/b/f\"")
    check hard.kind == 'h'
    check hard.name == "a/b/hl"
    check hard.linkTarget == "a/b/f"
    let sym = parseListingLine("lrwxrwxrwx 1000/100          0 " &
      "2026-11-16 02:15:44.325325783 \"a/sym link\" -> \"../x y\"")
    check sym.kind == 'l'
    check sym.name == "a/sym link"
    check sym.linkTarget == "../x y"
    let fifo = parseListingLine("prw-r--r-- 1000/100          0 " &
      "2026-11-16 02:15:44.33432581 \"a/fifo\"")
    check fifo.kind == 'p'

  test "C escapes, including non-ASCII bytes as octal, are decoded":
    let m = parseListingLine("-rw-r--r-- 1000/100          1 " &
      "2026-11-16 02:15:44.325325783 " &
      "\"a/we\\\"ird\\nn\\\\x\\t\\a\\b\\f\\r\\v\\?\\303\\251\"")
    check m.name == "a/we\"ird\nn\\x\t\a\b\f\r\v?\xC3\xA9"

  test "text that only looks like a link inside a quoted name stays the name":
    let m = parseListingLine("-rw-r--r-- 0/0 1 2026-11-16 02:15:44.3 " &
      "\"x\\\" -> \\\"y\"")
    check m.kind == '-'
    check m.name == "x\" -> \"y"
    check m.linkTarget == ""

  test "malformed lines are refused":
    for line in [
        "",
        "-rw-r--r-- 0/0 1 2026-11-16 02:15:44.3 no-quote",
        "-rw-r--r-- 0/0 1 2026-11-16 02:15:44.3 \"unterminated",
        "-rw-r--r-- 0/0 1 2026-11-16 02:15:44.3 \"a\" trailing",
        "-rw-r--r-- 0/0 1 2026-11-16 02:15:44.3 \"bad\\zescape\"",
        "-rw-r--r-- 0/0 1 2026-11-16 02:15:44.3 \"big\\777\"",
        "-rw-r--r-- 0/0 1 2026-11-16 02:15:44.3 \"nul\\000\"",
        "hrw-r--r-- 0/0 0 2026-11-16 02:15:44.3 \"a\"",
        "hrw-r--r-- 0/0 0 2026-11-16 02:15:44.3 \"a\" -> \"b\"",
        "lrwxrwxrwx 0/0 0 2026-11-16 02:15:44.3 \"a\"",
        "lrwxrwxrwx 0/0 0 2026-11-16 02:15:44.3 \"a\" link to \"b\"",
        "lrwxrwxrwx 0/0 0 2026-11-16 02:15:44.3 \"a\" -> \"b\" x"]:
      expect ValueError:
        discard parseListingLine(line)

suite "member names":
  test "only canonical relative names are accepted":
    check relativeNameProblem("a") == ""
    check relativeNameProblem("a/b c/d") == ""
    for bad in ["", "/etc/passwd", "a//b", "./a", "a/.", "a/..", "../a",
                "a/./b", "a/../b", "a/"]:
      check relativeNameProblem(bad).len > 0

suite "the rules every half applies":
  test "only files, hard links, symlinks and directories are carried":
    for kind in ['p', 'c', 'b', 'C', 'V', 'M', 'N', 'S', '?']:
      var s = initMemberSet()
      let problem = s.admit(member(kind, "x"))
      check "x" in problem
    var s = initMemberSet()
    check s.admit(member('-', "f")) == ""
    check s.admit(member('d', "d/")) == ""
    check s.admit(member('l', "l", "/anywhere")) == ""
    check s.admit(member('h', "h", "f")) == ""
    check s.finish() == ""
    check s.len == 4
    check "d" in s
    check s.kindOf("h") == 'h'

  test "a name is carried once":
    var s = initMemberSet()
    check s.admit(member('d', "a/")) == ""
    let again = s.admit(member('d', "a/"))
    check "once" in again
    var t = initMemberSet()
    check t.admit(member('-', "a")) == ""
    check "once" in t.admit(member('d', "a/"))

  test "non-canonical names are refused, the directory slash aside":
    var s = initMemberSet()
    check s.admit(member('d', "a/")) == ""
    check s.admit(member('d', "b")) == ""
    for bad in ["/etc/hostname", "a/../../etc", "./x", "a//b", "a/"]:
      var t = initMemberSet()
      check bad in t.admit(member('-', bad))
    var u = initMemberSet()
    check u.admit(member('d', "c//")).len > 0

  test "nothing is carried below a symlink member, in either order":
    var before = initMemberSet()
    check before.admit(member('l', "a/link", "/etc")) == ""
    check before.admit(member('-', "a/link/passwd")) == ""
    check "a/link" in before.finish()
    var after = initMemberSet()
    check after.admit(member('-', "a/link/passwd")) == ""
    check after.admit(member('l', "a/link", "/etc")) == ""
    check "a/link" in after.finish()
    var sibling = initMemberSet()
    check sibling.admit(member('l', "a/link", "/etc")) == ""
    check sibling.admit(member('-', "a/linked")) == ""
    check sibling.finish() == ""

  test "a hard link names an earlier regular-file member":
    var s = initMemberSet()
    check "f" in s.admit(member('h', "h", "f"))
    var t = initMemberSet()
    check t.admit(member('l', "l", "x")) == ""
    check "l" in t.admit(member('h', "h", "l"))
    var u = initMemberSet()
    check "/etc/shadow" in u.admit(member('h', "h", "/etc/shadow"))
    var v = initMemberSet()
    check v.admit(member('-', "f")) == ""
    check "../f" in v.admit(member('h', "h", "../f"))
    var w = initMemberSet()
    check w.admit(member('-', "f")) == ""
    check w.admit(member('h', "h", "f")) == ""
    check "h" in w.admit(member('h', "h2", "h"))

suite "declared members (the native half)":
  test "a member's type and link target are those contents declares":
    let file = DeclaredMember(kind: dkFile)
    check declaredMemberProblem(member('-', "f"), file) == ""
    check declaredMemberProblem(member('h', "f", "g"), file) == ""
    check declaredMemberProblem(member('l', "f", "g"), file).len > 0
    check declaredMemberProblem(member('d', "f/"), file).len > 0
    let plain = DeclaredMember(kind: dkPlainFile)
    check declaredMemberProblem(member('-', "c"), plain) == ""
    check declaredMemberProblem(member('h', "c", "g"), plain).len > 0
    let dir = DeclaredMember(kind: dkDir)
    check declaredMemberProblem(member('d', "d/"), dir) == ""
    check declaredMemberProblem(member('l', "d", "x"), dir).len > 0
    check declaredMemberProblem(member('-', "d"), dir).len > 0
    let link = DeclaredMember(kind: dkLink, target: "../x")
    check declaredMemberProblem(member('l', "l", "../x"), link) == ""
    check declaredMemberProblem(member('l', "l", "/etc"), link).len > 0
    check declaredMemberProblem(member('-', "l"), link).len > 0

suite "Nix store paths (the Nix half)":
  test "a registered path is one store-name component under /nix/store":
    check nixStorePathProblem(
      "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-a+b_c.d?e=f-g") == ""
    for bad in ["/nix/store", "/nix/store/", "/nix/store/a/b", "/etc",
                "/nix/store/.x", "/nix/store/..", "/nix/store/a b",
                "/nix/store/a\nb", "nix/store/a", "/nix/store/a/",
                "/nix/store/caf\xC3\xA9", "/nix/store//a"]:
      check nixStorePathProblem(bad).len > 0

  test "members lie inside a registered path":
    let registered = toHashSet(["nix/store/abc-x", "nix/store/def-y"])
    check nixMemberProblem("nix/store/abc-x", registered) == ""
    check nixMemberProblem("nix/store/abc-x/lib/f", registered) == ""
    check nixMemberProblem("nix/store/def-y/bin", registered) == ""
    for bad in ["nix/store/abc-xy", "nix/store/abc", "nix", "nix/store",
                "etc/evil", "nix/store/other/f", "nix/var/nix/db/db.sqlite",
                "abc-x"]:
      check bad in nixMemberProblem(bad, registered)

proc run(cmd: string; cwd = "") =
  let (output, code) = execCmdEx(cmd, workingDir = cwd)
  doAssert code == 0, cmd & "\n" & output

suite "listing real archives with the production helper":
  test "every name GNU tar writes is read back exactly":
    if findExe("tar").len == 0 or findExe("zstd").len == 0:
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let top = createTempDir("repro-tar-members-", "")
      defer: removeDir(top)
      let tree = top / "tree"
      let names = ["plain", "sp ace", "quo\"te", "new\nline", "back\\slash",
        "tab\there", "caf\xC3\xA9", "x -> y", "x link to y", "q?mark"]
      createDir(tree / "d")
      for n in names:
        writeFile(tree / "d" / n, n)
      createSymlink("../d/sp ace", tree / "d" / "sym -> link")
      run("ln " & quoteShell(tree / "d" / "plain") & " " &
        quoteShell(tree / "d" / "hard \"link\""))
      let partsDir = top / "parts"
      let (parts, _) = writeCompressedParts("tar --format=posix -C " &
        quoteShell(tree) & " -cf - d | zstd -q -c -1 --long=27", partsDir,
        64)
      check parts.len > 1
      let listing = top / "listing"
      listBundleMembers(partsDir, parts, listing)
      var seen: seq[TarMember]
      for (lineNo, m) in listingMembers(listing):
        check lineNo == seen.len + 1
        seen.add(m)
      var byName: seq[string]
      for m in seen: byName.add(memberPath(m))
      check "d" in byName
      for n in names:
        check ("d/" & n) in byName
      var s = initMemberSet()
      for m in seen:
        check s.admit(m) == ""
        if m.kind == 'l':
          check m.name == "d/sym -> link"
          check m.linkTarget == "../d/sp ace"
        if m.kind == 'h':
          check m.name == "d/hard \"link\"" or m.name == "d/plain"
          check m.linkTarget == "d/plain" or m.linkTarget == "d/hard \"link\""
      check s.finish() == ""

  test "a stream tar cannot read is refused, not listed short":
    if findExe("tar").len == 0 or findExe("zstd").len == 0:
      skip("GNU tar and zstd are not on PATH; bundles are written with them")
    else:
      let top = createTempDir("repro-tar-members-", "")
      defer: removeDir(top)
      let partsDir = top / "parts"
      let (parts, _) = writeCompressedParts(
        "head -c 4096 /dev/urandom | zstd -q -c -1 --long=27", partsDir, 1024)
      expect StoreBundleError:
        listBundleMembers(partsDir, parts, top / "listing")
