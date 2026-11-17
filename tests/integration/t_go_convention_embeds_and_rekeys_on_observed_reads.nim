## t_go_convention_embeds_and_rekeys_on_observed_reads — the Go standard
## convention (Tier 2b, ``repro-standard-provider``) builds what ``go build``
## builds, from what ``go list`` reports, and re-derives its graph whenever
## something ``go list`` actually read changes.
##
## What this test owns
## -------------------
## ``reprobuild-pm`` ``spec/Language-Conventions/Go.md`` as amended for issue
## ``issues/2026-11-12-go-import-and-embed-resolution-is-hand-approximated-and-wrong.md``:
##
##   * §"The embedcfg file": a package with ``//go:embed`` directives is
##     compiled with ``-embedcfg``, and each embed variable receives exactly
##     the files cmd/go would give it (a directory pattern skips ``.``- and
##     ``_``-prefixed names below it, an ``all:`` pattern keeps them, a
##     single-file pattern names one file). Without ``-embedcfg`` the compile
##     fails outright.
##   * §"Implicit-dependency capture" item 3: the graph is keyed on the reads
##     the io monitor observed ``go list`` make. A file newly matching an
##     embed directory pattern (a directory-membership change), an edit to a
##     ``replace``d module's source OUTSIDE the project root, and an edit
##     that adds an import to the project's own source each re-derive the
##     graph, so the rebuilt binary reflects the edit.
##   * §"The importcfg file": a ``replace``d module compiles under its
##     original import path (no ``importmap`` derived from ``go.mod``).
##   * §"Workspace and module mode": a ``go.work`` whose root is not itself a
##     module builds through one listing over its members, and each package
##     compiles at its own module's ``go`` version (a member using a Go 1.23
##     language feature next to a Go 1.22 member).
##
## Every case cross-checks the built binary's output against ``go run`` of the
## same tree, so the expectation is Go's own behaviour, not a transcription
## of it.
##
## Mocks: none. Each case drives the real built ``repro`` CLI, which
## dispatches the real prebuilt ``repro-standard-provider`` beside it; the Go
## toolchain is the one on PATH (``--tool-provisioning=path``).

import std/[algorithm, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

let reproBin = getEnv("REPROBUILD_REPRO",
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt))
let standardProviderBin = reproBin.parentDir /
  addFileExt("repro-standard-provider", ExeExt)

proc unavailable(): string =
  if not fileExists(reproBin):
    return "needs " & reproBin & " (run `just build`)"
  if not fileExists(standardProviderBin):
    return "needs " & standardProviderBin & " beside the CLI (run `just build`)"
  if findExe("go").len == 0:
    return "go not on PATH"
  ""

const ProjectFile = """
import repro_project_dsl

package goConventionProbe:
  uses:
    "go >=1.22 <2.0"

  executable $1:
    discard
"""

type Run = object
  exitCode: int
  output: string

proc explain(run: Run): string =
  "exit=" & $run.exitCode & "\n--- output ---\n" & run.output

proc runBuild(project: string): Run =
  var command = quoteShell(reproBin) & " build " & quoteShell(project)
  for arg in ["--tool-provisioning=path", "--daemon=off", "--no-runquota",
      "--progress=quiet", "--log=actions"]:
    command.add(" " & quoteShell(arg))
  let res = execCmdEx(command, workingDir = project)
  Run(exitCode: res.exitCode, output: res.output)

proc goRun(dir: string; pkg = "."): Run =
  ## Go's own answer for the same tree: the reference every case compares
  ## the reprobuild-built binary with.
  let res = execCmdEx(quoteShell(findExe("go")) & " run " & quoteShell(pkg),
    options = {poUsePath}, workingDir = dir)
  Run(exitCode: res.exitCode, output: res.output)

proc builtBinary(project, name: string): string =
  ## The convention puts each binary under
  ## ``<root>/.repro/build/<entry>/bin/<name>``; the entry name is the
  ## convention's choice, so look for it rather than restate it.
  let base = project / ".repro" / "build"
  if not dirExists(base):
    return ""
  for kind, entry in walkDir(base):
    if kind != pcDir:
      continue
    let candidate = entry / "bin" / addFileExt(name, ExeExt)
    if fileExists(candidate):
      return candidate
  ""

proc runBinary(project, name: string): Run =
  let bin = builtBinary(project, name)
  if bin.len == 0:
    return Run(exitCode: -1, output: "no built binary named " & name &
      " under " & project / ".repro" / "build")
  let res = execCmdEx(quoteShell(bin))
  Run(exitCode: res.exitCode, output: res.output)

proc writeTree(root: string; files: openArray[(string, string)]) =
  for (rel, content) in files:
    let path = root / rel
    createDir(path.parentDir)
    writeFile(path, content)

