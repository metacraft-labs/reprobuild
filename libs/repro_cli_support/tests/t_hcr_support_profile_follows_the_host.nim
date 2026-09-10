## The HCR coordinator negotiates THIS host's support profile.
##
## `repro hcr coordinate` and the `repro watch --hcr-*` session both pinned
## `CodetracerHcrSupportProfile` to the literal
## `"macos-arm64-direct-hcr-in-codetracer-v1"`. A C agent compiled for a Linux
## host advertises `linux-x86_64-elf-direct-hcr-v1` in its hello and the session
## rejects a mismatch, so on Linux the shipped CLI could not complete a
## negotiation at all — every Linux user hit it on their first command, and the
## Linux HCR demo shipped a separate patch driver rather than use this CLI.
##
## ## What is asserted, and why not simply the constant
##
## Asserting `CodetracerHcrSupportProfile == "linux-…"` inside a
## `when defined(linux)` would restate the implementation's own
## `when defined(macosx)` selection in different words: both halves would move
## together under any edit, and the check would pass over a constant that had
## stopped meaning anything. So the file asserts three things that fail
## independently:
##
## 1. **Agreement with the agent.** `defaultDirectSupportProfile()` is what a C
##    agent built for this host puts in its hello, and negotiation compares the
##    two strings. That is the contract, it lives in a different module, and it
##    holds on hosts neither branch below names. This is the assertion that
##    would have caught the original defect on any Linux or Windows host.
## 2. **The spelling, keyed on `hostOS` rather than on `defined(...)`.** The
##    literal strings are the ones `HCR-Prototype-Milestones.md` documents under
##    "Linux Implemented Support Profiles" and the ones compiled into the agent
##    header, so a rename that updated only one side is caught.
## 3. **A consequence of the choice.** `hcrObjectSymbolFor` turns the profile
##    into the symbol name looked up in the patch object — Mach-O prefixes an
##    underscore, ELF does not. A profile constant that is right-looking but
##    routes to the wrong object format still fails here, which is the failure
##    the user actually experiences.
##
## Assertion 3 is what keeps 1 and 2 from being a pair of string comparisons
## that a wrong-but-consistent rename would satisfy.
##
## ## Test-double policy: NO mocks, doubles or fakes
##
## Nothing here is substituted. `CodetracerHcrSupportProfile`,
## `hcrObjectSymbolFor` and `defaultDirectSupportProfile` are the production
## definitions, imported from the production modules. The properties under test
## are compile-time host selection and a pure string transform, so there is no
## boundary to stand in for and no reason to introduce one.
##
## Everything runs inside `test` bodies: enumerating a Nim test binary with
## `--list-json` executes module scope and every `suite` body, so module-scope
## work would run once per enumeration as well as once per run.

import std/unittest

import repro_cli_support
import repro_hcr_agent

suite "HCR coordinator support profile follows the host":
  test "it matches what an agent compiled for this host advertises":
    # Negotiation compares these two strings; a mismatch is rejected. This is
    # the assertion that fails on every host where the constant is wrong, not
    # only the two named below.
    check defaultDirectSupportProfile().len > 0
    check CodetracerHcrSupportProfile == defaultDirectSupportProfile()

  test "on this host it is spelled as the milestone documents it":
    # `hostOS`, not `when defined(macosx)`: the implementation selects with
    # `defined(macosx)`, so reusing that spelling here would restate the
    # definition rather than check it.
    var checkedHost = ""
    case hostOS
    of "macosx":
      checkedHost = hostOS
      check CodetracerHcrSupportProfile ==
        "macos-arm64-direct-hcr-in-codetracer-v1"
    of "linux":
      checkedHost = hostOS
      check CodetracerHcrSupportProfile == "linux-x86_64-elf-direct-hcr-v1"
    else:
      checkpoint("no documented HCR support profile for hostOS=" & hostOS)
      fail()
    # Without this the `else` branch could be silently taken on a host that
    # matched neither arm, leaving a test that asserted nothing and passed.
    check checkedHost == hostOS

  test "the chosen profile routes to this host's object format":
    # The consequence a user sees: Mach-O files a C function's code under
    # `_name` and ELF under `name`, so a plausible-looking but wrong profile
    # produces a lookup for a symbol that cannot exist in the patch object.
    let symbol = hcrObjectSymbolFor(CodetracerHcrSupportProfile, "patchable")
    case hostOS
    of "macosx":
      check symbol == "_patchable"
    of "linux":
      check symbol == "patchable"
    else:
      checkpoint("no documented object-symbol form for hostOS=" & hostOS)
      fail()

  test "the macOS profile keeps its Mach-O symbol form on every host":
    # Guards the other direction: the parameterisation must not have turned
    # `hcrObjectSymbolFor` into something host-derived. Passing the macOS
    # profile explicitly must still answer Mach-O, and the Linux profile ELF,
    # whichever host is running this.
    check hcrObjectSymbolFor(
      "macos-arm64-direct-hcr-in-codetracer-v1", "patchable") == "_patchable"
    check hcrObjectSymbolFor(
      "linux-x86_64-elf-direct-hcr-v1", "patchable") == "patchable"
