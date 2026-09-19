## The attestation agent: a small daemon that answers a challenge with
## evidence from whatever root of trust the machine has.
##
## Submodules:
##   * ``repro_attest_agent/limits`` — the request-size bounds and the
##     two-bucket rate limiter, applied before a request is understood.
##   * ``repro_attest_agent/httpd`` — a bounded HTTP/1.1 server over
##     ``std/net``, and nothing else.
##   * ``repro_attest_agent/agent`` — what each endpoint means and what
##     it refuses. Pure in the agent's state and the clock.
##   * ``repro_attest_agent/secrets`` — where a released secret is
##     allowed to land, and the ``statfs`` that makes "in memory only" a
##     checked property rather than a deployment convention.
##   * ``repro_attest_agent/remote_unseal`` — the other direction: an
##     early-boot client that attests to a broker for the key to this
##     machine's own state volumes, and whose refusal carries no key as a
##     property of the type rather than of the caller's care.
##   * ``repro_attest_agent/unseal_cli`` — the command that drives it and
##     runs the volume opener, with exactly one call site for the opener,
##     inside the callback a refusal never enters.
##   * ``repro_attest_agent/unit`` — the service unit, rendered by the
##     daemon it starts, so a flag has one spelling.
##   * ``repro_attest_agent/cli`` — the command line, including the
##     ``systemd-unit`` subcommand the image build calls. It is a library
##     module rather than the app's body so that a gate can render a unit
##     and feed its ``ExecStart`` back through the parser that will read
##     it at boot.
##
## The backend seam and the mock backend live in ``repro_attest``
## alongside the evidence model, because a driver produces evidence and
## every later backend implements against them rather than against this
## daemon.
##
## ## Mocking
##
## None.

import ./repro_attest_agent/agent
import ./repro_attest_agent/httpd
import ./repro_attest_agent/limits
import ./repro_attest_agent/secrets
import ./repro_attest_agent/unit

export agent, httpd, limits, secrets, unit
