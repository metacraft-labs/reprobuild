## Unit tests for ``repro_core/python_dep_scanner`` — the Mode 3
## Python dependency scanner.
##
## Each test below pins one slice of the scanner contract documented
## in ``reprobuild-specs/Three-Mode-Convention-System.md`` §"The
## scanner contract", restated for the Python side:
##
##   * member discovery filters by layout: a package without
##     ``__init__.py`` (e.g. PEP 420 namespace pkg) doesn't appear in
##     the Python scanner's member list.
##   * ``import X`` / ``from X import Y`` (single + grouped) emit a
##     workspace edge when the head resolves to another in-workspace
##     member.
##   * Stdlib heads (``sys`` / ``os`` / ``json`` / ``typing`` / ...)
##     NEVER produce an edge.
##   * Third-party heads (anything not stdlib AND not in-workspace)
##     are silently dropped — Mode 3 is in-workspace only.
##   * the scanner is byte-deterministic: two runs over the same tree
##     produce identical sorted edge lists.
##   * the unified ``scanWorkspaceAll`` merges Nim + Rust + Go +
##     Python outputs with stable ordering across mixed-language
##     workspaces.

import std/[os, strutils, unittest]

import repro_core

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-core-python-dep-scanner-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "repro_core.python_dep_scanner: import extraction":

  test "extractPythonImportRefs picks up single-line imports":
    let text = """
# import comment_ignored
import os
import sys
import mathlib
from typing import List
"""
    let refs = extractPythonImportRefs(text)
    check refs.len == 4
    check refs[0].head == "os"
    check refs[0].lineNumber == 2
    check refs[1].head == "sys"
    check refs[2].head == "mathlib"
    check refs[3].head == "typing"

  test "extractPythonImportRefs handles 'from X import (a, b)' grouped form (single-line)":
    let text = """
from mathlib import (add, sub)
from os.path import join
"""
    let refs = extractPythonImportRefs(text)
    check refs.len == 2
    check refs[0].head == "mathlib"
    check refs[1].head == "os"

  test "extractPythonImportRefs handles multi-line grouped form":
    let text = """
from mathlib import (
    add,
    sub,
)
import os
"""
    let refs = extractPythonImportRefs(text)
    # The grouped form emits ONE ref (the head ``mathlib``); the
    # multi-line continuation is consumed so the following ``import
    # os`` is correctly seen as a separate statement.
    check refs.len == 2
    check refs[0].head == "mathlib"
    check refs[1].head == "os"

  test "extractPythonImportRefs handles dotted imports and 'as' aliases":
    let text = """
import foo.bar
import foo.bar.baz as fb
from foo.qux import zap
"""
    let refs = extractPythonImportRefs(text)
    check refs.len == 3
    check refs[0].head == "foo"
    check refs[1].head == "foo"
    check refs[2].head == "foo"

  test "extractPythonImportRefs handles comma-separated 'import a, b'":
    let text = """
import os, sys, mathlib
"""
    let refs = extractPythonImportRefs(text)
    check refs.len == 3
    check refs[0].head == "os"
    check refs[1].head == "sys"
    check refs[2].head == "mathlib"

  test "extractPythonImportRefs emits empty head for relative imports":
    let text = """
from . import sibling
from ..pkg import x
from .submod import y
"""
    let refs = extractPythonImportRefs(text)
    check refs.len == 3
    for r in refs:
      check r.head == ""

  test "isPythonStdlibModule recognises common stdlib heads":
    check isPythonStdlibModule("sys")
    check isPythonStdlibModule("os")
    check isPythonStdlibModule("json")
    check isPythonStdlibModule("typing")
    check isPythonStdlibModule("pathlib")
    check isPythonStdlibModule("argparse")
    check isPythonStdlibModule("subprocess")
    check isPythonStdlibModule("collections")
    check not isPythonStdlibModule("mathlib")
    check not isPythonStdlibModule("requests")
    check not isPythonStdlibModule("numpy")

  test "stripPythonLineComment respects string literals":
    # The line-comment stripper must not chop inside a string literal.
    let text = """
import mathlib  # tail comment
s = "# not a comment"
import os
"""
    let refs = extractPythonImportRefs(text)
    check refs.len == 2
    check refs[0].head == "mathlib"
    check refs[1].head == "os"

