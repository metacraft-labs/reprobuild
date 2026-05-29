## Unit tests for ``repro_core/jsts_dep_scanner`` — the Mode 3 JS/TS
## dependency scanner.
##
## Each test below pins one slice of the scanner contract documented
## in ``reprobuild-specs/Three-Mode-Convention-System.md`` §"The
## scanner contract", restated for the JS/TS side:
##
##   * member discovery filters by layout: a member without an
##     ``index.{ts,js}`` / ``main.{ts,js}`` entry file (Layout B-src
##     / Layout B-flat / Layout A) doesn't appear in the JS/TS
##     scanner's member list.
##   * ESM ``import X from "Y"`` / ``import { a } from "Y"`` /
##     ``import * as X from "Y"`` / ``import "Y"`` / ``import("Y")`` /
##     ``export ... from "Y"`` / CommonJS ``require("Y")`` emit a
##     workspace edge when the head resolves to another in-workspace
##     member.
##   * Node builtin heads (``fs`` / ``path`` / ``http`` / ``crypto`` /
##     ``node:fs`` / ...) NEVER produce an edge.
##   * Third-party (external) heads (anything not Node-builtin AND not
##     in-workspace) are silently dropped — Mode 3 is in-workspace
##     only.
##   * the scanner is byte-deterministic: two runs over the same tree
##     produce identical sorted edge lists.
##   * the unified ``scanWorkspaceAll`` merges Nim + Rust + Go +
##     Python + JS/TS outputs with stable ordering across mixed-
##     language workspaces.

import std/[os, strutils, unittest]

import repro_core

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-core-jsts-dep-scanner-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "repro_core.jsts_dep_scanner: import extraction":

  test "extractJsTsImportRefs picks up basic ESM imports":
    let text = """
// import comment_ignored
import { add } from "mathlib";
import * as m from "mathlib";
import defaultExport from "mathlib";
import "side-effect-only";
"""
    let refs = extractJsTsImportRefs(text)
    check refs.len == 4
    check refs[0].head == "mathlib"
    check refs[0].lineNumber == 2
    check refs[1].head == "mathlib"
    check refs[2].head == "mathlib"
    check refs[3].head == "side-effect-only"

  test "extractJsTsImportRefs handles dynamic import() with string literal":
    let text = """
const m = await import("mathlib");
const dyn = await import("./local");
const n = await import("fs");
"""
    let refs = extractJsTsImportRefs(text)
    check refs.len == 3
    check refs[0].head == "mathlib"
    # Relative specifier — empty head so the resolver drops it.
    check refs[1].head == ""
    check refs[2].head == "fs"

  test "extractJsTsImportRefs handles require() (CommonJS)":
    let text = """
const m = require("mathlib");
const fs = require("fs");
const local = require("./util");
"""
    let refs = extractJsTsImportRefs(text)
    check refs.len == 3
    check refs[0].head == "mathlib"
    check refs[1].head == "fs"
    check refs[2].head == ""  # relative

  test "extractJsTsImportRefs handles 'export ... from \"...\"' re-exports":
    let text = """
export { add } from "mathlib";
export * from "mathlib";
export * as ns from "mathlib";
export type { Foo } from "mathlib";
"""
    let refs = extractJsTsImportRefs(text)
    check refs.len == 4
    for r in refs:
      check r.head == "mathlib"

  test "extractJsTsImportRefs handles 'import type' shape":
    let text = """
import type { Foo } from "mathlib";
import { type Bar, baz } from "mathlib";
"""
    let refs = extractJsTsImportRefs(text)
    check refs.len == 2
    check refs[0].head == "mathlib"
    check refs[1].head == "mathlib"

  test "extractJsTsImportRefs handles scoped packages (@scope/pkg)":
    let text = """
import { add } from "@scope/mathlib";
import { sub } from "@scope/mathlib/sub";
"""
    let refs = extractJsTsImportRefs(text)
    check refs.len == 2
    check refs[0].head == "@scope/mathlib"
    check refs[1].head == "@scope/mathlib"  # head is two segments

  test "extractJsTsImportRefs handles sub-paths ('mathlib/sub' -> 'mathlib')":
    let text = """
import { add } from "mathlib/sub/path";
"""
    let refs = extractJsTsImportRefs(text)
    check refs.len == 1
    check refs[0].head == "mathlib"

  test "isNodeBuiltinModule recognises Node builtins + node: prefix":
    check isNodeBuiltinModule("fs")
    check isNodeBuiltinModule("path")
    check isNodeBuiltinModule("http")
    check isNodeBuiltinModule("crypto")
    check isNodeBuiltinModule("os")
    check isNodeBuiltinModule("node:fs")
    check isNodeBuiltinModule("node:path")
    check not isNodeBuiltinModule("mathlib")
    check not isNodeBuiltinModule("@scope/mathlib")
    check not isNodeBuiltinModule("react")
    check not isNodeBuiltinModule("")

  test "stripJsTsLineComments respects string literals":
    # The line-comment stripper must not chop inside a string literal.
    let text = """
import { add } from "mathlib"; // tail comment
const s = "// not a comment";
import { sub } from "mathlib";
"""
    let refs = extractJsTsImportRefs(text)
    check refs.len == 2
    check refs[0].head == "mathlib"
    check refs[1].head == "mathlib"

  test "extractBareSpecifierHead drops relative and absolute paths":
    check extractBareSpecifierHead("mathlib") == "mathlib"
    check extractBareSpecifierHead("mathlib/sub") == "mathlib"
    check extractBareSpecifierHead("./local") == ""
    check extractBareSpecifierHead("../sibling") == ""
    check extractBareSpecifierHead("/abs/path") == ""
    check extractBareSpecifierHead("@scope/pkg") == "@scope/pkg"
    check extractBareSpecifierHead("@scope/pkg/sub") == "@scope/pkg"
    check extractBareSpecifierHead("") == ""

