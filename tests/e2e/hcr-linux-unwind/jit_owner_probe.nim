## HLX-M5 — the duplicate-`__jit_debug_descriptor` probe.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §8.3, last paragraph:
## both agents emit `__jit_debug_descriptor` and `__jit_debug_register_code`,
## "so linking the C and Nim agents into one binary produces duplicate symbols.
## The Linux port must pick one owner".
##
## This is that binary. It links `repro_hcr_agent.c` — which owns the two
## symbols on Linux — AND imports `repro_hcr_agent/debug_unwind`, the module
## that used to emit its own copy. The measurement is in two parts and both are
## made by `integration_hcr_linux_jit_symfile_accepted_by_gdb`:
##
##   1. THE LINK SUCCEEDS. With two owners it does not; `ld` refuses with
##      "multiple definition of `__jit_debug_descriptor`". The falsifier
##      `-d:reproHcrFalsifyDuplicateJitOwner` puts the second definition back
##      so that refusal can be observed rather than assumed.
##   2. `nm` reports EXACTLY ONE defined `__jit_debug_descriptor` and exactly
##      one defined `__jit_debug_register_code`. A count, not a presence check:
##      the debugger looks both up by name and one name must have one answer.
##
## It is deliberately not named `t_*`, so the suite walker does not enrol it as
## a gate of its own — it is an input to one.

import std/os

const agentCSource = currentSourcePath.parentDir.parentDir.parentDir.parentDir /
  "libs" / "repro_hcr_agent" / "c" / "repro_hcr_agent.c"
const agentCDir = agentCSource.parentDir

{.passC: "-D_GNU_SOURCE -I" & agentCDir.}
{.compile: agentCSource.}

import repro_hcr_agent/debug_unwind

proc main() =
  # Touch the module so nothing can decide it was unused and drop it. The
  # value is irrelevant; the LINK is the subject.
  echo "jit-owner-probe ok api=", UnwindRegistrationEvidence().api.len

main()
