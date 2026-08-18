## Compatibility import for the ambient-execution linter.
##
## The implementation lives in ``repro_core`` so out-of-tree project and
## provider compilations can resolve it through their normal library paths.

import repro_core/ambient_execution as repro_core_ambient_execution

export repro_core_ambient_execution
