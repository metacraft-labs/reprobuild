## Compatibility import path for the install-mirror resolver.
##
## The implementation lives in repro_project_dsl so project-DSL action
## emission can depend on it without importing repro_dsl_stdlib.

import repro_project_dsl/install_mirror_resolver
export install_mirror_resolver
