## ReproOS Agent Integration Protocol: the integration host, its
## capability model, approvals, audit log and wire codec.
##
## Spec: reprobuild-pm `spec/ReproOS-Agent-Integration-Protocol.md`.

import ./repro_agent_protocol/[types, capabilities, canonical, paths, audit,
                               host, wire, surface]

export types, capabilities, canonical, paths, audit, host, wire, surface