suite "repro_core.jsts_dep_scanner: edge inference":

  test "executable importing a library package emits one edge":
    let dir = makeScratch("two-package-import")
    # Layout B-src: <member>/src/<entry>.ts
    createDir(dir / "mathlib" / "src")
    writeFile(dir / "mathlib" / "src" / "index.ts",
      "export function add(a: number, b: number): number { return a + b; }\n")
    createDir(dir / "calc" / "src")
    writeFile(dir / "calc" / "src" / "main.ts", """
import { add } from "mathlib";
console.log("mathlib added 2+3 =", add(2, 3));
""")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package mathlibPkg:
  uses:
    "typescript"
  library mathlib

package calcPkg:
  uses:
    "typescript"
  executable calc:
    discard
""")
    let scan = scanWorkspaceJsTs(dir)
    check scan.members.len == 2
    check scan.edges.len == 1
    check scan.edges[0].fromPackage == "calcPkg"
    check scan.edges[0].toPackage == "mathlibPkg"
    check scan.edges[0].evidence.contains("main.ts:")
    check scan.edges[0].evidence.contains("import { add } from \"mathlib\";")
    removeDir(dir)

  test "Node builtin imports (fs, path, http) never produce an edge":
    let dir = makeScratch("node-builtins-only")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package solo:
  uses:
    "typescript"
  executable hello:
    discard
""")
    createDir(dir / "hello" / "src")
    writeFile(dir / "hello" / "src" / "main.ts", """
import { readFile } from "fs";
import { join } from "path";
import * as http from "http";
import { createHash } from "node:crypto";
console.log("hi");
""")
    let scan = scanWorkspaceJsTs(dir)
    check scan.members.len == 1
    check scan.edges.len == 0
    removeDir(dir)

  test "third-party imports (react, lodash, @scope/pkg) are silently dropped":
    # Mode 3 is in-workspace only; external imports belong to the
    # Mode 2 (package.json) path. The scanner emits no edge for them.
    let dir = makeScratch("thirdparty-imports")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package solo:
  uses:
    "typescript"
  executable hello:
    discard
""")
    createDir(dir / "hello" / "src")
    writeFile(dir / "hello" / "src" / "main.ts", """
import * as React from "react";
import { debounce } from "lodash";
import { something } from "@scope/pkg";
console.log("would render");
""")
    let scan = scanWorkspaceJsTs(dir)
    check scan.members.len == 1
    check scan.edges.len == 0
    removeDir(dir)

  test "layout B-flat: per-member <pkg>/index.ts works (no src/)":
    let dir = makeScratch("layout-b-flat")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package mathlibPkg:
  uses:
    "typescript"
  library mathlib

package calcPkg:
  uses:
    "typescript"
  executable calc:
    discard
""")
    createDir(dir / "mathlib")
    writeFile(dir / "mathlib" / "index.ts",
      "export function add(a: number, b: number): number { return a + b; }\n")
    createDir(dir / "calc")
    writeFile(dir / "calc" / "main.ts", """
import { add } from "mathlib";
console.log(add(1, 2));
""")
    let scan = scanWorkspaceJsTs(dir)
    check scan.members.len == 2
    check scan.edges.len == 1
    check scan.edges[0].fromPackage == "calcPkg"
    check scan.edges[0].toPackage == "mathlibPkg"
    removeDir(dir)

  test "members without an entry file are skipped (layout filter)":
    # A member with random .ts files but no recognised entry file
    # (``index.{ts,js}`` / ``main.{ts,js}``) doesn't make the scanner's
    # member list. Mirror of the Python PEP 420 case.
    let dir = makeScratch("no-entry-file")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package nsPkg:
  uses:
    "typescript"
  library ns
