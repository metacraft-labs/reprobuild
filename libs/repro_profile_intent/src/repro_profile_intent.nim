## Reprobuild `RBPI` profile-intent binary envelope (M83 Phase B).
##
## Phase A delivered the `repro_profile` macro library that builds a
## `ProfileIntent` value at compile time and emits it as JSON. Phase B
## introduces the on-disk BINARY envelope that the Phase D apply
## pipeline will consume: a magic+version+bodyLen+body+checksum
## framing modelled on M69's `RBIP` plan envelope and `RBSL`
## audit-log record, with a CBOR body for the `ProfileIntent` payload.
##
## This umbrella module re-exports the layered submodules so the
## user-facing surface is a single import.

import ./repro_profile_intent/envelope
import ./repro_profile_intent/codec
import ./repro_profile_intent/errors

export envelope.RbpiMagic
export envelope.RbpiSchemaVersion
export envelope.RbpiHeaderSize
export envelope.RbpiTrailerSize
export envelope.encodeRbpiHeader
export envelope.readRbpiHeader
export envelope.wrapEnvelope
export envelope.readEnvelope

export codec.encodeProfileIntentToBytes
export codec.decodeProfileIntentFromBytes
export codec.encodeRbpi
export codec.decodeRbpi

export errors.ERbpiCorrupt
export errors.raiseRbpiCorrupt
