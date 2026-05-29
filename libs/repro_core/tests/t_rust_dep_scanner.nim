## Unit tests for ``repro_core/rust_dep_scanner`` — the Mode 3 Rust
## dependency scanner.
##
## Each test below pins one slice of the scanner contract documented
## in ``reprobuild-specs/Three-Mode-Convention-System.md`` §"The
## scanner contract", restated for the Rust side:
##
##   * member discovery filters by layout: a package with only Nim
##     sources doesn't appear in the Rust scanner's member list.
##   * ``use <crate>::...`` / ``extern crate <crate>;`` emits a
##     workspace edge when the crate head resolves to another
##     in-workspace member.
##   * Stdlib heads (``std`` / ``core`` / ``alloc``) NEVER produce
##     an edge.
##   * External crate heads (anything not in the workspace, not
##     stdlib) are silently dropped — Mode 3 is in-workspace only.
##   * the scanner is byte-deterministic: two runs over the same tree
##     produce identical sorted edge lists.
##   * the unified ``scanWorkspaceAll`` merges Nim + C/C++ + Rust
##     outputs with stable ordering across mixed-language workspaces.

import std/[os, strutils, unittest]

import repro_core

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-core-rust-dep-scanner-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "repro_core.rust_dep_scanner: use-statement extraction":

  test "extractRustUseRefs picks up simple use and skips line comments":
    let text = """
// use ignored::stuff;
use mathlib::add;
use serde::{Deserialize, Serialize};
fn main() {}
"""
    let refs = extractRustUseRefs(text)
    check refs.len == 2
    check refs[0].crateHead == "mathlib"
    check refs[0].lineNumber == 2
    check refs[1].crateHead == "serde"
    check refs[1].lineNumber == 3

  test "pub use and pub(crate) use are recognised":
    let text = """
pub use foo::bar;
pub(crate) use baz::qux;
pub(super) use alpha::beta;
"""
    let refs = extractRustUseRefs(text)
    check refs.len == 3
    check refs[0].crateHead == "foo"
    check refs[1].crateHead == "baz"
    check refs[2].crateHead == "alpha"

  test "extern crate (legacy 2015-edition form) is recognised":
    let text = """
extern crate mathlib;
extern crate libc as c;
"""
    let refs = extractRustUseRefs(text)
    check refs.len == 2
    check refs[0].crateHead == "mathlib"
    check refs[1].crateHead == "libc"

  test "intra-crate heads (crate, self, super) extract but stdlib filter drops them":
    let text = """
use crate::module::item;
use self::sibling::Type;
use super::parent::other;
"""
    let refs = extractRustUseRefs(text)
    check refs.len == 3
    check isRustIntraCrateHead(refs[0].crateHead)
    check isRustIntraCrateHead(refs[1].crateHead)
    check isRustIntraCrateHead(refs[2].crateHead)

  test "stdlib heads are recognised by isRustStdlibCrate":
    check isRustStdlibCrate("std")
    check isRustStdlibCrate("core")
    check isRustStdlibCrate("alloc")
    check isRustStdlibCrate("proc_macro")
    check not isRustStdlibCrate("mathlib")
    check not isRustStdlibCrate("serde")

  test "normaliseRustCrateName collapses '-' to '_'":
    check normaliseRustCrateName("my-lib") == "my_lib"
    check normaliseRustCrateName("already_underscored") == "already_underscored"
    check normaliseRustCrateName("dashed-crate-name") == "dashed_crate_name"
    # Rust crate names are case-sensitive — no lower-casing.
    check normaliseRustCrateName("MyLib") == "MyLib"

