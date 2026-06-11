# nim-check: skip
#
# Linux-Distro-Recipe-Validation M9 — generation switch + rollback
# demo, profile B.
#
# Sibling of m9_profile_a.nim. Same resource address
# ("rollbackFile") so the apply pipeline treats this as an UPDATE
# of the existing managed file (not a destroy + create); same
# hostFile path so the rollback path can swap the live bytes back
# to A's content without touching any other state. Only the
# `content` differs — the test driver byte-compares the live file
# against "m9-profile-B\n" after applying B, then expects A's
# bytes back after `repro home rollback <id_A>`.
#
# Profile name is identical to profile A's
# (`m9-rollback-profile`) on purpose: the generation digest
# computation in M83 takes ALL declared inputs (profile name,
# host table, resource addresses + payloads). Holding name + host
# + address constant and varying only the file content gives the
# cleanest "two generations of the same profile" trajectory, which
# is what the M9 brief asks for.
#
# See m9_profile_a.nim for the full design rationale (why only
# fs.userFile, why package-free, why REPRO_HOST pin).

import repro_profile

profile "m9-rollback-profile":

  activity default:
    discard

  resources:
    fsUserFile(hostFile = "~/.config/m9-test/rollback-target.txt",
      content = "m9-profile-B\n",
      mode = "0644",
      address = "rollbackFile")

  hosts:
    "m9-test-host": [default]
