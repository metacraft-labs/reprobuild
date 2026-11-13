## The `agent-harbor` activity: the local agent of ReproOS and the
## integration host it talks through
## (ReproOS-Agent-Harbor-Integration M1; protocol spec
## `ReproOS-Agent-Integration-Protocol.md`).
##
## Enabling it adds two per-user services and a desktop entry:
##
## - `reproos-agent-host.service`: the integration host. It holds sessions,
##   grants, approvals and the audit log, and is the only path by which an
##   agent changes anything outside its workspaces;
## - `agent-harbor.service`: the Agent Harbor daemon, the provider the host
##   serves (absent in no-agent mode);
## - `agent-harbor.desktop`: the desktop surface.
##
## and the host's policy file, which names the provider, where model
## inference runs, the credential HANDLES the host may use on the
## provider's behalf, and the host's limits.
##
## ## Typed configuration without a `config:` section
##
## Like `attestation` and `reproos_desktop`, this module's settings are
## ordinary Nim — `AgentHarborActivityConfig` and
## `validateAgentHarborConfig`, raising `EConfigViolation` — because the
## `activity` macro has no `config:` or `validate:` section yet
## (Activity-Module-DSL AM1, AM4). The renderers are pure functions of the
## validated config, so a profile compile that accepts a configuration can
## render every file, and one that refuses it never renders any.
##
## ## Secrets
##
## A secret never appears in anything this module renders, because the
## configuration has nowhere to put one: credentials are HANDLES, names of
## entries in the user's secret store that the host dereferences at use
## (protocol §"Capabilities", `credentials.use`). A handle that looks like
## a secret itself — a known token prefix, or a long high-entropy string —
## is refused, so pasting a token where a handle belongs is a plan-time
## error and not a token in a generation.
##
## ## No-agent mode
##
## `provider = apNone` is a supported configuration, not a degraded one:
## the host still runs (other tools may be granted sessions through it)
## and no agent daemon, desktop entry or model configuration is rendered.
##
## ## Mocking
##
## None. Everything here is a pure function of the configuration.

import std/[algorithm, strutils]

import repro_profile

import ./config_violation

export config_violation

const
  ActivityName* = "agent-harbor"
  HostPackage* = "reproos-agent-host"
  AgentPackage* = "agent-harbor"
  HostUnitName* = "reproos-agent-host.service"
  AgentUnitName* = "agent-harbor.service"
  DesktopEntryName* = "agent-harbor.desktop"
  DefaultMaxSessions* = 4
  DefaultApprovalLifetimeSeconds* = 600

  SecretPrefixes = ["sk-", "sk_", "ghp_", "gho_", "ghs_", "github_pat_",
    "glpat-", "xoxb-", "xoxp-", "AKIA", "ASIA", "AIza", "ya29.", "eyJ"]
    ## Prefixes of widely used API tokens and JWTs. Not a secret scanner:
    ## the point is that a handle is a short name, so anything shaped like
    ## a token is refused rather than accepted.

type
  AgentProvider* = enum
    ## Which provider the host serves. Agent Harbor is the default;
    ## alternatives are admitted by curator policy after conformance (M7).
    apAgentHarbor = "agent-harbor"
    apNone = "none"

  InferenceLocality* = enum
    ilLocal = "local"
    ilRemote = "remote"

  AgentHarborActivityConfig* = object
    provider*: AgentProvider
    inference*: InferenceLocality
    model*: string
      ## The model identifier the provider uses; empty for its default.
    credentialHandles*: seq[string]
      ## Secret-store entry names, never secret values.
    maxSessions*: int
    approvalLifetimeSeconds*: int
    logLevel*: string
    updateChannel*: string

proc agentHarborConfig*(provider = apAgentHarbor; inference = ilLocal;
                        model = ""; credentialHandles: seq[string] = @[];
                        maxSessions = DefaultMaxSessions;
                        approvalLifetimeSeconds = DefaultApprovalLifetimeSeconds;
                        logLevel = "info"; updateChannel = "stable"):
    AgentHarborActivityConfig =
  AgentHarborActivityConfig(provider: provider, inference: inference,
    model: model, credentialHandles: credentialHandles,
    maxSessions: maxSessions, approvalLifetimeSeconds: approvalLifetimeSeconds,
    logLevel: logLevel, updateChannel: updateChannel)

proc isHandle(s: string): bool =
  ## Secret-store entry names: 1..64 of `[a-z0-9._-]`, starting with a
  ## letter.
  if s.len == 0 or s.len > 64 or s[0] notin {'a'..'z'}:
    return false
  for c in s:
    if c notin {'a'..'z', '0'..'9', '.', '_', '-'}:
      return false
  true

proc looksLikeSecret*(s: string): bool =
  ## A known token prefix, or a long run with the character mix of a
  ## random token (letters of both cases and digits).
  for p in SecretPrefixes:
    if s.startsWith(p):
      return true
  if s.len >= 32:
    var lower, upper, digit = false
    for c in s:
      if c in {'a'..'z'}: lower = true
      elif c in {'A'..'Z'}: upper = true
      elif c in {'0'..'9'}: digit = true
    if lower and upper and digit:
      return true
  false

