## Windows-Runner-Binary-Cache-Deploy M5 — reprobuild deploy agent.
##
## Umbrella module. Users ``import repro_deploy_agent`` and get the signed
## desired-state manifest codec + the poll/verify/monotonic-apply agent
## core + the durable per-tick status record. The production apply hook
## (``mkRunInfraApplyHook``) lives in the ``repro_deploy_agent/apply_hook``
## submodule so consumers that only need the manifest + agent core don't
## pull in the ``repro_infra`` apply tree.

import repro_deploy_agent/manifest
import repro_deploy_agent/agent
import repro_deploy_agent/tick_status

export manifest, agent, tick_status
