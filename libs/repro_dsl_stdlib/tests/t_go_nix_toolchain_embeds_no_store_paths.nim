## The catalog's Nix-mode Go compiles binaries that embed no /nix/store path
## (ReproOS Add-On Mode §13 decision 36).
##
## THE NEED. nixpkgs patches Go's standard library so that ``time`` reads its
## zoneinfo, ``net`` its ``services`` and ``protocols``, and ``mime`` its
## ``mime.types`` from fixed store paths (tzdata, iana-etc, mailcap). Every
## binary that Go compiles embeds them, so a Go program the catalog builds
## and ships to a Debian host looks them up in a store the host does not
## have; and the Nix and tarball modes, one patched and one not, build
## different bytes from the same source. The catalog's `go` therefore
## realises go.dev's own release through Nix
## (``packages/nix/go-1.25.4/default.nix``).
##
## WHAT IS CHECKED. The expression is realised with ``nix build --file``
## exactly as the engine's Nix provisioning realises it, and is go.dev's
## 1.25.4 (``VERSION``). A program that uses all three patched packages
## (``time.LoadLocation``, ``net.LookupPort``, ``mime.TypeByExtension``) is
## built with it the way ``go_package`` builds (``-trimpath``,
## ``CGO_ENABLED=0``, module mode off, a fresh build cache), runs, and its
## bytes contain no ``/nix/store/``.
##
## Falsifying mutation: ``REPRO_GO_TOOLCHAIN_MUTATION=nixpkgs-go`` builds
## the same program with the pinned nixpkgs' ``go`` (what the catalog used
## before) and the test goes red: that binary embeds the tzdata, iana-etc
## and mailcap paths.
##
## Needs ``nix``. Without it the test says so and is skipped, unless
## ``REPRO_GO_NIX_TOOLCHAIN_REQUIRED=1``, which makes its absence a failure.
##
## *Mocking.* None: the real expression, the real nixpkgs pin, a real build.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip

const
  StdlibPackages = currentSourcePath.parentDir.parentDir / "src" /
    "repro_dsl_stdlib" / "packages"
  GoExpression = StdlibPackages / "nix" / "go-1.25.4" / "default.nix"
  NixpkgsPin = StdlibPackages / "nix" / "nixpkgs.nix"
  Program = """
package main

import (
	"fmt"
	"mime"
	"net"
	"time"
)

func main() {
	loc, err := time.LoadLocation("UTC")
	port, perr := net.LookupPort("tcp", "https")
	fmt.Println(loc, err == nil, port, perr == nil, mime.TypeByExtension(".html"))
}
"""

proc realise(): tuple[root: string; output: string] =
  ## The Go toolchain under test: the stdlib expression, or under the
  ## falsifying mutation the pinned nixpkgs' `go`.
  let mutation = getEnv("REPRO_GO_TOOLCHAIN_MUTATION")
  let cmd =
    if mutation == "nixpkgs-go":
      quoteShellCommand(["nix", "build", "--no-link", "--print-out-paths",
        "--impure", "--expr", "(import " & NixpkgsPin & ").go"])
    elif mutation.len > 0:
      raise newException(ValueError,
        "unknown REPRO_GO_TOOLCHAIN_MUTATION " & mutation)
    else:
      quoteShellCommand(["nix", "build", "--no-link", "--print-out-paths",
        "--file", GoExpression])
  let (o, c) = execCmdEx(cmd)
  if c != 0: return ("", o)
  for line in o.splitLines():
    if line.startsWith("/nix/store/"): result.root = line.strip()
  result.output = o

suite "Nix-mode Go embeds no store path":
  test "a program built with the catalog's Nix-mode Go embeds no /nix/store path":
    if findExe("nix").len == 0:
      check getEnv("REPRO_GO_NIX_TOOLCHAIN_REQUIRED") != "1"
      skip("nix is not on PATH; the Nix-mode Go toolchain cannot be realised here")
    else:
      let (root, output) = realise()
      checkpoint output
      require root.len > 0
      let goExe = root / "bin" / "go"
      require fileExists(goExe)
      if getEnv("REPRO_GO_TOOLCHAIN_MUTATION").len == 0:
        # go.dev's release, unpacked as-is: its VERSION file names it.
        check readFile(root / "VERSION").startsWith("go1.25.4")
      let work = createTempDir("go-nix-store-paths-", "")
      defer: removeDir(work)
      writeFile(work / "main.go", Program)
      let env = "env -i HOME=" & quoteShell(work / "home") &
        " PATH=" & quoteShell(getEnv("PATH")) &
        " GOCACHE=" & quoteShell(work / "cache") &
        " GOPATH=" & quoteShell(work / "gopath") &
        " GO111MODULE=off GOTELEMETRY=off CGO_ENABLED=0 GOFLAGS= "
      let build = execCmdEx(env & "sh -c " & quoteShell("cd " &
        quoteShell(work) & " && " & quoteShell(goExe) &
        " build -trimpath -o prog ."))
      checkpoint build.output
      require build.exitCode == 0
      let run = execCmdEx(quoteShell(work / "prog"))
      checkpoint run.output
      check run.exitCode == 0
      check run.output.startsWith("UTC true 443 true text/html")
      let bytes = readFile(work / "prog")
      var embedded: seq[string]
      var i = bytes.find("/nix/store/")
      while i >= 0 and embedded.len < 8:
        var j = i
        while j < bytes.len and bytes[j] notin {'\0', '\n', ' ', '"'}: inc j
        embedded.add(bytes[i ..< min(j, i + 120)])
        i = bytes.find("/nix/store/", j)
      checkpoint "embedded: " & embedded.join(", ")
      check embedded.len == 0