# ------------------------------------------------------------ fixtures

const
  EmbedMain = """
package main

import (
	"embed"
	"fmt"
	"io/fs"
)

//go:embed static
var dirFS embed.FS

//go:embed static/a.txt
var single string

//go:embed all:static/sub
var allFS embed.FS

func list(name string, f embed.FS) {
	fs.WalkDir(f, ".", func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			fmt.Println(name, p)
		}
		return nil
	})
}

func main() {
	list("dir", dirFS)
	list("all", allFS)
	fmt.Print("single ", single)
}
"""

  PlainMain = "package main\n\nimport \"fmt\"\n\n" &
    "func main() { fmt.Println(\"plain\") }\n"
  # The same program with one more stdlib import: case (e).
  PlainMainWithStrings = "package main\n\nimport (\n\t\"fmt\"\n\t\"strings\"\n)\n\n" &
    "func main() { fmt.Println(strings.ToUpper(\"plain\")) }\n"

proc plainProject(root: string) =
  ## No embed, no replace: case (e) isolates re-keying on the project's own
  ## source from everything else this test checks.
  writeTree(root, [
    ("repro.nim", ProjectFile % "plainprobe"),
    ("go.mod", "module example.com/plainprobe\n\ngo 1.22\n"),
    ("main.go", PlainMain),
  ])

proc embedProject(root: string) =
  writeTree(root, [
    ("repro.nim", ProjectFile % "embedprobe"),
    ("go.mod", "module example.com/embedprobe\n\ngo 1.22\n"),
    ("main.go", EmbedMain),
    ("static/a.txt", "alpha\n"),
    ("static/.hidden.txt", "hidden\n"),
    ("static/_under.txt", "under\n"),
    ("static/sub/b.txt", "beta\n"),
    ("static/sub/.subhidden.txt", "subhidden\n"),
  ])

proc replaceProject(base: string): string =
  ## ``<base>/app`` replaces ``example.com/dep`` with ``<base>/dep`` — a
  ## module OUTSIDE the project root.
  writeTree(base / "dep", [
    ("go.mod", "module example.com/dep\n\ngo 1.22\n"),
    ("dep.go", "package dep\n\nfunc Hello() string { return \"dep\" }\n"),
  ])
  writeTree(base / "app", [
    ("repro.nim", ProjectFile % "replaceprobe"),
    ("go.mod", "module example.com/replaceprobe\n\ngo 1.22\n\n" &
      "require example.com/dep v0.0.0\n\nreplace example.com/dep => ../dep\n"),
    ("main.go", "package main\n\nimport (\n\t\"fmt\"\n\n" &
      "\t\"example.com/dep\"\n)\n\nfunc main() { fmt.Println(dep.Hello()) }\n"),
  ])
  base / "app"

proc workspaceProject(root: string) =
  ## A ``go.work`` root that is NOT a module. ``lib`` declares ``go 1.23.0``
  ## (the patch-release form ``go mod init`` writes; the compiler accepts it
  ## only reduced to ``-lang=go1.23``) and ranges over a function iterator,
  ## which the compiler accepts only at ``-lang=go1.23`` or later; ``api``
  ## declares ``go 1.22`` and imports it.
  writeTree(root, [
    ("repro.nim", ProjectFile % "api"),
    ("go.work", "go 1.23.0\n\nuse (\n\t./api\n\t./lib\n)\n"),
    ("lib/go.mod", "module example.com/lib\n\ngo 1.23.0\n"),
    ("lib/lib.go", "package lib\n\n" &
      "func seq(yield func(int) bool) {\n" &
      "\tfor i := 1; i <= 3; i++ {\n\t\tif !yield(i) {\n\t\t\treturn\n\t\t}\n\t}\n}\n\n" &
      "func Sum() int {\n\ts := 0\n\tfor v := range seq {\n\t\ts += v\n\t}\n\treturn s\n}\n"),
    ("api/go.mod", "module example.com/api\n\ngo 1.22\n\n" &
      "require example.com/lib v0.0.0\n"),
    ("api/main.go", "package main\n\nimport (\n\t\"fmt\"\n\n" &
      "\t\"example.com/lib\"\n)\n\nfunc main() { fmt.Println(\"sum\", lib.Sum()) }\n"),
  ])

proc sortedLines(text: string): seq[string] =
  for line in text.splitLines():
    if line.len > 0:
      result.add(line)
  result.sort()

