# nim-check: skip
#
# M79 gate fixture: a home profile that declares a `shell.integration`
# resource through the top-level `resources:` block (M78 production
# source). `repro home apply` materializes the shell-integration
# managed block through the M68 `shell.integration` driver, which
# reuses the shared managed-block writer.
#
# M79 exercises apply idempotency: an unchanged `shell.integration`
# resource must re-plan as `no-op`, not `update`. Before the M79 fix
# the desired-state digest hashed the block content VERBATIM while
# the writer appended a trailing newline, so the digests never
# matched and the resource re-planned as `update` on every apply.
#
# M83 Phase F2 migration: built via the Phase A `repro_profile` macro
# library so `repro home apply` takes the compile-then-apply path
# (Phase D) end-to-end.

import repro_profile

profile "m79-shell-integration-idempotent":

  activity default:
    `m79-fixture`

  resources:
    # A `shell.integration` resource: written as a repro-managed
    # block into a shell startup file. The content deliberately does
    # NOT end with a newline so the writer's trailing-`\n`
    # normalization is exercised — this is the exact mismatch M79
    # fixes.
    shellIntegration(hostFile = "~/.m79-shell-integration-rc",
      blockId = "m79-shell-block",
      content = "eval \"$(repro hook init)\"",
      address = "shellHook")

  hosts:
    "m79-gate-host": [default]