""")
    createDir(dir / "ns" / "src")
    writeFile(dir / "ns" / "src" / "helper.ts",
      "export function fn(): number { return 42; }\n")
    # Note: NO index.ts / main.ts under ns/src/
    let scan = scanWorkspaceJsTs(dir)
    check scan.members.len == 0
    removeDir(dir)

  test "multi-pkg workspace with chains: a -> b -> c":
    let dir = makeScratch("multi-pkg-chain")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package pkgA:
  uses:
    "typescript"
  library a

package pkgB:
  uses:
    "typescript"
  library b

package pkgC:
  uses:
    "typescript"
  executable c:
    discard
""")
    createDir(dir / "a" / "src")
    writeFile(dir / "a" / "src" / "index.ts",
      "export function aFn(): number { return 1; }\n")
    createDir(dir / "b" / "src")
    writeFile(dir / "b" / "src" / "index.ts", """
import { aFn } from "a";
export function bFn(): number { return aFn() + 1; }
""")
    createDir(dir / "c" / "src")
    writeFile(dir / "c" / "src" / "main.ts", """
import { bFn } from "b";
console.log(bFn());
""")
    let scan = scanWorkspaceJsTs(dir)
    check scan.members.len == 3
    check scan.edges.len == 2
    var sawBA = false
    var sawCB = false
    for e in scan.edges:
      if e.fromPackage == "pkgB" and e.toPackage == "pkgA":
        sawBA = true
      if e.fromPackage == "pkgC" and e.toPackage == "pkgB":
        sawCB = true
    check sawBA
    check sawCB
    removeDir(dir)

  test "JavaScript (no TypeScript) workspace also works":
    let dir = makeScratch("js-only")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package mathlibPkg:
  uses:
    "node"
  library mathlib

package calcPkg:
  uses:
    "node"
  executable calc:
    discard
""")
    createDir(dir / "mathlib" / "src")
    writeFile(dir / "mathlib" / "src" / "index.js", """
exports.add = function(a, b) { return a + b; };
""")
    createDir(dir / "calc" / "src")
    writeFile(dir / "calc" / "src" / "main.js", """
const { add } = require("mathlib");
console.log(add(2, 3));
""")
    let scan = scanWorkspaceJsTs(dir)
    check scan.members.len == 2
    check scan.edges.len == 1
    check scan.edges[0].fromPackage == "calcPkg"
    check scan.edges[0].toPackage == "mathlibPkg"
    removeDir(dir)

suite "repro_core.jsts_dep_scanner: determinism":

  test "two runs over the same workspace produce byte-identical edges":
    let dir = makeScratch("determinism")
    createDir(dir / "alpha" / "src")
    writeFile(dir / "alpha" / "src" / "index.ts",
      "export function hi(): number { return 1; }\n")
    createDir(dir / "beta" / "src")
    writeFile(dir / "beta" / "src" / "main.ts", """
import { hi } from "alpha";
console.log(hi());
""")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package alphaPkg:
  uses:
    "typescript"
  library alpha

package betaPkg:
  uses:
    "typescript"
  executable beta:
    discard
""")
    let s1 = scanWorkspaceJsTs(dir)
    let s2 = scanWorkspaceJsTs(dir)
    check s1.edges.len == s2.edges.len
    for i in 0 ..< s1.edges.len:
      check s1.edges[i].fromPackage == s2.edges[i].fromPackage
      check s1.edges[i].toPackage == s2.edges[i].toPackage
      check s1.edges[i].evidence == s2.edges[i].evidence
    removeDir(dir)

suite "repro_core.jsts_dep_scanner: scanWorkspaceAll integration":

  test "scanWorkspaceAll merges JS/TS members + edges into the unified result":
    let dir = makeScratch("merge-jsts-into-all")
    createDir(dir / "mathlib" / "src")
    writeFile(dir / "mathlib" / "src" / "index.ts",
      "export function add(a: number, b: number): number { return a + b; }\n")
    createDir(dir / "calc" / "src")
    writeFile(dir / "calc" / "src" / "main.ts", """
import { add } from "mathlib";
console.log(add(2, 3));
""")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package mathlibPkg:
  uses:
    "typescript"
  library mathlib

package calcPkg:
  uses:
    "typescript"
  executable calc:
    discard
""")
    let unified = scanWorkspaceAll(dir)
    # The unified result must include both JS/TS-discovered members
    # and the JS/TS edge.
    var sawMathlib = false
    var sawCalc = false
    for m in unified.members:
      if m.package == "mathlibPkg" and m.member == "mathlib":
        sawMathlib = true
      if m.package == "calcPkg" and m.member == "calc":
        sawCalc = true
    check sawMathlib
    check sawCalc
    var sawCalcToMathlib = false
    for e in unified.edges:
      if e.fromPackage == "calcPkg" and e.toPackage == "mathlibPkg":
        sawCalcToMathlib = true
    check sawCalcToMathlib
    removeDir(dir)
