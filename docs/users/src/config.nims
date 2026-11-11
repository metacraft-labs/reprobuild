# Sibling-repo paths for the reprobuild documentation site, mirroring
# isonim/docs/users/config.nims. The site is an isonim-docs consumer: the
# framework and its dependencies are separate repositories checked out next
# to this one (../isonim-docs, ../isonim, ...), as in a reprobuild workspace
# or as the deploy workflow clones them.
#
# It sits in src/, next to the entry points, and every recipe compiles with
# --skipParentCfg: Nim would otherwise also apply the config files of every
# parent directory, including the reprobuild engine's own config.nims at the
# repository root, which has nothing to do with this site. This file repeats
# the paths isonim-docs' own config.nims sets up, adjusted for this package's
# depth (docs/users/src/).
import std/os

let root = currentSourcePath().parentDir()
# The directory holding the sibling checkouts: <checkout>/docs/users/src/../../../..
let siblingRoot = getEnv("REPRO_DOCS_SIBLING_ROOT", root / "../../../..")

switch("path", siblingRoot / "isonim/src")
switch("path", siblingRoot / "isonim-docs/src") ## the framework (isonim-docs)
switch("path", siblingRoot / "codetracer-design-system/nim") ## the shared Metacraft docs theme
switch("path", siblingRoot / "nim-everywhere/src")
switch("path", siblingRoot / "nim-faststreams")
switch("path", siblingRoot / "nim-stew")
switch("path", siblingRoot / "isonim/vendor/chronicles")
switch("path", siblingRoot / "isonim/vendor/serialization")
switch("path", siblingRoot / "isonim/vendor/json_serialization")
switch("define", "chronicles_sinks=textlines[stderr]")
switch("define", "chronicles_runtime_filtering=on")
switch("define", "chronicles_log_level=INFO")
