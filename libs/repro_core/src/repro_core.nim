import repro_core/types

export types

const ReprobuildVersion* = "0.1.0"

proc versionString*(): string =
  ReprobuildVersion
