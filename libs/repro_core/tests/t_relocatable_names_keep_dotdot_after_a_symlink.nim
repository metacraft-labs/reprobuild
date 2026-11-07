## Unit tests for ``repro_core/relocation`` — a recipe-relative name never
## folds a ``..`` that follows a symlink lexically.
##
## The contract:
##
## * ``reprobuild-specs/Monitor-Hook-Shim.md`` §"Metadata, Probe, And
##   Symlink APIs": "``..`` after a link applies to where the link points,
##   not to the text before it", and "Never pop a symlink component
##   lexically". With ``link -> sub/target`` and cwd ``<root>``, the shims
##   record ``open("link/../file")`` as ``<root>/link/../file``; the kernel
##   opened ``<root>/sub/file``.
## * ``reprobuild-specs/Hermetic-Builds-And-Path-Independence.md``
##   §"Engine-internal recipe compiles": a relative recorded name resolves
##   against the CONSULTING action's working directory.
##
## So ``relocatableName`` must not turn ``<root>/link/../file`` into
## ``file`` (which ``rebasedName`` / ``recordedInputLocation`` would resolve
## to the decoy ``<root>/file``), and resolving a relative name must fold its
## ``..`` against the consulting tree, keeping one that follows a symlink
## there. Every case runs against a real temporary directory with a real
## symlink — no mocks — because the rule is about what ``lstat`` says.

import std/[os, tempfiles, unittest]

import repro_core/relocation
import repro_local_store

proc tree(): string =
  ## ``<root>/sub/target/``, ``<root>/sub/file``, ``<root>/real/``,
  ## ``<root>/link -> sub/target`` and the decoy ``<root>/file``, which a
  ## lexical fold of ``link/../file`` names instead of ``sub/file``.
  result = createTempDir("repro-relocation-dotdot", "")
  createDir(result / "sub" / "target")
  createDir(result / "real")
  writeFile(result / "sub" / "file", "read through the link")
  writeFile(result / "file", "decoy")
  createSymlink("sub/target", result / "link")

suite "relocatable names keep a .. that follows a symlink":

  test "foldedPath folds after a real directory, not after a symlink":
    let root = tree()
    defer: removeDir(root)
    check foldedPath(root & "/real/../file") == (root & "/file", true)
    check foldedPath(root & "/link/../file") ==
      (root & "/link/../file", false)
    # An absent component cannot be examined either.
    check foldedPath(root & "/gone/../file") ==
      (root & "/gone/../file", false)
    # A file is not a directory to pop.
    check foldedPath(root & "/file/../file") ==
      (root & "/file/../file", false)

  test "a .. at the root stays at the root":
    check foldedPath("/../etc/./hosts") == ("/etc/hosts", true)
    check foldedPath("/..") == ("/", true)

  test "a path without .. is folded lexically and unchanged otherwise":
    # These do not exist: the fast path must not consult the filesystem.
    check foldedPath("/no/such//dir/./x/") == ("/no/such/dir/x", true)
    check foldedPath("rel/./x") == ("rel/x", true)
    check relocatableName("/no/such/base/a/b.nim", "/no/such/base", []) ==
      "a/b.nim"

  test "relocatableName keeps an input reached through link/.. absolute":
    let root = tree()
    defer: removeDir(root)
    let observed = root & "/link/../file"
    let name = relocatableName(observed, root, [])
    checkpoint("relocatableName -> " & name)
    check name == observed
    # Resolved for a lookup, it still names what the kernel opened.
    check readFile(rebasedName(name, root)) == "read through the link"
    check readFile(recordedInputLocation(root, name)) ==
      "read through the link"

  test "a .. after a real directory still relocates":
    let root = tree()
    defer: removeDir(root)
    check relocatableName(root & "/real/../file", root, []) == "file"
    check relocatableName(root & "/real/../sub/file", root / "real", []) ==
      "../sub/file"

  test "a relative name's .. is folded against the consulting tree":
    let root = tree()
    defer: removeDir(root)
    # `link/../file` in the consulting copy: kept, for the kernel to
    # resolve through the link, not folded onto the decoy.
    let viaLink = rebasedName("link/../file", root)
    check viaLink == root & "/link/../file"
    check readFile(viaLink) == "read through the link"
    check recordedInputLocation(root, "link/../file") == viaLink
    # `../x` from a real cwd folds, as it always did.
    check rebasedName("../file", root / "real") == root / "file"
    check recordedInputLocation(root / "real", "../sub/file") ==
      root / "sub" / "file"
    # A cwd that IS the link: its `..` is the target's parent, `sub`.
    let fromLink = rebasedName("../file", root / "link")
    check fromLink == root & "/link/../file"
    check readFile(fromLink) == "read through the link"

  test "a name that climbs out of a symlinked base stays absolute":
    let root = tree()
    defer: removeDir(root)
    # The base IS the link. `relativePath` would name `<root>/file` as
    # `../file`, but `rebasedName` resolves that `..` where the link points
    # (`<root>/sub`), so the name would revalidate `sub/file`, not the file
    # observed. Kept absolute instead, it still names the observed file.
    let observed = root / "file"
    let name = relocatableName(observed, root / "link", [])
    checkpoint("relocatableName -> " & name)
    check name == observed
    check readFile(rebasedName(name, root / "link")) == "decoy"
    # Climbing out of a real directory still relocates, and round-trips.
    let fromReal = relocatableName(observed, root / "real", [])
    check fromReal == "../file"
    check readFile(rebasedName(fromReal, root / "real")) == "decoy"

  when not defined(windows):
    test "a backslash is not a separator on POSIX":
      # `a\..\b` is one file name here, not `a`, `..`, `b`: folding it would
      # name a different file from the one the kernel opens.
      let root = tree()
      defer: removeDir(root)
      check foldedPath(root & "/real\\..\\file").path != root & "/file"
      check rebasedName("real\\..\\file", root) != root / "file"

  test "names without .. resolve exactly as before":
    check rebasedName("a/./b.nim", "/no/such/base") == "/no/such/base/a/b.nim"
    check recordedInputLocation("/no/such/base", "a/b.nim") ==
      "/no/such/base/a/b.nim"
    check rebasedName("/abs/x", "/no/such/base") == "/abs/x"
