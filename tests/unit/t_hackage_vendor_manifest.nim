## The committed Hackage closure manifest and the vendor action that turns it
## into a `file+noindex` repository.
##
## The reader is strict on purpose (`repro_core/hackage_closure`): a line it
## skipped would be a package missing from the repository, and that surfaces
## inside cabal's solver, far from the manifest. So each refusal is asserted.
## The vendor action is then EXECUTED -- its emitted shell bytes, run by `sh`
## against archives served from `file://` URLs -- to show that it lays out
## the repository, writes the private cabal configuration, and refuses an
## archive whose bytes do not match the pin.
##
## No mocks: the manifest is parsed by the reader the convention and the
## constructor use, and the action runs the real `curl` / `sha256sum` / `cp`.
## Only the URLs are local, so the test needs no network.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_attest/measurement
import repro_core/ambient_execution
import repro_core/hackage_closure
import repro_project_dsl
import repro_project_dsl/hackage_vendor

const
  Sha = "687008d6ddcadfd6603c805067f005067f0e428856fc83eceed68d0c6fc3da52"
  Sha2 = "a5bc9928c817f3c41c3f4c757103f9baafa8c9d3cdf5295926c34e147801cf38"
  Header = HackageVendorManifestHeader & "\n"

proc line(name, sha, url: string): string = name & " " & sha & " " & url & "\n"

proc fileSha256(path: string): string =
  sha256Hex(readFile(path)).toLowerAscii()

proc runAction(action: BuildActionDef): int =
  for argument in action.call.arguments:
    if argument.name == "argv":
      let argv = argument.encodedValue.split('\x1f')
      let process = uncontrolledStartProcess(uncontrolledFindExe(argv[0]),
        args = argv[1 .. ^1], options = {poParentStreams})
      try:
        return process.waitForExit()
      finally:
        process.close()
  raise newException(ValueError, "action has no argv")

proc fileUrl(path: string): string =
  var p = path.replace('\\', '/')
  if not p.startsWith("/"):
    p = "/" & p
  "file://" & p

suite "hackage vendor manifest":
  test "a tarball and its revised description round-trip":
    let entries = @[
      HackageVendorEntry(fileName: "megaparsec-9.5.0.tar.gz", sha256: Sha,
        url: sdistUrl("megaparsec-9.5.0")),
      HackageVendorEntry(fileName: "megaparsec-9.5.0.cabal", sha256: Sha2,
        url: revisionUrl("megaparsec-9.5.0", 4))]
    let text = renderHackageVendorManifest(entries, ["a comment"])
    check text.startsWith(Header)
    check parseHackageVendorManifest(text) == entries
    check entries[0].url == "https://hackage.haskell.org/package/" &
      "megaparsec-9.5.0/megaparsec-9.5.0.tar.gz"
    check entries[1].url ==
      "https://hackage.haskell.org/package/megaparsec-9.5.0/revision/4.cabal"

  test "a manifest without the header is refused":
    expect HackageClosureError:
      discard parseHackageVendorManifest(
        line("colour-2.3.7.tar.gz", Sha, sdistUrl("colour-2.3.7")))

  test "a file name that is not a package archive or description is refused":
    for bad in ["colour.tar.gz", "colour-2.3.7.zip", "../colour-2.3.7.tar.gz",
                "colour-2.x.tar.gz"]:
      expect HackageClosureError:
        discard parseHackageVendorManifest(Header & line(bad, Sha,
          sdistUrl("colour-2.3.7")))

  test "a digest that is not sha256 hex is refused":
    expect HackageClosureError:
      discard parseHackageVendorManifest(Header & line("colour-2.3.7.tar.gz",
        "abc", sdistUrl("colour-2.3.7")))

  test "a plain-http url is refused":
    expect HackageClosureError:
      discard parseHackageVendorManifest(Header & line("colour-2.3.7.tar.gz",
        Sha, "http://hackage.haskell.org/x.tar.gz"))

  test "a file listed twice is refused":
    let l = line("colour-2.3.7.tar.gz", Sha, sdistUrl("colour-2.3.7"))
    expect HackageClosureError:
      discard parseHackageVendorManifest(Header & l & l)

  test "a revised description without its tarball is refused":
    expect HackageClosureError:
      discard parseHackageVendorManifest(Header & line(
        "megaparsec-9.5.0.cabal", Sha2, revisionUrl("megaparsec-9.5.0", 4)))

  test "the private cabal configuration names only the vendored repository":
    let config = hackageCabalConfig("C:\\work\\.repro\\hackage-vendor\\repo")
    check config == "repository reprobuild-vendor\n" &
      "  url: file+noindex://C:/work/.repro/hackage-vendor/repo\n"
    check "hackage.haskell.org" notin config

suite "hackage vendor action":
  test "a recipe without a committed manifest is refused by name":
    let root = createTempDir("repro-hv-", "")
    defer: removeDir(root)
    try:
      discard readHackageVendorManifest(root)
      check false
    except HackageClosureError as err:
      check HackageVendorManifestName in err.msg

  test "the action builds the repository and the config, and verifies":
    let root = createTempDir("repro-hv-", "")
    let served = createTempDir("repro-hv-served-", "")
    defer:
      removeDir(root)
      removeDir(served)
    writeFile(served / "colour-2.3.7.tar.gz", "pretend sdist bytes\n")
    writeFile(served / "colour-2.3.7.cabal", "name: colour\n")
    let tarSha = fileSha256(served / "colour-2.3.7.tar.gz")
    let cabalSha = fileSha256(served / "colour-2.3.7.cabal")
    # The action's loop reads the manifest file itself, so a `file://` URL
    # (which the strict reader would refuse) stands in for Hackage here.
    writeFile(root / HackageVendorManifestName, Header &
      line("colour-2.3.7.tar.gz", tarSha,
        fileUrl(served / "colour-2.3.7.tar.gz")) &
      line("colour-2.3.7.cabal", cabalSha,
        fileUrl(served / "colour-2.3.7.cabal")))
    let action = emitHackageVendorAction(root, "nixfmtSource", @[],
      "fetch-id", root / "fetch.stamp")
    check action.id == hackageVendorActionId("nixfmtSource")
    check action.deps == @["fetch-id"]
    check hackageVendorManifestPath(root) in action.inputs
    check action.outputs == @[hackageVendorStampPath(root)]
    check not action.cacheable

    check runAction(action) == 0
    let repo = hackageVendorRepoDir(root)
    check readFile(repo / "colour-2.3.7.tar.gz") == "pretend sdist bytes\n"
    check readFile(repo / "colour-2.3.7.cabal") == "name: colour\n"
    check readFile(hackageCabalDir(root) / "config") ==
      hackageCabalConfig(repo)
    check fileExists(hackageVendorStampPath(root))

    # A cached archive whose bytes no longer match the pin fails the step:
    # the check runs on every execution, not only after a download.
    writeFile(hackageVendorCacheDir(root) / "colour-2.3.7.tar.gz",
      "tampered\n")
    check runAction(action) != 0
