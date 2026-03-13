## parse_net.nim - Main application with Jester routes
##
## REST API for parsing, validating, and repairing AI-generated structured outputs.

import std/[json, strutils, tables, os]
import jester
import models, services, clients

# Global state
var schemaService = newSchemaService()
var validationService = newValidationService()
var repairService = newRepairService()
var convertService = newConvertService()

proc jsonResponse(data: JsonNode): string =
  return $(%*{"data": data})

proc jsonListResponse(data: JsonNode, count: int): string =
  return $(%*{"data": data, "count": count})

proc jsonError(message: string): string =
  return $(%*{"error": {"message": message}})

proc getPort(): int =
  let portStr = getEnv("PORT", "8080")
  try:
    return parseInt(portStr)
  except ValueError:
    return 8080

let appPort = getPort()

settings:
  port = Port(appPort)
  bindAddr = "0.0.0.0"

routes:
  # -------------------------------------------------------
  # Health check
  # -------------------------------------------------------
  get "/health":
    resp Http200, {"Content-Type": "application/json"}, $(%*{
      "status": "healthy",
      "service": "parse-net",
      "version": "0.1.0"
    })

  # -------------------------------------------------------
  # Schema Registry
  # -------------------------------------------------------
  post "/api/schemas":
    try:
      let body = parseJson(request.body)
      let schema = schemaService.registerSchema(body)
      resp Http201, {"Content-Type": "application/json"}, jsonResponse(schemaToJson(schema))
    except JsonParsingError:
      resp Http400, {"Content-Type": "application/json"}, jsonError("Invalid JSON in request body")
    except CatchableError as e:
      resp Http400, {"Content-Type": "application/json"}, jsonError(e.msg)

  get "/api/schemas":
    let schemas = schemaService.listSchemas()
    var arr = newJArray()
    for s in schemas:
      arr.add(schemaToJson(s))
    resp Http200, {"Content-Type": "application/json"}, jsonListResponse(arr, schemas.len)

  get "/api/schemas/@id":
    try:
      let schema = schemaService.getSchema(@"id")
      resp Http200, {"Content-Type": "application/json"}, jsonResponse(schemaToJson(schema))
    except KeyError:
      resp Http404, {"Content-Type": "application/json"}, jsonError("Schema not found: " & @"id")

  delete "/api/schemas/@id":
    if schemaService.deleteSchema(@"id"):
      resp Http200, {"Content-Type": "application/json"}, $(%*{"data": {"deleted": true, "id": @"id"}})
    else:
      resp Http404, {"Content-Type": "application/json"}, jsonError("Schema not found: " & @"id")

  # -------------------------------------------------------
  # Validation
  # -------------------------------------------------------
  post "/api/validate":
    try:
      let body = parseJson(request.body)

      # Get schema_id and data from body
      let schemaId = body{"schema_id"}.getStr("")
      if schemaId.len == 0:
        resp Http400, {"Content-Type": "application/json"}, jsonError("schema_id is required")
        return

      let data = body{"data"}
      if data == nil or data.kind == JNull:
        resp Http400, {"Content-Type": "application/json"}, jsonError("data field is required")
        return

      let schema = schemaService.getSchema(schemaId)
      let valResult = validationService.validate(data, schema)
      resp Http200, {"Content-Type": "application/json"}, jsonResponse(validationResultToJson(valResult))
    except KeyError:
      resp Http404, {"Content-Type": "application/json"}, jsonError("Schema not found")
    except JsonParsingError:
      resp Http400, {"Content-Type": "application/json"}, jsonError("Invalid JSON in request body")
    except CatchableError as e:
      resp Http400, {"Content-Type": "application/json"}, jsonError(e.msg)

  # -------------------------------------------------------
  # Repair
  # -------------------------------------------------------
  post "/api/repair":
    try:
      let body = parseJson(request.body)
      let text = body{"text"}.getStr("")
      if text.len == 0:
        resp Http400, {"Content-Type": "application/json"}, jsonError("text field is required")
        return

      let repairRes = repairService.repair(text)
      var response = repairResultToJson(repairRes)

      # Add AI suggestions
      var suggestions = repairService.client.analyzeAndSuggest(text)
      response["suggestions"] = suggestionsToJson(suggestions)

      resp Http200, {"Content-Type": "application/json"}, jsonResponse(response)
    except JsonParsingError:
      resp Http400, {"Content-Type": "application/json"}, jsonError("Invalid JSON in request body")
    except CatchableError as e:
      resp Http400, {"Content-Type": "application/json"}, jsonError(e.msg)

  # -------------------------------------------------------
  # Convert
  # -------------------------------------------------------
  post "/api/convert":
    try:
      let body = parseJson(request.body)
      let input = body{"input"}.getStr("")
      let toFormat = body{"to_format"}.getStr("")

      if input.len == 0:
        resp Http400, {"Content-Type": "application/json"}, jsonError("input field is required")
        return

      if toFormat.len == 0:
        resp Http400, {"Content-Type": "application/json"}, jsonError("to_format field is required")
        return

      let convResult = convertService.convert(input, toFormat)
      if convResult.success:
        resp Http200, {"Content-Type": "application/json"}, jsonResponse(convertResultToJson(convResult))
      else:
        resp Http400, {"Content-Type": "application/json"}, jsonError(convResult.error)
    except JsonParsingError:
      resp Http400, {"Content-Type": "application/json"}, jsonError("Invalid JSON in request body")
    except CatchableError as e:
      resp Http400, {"Content-Type": "application/json"}, jsonError(e.msg)

  # -------------------------------------------------------
  # Parse (full pipeline: repair -> validate -> result)
  # -------------------------------------------------------
  post "/api/parse":
    try:
      let body = parseJson(request.body)
      let text = body{"text"}.getStr("")
      let schemaId = body{"schema_id"}.getStr("")

      if text.len == 0:
        resp Http400, {"Content-Type": "application/json"}, jsonError("text field is required")
        return

      if schemaId.len == 0:
        resp Http400, {"Content-Type": "application/json"}, jsonError("schema_id is required")
        return

      # Step 1: Repair
      let repairResult = repairService.repair(text)

      # Step 2: Validate (if repair was successful)
      var parseResult: ParseResult
      parseResult.repairResult = repairResult

      if repairResult.success:
        let schema = schemaService.getSchema(schemaId)
        parseResult.validationResult = validationService.validate(repairResult.parsedJson, schema)
        parseResult.success = parseResult.validationResult.valid
        if parseResult.success:
          parseResult.data = repairResult.parsedJson
      else:
        parseResult.success = false
        parseResult.validationResult = ValidationResult(
          valid: false,
          errors: @[ValidationError(
            field: "<root>",
            message: "JSON repair failed - cannot validate",
            expected: "valid JSON",
            actual: "malformed text"
          )],
          schemaId: schemaId,
          schemaName: ""
        )

      resp Http200, {"Content-Type": "application/json"}, jsonResponse(parseResultToJson(parseResult))
    except KeyError:
      resp Http404, {"Content-Type": "application/json"}, jsonError("Schema not found")
    except JsonParsingError:
      resp Http400, {"Content-Type": "application/json"}, jsonError("Invalid JSON in request body")
    except CatchableError as e:
      resp Http400, {"Content-Type": "application/json"}, jsonError(e.msg)

  # -------------------------------------------------------
  # Stats
  # -------------------------------------------------------
  get "/api/stats":
    var globalStats = Stats(
      totalValidations: validationService.stats.totalValidations,
      totalRepairs: repairService.stats.totalRepairs,
      totalConversions: convertService.stats.totalConversions,
      successfulValidations: validationService.stats.successfulValidations,
      successfulRepairs: repairService.stats.successfulRepairs,
      successfulConversions: convertService.stats.successfulConversions
    )
    resp Http200, {"Content-Type": "application/json"}, jsonResponse(statsToJson(globalStats))
