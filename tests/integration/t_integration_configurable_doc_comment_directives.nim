## M58 gate: `integration_configurable_doc_comment_directives`.
##
## Normative description:
##
##   `@id stable-name` attaches a persistent id and is removed from
##   the displayed description; an `@id` containing uppercase or
##   unsupported punctuation is rejected at macro expansion; unknown
##   directive names produce `EUnknownDirective`; reserved future
##   directives produce a structured "not yet supported" diagnostic.

import std/[strutils, unittest]
import repro_dsl_stdlib/configurables

suite "M58 doc-comment directives":

  test "@id is extracted and removed from description":
    var portHandle: Configurable[int]
    let ctx = evalConfig:
      config:
        ## TCP port the API server binds.
        ## Increase past 1024 to avoid root-port restrictions.
        ## @id api-server-port
        port = 8080
      portHandle = port
    check ctx.read(portHandle) == 8080
    check ctx.persistentId(portHandle) == "api-server-port"
    let desc = ctx.description(portHandle)
    check desc.contains("TCP port")
    check desc.contains("Increase past 1024")
    check not desc.contains("@id")
    check not desc.contains("api-server-port")

  test "uppercase in @id is rejected at parse time":
    # The doc text passed to `parseDocCommentChecked` mirrors the
    # post-`extractLeadDoc` form: `## ` prefix stripped, lines
    # joined with newlines.
    expect EInvalidId:
      discard parseDocCommentChecked(
        "TCP port.\n@id API-Server-Port", false)

  test "punctuation other than '-' in @id is rejected":
    expect EInvalidId:
      discard parseDocCommentChecked(
        "TCP port.\n@id api_server_port", false)
    expect EInvalidId:
      discard parseDocCommentChecked(
        "TCP port.\n@id api.server.port", false)

  test "valid @id forms are accepted":
    let parsed = parseDocCommentChecked(
      "TCP port.\n@id api-server-port", false)
    check parsed.explicitId == "api-server-port"
    check parsed.description == "TCP port."

  test "unknown directive names produce EUnknownDirective":
    expect EUnknownDirective:
      discard parseDocCommentChecked(
        "TCP port.\n@whatever foo", false)

  test "reserved future directives produce structured 'not yet supported' diagnostic":
    expect EFutureDirective:
      discard parseDocCommentChecked(
        "TCP port.\n@deprecated use newPort", false)
    expect EFutureDirective:
      discard parseDocCommentChecked(
        "TCP port.\n@since 1.0", false)
    expect EFutureDirective:
      discard parseDocCommentChecked(
        "TCP port.\n@hidden true", false)
    expect EFutureDirective:
      discard parseDocCommentChecked(
        "TCP port.\n@unit seconds", false)

  test "description without directives passes through unchanged":
    let parsed = parseDocCommentChecked(
      "Line one.\nLine two.", false)
    check parsed.explicitId == ""
    check parsed.description == "Line one.\nLine two."

  test "reserved-future directive in a config: block is rejected":
    check not compiles((block:
      let ctx = evalConfig:
        config:
          ## TCP port.
          ## @deprecated use newPort
          port = 8080
    ))
