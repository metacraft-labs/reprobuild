## Asking for the version must not provision a project's pinned toolchain.
##
## `applyProjectPinsAtEntry` runs before any dispatch. When the project pins a
## provider compiler it realizes that compiler first (which can mean a
## download or a source build), unless `needsProviderToolchain` says the
## invocation can never compile a provider. `repro --version` is exempt; the
## `repro version` verb answers the same question and must be exempt too,
## with or without `--json` or a help flag. A verb that does compile a
## provider (`build`) must still realize it.
##
## *Mocking.* None: the decision is a pure function of the argv, read through
## `{.all.}` so it does not have to become public API.

import std/unittest

import repro_cli_support/project_pins {.all.}

suite "the version verb realizes no pinned toolchain":
  test "every spelling of the version request is exempt":
    check not needsProviderToolchain(["--version"])
    check not needsProviderToolchain(["-V"])
    check not needsProviderToolchain(["version"])
    check not needsProviderToolchain(["version", "--json"])
    check not needsProviderToolchain(["version", "--help"])

  test "a verb that compiles providers still realizes the pin":
    check needsProviderToolchain(["build"])
