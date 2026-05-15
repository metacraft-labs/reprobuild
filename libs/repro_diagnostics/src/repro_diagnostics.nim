type
  Diagnostic* = object
    id*: string
    message*: string

proc diagnostic*(id, message: string): Diagnostic =
  Diagnostic(id: id, message: message)
