## GM5 fixture: a profile whose intent a compile-time `when defined(macosx)`
## decides, so an export compiled on Linux does not describe the darwin
## targets (`platforms` says `differs`) and `readIntent` must refuse them.
## See ../README.md.
import repro_profile

profile "gm5CompileTime":
  activity default:
    bash

  resources:
    envUserVariable(name = "GM5_EVERYWHERE", value = "1")
    when defined(macosx):
      envUserVariable(name = "GM5_MAC_ONLY", value = "1")