suite "repro_core.python_dep_scanner: edge inference":

  test "executable importing a library package emits one edge":
    let dir = makeScratch("two-package-import")
    # Layout B-flat: <member>/<member>/__init__.py
    createDir(dir / "mathlib" / "mathlib")
    writeFile(dir / "mathlib" / "mathlib" / "__init__.py",
      "def add(a, b):\n    return a + b\n")

    createDir(dir / "calc" / "calc")
    writeFile(dir / "calc" / "calc" / "__init__.py", "")
    writeFile(dir / "calc" / "calc" / "__main__.py", """
from mathlib import add
print("mathlib added 2+3 =", add(2, 3))
""")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package mathlibPkg:
  uses:
    "python3"
  library mathlib

package calcPkg:
  uses:
    "python3"
  executable calc:
    discard
""")
    let scan = scanWorkspacePython(dir)
    check scan.members.len == 2
    check scan.edges.len == 1
    check scan.edges[0].fromPackage == "calcPkg"
    check scan.edges[0].toPackage == "mathlibPkg"
    check scan.edges[0].evidence.contains("__main__.py:")
    check scan.edges[0].evidence.contains("from mathlib import add")
    removeDir(dir)

  test "stdlib imports (sys, os, json, typing) never produce an edge":
    let dir = makeScratch("stdlib-only-import")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package solo:
  uses:
    "python3"
  executable hello:
    discard
""")
    createDir(dir / "hello" / "hello")
    writeFile(dir / "hello" / "hello" / "__init__.py", "")
    writeFile(dir / "hello" / "hello" / "__main__.py", """
import sys
import os
import json
from typing import List
from pathlib import Path
from argparse import ArgumentParser
print("hi")
""")
    let scan = scanWorkspacePython(dir)
    check scan.members.len == 1
    check scan.edges.len == 0
    removeDir(dir)

  test "third-party imports (requests, numpy) are silently dropped":
    # Mode 3 is in-workspace only; external imports belong to the
    # Mode 2 (pyproject.toml) path. The scanner emits no edge for
    # them.
    let dir = makeScratch("thirdparty-import")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package solo:
  uses:
    "python3"
  executable hello:
    discard
""")
    createDir(dir / "hello" / "hello")
    writeFile(dir / "hello" / "hello" / "__init__.py", "")
    writeFile(dir / "hello" / "hello" / "__main__.py", """
import requests
import numpy as np
from sqlalchemy import create_engine
print("would call out")
""")
    let scan = scanWorkspacePython(dir)
    check scan.members.len == 1
    check scan.edges.len == 0
    removeDir(dir)

  test "layout B-src: per-member src/<pkg>/__init__.py works":
    let dir = makeScratch("layout-b-src")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package mathlibPkg:
  uses:
    "python3"
  library mathlib

package calcPkg:
  uses:
    "python3"
  executable calc:
    discard
""")
    createDir(dir / "mathlib" / "src" / "mathlib")
    writeFile(dir / "mathlib" / "src" / "mathlib" / "__init__.py",
      "def add(a, b):\n    return a + b\n")
    createDir(dir / "calc" / "src" / "calc")
    writeFile(dir / "calc" / "src" / "calc" / "__init__.py", "")
    writeFile(dir / "calc" / "src" / "calc" / "__main__.py", """
from mathlib import add
print(add(1, 2))
""")
    let scan = scanWorkspacePython(dir)
    check scan.members.len == 2
    check scan.edges.len == 1
    check scan.edges[0].fromPackage == "calcPkg"
    check scan.edges[0].toPackage == "mathlibPkg"
    removeDir(dir)

  test "members without __init__.py are skipped (PEP 420 not supported)":
    # PEP 420 namespace packages (no ``__init__.py``) are explicitly
    # out of scope for M32 — the scanner requires ``__init__.py``.
    let dir = makeScratch("pep420")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package nsPkg:
  uses:
    "python3"
  library ns
