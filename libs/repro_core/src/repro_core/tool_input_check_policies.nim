## The input-check policy a tool declares for the edges that run it
## (Caching-Architecture.md, decision D2).
##
## THE DECLARATION is ``inputCheckPolicy hybrid`` in the tool's ``cli:`` block
## in ``repro_dsl_stdlib``. A typed call of the tool takes it as the default of
## its ``actionCachePolicy`` formal, so that path needs nothing from here.
##
## THIS TABLE is for the other path: an edge that names the tool only in its
## ``toolIdentityRefs`` -- the C convention's ``inlineExecCall`` compile,
## archive and link edges (``toolIdentityRefs = @["gcc"]`` / ``@["ar"]``), and
## a build file's ``buildAction(…, toolIdentityRefs = @["gcc"])``. Lowering
## (``repro_cli_support.lowerGraphAction``) resolves an edge that states no
## policy against the refs that RESOLVED to a tool profile, and the CLI spec
## is not available there: it is compiled into the recipe provider, and the
## lowering sees only the recorded call. So, as with
## ``entropy_blessings.EntropyBlessedTools``, the per-tool half is a constant
## in the lowest library both sides can see, and
## ``libs/repro_dsl_stdlib/tests/t_tool_input_check_policies.nim`` asserts
## that every entry is backed by the same declaration on a real registered
## edge of that tool. An entry whose spec stops declaring fails that test; the
## table cannot become a second, independent authority.
##
## WHY ``hybrid`` FOR THESE THREE. Both ``hybrid`` and ``checksum`` record a
## content hash for every regular-file input, which is what a record shared
## across checkouts needs (Edge-Derived-Identities.md §3.3a). ``hybrid`` keeps
## the warm no-op consultation at one ``lstat`` per unchanged input and hashes
## only an input whose metadata moved. A compile, an archive and a link are
## pure functions of their inputs' bytes, so nothing about them needs the
## timestamp policy's weaker evidence.
##
## Keyed by the bare PACKAGE name of the profile a ref resolved to (the
## ``uses:`` selector without its constraint), with the executable name as a
## second key: in tarball mode the ``ar`` a C convention edge names resolves
## to the ``gcc`` package's exported archiver, and that profile is ``gcc``'s.

import std/options

import repro_core/input_check_policy

type
  ToolInputCheckPolicy* = object
    tool*: string
      ## The package (or executable) name the declaration is made for.
    policy*: FileFingerprintPolicy
    spec*: string
      ## The stdlib file that carries the ``cli:`` declaration, relative to
      ## the repository root: what a diagnostic sends a reader to.

const ToolInputCheckPolicies*: seq[ToolInputCheckPolicy] = @[
  ToolInputCheckPolicy(tool: "gcc", policy: ffpHybrid,
    spec: "libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/gcc.nim"),
  ToolInputCheckPolicy(tool: "clang", policy: ffpHybrid,
    spec: "libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/clang.nim"),
  ToolInputCheckPolicy(tool: "ar", policy: ffpHybrid,
    spec: "libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/binutils.nim"),
]

proc toolDeclaredInputCheckPolicy*(tool: string): Option[FileFingerprintPolicy] =
  ## The policy `tool` declares, or none.
  for entry in ToolInputCheckPolicies:
    if entry.tool == tool:
      return some(entry.policy)
  none(FileFingerprintPolicy)

proc strongestInputCheckPolicy*(a, b: FileFingerprintPolicy):
    FileFingerprintPolicy =
  ## D2: when an edge names several declaring tools, the strongest wins --
  ## ``checksum`` over ``hybrid`` over ``timestamp``.
  proc rank(p: FileFingerprintPolicy): int =
    case p
    of ffpTimestamp: 0
    of ffpHybrid: 1
    of ffpChecksum: 2
  if rank(b) > rank(a): b else: a