suite "Go convention: embed, observed-read keying, replace, workspace":

  test "(a) //go:embed packages build and embed exactly what go embeds":
    let why = unavailable()
    if why.len > 0:
      skip(why)
    else:
      block caseBody:
        let root = createTempDir("repro-go-embed-", "")
        defer: removeDir(root)
        embedProject(root)
        let reference = goRun(root)
        checkpoint("go run: " & explain(reference))
        check reference.exitCode == 0
        if not (reference.exitCode == 0): break caseBody
        # Go's own resolution, written out so a regression in the fixture is
        # visible too: the directory pattern drops the dot- and underscore-
        # prefixed names below it, the all: pattern keeps them.
        check sortedLines(reference.output) == @[
          "all static/sub/.subhidden.txt", "all static/sub/b.txt",
          "dir static/a.txt", "dir static/sub/b.txt", "single alpha"]
        let build = runBuild(root)
        checkpoint("repro build: " & explain(build))
        check build.exitCode == 0
        check "standardDirect: dispatching" in build.output
        let ran = runBinary(root, "embedprobe")
        checkpoint("built binary: " & explain(ran))
        check ran.exitCode == 0
        check ran.output == reference.output

  test "(b) a file newly matching an embed directory pattern is embedded on rebuild":
    let why = unavailable()
    if why.len > 0:
      skip(why)
    else:
      block caseBody:
        let root = createTempDir("repro-go-embed-new-", "")
        defer: removeDir(root)
        embedProject(root)
        let first = runBuild(root)
        checkpoint("first build: " & explain(first))
        check first.exitCode == 0
        if not (first.exitCode == 0): break caseBody
        writeFile(root / "static" / "new.txt", "new\n")
        let reference = goRun(root)
        check reference.exitCode == 0
        if not (reference.exitCode == 0): break caseBody
        check "dir static/new.txt" in reference.output
        let second = runBuild(root)
        checkpoint("rebuild: " & explain(second))
        check second.exitCode == 0
        let ran = runBinary(root, "embedprobe")
        checkpoint("built binary: " & explain(ran))
        check ran.output == reference.output

  test "(c) an edit to a replaced module outside the root re-derives the graph":
    let why = unavailable()
    if why.len > 0:
      skip(why)
    else:
      block caseBody:
        let base = createTempDir("repro-go-replace-", "")
        defer: removeDir(base)
        let app = replaceProject(base)
        let first = runBuild(app)
        checkpoint("first build: " & explain(first))
        check first.exitCode == 0
        if not (first.exitCode == 0): break caseBody
        let ranFirst = runBinary(app, "replaceprobe")
        checkpoint("first binary: " & explain(ranFirst))
        check ranFirst.output == "dep\n"
        # The edit adds an import the first listing never saw, so the old
        # importcfg cannot compile it: only a re-derived graph builds.
        writeFile(base / "dep" / "dep.go", "package dep\n\nimport \"strings\"\n\n" &
          "func Hello() string { return strings.ToUpper(\"dep\") }\n")
        let reference = goRun(app)
        check reference.exitCode == 0
        if not (reference.exitCode == 0): break caseBody
        check reference.output == "DEP\n"
        let second = runBuild(app)
        checkpoint("rebuild: " & explain(second))
        check second.exitCode == 0
        let ran = runBinary(app, "replaceprobe")
        checkpoint("rebuilt binary: " & explain(ran))
        check ran.output == reference.output

  test "(d) a go.work workspace builds as one DAG, each package at its module's go version":
    let why = unavailable()
    if why.len > 0:
      skip(why)
    else:
      block caseBody:
        let root = createTempDir("repro-go-work-", "")
        defer: removeDir(root)
        workspaceProject(root)
        let reference = goRun(root, "./api")
        checkpoint("go run: " & explain(reference))
        check reference.exitCode == 0
        if not (reference.exitCode == 0): break caseBody
        check reference.output == "sum 6\n"
        let build = runBuild(root)
        checkpoint("repro build: " & explain(build))
        check build.exitCode == 0
        let ran = runBinary(root, "api")
        checkpoint("built binary: " & explain(ran))
        check ran.output == reference.output

  test "(e) adding an import to the project's own source re-derives the graph":
    let why = unavailable()
    if why.len > 0:
      skip(why)
    else:
      block caseBody:
        let root = createTempDir("repro-go-edit-", "")
        defer: removeDir(root)
        plainProject(root)
        let first = runBuild(root)
        checkpoint("first build: " & explain(first))
        check first.exitCode == 0
        if not (first.exitCode == 0): break caseBody
        check runBinary(root, "plainprobe").output == "plain\n"
        writeFile(root / "main.go", PlainMainWithStrings)
        let reference = goRun(root)
        check reference.exitCode == 0
        if not (reference.exitCode == 0): break caseBody
        check reference.output == "PLAIN\n"
        let second = runBuild(root)
        checkpoint("rebuild: " & explain(second))
        check second.exitCode == 0
        let ran = runBinary(root, "plainprobe")
        checkpoint("rebuilt binary: " & explain(ran))
        check ran.output == reference.output