""")
    # Note: NO __init__.py at any level
    createDir(dir / "ns" / "ns")
    writeFile(dir / "ns" / "ns" / "mod.py",
      "def fn():\n    return 42\n")
    let scan = scanWorkspacePython(dir)
    check scan.members.len == 0
    removeDir(dir)

  test "multi-pkg workspace with chains: a -> b -> c":
    let dir = makeScratch("multi-pkg-chain")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package pkgA:
  uses:
    "python3"
  library a

package pkgB:
  uses:
    "python3"
  library b

package pkgC:
  uses:
    "python3"
  executable c:
    discard
""")
    createDir(dir / "a" / "a")
    writeFile(dir / "a" / "a" / "__init__.py",
      "def a_fn():\n    return 1\n")
    createDir(dir / "b" / "b")
    writeFile(dir / "b" / "b" / "__init__.py", """
from a import a_fn
def b_fn():
    return a_fn() + 1
""")
    createDir(dir / "c" / "c")
    writeFile(dir / "c" / "c" / "__init__.py", "")
    writeFile(dir / "c" / "c" / "__main__.py", """
from b import b_fn
print(b_fn())
""")
    let scan = scanWorkspacePython(dir)
    check scan.members.len == 3
    check scan.edges.len == 2
    # Two edges: pkgB -> pkgA, pkgC -> pkgB.
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

suite "repro_core.python_dep_scanner: determinism":

  test "two runs over the same workspace produce byte-identical edges":
    let dir = makeScratch("determinism")
    createDir(dir / "alpha" / "alpha")
    writeFile(dir / "alpha" / "alpha" / "__init__.py",
      "def hi():\n    return 1\n")
    createDir(dir / "beta" / "beta")
    writeFile(dir / "beta" / "beta" / "__init__.py", "")
    writeFile(dir / "beta" / "beta" / "__main__.py", """
from alpha import hi
print(hi())
""")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package alphaPkg:
  uses:
    "python3"
  library alpha

package betaPkg:
  uses:
    "python3"
  executable beta:
    discard
""")
    let first = scanWorkspacePython(dir)
    let second = scanWorkspacePython(dir)
    check first.edges.len == second.edges.len
    check first.edges.len >= 1
    for i in 0 ..< first.edges.len:
      check first.edges[i].fromPackage == second.edges[i].fromPackage
      check first.edges[i].toPackage == second.edges[i].toPackage
      check first.edges[i].evidence == second.edges[i].evidence
    removeDir(dir)

suite "repro_core.python_dep_scanner: unified multi-language scan":

  test "scanWorkspaceAll unions Nim + Python members + edges deterministically":
    # A mixed workspace: one Nim package + one Python library + one
    # Python executable importing the library.
    let dir = makeScratch("multi-language-python")
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

    createDir(dir / "py-lib" / "mathlib" / "mathlib")
    writeFile(dir / "py-lib" / "mathlib" / "mathlib" / "__init__.py",
      "def add(a, b):\n    return a + b\n")
    writeFile(dir / "py-lib" / "repro.nim", """
import repro_project_dsl

package pyLib:
  uses:
    "python3"
  library mathlib
""")

    createDir(dir / "py-app" / "calc" / "calc")
    writeFile(dir / "py-app" / "calc" / "calc" / "__init__.py", "")
    writeFile(dir / "py-app" / "calc" / "calc" / "__main__.py", """
from mathlib import add
print(add(2, 3))
""")
    writeFile(dir / "py-app" / "repro.nim", """
import repro_project_dsl

package pyApp:
  uses:
    "python3"
  executable calc:
    discard
""")
    let unified = scanWorkspaceAll(dir)
    var nimSeen = false
    var pyLibSeen = false
    var pyAppSeen = false
    for m in unified.members:
      if m.package == "nimSolo": nimSeen = true
      if m.package == "pyLib": pyLibSeen = true
      if m.package == "pyApp": pyAppSeen = true
    check nimSeen
    check pyLibSeen
    check pyAppSeen
    var pyEdgeFound = false
    for e in unified.edges:
      if e.fromPackage == "pyApp" and e.toPackage == "pyLib":
        pyEdgeFound = true
    check pyEdgeFound
    removeDir(dir)