suite "repro_core.rust_dep_scanner: edge inference":

  test "executable using a library crate in another package emits one edge":
    let dir = makeScratch("two-package-use")
    # Layout B: two packages, each in its own subdir under the
    # workspace root.
    createDir(dir / "mathlib")
    writeFile(dir / "mathlib" / "repro.nim", """
import repro_project_dsl

package mathlibPkg:
  uses:
    "rust"
  library mathlib
""")
    createDir(dir / "mathlib" / "src")
    writeFile(dir / "mathlib" / "src" / "lib.rs",
      "pub fn add(a: i32, b: i32) -> i32 { a + b }\n")

    createDir(dir / "calc")
    writeFile(dir / "calc" / "repro.nim", """
import repro_project_dsl

package calcPkg:
  uses:
    "rust"
  executable calc:
    discard
""")
    createDir(dir / "calc" / "src")
    writeFile(dir / "calc" / "src" / "main.rs",
      "use mathlib::add;\nfn main() { println!(\"{}\", add(1, 2)); }\n")

    let scan = scanWorkspaceRust(dir)
    check scan.members.len == 2
    check scan.edges.len == 1
    check scan.edges[0].fromPackage == "calcPkg"
    check scan.edges[0].toPackage == "mathlibPkg"
    check scan.edges[0].evidence.contains("main.rs:")
    check scan.edges[0].evidence.contains("use mathlib::add;")
    removeDir(dir)

  test "stdlib use (use std::collections::HashMap) never produces an edge":
    let dir = makeScratch("stdlib-only-use")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package solo:
  uses:
    "rust"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.rs",
      "use std::collections::HashMap;\nuse core::mem;\nfn main() { let _: HashMap<i32, i32> = HashMap::new(); }\n")
    let scan = scanWorkspaceRust(dir)
    check scan.members.len == 1
    check scan.edges.len == 0
    removeDir(dir)

  test "external (non-workspace, non-stdlib) crate is silently dropped":
    # Mode 3 is in-workspace only; external crates like serde belong
    # to the Mode 2 (Cargo) path. The scanner doesn't fail loudly —
    # it just emits no edge for the external import.
    let dir = makeScratch("external-crate-use")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package solo:
  uses:
    "rust"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.rs", """
use serde::Deserialize;
use tokio::runtime::Runtime;
fn main() {}
""")
    let scan = scanWorkspaceRust(dir)
    check scan.members.len == 1
    check scan.edges.len == 0
    removeDir(dir)

  test "layout B: two packages in one project file with per-member subdirs":
    # The canonical multi-package shape used by the M30 fixture.
    let dir = makeScratch("layout-b-multi-package")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package mathlibPkg:
  uses:
    "rust"
  library mathlib

package calcPkg:
  uses:
    "rust"
  executable calc:
    discard
""")
    createDir(dir / "mathlib")
    createDir(dir / "mathlib" / "src")
    writeFile(dir / "mathlib" / "src" / "lib.rs",
      "pub fn add(a: i32, b: i32) -> i32 { a + b }\n")
    createDir(dir / "calc")
    createDir(dir / "calc" / "src")
    writeFile(dir / "calc" / "src" / "main.rs",
      "use mathlib::add;\nfn main() { println!(\"{}\", add(1, 2)); }\n")
    let scan = scanWorkspaceRust(dir)
    check scan.members.len == 2
    check scan.edges.len == 1
    check scan.edges[0].fromPackage == "calcPkg"
    check scan.edges[0].toPackage == "mathlibPkg"
    removeDir(dir)

  test "self-use (same package's own crate name) does NOT emit an edge":
    let dir = makeScratch("self-use")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package soloPkg:
  uses:
    "rust"
  library foo
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "lib.rs", """
// Same-crate self-import via the package-name index — should NOT
// produce a workspace edge.
extern crate soloPkg;
pub fn helper() -> i32 { 7 }
""")
    let scan = scanWorkspaceRust(dir)
    check scan.members.len == 1
    check scan.edges.len == 0
    removeDir(dir)

  test "intra-crate use crate::... never produces an edge":
    let dir = makeScratch("intra-crate-use")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package solo:
  uses:
    "rust"
  library foo
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "lib.rs", """
use crate::helper::inner;
use self::sibling::Other;
use super::parent::Up;
pub fn run() {}
""")
    let scan = scanWorkspaceRust(dir)
    check scan.members.len == 1
    check scan.edges.len == 0
    removeDir(dir)

