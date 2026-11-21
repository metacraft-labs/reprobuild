## The per-test producer's library half (``ct_test_nim_unittest/tests_fragment``):
## how a test binary's listing becomes one exact-run record per test, what
## it refuses, and the command line the engine and the program share.
##
## No mocks. The pure cases run the production procedures on literal
## listings. The listing cases run real processes: on POSIX, small shell
## scripts stand in for a test binary's ``--entrypoint=tests --list``
## answer, because what is under test is how the producer reads a listing
## process (both streams, the exit code), not the tests entry itself. A real
## nim-entrypoints binary is listed and run per test by
## ``tests/integration/test_cs_m14_repro_collects_tests_per_entry.nim``.

import std/[json, os, strutils, tempfiles, unittest]

import ct_test_nim_unittest/tests_fragment

proc request(): PerTestRequest =
  PerTestRequest(binary: "/abs/build/test-bin/suite",
    fragment: "build/tests-per-entry/suite.rbdyn",
    idPrefix: "pkg.tests", collectorId: "pkg.tests",
    statsName: "build/test-bin/suite", cwd: "/abs")

proc records(text: string): seq[JsonNode] =
  for line in text.splitLines():
    if line.startsWith("create-action\t"):
      result.add(parseJson(line["create-action\t".len .. ^1]))

proc depLines(text: string): seq[string] =
  for line in text.splitLines():
    if line.startsWith("dep\t"):
      result.add(line)

suite "a listing becomes one exact run per test":

  test "names are read in order, line endings and the final newline dropped":
    check parseTestListing("alpha\nbeta\ngamma\n") ==
      @["alpha", "beta", "gamma"]
    check parseTestListing("alpha\r\nbeta\r\n") == @["alpha", "beta"]
    # A name is kept verbatim, pattern characters and spaces included.
    check parseTestListing("a*b\ns::a?c\nwith space\n") ==
      @["a*b", "s::a?c", "with space"]

  test "a name listed twice is refused, naming it":
    var message = ""
    try:
      discard parseTestListing("alpha\nbeta\nalpha\ngamma\nbeta\n", "bin/x")
    except TestsFragmentError as err:
      message = err.msg
    checkpoint(message)
    check "bin/x" in message
    check "\"alpha\"" in message
    check "\"beta\"" in message
    check "more than once" in message
    check "\"gamma\"" notin message

  test "an empty listing and an empty name are refused":
    expect TestsFragmentError:
      discard parseTestListing("")
    expect TestsFragmentError:
      discard parseTestListing("alpha\n\nbeta\n")

  test "ids spell the name with id characters and stay unique":
    check testActionIdPart("a*b c.d") == "a_b_c_d"
    check perTestActionIds("p", ["alpha", "a b", "a_b", "a?b"]) ==
      @["p.test.alpha", "p.test.a_b", "p.test.a_b-2", "p.test.a_b-3"]

  test "every record runs exactly its test, monitored and cacheable":
    let names = @["alpha", "a*b", "tab\tname"]
    let text = perTestFragmentText(request(), names)
    check text.startsWith("repro-dynamic-graph-v1\n")
    let recs = records(text)
    check recs.len == 3
    let ids = perTestActionIds("pkg.tests", names)
    for i, rec in recs:
      checkpoint($rec)
      check rec["id"].getStr() == ids[i]
      var argv: seq[string] = @[]
      for item in rec["argv"]:
        argv.add(item.getStr())
      check argv == @["/abs/build/test-bin/suite", "--entrypoint=tests",
        "--run-exact=" & names[i]]
      check rec["cwd"].getStr() == "/abs"
      check rec["inputs"] == %["/abs/build/test-bin/suite"]
      check rec["dependencyPolicy"] == %*{"kind": "automaticMonitor"}
      check rec["cacheable"].getBool()
      check rec["commandStatsId"].getStr() ==
        "build/test-bin/suite::" & names[i]
    # The tab is escaped inside the JSON, so each record is one line.
    check text.splitLines().len == 1 + 3 + 3 + 1
    check depLines(text) == @[
      "dep\tpkg.tests\tpkg.tests.test.alpha",
      "dep\tpkg.tests\tpkg.tests.test.a_b",
      "dep\tpkg.tests\tpkg.tests.test.tab_name"]

  test "the fragment is counted back by the collector":
    let dir = createTempDir("tests-fragment-count-", "")
    defer: removeDir(dir)
    let path = dir / "f.rbdyn"
    writeFile(path, perTestFragmentText(request(), ["alpha", "beta"]))
    check countFragmentRuns(path) == 2
    writeFile(path, "not a fragment\n")
    expect TestsFragmentError:
      discard countFragmentRuns(path)
    expect TestsFragmentError:
      discard countFragmentRuns(dir / "missing.rbdyn")

