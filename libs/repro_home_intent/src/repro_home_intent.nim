## Reprobuild home-profile intent layer (M60).
##
## Parses, validates, and structurally edits the user's `home.nim`
## profile per `docs/specs/Home-Profile-Intent-Layer.md`. The CLI
## (`repro home ...`, M61) and the apply pipeline (M63) compose on top
## of this library; this module is the umbrella import.

import repro_home_intent/errors
import repro_home_intent/host_identity
import repro_home_intent/predicate
import repro_home_intent/model
import repro_home_intent/parser
import repro_home_intent/editor
import repro_home_intent/config_resolver

export errors
export host_identity
export predicate
export model
export parser
export editor
export config_resolver
