## DSL-port M8 / M9.A / M9.B — ``fs`` namespace shim.
##
## Nim has no namespace keyword. The idiomatic ``fs.configFile(...)`` /
## ``fs.managedBlock(...)`` / ``fs.symlink(...)`` / ``fs.directory(...)``
## callsite syntax is achieved by importing this module under the ``fs``
## alias:
##
## .. code-block:: nim
##   import repro_project_dsl
##   import repro_project_dsl/fs as fs
##
##   package myPkg:
##     build:
##       fs.configFile(
##         path = "~/.config/myapp.conf",
##         content = "key = value\n"
##       )
##       fs.managedBlock(
##         path = "/etc/ld.so.conf.d/00-reproos-linux.conf",
##         blockId = "libpaths",
##         scope = bsSystem,
##         content = "/opt/test/lib\n"
##       )
##       fs.symlink(
##         path = "/etc/systemd/system/systemd-logind.service",
##         target = "/lib/systemd/system/systemd-logind.service"
##       )
##       fs.directory(
##         path = "/var/lib/dbus",
##         mode = 0o755
##       )
##
## The procs themselves live in
## ``repro_project_dsl/dsl_port_runtime.nim`` (so the umbrella include
## chain carries the runtime state); this module simply re-exports the
## umbrella so the ``fs.<name>`` qualified-call form resolves. Callers
## that import ``repro_project_dsl`` directly can also call the procs
## unqualified (``configFile(...)`` / ``managedBlock(...)``) — both
## spellings hit the same procs.
##
## The reason ``import`` rather than ``include`` is used: the umbrella
## module already defines every fs.* symbol via its include chain;
## re-including would multiply-define them. Importing keeps the
## fs.<name> qualification working at the callsite without redefining
## anything.

import ../repro_project_dsl
export repro_project_dsl
