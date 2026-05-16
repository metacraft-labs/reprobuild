type GxHashDigest* = distinct uint64

proc isAvailable*(): bool =
  false

proc unavailableReason*(): string =
  "no real GxHash implementation is wired in this M6 foundation slice"
