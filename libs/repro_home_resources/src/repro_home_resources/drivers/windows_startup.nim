## `windows.startup` driver — wraps `HKCU\Software\Microsoft\Windows
## \CurrentVersion\Run` writes.
##
## Lifecycle: install / update / uninstall. A startup entry is just
## a REG_SZ value under the Run key whose contents are the launch
## command. The driver reuses the registry driver for I/O.

import ./../errors
import ./../manifest_record
import ./../types
import ./registry

const
  RunSubkey* = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"

proc observeStartup*(name: string): ObservedState =
  observeRegistryValue("HKCU\\" & RunSubkey, name)

proc applyStartup*(name, command: string): seq[byte] =
  ## Write the startup entry. Returns the raw recorded bytes
  ## (UTF-16LE NUL-terminated).
  when defined(windows):
    let payload = encodeString(command)
    writeRegistryValue(RunSubkey, name, 1'u32, payload)  # REG_SZ
    result = payload
  else:
    result = @[]

proc destroyStartup*(name: string) =
  when defined(windows):
    deleteRegistryValue(RunSubkey, name)
