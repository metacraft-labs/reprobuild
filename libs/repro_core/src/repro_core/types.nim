type
  StableId* = distinct array[16, byte]
  StableName* = distinct string
  CapabilityName* = distinct string
  SchemaVersion* = distinct uint16
  ByteCount* = distinct uint64
  ProjectName* = distinct string
  Version* = distinct string

proc `$`*(id: StableId): string =
  const hex = "0123456789abcdef"
  let bytes = array[16, byte](id)
  result = newStringOfCap(32)
  for b in bytes:
    result.add(hex[int(b shr 4)])
    result.add(hex[int(b and 0x0f)])

proc stableId*(bytes: array[16, byte]): StableId =
  StableId(bytes)

proc `==`*(a, b: StableId): bool =
  array[16, byte](a) == array[16, byte](b)

proc `==`*(a, b: StableName): bool =
  string(a) == string(b)

proc `==`*(a, b: CapabilityName): bool =
  string(a) == string(b)

proc `==`*(a, b: ProjectName): bool =
  string(a) == string(b)

proc `==`*(a, b: Version): bool =
  string(a) == string(b)

proc `$`*(name: StableName): string =
  string(name)

proc `$`*(name: CapabilityName): string =
  string(name)

proc `$`*(name: ProjectName): string =
  string(name)

proc `$`*(version: Version): string =
  string(version)
