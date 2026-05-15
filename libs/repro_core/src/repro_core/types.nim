type
  ProjectName* = distinct string
  Version* = distinct string

proc `$`*(name: ProjectName): string =
  string(name)

proc `$`*(version: Version): string =
  string(version)
