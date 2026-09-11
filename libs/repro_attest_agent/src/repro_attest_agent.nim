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
import ./repro_attest_agent/unit

export agent, httpd, limits, unit
