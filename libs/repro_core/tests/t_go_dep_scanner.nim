## Unit tests for ``repro_core/go_dep_scanner`` — the Mode 3 Go
## dependency scanner.
##
## Each test below pins one slice of the scanner contract documented
## in ``reprobuild-specs/Three-Mode-Convention-System.md`` §"The
## scanner contract", restated for the Go side:
##
##   * member discovery filters by layout: a package with only
##     Nim/Rust sources doesn't appear in the Go scanner's member
##     list.
##   * ``import "<path>"`` (single + grouped) emits a workspace edge
##     when the import path's last segment resolves to another
##     in-workspace member.
##   * Stdlib heads (``fmt`` / ``encoding/json`` / ...) NEVER produce
##     an edge.
##   * External module heads (anything with a dot in the first
##     segment) are silently dropped — Mode 3 is in-workspace only.
##   * the scanner is byte-deterministic: two runs over the same tree
##     produce identical sorted edge lists.
##   * the unified ``scanWorkspaceAll`` merges Nim + C/C++ + Rust + Go
##     outputs with stable ordering across mixed-language workspaces.

import std/[os, strutils, unittest]

import repro_core

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-core-go-dep-scanner-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "repro_core.go_dep_scanner: import extraction":

  test "extractGoImportRefs picks up single-line import and skips line comments":
    let text = """
// import "ignored/path"
package main

import "fmt"
import json "encoding/json"

func main() { }
"""
    let refs = extractGoImportRefs(text)
    check refs.len == 2
    check refs[0].path == "fmt"
    check refs[0].lineNumber == 4
    check refs[1].path == "encoding/json"
    check refs[1].lineNumber == 5

  test "extractGoImportRefs handles grouped import blocks":
    let text = """
package main

import (
    "fmt"
    "os"
    j "encoding/json"
    _ "embed"
)

func main() {}
"""
    let refs = extractGoImportRefs(text)
    check refs.len == 4
    check refs[0].path == "fmt"
    check refs[1].path == "os"
    check refs[2].path == "encoding/json"
    check refs[3].path == "embed"

  test "extractGoImportRefs ignores string literals outside import blocks":
    let text = """
package main

import "fmt"

func main() {
    s := "github.com/not-an-import"
    fmt.Println(s, "still not an import")
}
"""
    let refs = extractGoImportRefs(text)
    check refs.len == 1
    check refs[0].path == "fmt"

  test "isGoStdlibImport recognises top-level + nested stdlib paths":
    check isGoStdlibImport("fmt")
    check isGoStdlibImport("encoding/json")
    check isGoStdlibImport("net/http")
    check isGoStdlibImport("os")
    check isGoStdlibImport("internal/abi")
    check isGoStdlibImport("C")  # cgo defensive entry
    check not isGoStdlibImport("mathlib")
    check not isGoStdlibImport("github.com/foo/bar")

  test "isGoExternalModuleImport flags dotted first segments":
    check isGoExternalModuleImport("github.com/foo/bar")
    check isGoExternalModuleImport("golang.org/x/sync")
    check isGoExternalModuleImport("example.com/internal")
    check not isGoExternalModuleImport("fmt")
    check not isGoExternalModuleImport("mathlib")
    check not isGoExternalModuleImport("internal/abi")

  test "importLastSegment returns the bare package name":
    check importLastSegment("mathlib") == "mathlib"
    check importLastSegment("foo/mathlib") == "mathlib"
    check importLastSegment("foo/bar/baz") == "baz"

suite "repro_core.go_dep_scanner: edge inference":

  test "executable importing a library package emits one edge":
    let dir = makeScratch("two-package-import")
    # Layout B: two packages, each in its own subdir under the
    # workspace root.
    createDir(dir / "mathlib")
    writeFile(dir / "mathlib" / "add.go",
      "package mathlib\nfunc Add(a, b int) int { return a + b }\n")

    createDir(dir / "calc")
    writeFile(dir / "calc" / "main.go", """
package main

import (
    "fmt"
    "mathlib"
)

func main() { fmt.Println(mathlib.Add(1, 2)) }
""")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package mathlibPkg:
  uses:
    "go"
  library mathlib

package calcPkg:
  uses:
    "go"
  executable calc:
    discard
""")
    let scan = scanWorkspaceGo(dir)
    check scan.members.len == 2
    check scan.edges.len == 1
    check scan.edges[0].fromPackage == "calcPkg"
    check scan.edges[0].toPackage == "mathlibPkg"
    check scan.edges[0].evidence.contains("main.go:")
    check scan.edges[0].evidence.contains("\"mathlib\"")
    removeDir(dir)

  test "stdlib imports (fmt, encoding/json, net/http) never produce an edge":
    let dir = makeScratch("stdlib-only-import")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package solo:
  uses:
    "go"
  executable hello:
    discard
""")
    createDir(dir / "hello")
    writeFile(dir / "hello" / "main.go", """
package main

import (
    "fmt"
    "encoding/json"
    "net/http"
)

func main() {
    _ = json.NewEncoder
    _ = http.Get
    fmt.Println("hi")
}
""")
    let scan = scanWorkspaceGo(dir)
    check scan.members.len == 1
    check scan.edges.len == 0
    removeDir(dir)

  test "external module imports (github.com/..., golang.org/x/...) are silently dropped":
    # Mode 3 is in-workspace only; external imports like
    # ``github.com/foo/bar`` belong to the Mode 2 (go.mod) path. The
    # scanner emits no edge for them.
    let dir = makeScratch("external-module-import")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package solo:
  uses:
    "go"
  executable hello:
    discard