suite "the producer's command line":

  test "the engine's command line parses back to the same request":
    let argv = producerListArgv("/bin/repro-tests-fragment", request())
    check argv[0] == "/bin/repro-tests-fragment"
    let command = parseProducerArgs(argv[1 .. ^1])
    check command.kind == pckList
    check command.request == request()
    let collect = parseProducerArgs(
      producerCheckArgv("/p", "f.rbdyn")[1 .. ^1])
    check collect.kind == pckCheck
    check collect.fragment == "f.rbdyn"

  test "a malformed command line is refused with exit code 64":
    expect TestsFragmentError:
      discard parseProducerArgs(["--binary=/b", "--out=f"])
    expect TestsFragmentError:
      discard parseProducerArgs(["--bogus"])
    expect TestsFragmentError:
      discard parseProducerArgs(["--check=f", "--binary=/b"])
    check runProducer(["--bogus"]) == 64
    check runProducer([]) == 64
    check runProducer(["--help"]) == 0

when defined(posix):
  proc script(dir, name, body: string): string =
    result = dir / name
    writeFile(result, "#!/bin/sh\n" & body)
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

  suite "listing a binary":

    test "the list is read from stdout, and a large stderr does not block it":
      let dir = createTempDir("tests-fragment-list-", "")
      defer: removeDir(dir)
      # 256 KiB on stderr before the list: more than a pipe holds, so a
      # reader that drained stdout first would wait forever.
      let binary = script(dir, "lister",
        "[ \"$1 $2\" = \"--entrypoint=tests --list\" ] || exit 9\n" &
        "head -c 262144 /dev/zero | tr '\\0' x >&2\n" &
        "printf 'alpha\\nbeta\\ngamma\\n'\n")
      check listTests(binary) == @["alpha", "beta", "gamma"]

      let outPath = dir / "out" / "suite.rbdyn"
      var req = request()
      req.binary = binary
      req.fragment = outPath
      check writePerTestFragment(req) == 3
      check records(readFile(outPath)).len == 3

    test "a failing listing is refused with its exit code and stderr":
      let dir = createTempDir("tests-fragment-fail-", "")
      defer: removeDir(dir)
      let binary = script(dir, "no-tests-entry",
        "echo 'unknown entry: tests' >&2\nexit 64\n")
      var message = ""
      try:
        discard listTests(binary)
      except TestsFragmentError as err:
        message = err.msg
      checkpoint(message)
      check "exited with code 64" in message
      check "unknown entry: tests" in message
      check "import entrypoints/tests" in message
      # The program reports it as a refusal (1), not a usage error, and
      # writes no fragment.
      let outPath = dir / "suite.rbdyn"
      check runProducer(["--binary=" & binary, "--out=" & outPath,
        "--id-prefix=p", "--collector=p"]) == 1
      check not fileExists(outPath)

    test "a listing that names a test twice writes no fragment":
      let dir = createTempDir("tests-fragment-dup-", "")
      defer: removeDir(dir)
      let binary = script(dir, "dup", "printf 'alpha\\nalpha\\n'\n")
      let outPath = dir / "suite.rbdyn"
      check runProducer(["--binary=" & binary, "--out=" & outPath,
        "--id-prefix=p", "--collector=p"]) == 1
      check not fileExists(outPath)
