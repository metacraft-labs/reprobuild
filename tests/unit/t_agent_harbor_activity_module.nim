## ReproOS-Agent-Harbor-Integration M1 deliverables 2 and 4 at module
## level: the typed `agent-harbor` activity renders the host and agent
## user units, the desktop entry and the host's policy file from a
## validated configuration; no-agent mode is a supported configuration; and
## a secret can never reach a rendered file, because a value shaped like
## one is refused where a credential handle belongs.
##
## Pure functions of the configuration; nothing to mock.

import std/[strutils, unittest]

import repro_dsl_stdlib/packages/system/agent_harbor

const
  Host = "/run/current-system/sw/bin/reproos-agent-host"
  Ah = "/run/current-system/sw/bin/ah"
  Gui = "/run/current-system/sw/bin/agent-harbor-gui"

proc refused(cfg: AgentHarborActivityConfig): bool =
  try:
    validateAgentHarborConfig(cfg)
    false
  except EConfigViolation:
    true

suite "M1 — the agent-harbor activity":
  test "Agent Harbor is the default provider and renders every surface":
    let cfg = agentHarborConfig(credentialHandles = @["anthropic-main"])
    check cfg.provider == apAgentHarbor
    let spec = agentHarborActivity(cfg)
    check spec.systemPackages == @["reproos-agent-host", "agent-harbor"]
    check "ExecStart=" & Host & " --config" in renderHostUnit(cfg, Host)
    let agent = renderAgentUnit(cfg, Ah)
    check "ExecStart=" & Ah & " server start" in agent
    check "Wants=" & HostUnitName in agent
    check "Exec=" & Gui & " %u" in renderDesktopEntry(cfg, Gui)
    let toml = renderHostConfig(cfg)
    check "provider = \"agent-harbor\"" in toml
    check "credential_handles = [\"anthropic-main\"]" in toml

  test "no-agent mode installs and renders only the host":
    let cfg = agentHarborConfig(provider = apNone)
    let spec = agentHarborActivity(cfg)
    check spec.systemPackages == @["reproos-agent-host"]
    check renderAgentUnit(cfg, Ah) == ""
    check renderDesktopEntry(cfg, Gui) == ""
    check renderHostUnit(cfg, Host).len > 0
    check "provider = \"none\"" in renderHostConfig(cfg)
    # Provider settings without a provider are a contradiction.
    check refused(agentHarborConfig(provider = apNone, model = "x"))
    check refused(agentHarborConfig(provider = apNone,
                                    credentialHandles = @["a"]))

  test "a secret value where a handle belongs is refused":
    for secret in ["sk-ant-api03-abcdefghijklmnop", "ghp_0123456789abcdef",
                   "AKIAIOSFODNN7EXAMPLE",
                   "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig",
                   "q8ZpW3nR7tY2uI9oP4aS6dF1gH5jK0lZxC"]:
      checkpoint secret
      check refused(agentHarborConfig(credentialHandles = @[secret]))
      check refused(agentHarborConfig(model = secret))

  test "handles, limits and enumerations are validated":
    check not refused(agentHarborConfig(credentialHandles = @["github.work"]))
    check refused(agentHarborConfig(credentialHandles = @["Has Spaces"]))
    check refused(agentHarborConfig(credentialHandles = @["../etc/passwd"]))
    check refused(agentHarborConfig(maxSessions = 0))
    check refused(agentHarborConfig(maxSessions = 17))
    check refused(agentHarborConfig(approvalLifetimeSeconds = 5))
    check refused(agentHarborConfig(logLevel = "trace"))
    check refused(agentHarborConfig(updateChannel = "nightly"))
    expect EConfigViolation:
      discard agentHarborActivity(agentHarborConfig(maxSessions = 99))

  test "one configuration renders one policy file":
    let a = agentHarborConfig(credentialHandles = @["b-key", "a-key"])
    let b = agentHarborConfig(credentialHandles = @["a-key", "b-key"])
    check renderHostConfig(a) == renderHostConfig(b)
    check "credential_handles = [\"a-key\", \"b-key\"]" in renderHostConfig(a)
