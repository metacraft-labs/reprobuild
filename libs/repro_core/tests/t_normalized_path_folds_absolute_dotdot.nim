## Unit tests for ``repro_core/paths.normalizedPath`` — an absolute path's
## ``.`` and ``..`` segments are folded; a relative path's ``..`` is still
## refused.
##
## The contract (``normalizedPath``'s doc comment):
##
## * An absolute path — POSIX ``/...`` or a drive-rooted ``D:/...`` in
##   either separator spelling — has ``.`` and ``..`` folded, so a root
##   named as ``<checkout>/../<sibling>`` (an operator's
##   ``$REPROBUILD_REPO_ROOT``, say) is accepted as ``<sibling>``'s own
##   spelling instead of failing with "must not contain '..'".
## * A ``..`` that climbs above the root is refused.
## * On a POSIX host a ``..`` pops only an existing directory that is not a
##   symlink: the kernel resolves ``link/..`` against the link's target, so
##   a lexical fold would name a different directory
##   (Monitor-Hook-Shim.md §"Metadata, Probe, And Symlink APIs").
##   Windows folds lexically itself, so a drive-rooted path folds purely.
## * A relative path keeps its spelling, and its ``..`` is refused.
## * A UNC or device path (two leading separators) still refuses ``..``.
##
## The POSIX cases run against a real temporary directory with a real
## symlink — no mocks — because the rule is about what ``lstat`` says. The
## drive-rooted cases need no filesystem, so they run on every host.

import std/[os, strutils, tempfiles, unittest]

import repro_core/paths as corepaths

proc tree(): string =
  ## ``<root>/real/``, ``<root>/sub/target/``, ``<root>/file`` and, where
  ## the host has them, ``<root>/link -> sub/target``.
  result = createTempDir("repro-normalized-dotdot", "")
  createDir(result / "real")
  createDir(result / "sub" / "target")
  writeFile(result / "file", "")
  when not defined(windows):
    createSymlink("sub/target", result / "link")

proc slashed(path: string): string =
  ## ``path`` in ``normalizedPath``'s separator spelling.
  path.replace('\\', '/')

suite "normalizedPath folds dot segments of an absolute path":

  test "a POSIX-style absolute path folds a .. after a real directory":
    let root = tree()
    defer: removeDir(root)
    let folded = corepaths.normalizedPath(root & "/real/../file")
    check folded.value == slashed(root) & "/file"
    when not defined(windows):
      check folded.kind == npAbsolute

  test "mixed separators fold like forward slashes":
    let root = tree()
    defer: removeDir(root)
    check corepaths.normalizedPath(root & "\\real/..\\file").value ==
      slashed(root) & "/file"

  test "a . segment of an absolute path is dropped without the filesystem":
    # None of these exist: only a `..` consults `lstat`.
    check corepaths.normalizedPath("/no/such/./dir/.").value == "/no/such/dir"
    check corepaths.normalizedPath("/no//such/./dir/").value ==
      "/no/such/dir/"
    check corepaths.normalizedPath("/.").value == "/"

  test "an absolute path without dot segments keeps its spelling":
    check corepaths.normalizedPath("/usr/bin/cc").value == "/usr/bin/cc"
    check corepaths.normalizedPath("/workspace/project/").value ==
      "/workspace/project/"

  test "a drive-rooted Windows path folds lexically on every host":
    # The spelling a Windows job produces for `<checkout>/../<sibling>`.
    check corepaths.normalizedPath(
      "D:\\a\\agent\\agent/../reprobuild").value == "D:/a/agent/reprobuild"
    check corepaths.normalizedPath("C:\\x\\.\\y\\..\\z\\").value ==
      "C:/x/z/"
    check corepaths.normalizedPath("c:/x/y/../../z").value == "c:/z"
    check corepaths.normalizedPath("D:/a/..").value == "D:/"
    # These do not exist on any host: Windows folds before it resolves, so
    # no filesystem check applies.
    check corepaths.normalizedPath("Q:/no/such/../dir").value == "Q:/no/dir"

suite "normalizedPath refuses what it cannot fold":

  test "a .. above a POSIX root is refused":
    expect ValueError:
      discard corepaths.normalizedPath("/..")
    expect ValueError:
      discard corepaths.normalizedPath("/../etc/hosts")

  test "a .. above a drive root is refused":
    expect ValueError:
      discard corepaths.normalizedPath("D:/..")
    expect ValueError:
      discard corepaths.normalizedPath("D:\\a\\..\\..\\b")

  test "a relative path keeps refusing ..":
    expect ValueError:
      discard corepaths.normalizedPath("a/../b")
    expect ValueError:
      discard corepaths.normalizedPath("../x")
    expect ValueError:
      discard corepaths.normalizedPath("a\\..\\b")
    # Drive-relative: resolved against a per-drive directory we cannot see,
    # so it is not a root to fold against.
    expect ValueError:
      discard corepaths.normalizedPath("D:x\\..\\y")

  test "a relative path keeps its spelling":
    check corepaths.normalizedPath("./a/b").value == "./a/b"
    check corepaths.normalizedPath("a/./b").value == "a/./b"
    check corepaths.normalizedPath("a/b").kind == npRelative
    check corepaths.normalizedPath(".").value == "."

  test "a UNC or device path keeps refusing ..":
    expect ValueError:
      discard corepaths.normalizedPath("\\\\server\\share\\a\\..\\b")
    expect ValueError:
      discard corepaths.normalizedPath("\\\\?\\C:\\a\\..\\b")
    expect ValueError:
      discard corepaths.normalizedPath("//server/share/a/../b")

  test "an empty path is refused":
    expect ValueError:
      discard corepaths.normalizedPath("  ")

  when not defined(windows):
    test "a .. after a POSIX symlink is refused, not folded lexically":
      let root = tree()
      defer: removeDir(root)
      # The kernel reaches `<root>/sub/file`; a lexical fold names
      # `<root>/file`, a different file.
      expect ValueError:
        discard corepaths.normalizedPath(root & "/link/../file")

    test "a .. after an absent or non-directory component is refused":
      let root = tree()
      defer: removeDir(root)
      expect ValueError:
        discard corepaths.normalizedPath(root & "/gone/../file")
      expect ValueError:
        discard corepaths.normalizedPath(root & "/file/../file")
