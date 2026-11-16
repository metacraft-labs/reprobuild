## ``import reprobuild/system`` -- the entry point for a ``system.nim`` profile.
##
## The profile DSL with its system-scope declarations: host registry,
## activities, base OS, disks, system resources and services.
##
## The home and system profile vocabularies are one library today, so this
## module and ``reprobuild/home`` export the same symbols; they are separate
## names so a profile states which kind it is and so either can narrow without
## breaking the other's importers. Same symbols as the legacy
## ``import repro_profile``.
##
## Note for authors: the module's own name is ``system``, like Nim's implicit
## ``system`` module. Unqualified calls are unaffected; a recipe that wants a
## qualified ``system.<proc>`` from Nim's standard library while importing this
## module should import it under another name
## (``import reprobuild/system as reproSystem``).

import repro_profile
export repro_profile