suite "repro_core.rust_dep_scanner: determinism":

  test "two runs over the same workspace produce byte-identical edges":
    let dir = makeScratch("determinism")
    createDir(dir / "alpha")
    writeFile(dir / "alpha" / "repro.nim", """
import repro_project_dsl

package alpha:
  uses:
    "rust"
  library alpha
""")
    createDir(dir / "alpha" / "src")
    writeFile(dir / "alpha" / "src" / "lib.rs",
      "pub fn alpha_core() -> i32 { 1 }\n")

    createDir(dir / "beta")
    writeFile(dir / "beta" / "repro.nim", """
import repro_project_dsl

package beta:
  uses:
    "rust"
  executable beta:
    discard
""")
    createDir(dir / "beta" / "src")
    writeFile(dir / "beta" / "src" / "main.rs",
      "use alpha::alpha_core;\nfn main() { println!(\"{}\", alpha_core()); }\n")
    let first = scanWorkspaceRust(dir)
    let second = scanWorkspaceRust(dir)
    check first.edges.len == second.edges.len
    check first.edges.len >= 1
    for i in 0 ..< first.edges.len:
      check first.edges[i].fromPackage == second.edges[i].fromPackage
      check first.edges[i].toPackage == second.edges[i].toPackage
      check first.edges[i].evidence == second.edges[i].evidence
    removeDir(dir)

suite "repro_core.rust_dep_scanner: rendered output":

  test "renderScannedDepsFile emits the expected depends_on block for a Rust edge":
    let dir = makeScratch("rendered-output")
    createDir(dir / "mathlib")
    writeFile(dir / "mathlib" / "repro.nim", """
import repro_project_dsl

package mathlibPkg:
  uses:
    "rust"
  library mathlib
""")
    createDir(dir / "mathlib" / "src")
    writeFile(dir / "mathlib" / "src" / "lib.rs",
      "pub fn add(a: i32, b: i32) -> i32 { a + b }\n")

    createDir(dir / "calc")
    writeFile(dir / "calc" / "repro.nim", """
import repro_project_dsl

package calcPkg:
  uses:
    "rust"
  executable calc:
    discard
""")
    createDir(dir / "calc" / "src")
    writeFile(dir / "calc" / "src" / "main.rs",
      "use mathlib::add;\nfn main() { let _ = add(1, 2); }\n")
    let scan = scanWorkspaceRust(dir)
    let rendered = renderScannedDepsFile(scan.edges, "0.1.0", scan.members,
      dir)
    check rendered.contains("DO NOT EDIT")
    check rendered.contains("depends_on calcPkg: mathlibPkg")
    check rendered.contains("main.rs:") # evidence comment
    removeDir(dir)

suite "repro_core.rust_dep_scanner: unified multi-language scan":

  test "scanWorkspaceAll unions Nim, C/C++, and Rust members + edges deterministically":
    # A mixed workspace: one Nim package + a Rust library + a Rust
    # executable. Each package lives in its own directory under the
    # workspace root.
    let dir = makeScratch("multi-language")
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

    createDir(dir / "rust-lib")
    writeFile(dir / "rust-lib" / "repro.nim", """
import repro_project_dsl

package rustLib:
  uses:
    "rust"
  library rustLib
""")
    createDir(dir / "rust-lib" / "src")
    writeFile(dir / "rust-lib" / "src" / "lib.rs",
      "pub fn answer() -> i32 { 42 }\n")

    createDir(dir / "rust-app")
    writeFile(dir / "rust-app" / "repro.nim", """
import repro_project_dsl

package rustApp:
  uses:
    "rust"
  executable rustApp:
    discard
""")
    createDir(dir / "rust-app" / "src")
    writeFile(dir / "rust-app" / "src" / "main.rs",
      "use rustLib::answer;\nfn main() { println!(\"{}\", answer()); }\n")
    let unified = scanWorkspaceAll(dir)
    var nimSeen = false
    var rustLibSeen = false
    var rustAppSeen = false
    for m in unified.members:
      if m.package == "nimSolo": nimSeen = true
      if m.package == "rustLib": rustLibSeen = true
      if m.package == "rustApp": rustAppSeen = true
    check nimSeen
    check rustLibSeen
    check rustAppSeen
    var rustEdgeFound = false
    for e in unified.edges:
      if e.fromPackage == "rustApp" and e.toPackage == "rustLib":
        rustEdgeFound = true
    check rustEdgeFound
    removeDir(dir)
