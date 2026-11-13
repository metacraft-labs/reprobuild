## `repro build .#apps` writes the binary cache's dependency list, tied to
## the binary it built (ReproOS Add-On Mode spec §13 decision 74; reprobuild-
## pm issue 2026-11-08-apps-build-path-of-the-helper-guard-has-no-runnable-
## falsifier).
##
## The engine of this tree (`build/bin/repro`, built at the commit under
## test) builds `.#apps` in a scratch copy of the committed tree (`git
## archive HEAD`, outside any workspace, so no sibling checkout enters).
## Then `repro_test_support/fresh_binary` accepts the copy's
## `build/bin/repro-binary-cache`: the `apps` collection carries the list
## edge, the edge ran, and it wrote a list naming that binary's digest.
##
## Falsifier: `A11_APPS_FALSIFIER=list-for-earlier-binary` in the
## environment. The test then drops a selector file into the copy that
## the list writer reads inside the edge, and the edge writes a list for
## another binary. fresh_binary refuses the binary, and the case is red.
##
## Opt-in: it builds every app of the tree (an hour from a cold cache), so
## it runs only with `REPRO_RUN_APPS_HELPER_LIST_TEST=1` and skips with
## that reason otherwise. Linux only: the edge needs strace.
##
## Mocks: none -- the real engine, the real graph, the real writer.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support/fresh_binary
import repro_test_support/reasoned_skip

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir

suite "repro build .#apps writes the helper lists":
  test "the binary cache built by .#apps is accepted by fresh_binary":
    when not defined(linux):
      skip("Linux only: the list edge traces the compiler with strace")
    else:
      if getEnv("REPRO_RUN_APPS_HELPER_LIST_TEST") != "1":
        skip("opt-in: set REPRO_RUN_APPS_HELPER_LIST_TEST=1 (it builds every app of the tree)")
      else:
        let engine = RepoRoot / "build" / "bin" / "repro".addFileExt(ExeExt)
        require fileExists(engine)
        let base = createTempDir("apps-helper-lists-", "")
        let copy = base / "reprobuild"
        createDir(copy)
        let (ao, ac) = execCmdEx("git -C " & quoteShell(RepoRoot) &
          " archive HEAD | tar -x -C " & quoteShell(copy))
        require ac == 0
        checkpoint ao
        let falsifier = getEnv("A11_APPS_FALSIFIER")
        if falsifier.len > 0:
          createDir(copy / "build" / "nimcache" / "repro-binary-cache")
          writeFile(copy / "build" / "nimcache" / "repro-binary-cache" /
                    "write-helper-deps.mutation", falsifier)
        let (bo, bc) = execCmdEx(quoteShellCommand([engine, "build", ".#apps"]),
                                 workingDir = copy)
        checkpoint bo[max(0, bo.len - 4000) .. ^1]
        check bc == 0
        var verdict = ""
        try:
          discard freshRepoBinary(copy, "repro-binary-cache")
          verdict = "accepted"
        except StaleHelperBinary as e:
          verdict = e.msg
        checkpoint verdict
        check verdict == "accepted"
        removeDir(base)