proc validateAgentHarborConfig*(cfg: AgentHarborActivityConfig) =
  for h in cfg.credentialHandles:
    if looksLikeSecret(h):
      raise newException(EConfigViolation,
        "the agent-harbor activity was given a credential that looks like " &
        "a secret VALUE, not the name of a secret-store entry. A value " &
        "written here would be rendered into the generation, where every " &
        "user and every backup can read it. Store the secret in the " &
        "user's secret store and list the entry's name instead.")
    if not isHandle(h):
      raise newException(EConfigViolation,
        "the agent-harbor activity was given the credential handle " &
        h.escape & "; a handle is the name of a secret-store entry: " &
        "lowercase letters, digits, '.', '_' or '-', at most 64, " &
        "starting with a letter.")
  if cfg.model.len > 0 and (looksLikeSecret(cfg.model) or
      cfg.model.len > 128 or ' ' in cfg.model or '\n' in cfg.model):
    raise newException(EConfigViolation,
      "the agent-harbor activity's model " & cfg.model.escape &
      " is not a model identifier.")
  if cfg.maxSessions < 1 or cfg.maxSessions > 16:
    raise newException(EConfigViolation,
      "the agent-harbor activity allows 1..16 concurrent sessions " &
      "(the protocol's per-user bound), not " & $cfg.maxSessions & ".")
  if cfg.approvalLifetimeSeconds < 30 or cfg.approvalLifetimeSeconds > 3600:
    raise newException(EConfigViolation,
      "an approval must expire between 30 seconds and an hour after the " &
      "user gives it, not after " & $cfg.approvalLifetimeSeconds & ".")
  if cfg.logLevel notin ["error", "warn", "info", "debug"]:
    raise newException(EConfigViolation,
      "unknown agent-harbor log level " & cfg.logLevel.escape & ".")
  if cfg.updateChannel notin ["stable", "beta"]:
    raise newException(EConfigViolation,
      "unknown agent-harbor update channel " & cfg.updateChannel.escape & ".")
  if cfg.provider == apNone and (cfg.model.len > 0 or
      cfg.credentialHandles.len > 0):
    raise newException(EConfigViolation,
      "the agent-harbor activity is in no-agent mode, which runs no " &
      "provider, but it was also given a model or credentials for one. " &
      "Choose a provider, or drop the provider settings.")

proc renderHostUnit*(cfg: AgentHarborActivityConfig; hostExe: string): string =
  ## The systemd USER unit of the integration host.
  ## https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
  result = "[Unit]\nDescription=ReproOS agent integration host\n\n" &
    "[Service]\nType=simple\nExecStart=" & hostExe &
    " --config %h/.config/reproos/agent-host.toml\n" &
    "Restart=on-failure\nNoNewPrivileges=yes\n\n" &
    "[Install]\nWantedBy=default.target\n"

proc renderAgentUnit*(cfg: AgentHarborActivityConfig; ahExe: string): string =
  ## The Agent Harbor daemon's USER unit, the same command its own
  ## home-manager module runs (agent-harbor `nix/home-manager-module.nix`).
  ## Empty in no-agent mode.
  if cfg.provider == apNone:
    return ""
  "[Unit]\nDescription=Agent Harbor user daemon\n" &
    "After=" & HostUnitName & "\nWants=" & HostUnitName & "\n\n" &
    "[Service]\nType=simple\nExecStart=" & ahExe &
    " server start --no-access-point-loop\nRestart=on-failure\n\n" &
    "[Install]\nWantedBy=default.target\n"

proc renderDesktopEntry*(cfg: AgentHarborActivityConfig; guiExe: string): string =
  ## https://specifications.freedesktop.org/desktop-entry-spec/latest/
  ## Empty in no-agent mode.
  if cfg.provider == apNone:
    return ""
  "[Desktop Entry]\nType=Application\nName=Agent Harbor\n" &
    "Comment=Change installed software with the local agent\n" &
    "Exec=" & guiExe & " %u\nIcon=agent-harbor\n" &
    "Categories=Development;Utility;\n" &
    "MimeType=x-scheme-handler/agent-harbor;\nStartupWMClass=agent-harbor\n"

proc tomlString(s: string): string =
  ## A TOML basic string. Only validated values reach here.
  "\"" & s.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

proc renderHostConfig*(cfg: AgentHarborActivityConfig): string =
  ## The host's policy file. Handles only; sorted, so one configuration
  ## renders one file.
  var handles = cfg.credentialHandles
  handles.sort()
  result = "# Rendered by the agent-harbor activity. Do not edit; change " &
    "the profile.\n" &
    "provider = " & tomlString($cfg.provider) & "\n" &
    "inference = " & tomlString($cfg.inference) & "\n" &
    "model = " & tomlString(cfg.model) & "\n" &
    "max_sessions = " & $cfg.maxSessions & "\n" &
    "approval_lifetime_seconds = " & $cfg.approvalLifetimeSeconds & "\n" &
    "log_level = " & tomlString(cfg.logLevel) & "\n" &
    "update_channel = " & tomlString(cfg.updateChannel) & "\n" &
    "credential_handles = ["
  for i, h in handles:
    if i > 0: result.add ", "
    result.add tomlString(h)
  result.add "]\n"

# The list sections are string LITERALS for the reason `attestation`
# gives: the macro takes an identifier's own name. The static block keeps
# the literals and the constants from parting.
static:
  doAssert ActivityName == "agent-harbor"
  doAssert HostPackage == "reproos-agent-host"
  doAssert AgentPackage == "agent-harbor"

proc agentHarborActivity*(cfg: AgentHarborActivityConfig): SystemActivitySpec =
  ## The activity, validated: there is no unchecked constructor. No-agent
  ## mode installs only the host.
  validateAgentHarborConfig(cfg)
  if cfg.provider == apNone:
    return buildActivitySpec("agent-harbor"):
      displayName: "Agent integration host (no agent)"
      description: "The ReproOS agent integration host, with no agent."
      systemPackages: ["reproos-agent-host"]
  buildActivitySpec("agent-harbor"):
    displayName: "Agent Harbor"
    description: "Agent Harbor, the local agent, and its integration host."
    systemPackages: ["reproos-agent-host", "agent-harbor"]
