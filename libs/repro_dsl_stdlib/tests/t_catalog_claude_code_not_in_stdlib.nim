## `claude-code` is NOT a built-in stdlib package.
##
## The canonical `claude-code` package is defined exactly once, in the
## reprobuild-llm-agent-packages repository (packages/interfaces/claude-code,
## packages/vendor/claude-code, published-interfaces/). The stdlib used to carry
## a second, duplicate `package `claude-code`` with tarball realizations
## (``packages/claude_code.nim``); it was removed so that a profile or project
## resolving `claude-code` gets the canonical definition and never a stdlib one.
##
## This test pins that removal: with only the stdlib linked, the name must be
## unknown to the engine's package registry and to the profile tool lookup, and
## must carry no tarball realizations. It is falsifiable: restoring the
## stdlib module (and its import in ``package_registry``) turns every check
## red. Lookups stay case- and separator-sensitive, so the old spelling
## `claude_code` is unknown too.
##
## Mocking: none; this reads the real registry.

import std/unittest

import repro_dsl_stdlib/package_registry
import repro_home_apply/package_catalog

suite "claude-code is not defined by the stdlib":
  test "the engine registry does not link a `claude-code` package":
    check not isLinkedPackage("claude-code")

  test "a profile resolving `claude-code` finds nothing in the stdlib":
    let use = profileToolUse("claude-code")
    check not use.known
    check use.useDef.tarballProvisioning.len == 0

  test "the legacy separator spelling is unknown as well":
    check not profileToolUse("claude_code").known
