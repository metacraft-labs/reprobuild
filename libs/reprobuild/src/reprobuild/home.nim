## ``import reprobuild/home`` -- the entry point for a ``home.nim`` profile.
##
## The profile DSL: ``profile`` / ``activity`` / ``config`` / ``hosts`` /
## ``resources`` declarations, the standard predicate set, resource
## constructors, content helpers and the profile build actions.
##
## The home and system profile vocabularies are one library today, so this
## module and ``reprobuild/system`` export the same symbols; they are separate
## names so a profile states which kind it is and so either can narrow without
## breaking the other's importers. Same symbols as the legacy
## ``import repro_profile``.

import repro_profile
export repro_profile