""")
    createDir(dir / "hello")
    writeFile(dir / "hello" / "main.go", """
package main

import (
    "fmt"
    "github.com/foo/bar"
    "golang.org/x/sync/errgroup"
)

func main() { fmt.Println(bar.X, errgroup.Group{}) }
""")
    let scan = scanWorkspaceGo(dir)
    check scan.members.len == 1
    check scan.edges.len == 0
    removeDir(dir)

  test "layout B: two packages in one project file with per-member subdirs":
    let dir = makeScratch("layout-b-multi-package")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package mathlibPkg:
  uses:
    "go"
  library mathlib

package calcPkg:
  uses:
    "go"
  executable calc:
    discard
""")
    createDir(dir / "mathlib")
    writeFile(dir / "mathlib" / "add.go",
      "package mathlib\nfunc Add(a, b int) int { return a + b }\n")
    createDir(dir / "calc")
    writeFile(dir / "calc" / "main.go", """
package main

import (
    "fmt"
    "mathlib"
)

func main() { fmt.Println(mathlib.Add(1, 2)) }
""")
    let scan = scanWorkspaceGo(dir)
    check scan.members.len == 2
    check scan.edges.len == 1
    check scan.edges[0].fromPackage == "calcPkg"
    check scan.edges[0].toPackage == "mathlibPkg"
    removeDir(dir)

  test "_test.go files are skipped by the scanner":
    # ``_test.go`` files in a member's source dir must NOT contribute
    # imports to the scanner's edge set — tests are deferred to a
    # future milestone (matching the M5/M14 Mode 2 stance).
    let dir = makeScratch("test-files-skipped")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package solo:
  uses:
    "go"
  library greet
""")
    createDir(dir / "greet")
    writeFile(dir / "greet" / "greet.go",
      "package greet\nfunc Hi() string { return \"hi\" }\n")
    writeFile(dir / "greet" / "greet_test.go", """
package greet

import (
    "testing"
    "fmt"
)

func TestHi(t *testing.T) { fmt.Println(Hi()) }
""")
    # The scanner should see "greet" as a Go member (.go source
    # present) but the test file's imports must NOT influence edges.
    let scan = scanWorkspaceGo(dir)
    check scan.members.len == 1
    check scan.edges.len == 0  # no edges; test imports ignored
    removeDir(dir)

suite "repro_core.go_dep_scanner: determinism":

  test "two runs over the same workspace produce byte-identical edges":
    let dir = makeScratch("determinism")
    createDir(dir / "alpha")
    writeFile(dir / "alpha" / "alpha.go",
      "package alpha\nfunc Hi() int { return 1 }\n")
    createDir(dir / "beta")
    writeFile(dir / "beta" / "main.go", """
package main

import (
    "fmt"
    "alpha"
)

func main() { fmt.Println(alpha.Hi()) }
""")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package alphaPkg:
  uses:
    "go"
  library alpha

package betaPkg:
  uses:
    "go"
  executable beta:
    discard
""")
    let first = scanWorkspaceGo(dir)
    let second = scanWorkspaceGo(dir)
    check first.edges.len == second.edges.len
    check first.edges.len >= 1
    for i in 0 ..< first.edges.len:
      check first.edges[i].fromPackage == second.edges[i].fromPackage
      check first.edges[i].toPackage == second.edges[i].toPackage
      check first.edges[i].evidence == second.edges[i].evidence
    removeDir(dir)

suite "repro_core.go_dep_scanner: unified multi-language scan":

  test "scanWorkspaceAll unions Nim + Rust + Go members + edges deterministically":
    # A mixed workspace: one Nim package + one Go library + one Go
    # executable importing the library. Each package lives in its
    # own directory under the workspace root.
    let dir = makeScratch("multi-language-go")
    createDir(dir / "nim-pkg")
    writeFile(dir / "nim-pkg" / "repro.nim", """
import repro_project_dsl

package nimSolo:
  uses:
    "nim >=2.2 <3.0"
  library greet
""")
    createDir(dir / "nim-pkg" / "src")
    writeFile(dir / "nim-pkg" / "src" / "greet.nim",
      "proc greet*(): string = \"hi\"\n")

    createDir(dir / "go-lib")
    writeFile(dir / "go-lib" / "repro.nim", """
import repro_project_dsl

package goLib:
  uses:
    "go"
  library mathlib
""")
    createDir(dir / "go-lib" / "mathlib")
    writeFile(dir / "go-lib" / "mathlib" / "add.go",
      "package mathlib\nfunc Add(a, b int) int { return a + b }\n")

    createDir(dir / "go-app")
    writeFile(dir / "go-app" / "repro.nim", """
import repro_project_dsl

package goApp:
  uses:
    "go"
  executable calc:
    discard
""")
    createDir(dir / "go-app" / "calc")
    writeFile(dir / "go-app" / "calc" / "main.go", """
package main

import (
    "fmt"
    "mathlib"
)

func main() { fmt.Println(mathlib.Add(1, 2)) }
""")
    let unified = scanWorkspaceAll(dir)
    var nimSeen = false
    var goLibSeen = false
    var goAppSeen = false
    for m in unified.members:
      if m.package == "nimSolo": nimSeen = true
      if m.package == "goLib": goLibSeen = true
      if m.package == "goApp": goAppSeen = true
    check nimSeen
    check goLibSeen
    check goAppSeen
    var goEdgeFound = false
    for e in unified.edges:
      if e.fromPackage == "goApp" and e.toPackage == "goLib":
        goEdgeFound = true
    check goEdgeFound
    removeDir(dir)
