## Verification: the half of the attestation chain that decides whether
## to believe a machine.
##
## ## Why this is its own library
##
## ``repro_attest`` holds the schemas and the backend seam, and the
## attestation agent is built on it. This library is built on
## ``repro_attest`` too — and the agent must never be built on *this*
## one. The agent sits inside every attested trusted computing base, and
## linking a verifier into it would ship the code that decides whether to
## trust into the thing being trusted. That rule shapes the daemon; its
## inverse is what this package boundary is for: **nothing in this
## library imports the agent**, so a verdict can never come to depend on
## the agent's internals to reach its conclusion.
##
## The separation is not a convention. ``t_verdict_enumerates_checks``
## walks the module closure of this library and refuses an edge into the
## agent's package.
##
## Submodules:
##   * ``repro_attest_verify/policy`` — the
##     ``reproos.attestation-policy.v1`` document: typed record and a
##     fail-closed reader that refuses an incoherent policy at parse
##     time, not one report at a time.
##   * ``repro_attest_verify/verdict`` — every check this build performs,
##     what came of each, and the three refusals that make a skip
##     unspellable as a pass.
##   * ``repro_attest_verify/evidence`` — reading backend-native
##     evidence, and the projection that makes "a verdict never rests on
##     the instance's own claims" a property of a type rather than of a
##     comment.
##   * ``repro_attest_verify/challenge`` — minting a nonce and
##     remembering when, so freshness can be bounded without a database.
##   * ``repro_attest_verify/verify`` — the driver, and the seam an
##     embedding caller with its own backend reader plugs into.
##   * ``repro_attest_verify/fetch`` — the command line's
##     ``--report-url``. Deliberately NOT imported by ``verify``: the
##     verifier proper touches no socket.

import ./repro_attest_verify/policy
import ./repro_attest_verify/verdict
import ./repro_attest_verify/evidence
import ./repro_attest_verify/challenge
import ./repro_attest_verify/verify

export policy, verdict, evidence, challenge, verify
