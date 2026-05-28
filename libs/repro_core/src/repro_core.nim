import repro_core/types
import repro_core/paths
import repro_core/process_specs
import repro_core/dependency_gathering
import repro_core/parallel
import repro_core/codec
import repro_core/dep_graph
import repro_core/project_file
import repro_core/nim_dep_scanner

export types
export paths
export process_specs
export dependency_gathering
export parallel
export codec
export dep_graph
export project_file
export nim_dep_scanner

const ReprobuildVersion* = "0.1.0"

proc versionString*(): string =
  ReprobuildVersion
