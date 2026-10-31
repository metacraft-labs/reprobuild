## Compile-time falsifying mutations of the deploy agent's own checks.
##
## The same switch as the add-on's (``-d:reproAddonMutation=<name>``,
## ``repro_addon/mutations``): a gate builds a separate binary with one
## check broken and requires it to go red. This library cannot import the
## add-on's module (the add-on depends on it), so it reads the same define
## here; the names are also listed in the add-on's ``KnownAddonMutations``
## so a static add-on build with one of them is accepted. A build without
## the define contains none of the broken code.
##
## ===================================  ====================================
## name                                 what the build does wrong
## ===================================  ====================================
## ``rdmf-ignores-revoked-keys``        a producer seals to a recipient key
##                                      on its revoked-key list
## ``rdmf-skips-closure-digest``        a v3 closure digest is never
##                                      compared with the output it pins
## ``rdmf-ignores-issued-at``           a stale v3 manifest is not reported
##                                      ``aoStale``
## ===================================  ====================================

const AgentMutation {.strdefine: "reproAddonMutation".} = ""

const KnownAgentMutations* = ["rdmf-ignores-revoked-keys",
                              "rdmf-skips-closure-digest",
                              "rdmf-ignores-issued-at"]

template agentMutated*(name: static string): bool =
  ## True only in the build compiled with ``-d:reproAddonMutation=<name>``.
  static:
    doAssert name in KnownAgentMutations, "unknown agent mutation " & name
  AgentMutation == name
