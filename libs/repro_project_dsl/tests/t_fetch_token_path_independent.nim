## A fetch's up-to-date token binds WHAT it acquires, not WHERE the checkout
## is. It is a hash over the acquisition program, and that program names the
## project's own paths; hashed as written, two checkouts of one recipe got two
## tokens — and since the token is part of the action's static description,
## their portable fingerprints could never agree (Cache-Scope P3.4). Portable
## logicalization rewrites a path that appears as TEXT, but cannot reach one
## inside a hash, so the program is hashed with the project path taken out.

import std/[strutils, unittest]

import repro_project_dsl/shell_fetch

proc fetchScript(projectRoot, url: string): string =
  let scratch = projectRoot & "/.repro/fetch"
  var script = "set -e; "
  script.appendCurlDownload(scratch & "/abc.tar", url)
  script.appendTarExtraction(scratch & "/abc.tar", projectRoot & "/src", 1)
  script.appendVerifiedFetchStamp(scratch & "/abc.stamp")
  script

proc tokenOf(script: string): string =
  let at = script.find("repro-source-fetch-v1:")
  require at >= 0
  script[at ..< at + "repro-source-fetch-v1:".len + 64]

suite "fetch up-to-date token":

  test "two checkouts of one fetch agree; another source does not":
    let url = "https://example.invalid/pkg-1.0.tar.gz"
    let a = fetchScript("M:/m/dev/packages/source/pkg", url)
    let b = fetchScript("M:/m/elsewhere/deeper/packages/source/pkg", url)
    check a != b                       # the programs do name their paths
    check tokenOf(a) == tokenOf(b)     # ...but the token does not
    check tokenOf(fetchScript("M:/m/dev/packages/source/pkg",
      "https://example.invalid/pkg-2.0.tar.gz")) != tokenOf(a)

  test "the anchor is the project the stamp lives under, either spelling":
    check projectAnchorOf("M:\\m\\dev\\pkg\\.repro\\fetch\\x.stamp") ==
      "M:/m/dev/pkg"
    check projectAnchorOf("/no/repro/dir/x.stamp") == ""
    check withoutProjectPath("cd \"M:\\m\\dev\\pkg\\src\" && ls M:/m/dev/pkg",
      "M:/m/dev/pkg") == "cd \"<project>\\src\" && ls <project>"
