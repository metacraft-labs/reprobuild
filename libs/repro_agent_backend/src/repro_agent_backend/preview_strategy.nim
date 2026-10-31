## Choosing how a change is previewed: hot code reload or a supervised
## rebuild and restart (ReproOS-Agent-Harbor-Integration M4 deliverable 1).
##
## HCR is used only when the running application PROVES it supports it:
## the application links the HCR agent and opts in (spec `HCR/HCR-Overview.md`
## §"Synchronized mode": `rb_hcr_wants_reload` / `rb_hcr_apply_reload`), its
## agent's hello advertises a support profile equal to this host's direct
## profile (`repro_hcr_agent/protocol.defaultDirectSupportProfile`) and the
## `source-reload` capability, and the change touches only source files, not
## the recipe that defines the build graph. A graph change is a new build,
## not a patch, so it always restarts. Anything short of all of that falls
## back to restart, with the reason named so the user sees why.

import std/strutils

import repro_hcr_agent/protocol

type
  PreviewStrategy* = enum
    psRestart = "restart"
    psHcr = "hcr"

  HcrAdvertisement* = object
    ## What the running application's HCR agent said in its hello, or
    ## `connected = false` when no agent connected.
    connected*: bool
    supportProfile*: string
    capabilities*: seq[string]

  PreviewDecision* = object
    strategy*: PreviewStrategy
    reason*: string

const SourceReloadCapability* = "source-reload"

proc touchesDefinition*(changedPaths: seq[string]): bool =
  ## Whether a change edits a recipe (`repro.nim` at any depth) — the build
  ## graph's definition rather than its sources.
  for p in changedPaths:
    if p == "repro.nim" or p.endsWith("/repro.nim"):
      return true
  false

proc choosePreviewStrategy*(hostProfile: string; app: HcrAdvertisement;
                            changedPaths: seq[string]): PreviewDecision =
  if hostProfile.len == 0:
    return PreviewDecision(strategy: psRestart,
      reason: "this host has no direct-patch HCR profile")
  if not app.connected:
    return PreviewDecision(strategy: psRestart,
      reason: "the application did not connect an HCR agent")
  if app.supportProfile != hostProfile:
    return PreviewDecision(strategy: psRestart,
      reason: "the application's HCR profile " & app.supportProfile.escape &
        " is not this host's " & hostProfile.escape)
  if SourceReloadCapability notin app.capabilities:
    return PreviewDecision(strategy: psRestart,
      reason: "the application's HCR agent does not offer source-reload")
  if changedPaths.len == 0:
    return PreviewDecision(strategy: psRestart, reason: "nothing changed")
  if touchesDefinition(changedPaths):
    return PreviewDecision(strategy: psRestart,
      reason: "the change edits the recipe, which is a rebuild, not a patch")
  PreviewDecision(strategy: psHcr,
    reason: "the application's HCR agent supports " & hostProfile)

proc hostDirectProfile*(): string =
  ## This host's direct-patch profile, empty when it has none.
  defaultDirectSupportProfile()

proc changedPathsOf*(unifiedDiff: string): seq[string] =
  ## The workspace-relative paths a `git diff` touches, from its
  ## `diff --git a/<p> b/<p>` headers.
  for line in unifiedDiff.splitLines:
    if line.startsWith("diff --git a/"):
      let rest = line["diff --git a/".len .. ^1]
      let sep = rest.find(" b/")
      if sep > 0:
        result.add rest[0 ..< sep]
