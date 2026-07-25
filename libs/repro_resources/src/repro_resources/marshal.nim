## Provider<->client marshalling for a `ResourceInstance`'s attribute
## box, reusing the `Typed-Graph-Extensions.md` registry verbatim.
##
## A provider defines its attribute record `T` and calls
## `registerExtension[T](typeId)` (typically right beside
## `registerResourceProvider`); this module then serializes and
## re-hydrates the `attrs` box by `typeId` across the provider->client
## boundary. An unknown `typeId` at unmarshal time is a HARD error — an
## unknown resource cannot be silently dropped.

import std/tables

import repro_project_dsl          # ExtensionBox, extensionRegistry

proc marshalAttrs*(box: ExtensionBox): string =
  ## Serialize an attribute box by its `typeId` through the shared
  ## Typed-Graph-Extensions marshaller registry.
  ##
  ## M2 opaque pass-through: a `RawExtensionBox` (produced by
  ## `unmarshalAttrsOrRaw` for a typeId whose codec is NOT registered in
  ## this process — e.g. the `repro` CLI routing an out-of-tree provider's
  ## resources) re-serializes to its carried `raw` bytes VERBATIM, with no
  ## registry lookup. This is an identity round-trip: the bytes reaching the
  ## provider session / the state store are byte-for-byte what was decoded.
  if box of RawExtensionBox:
    return RawExtensionBox(box).raw
  if not extensionRegistry.contains(box.typeId):
    raise newException(KeyError,
      "no attribute marshaller registered for resource typeId '" &
      box.typeId & "'; the provider must call " &
      "registerExtension[Attrs](\"" & box.typeId & "\")")
  extensionRegistry[box.typeId].marshal(box)

proc unmarshalAttrs*(typeId: string; payload: string): ExtensionBox =
  ## Re-hydrate an attribute box for `typeId`. Hard error on an
  ## unknown id. `payload` is the versioned SSZ envelope bytes carried
  ## as a byte-per-char string (see `attr_ssz`), NOT JSON.
  if not extensionRegistry.contains(typeId):
    raise newException(KeyError,
      "no attribute marshaller registered for resource typeId '" &
      typeId & "'; the applying process is missing the interface dependency " &
      "that exports this resource type — import the producer's lifted " &
      "interface (which regenerates the attrs type and registers its SSZ " &
      "codec via registerExtension[Attrs](\"" & typeId & "\")) so the box " &
      "can be unmarshalled without linking the provider/driver module")
  result = extensionRegistry[typeId].unmarshal(payload)
  result.typeId = typeId

proc unmarshalAttrsOrRaw*(typeId: string; payload: string): ExtensionBox =
  ## Re-hydrate an attribute box for `typeId`, tolerating an UNREGISTERED
  ## codec by boxing the payload OPAQUELY (M2 opaque attr pass-through).
  ##
  ## * `typeId` registered  -> the typed box (`extensionRegistry[...].unmarshal`),
  ##   exactly like `unmarshalAttrs`. A provider process that links the attrs
  ##   codec gets the usable typed value.
  ## * `typeId` unregistered -> a `RawExtensionBox(typeId, raw = payload)`. The
  ##   `repro` CLI, which merely ROUTES an out-of-tree provider's resources to
  ##   the provider session (and stores the opaque bytes), does not need the
  ##   codec; the payload survives verbatim through `marshalAttrs`.
  ##
  ## This is DELIBERATELY separate from the strict `unmarshalAttrs`, which
  ## still hard-errors on an unknown id — callers that genuinely require the
  ## typed `.val` must fail loudly (M1b `t_attr_missing_interface_diagnostic`).
  if extensionRegistry.contains(typeId):
    result = extensionRegistry[typeId].unmarshal(payload)
    result.typeId = typeId
  else:
    result = RawExtensionBox(typeId: typeId, raw: payload)
