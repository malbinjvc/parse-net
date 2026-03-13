## models.nim - Data types for ParseNet
##
## Defines Schema, ValidationResult, RepairResult, ConvertResult,
## ParseResult, Stats, and related types.

import std/[json, strutils]

type
  FieldType* = enum
    ftString = "string"
    ftNumber = "number"
    ftBoolean = "boolean"
    ftArray = "array"
    ftObject = "object"

  SchemaField* = object
    name*: string
    fieldType*: FieldType
    required*: bool
    properties*: seq[SchemaField]  # For nested objects

  Schema* = object
    id*: string
    name*: string
    description*: string
    fields*: seq[SchemaField]
    createdAt*: string

  ValidationError* = object
    field*: string
    message*: string
    expected*: string
    actual*: string

  ValidationResult* = object
    valid*: bool
    errors*: seq[ValidationError]
    schemaId*: string
    schemaName*: string

  RepairAction* = object
    description*: string
    applied*: bool

  RepairResult* = object
    original*: string
    repaired*: string
    actions*: seq[RepairAction]
    success*: bool
    parsedJson*: JsonNode

  ConvertResult* = object
    input*: string
    output*: string
    fromFormat*: string
    toFormat*: string
    success*: bool
    error*: string

  ParseResult* = object
    repairResult*: RepairResult
    validationResult*: ValidationResult
    success*: bool
    data*: JsonNode

  Stats* = object
    totalValidations*: int
    totalRepairs*: int
    totalConversions*: int
    successfulValidations*: int
    successfulRepairs*: int
    successfulConversions*: int

proc fieldTypeFromString*(s: string): FieldType =
  case s.toLowerAscii()
  of "string": ftString
  of "number": ftNumber
  of "boolean": ftBoolean
  of "array": ftArray
  of "object": ftObject
  else: ftString

proc parseSchemaField*(node: JsonNode): SchemaField =
  result.name = node{"name"}.getStr("")
  result.fieldType = fieldTypeFromString(node{"type"}.getStr("string"))
  result.required = node{"required"}.getBool(false)
  result.properties = @[]
  if node.hasKey("properties"):
    for prop in node["properties"]:
      result.properties.add(parseSchemaField(prop))

proc parseSchema*(node: JsonNode): Schema =
  result.name = node{"name"}.getStr("")
  result.description = node{"description"}.getStr("")
  result.fields = @[]
  if node.hasKey("fields"):
    for field in node["fields"]:
      result.fields.add(parseSchemaField(field))

proc schemaFieldToJson*(field: SchemaField): JsonNode =
  result = %*{
    "name": field.name,
    "type": $field.fieldType,
    "required": field.required
  }
  if field.properties.len > 0:
    var props = newJArray()
    for p in field.properties:
      props.add(schemaFieldToJson(p))
    result["properties"] = props

proc schemaToJson*(schema: Schema): JsonNode =
  var fields = newJArray()
  for f in schema.fields:
    fields.add(schemaFieldToJson(f))
  result = %*{
    "id": schema.id,
    "name": schema.name,
    "description": schema.description,
    "fields": fields,
    "created_at": schema.createdAt
  }

proc validationErrorToJson*(err: ValidationError): JsonNode =
  result = %*{
    "field": err.field,
    "message": err.message,
    "expected": err.expected,
    "actual": err.actual
  }

proc validationResultToJson*(vr: ValidationResult): JsonNode =
  var errs = newJArray()
  for e in vr.errors:
    errs.add(validationErrorToJson(e))
  result = %*{
    "valid": vr.valid,
    "errors": errs,
    "schema_id": vr.schemaId,
    "schema_name": vr.schemaName
  }

proc repairActionToJson*(action: RepairAction): JsonNode =
  result = %*{
    "description": action.description,
    "applied": action.applied
  }

proc repairResultToJson*(rr: RepairResult): JsonNode =
  var actions = newJArray()
  for a in rr.actions:
    actions.add(repairActionToJson(a))
  result = %*{
    "original": rr.original,
    "repaired": rr.repaired,
    "actions": actions,
    "success": rr.success
  }

proc convertResultToJson*(cr: ConvertResult): JsonNode =
  result = %*{
    "input": cr.input,
    "output": cr.output,
    "from_format": cr.fromFormat,
    "to_format": cr.toFormat,
    "success": cr.success
  }
  if cr.error.len > 0:
    result["error"] = %cr.error

proc parseResultToJson*(pr: ParseResult): JsonNode =
  result = %*{
    "repair": repairResultToJson(pr.repairResult),
    "validation": validationResultToJson(pr.validationResult),
    "success": pr.success
  }
  if pr.data != nil:
    result["data"] = pr.data

proc statsToJson*(stats: Stats): JsonNode =
  var successRate = 0.0
  let total = stats.totalValidations + stats.totalRepairs + stats.totalConversions
  let successes = stats.successfulValidations + stats.successfulRepairs + stats.successfulConversions
  if total > 0:
    successRate = (successes.float / total.float) * 100.0
  result = %*{
    "total_validations": stats.totalValidations,
    "total_repairs": stats.totalRepairs,
    "total_conversions": stats.totalConversions,
    "successful_validations": stats.successfulValidations,
    "successful_repairs": stats.successfulRepairs,
    "successful_conversions": stats.successfulConversions,
    "success_rate": successRate
  }
