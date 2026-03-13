## services.nim - Core business logic for ParseNet
##
## SchemaService: CRUD for schemas
## ValidationService: validate JSON against schemas
## RepairService: fix malformed JSON
## ConvertService: format conversion (json->csv, json->yaml)

import std/[json, tables, strutils, times]
import models, clients

# ============================================================
# SchemaService - In-memory schema registry
# ============================================================

type
  SchemaService* = object
    schemas*: Table[string, Schema]
    nextId*: int

proc newSchemaService*(): SchemaService =
  result.schemas = initTable[string, Schema]()
  result.nextId = 1

proc registerSchema*(svc: var SchemaService, body: JsonNode): Schema =
  var schema = parseSchema(body)
  schema.id = "schema_" & $svc.nextId
  schema.createdAt = now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  svc.nextId += 1
  svc.schemas[schema.id] = schema
  return schema

proc getSchema*(svc: SchemaService, id: string): Schema =
  if id in svc.schemas:
    return svc.schemas[id]
  raise newException(KeyError, "Schema not found: " & id)

proc listSchemas*(svc: SchemaService): seq[Schema] =
  result = @[]
  for id, schema in svc.schemas:
    result.add(schema)

proc deleteSchema*(svc: var SchemaService, id: string): bool =
  if id in svc.schemas:
    svc.schemas.del(id)
    return true
  return false

# ============================================================
# ValidationService - Validate JSON against schema
# ============================================================

type
  ValidationService* = object
    stats*: Stats

proc newValidationService*(): ValidationService =
  result.stats = Stats()

proc typeMatches(node: JsonNode, ft: FieldType): bool =
  case ft
  of ftString: return node.kind == JString
  of ftNumber: return node.kind == JInt or node.kind == JFloat
  of ftBoolean: return node.kind == JBool
  of ftArray: return node.kind == JArray
  of ftObject: return node.kind == JObject

proc validateFields(data: JsonNode, fields: seq[SchemaField], prefix: string): seq[ValidationError] =
  result = @[]
  for field in fields:
    let fieldPath = if prefix.len > 0: prefix & "." & field.name else: field.name

    if field.required:
      if not data.hasKey(field.name):
        result.add(ValidationError(
          field: fieldPath,
          message: "Required field missing",
          expected: $field.fieldType,
          actual: "missing"
        ))
        continue

    if data.hasKey(field.name):
      let node = data[field.name]

      # Check for null
      if node.kind == JNull:
        if field.required:
          result.add(ValidationError(
            field: fieldPath,
            message: "Required field is null",
            expected: $field.fieldType,
            actual: "null"
          ))
        continue

      # Type check
      if not typeMatches(node, field.fieldType):
        var actualType = ""
        case node.kind
        of JString: actualType = "string"
        of JInt, JFloat: actualType = "number"
        of JBool: actualType = "boolean"
        of JArray: actualType = "array"
        of JObject: actualType = "object"
        of JNull: actualType = "null"
        result.add(ValidationError(
          field: fieldPath,
          message: "Type mismatch",
          expected: $field.fieldType,
          actual: actualType
        ))

      # Nested object validation
      if field.fieldType == ftObject and node.kind == JObject and field.properties.len > 0:
        let nested = validateFields(node, field.properties, fieldPath)
        result.add(nested)

proc validate*(svc: var ValidationService, data: JsonNode, schema: Schema): ValidationResult =
  svc.stats.totalValidations += 1
  result.schemaId = schema.id
  result.schemaName = schema.name

  if data.kind != JObject:
    result.valid = false
    result.errors = @[ValidationError(
      field: "<root>",
      message: "Expected JSON object at root level",
      expected: "object",
      actual: $data.kind
    )]
    return result

  result.errors = validateFields(data, schema.fields, "")
  result.valid = result.errors.len == 0
  if result.valid:
    svc.stats.successfulValidations += 1

# ============================================================
# RepairService - Fix malformed JSON from LLM outputs
# ============================================================

type
  RepairService* = object
    client*: MockClaudeClient
    stats*: Stats

proc newRepairService*(): RepairService =
  result.client = newMockClaudeClient()
  result.stats = Stats()

proc stripCodeFences(text: string): (string, bool) =
  var s = text.strip()
  var modified = false

  # Remove ```json ... ``` or ```JSON ... ``` or ``` ... ```
  if s.startsWith("```"):
    let firstNewline = s.find('\n')
    if firstNewline > 0:
      s = s[(firstNewline + 1)..^1]
      modified = true

  if s.endsWith("```"):
    s = s[0..^4].strip()
    modified = true

  return (s, modified)

proc fixTrailingCommas(text: string): (string, bool) =
  var s = text
  var modified = false

  # Fix ,} and ,]
  while ",}" in s:
    s = s.replace(",}", "}")
    modified = true
  while ",]" in s:
    s = s.replace(",]", "]")
    modified = true

  # Also handle whitespace between comma and closing bracket
  # e.g., ", }" or ",\n}"
  var output = ""
  var i = 0
  while i < s.len:
    if s[i] == ',':
      # Look ahead past whitespace
      var j = i + 1
      while j < s.len and s[j] in {' ', '\t', '\n', '\r'}:
        j += 1
      if j < s.len and s[j] in {'}', ']'}:
        # Skip the comma
        modified = true
        i += 1
        continue
    output.add(s[i])
    i += 1

  return (output, modified)

proc fixSingleQuotes(text: string): (string, bool) =
  # Replace single quotes with double quotes for JSON strings
  # Be careful: only replace quotes that are used as string delimiters
  var s = text
  var modified = false
  var output = ""
  var inDoubleQuote = false
  var i = 0

  while i < s.len:
    if s[i] == '"' and (i == 0 or s[i-1] != '\\'):
      inDoubleQuote = not inDoubleQuote
      output.add(s[i])
    elif s[i] == '\'' and not inDoubleQuote:
      output.add('"')
      modified = true
    else:
      output.add(s[i])
    i += 1

  return (output, modified)

proc fixUnquotedKeys(text: string): (string, bool) =
  # Add quotes to unquoted keys in JSON-like text
  var s = text
  var modified = false
  var output = ""
  var i = 0

  while i < s.len:
    # Skip whitespace at start of potential key
    if i == 0 or s[i-1] in {'{', ',', '\n', '\r'}:
      # Skip leading whitespace
      var keyStart = i
      while keyStart < s.len and s[keyStart] in {' ', '\t', '\n', '\r'}:
        output.add(s[keyStart])
        keyStart += 1
      i = keyStart

      if i >= s.len:
        break

      # Check if this looks like an unquoted key (alphanumeric followed by :)
      if s[i] notin {'"', '\'', '{', '}', '[', ']', ' ', '\t', '\n', '\r'}:
        var keyEnd = i
        while keyEnd < s.len and s[keyEnd] notin {':', ' ', '\t', '\n', '\r', '"', '\'', '{', '}', '[', ']', ','}:
          keyEnd += 1

        # Skip whitespace to look for colon
        var colonPos = keyEnd
        while colonPos < s.len and s[colonPos] in {' ', '\t'}:
          colonPos += 1

        if colonPos < s.len and s[colonPos] == ':':
          # This is an unquoted key
          let key = s[i..<keyEnd]
          output.add('"')
          output.add(key)
          output.add('"')
          modified = true
          i = keyEnd
          continue

    output.add(s[i])
    i += 1

  return (output, modified)

proc removeComments(text: string): (string, bool) =
  var s = text
  var modified = false
  var output = ""
  var i = 0
  var inString = false

  while i < s.len:
    if s[i] == '"' and (i == 0 or s[i-1] != '\\'):
      inString = not inString
      output.add(s[i])
    elif not inString and i + 1 < s.len and s[i] == '/' and s[i+1] == '/':
      # Single-line comment: skip until end of line
      modified = true
      while i < s.len and s[i] != '\n':
        i += 1
      continue
    elif not inString and i + 1 < s.len and s[i] == '/' and s[i+1] == '*':
      # Multi-line comment: skip until */
      modified = true
      i += 2
      while i + 1 < s.len and not (s[i] == '*' and s[i+1] == '/'):
        i += 1
      i += 2
      continue
    else:
      output.add(s[i])
    i += 1

  return (output, modified)

proc replaceJsValues(text: string): (string, bool) =
  var s = text
  var modified = false
  if "undefined" in s:
    s = s.replace("undefined", "null")
    modified = true
  if "NaN" in s:
    s = s.replace("NaN", "0")
    modified = true
  if "Infinity" in s:
    s = s.replace("Infinity", "999999999")
    modified = true
  return (s, modified)

proc repair*(svc: var RepairService, text: string): RepairResult =
  svc.stats.totalRepairs += 1
  result.original = text
  result.actions = @[]
  result.success = false

  var current = text

  # Step 1: Strip code fences
  let (s1, m1) = stripCodeFences(current)
  if m1:
    result.actions.add(RepairAction(description: "Removed markdown code fences", applied: true))
    current = s1

  # Step 2: Remove comments
  let (s2, m2) = removeComments(current)
  if m2:
    result.actions.add(RepairAction(description: "Removed JavaScript-style comments", applied: true))
    current = s2

  # Step 3: Replace JS values
  let (s3, m3) = replaceJsValues(current)
  if m3:
    result.actions.add(RepairAction(description: "Replaced JavaScript-specific values", applied: true))
    current = s3

  # Step 4: Fix single quotes
  let (s4, m4) = fixSingleQuotes(current)
  if m4:
    result.actions.add(RepairAction(description: "Replaced single quotes with double quotes", applied: true))
    current = s4

  # Step 5: Fix unquoted keys
  let (s5, m5) = fixUnquotedKeys(current)
  if m5:
    result.actions.add(RepairAction(description: "Added quotes to unquoted keys", applied: true))
    current = s5

  # Step 6: Fix trailing commas
  let (s6, m6) = fixTrailingCommas(current)
  if m6:
    result.actions.add(RepairAction(description: "Removed trailing commas", applied: true))
    current = s6

  result.repaired = current

  # Try to parse the repaired JSON
  try:
    result.parsedJson = parseJson(current)
    result.success = true
    svc.stats.successfulRepairs += 1
  except JsonParsingError:
    # Get suggestions from MockClaudeClient
    var suggestions = svc.client.analyzeAndSuggest(text)
    for s in suggestions:
      result.actions.add(RepairAction(
        description: "AI Suggestion: " & s.suggestion,
        applied: false
      ))
    result.parsedJson = newJNull()

# ============================================================
# ConvertService - Format conversion
# ============================================================

type
  ConvertService* = object
    stats*: Stats

proc newConvertService*(): ConvertService =
  result.stats = Stats()

proc jsonToCsv(data: JsonNode): string =
  ## Convert a JSON array of objects to CSV format
  if data.kind != JArray or data.len == 0:
    return ""

  # Get headers from first object
  let first = data[0]
  if first.kind != JObject:
    return ""

  var headers: seq[string] = @[]
  for key, val in first:
    headers.add(key)

  # Build CSV
  var lines: seq[string] = @[]
  lines.add(headers.join(","))

  for item in data:
    if item.kind != JObject:
      continue
    var row: seq[string] = @[]
    for h in headers:
      if item.hasKey(h):
        let val = item[h]
        case val.kind
        of JString:
          # Escape quotes and wrap in quotes if contains comma
          var s = val.getStr()
          if ',' in s or '"' in s or '\n' in s:
            s = "\"" & s.replace("\"", "\"\"") & "\""
          row.add(s)
        of JInt:
          row.add($val.getInt())
        of JFloat:
          row.add($val.getFloat())
        of JBool:
          row.add($val.getBool())
        of JNull:
          row.add("")
        else:
          row.add($val)
      else:
        row.add("")
    lines.add(row.join(","))

  return lines.join("\n")

proc jsonNodeToYaml(node: JsonNode, indent: int): string =
  let prefix = "  ".repeat(indent)
  case node.kind
  of JObject:
    var lines: seq[string] = @[]
    for key, val in node:
      case val.kind
      of JObject:
        lines.add(prefix & key & ":")
        lines.add(jsonNodeToYaml(val, indent + 1))
      of JArray:
        lines.add(prefix & key & ":")
        for item in val:
          lines.add(prefix & "  - " & (if item.kind == JString: item.getStr() else: $item))
      of JString:
        lines.add(prefix & key & ": " & val.getStr())
      of JInt:
        lines.add(prefix & key & ": " & $val.getInt())
      of JFloat:
        lines.add(prefix & key & ": " & $val.getFloat())
      of JBool:
        lines.add(prefix & key & ": " & $val.getBool())
      of JNull:
        lines.add(prefix & key & ": null")
    return lines.join("\n")
  of JArray:
    var lines: seq[string] = @[]
    for item in node:
      case item.kind
      of JObject:
        lines.add(prefix & "-")
        lines.add(jsonNodeToYaml(item, indent + 1))
      of JString:
        lines.add(prefix & "- " & item.getStr())
      else:
        lines.add(prefix & "- " & $item)
    return lines.join("\n")
  of JString:
    return prefix & node.getStr()
  of JInt:
    return prefix & $node.getInt()
  of JFloat:
    return prefix & $node.getFloat()
  of JBool:
    return prefix & $node.getBool()
  of JNull:
    return prefix & "null"

proc jsonToYaml(data: JsonNode): string =
  return jsonNodeToYaml(data, 0)

proc convert*(svc: var ConvertService, input: string, toFormat: string): ConvertResult =
  svc.stats.totalConversions += 1
  result.input = input
  result.fromFormat = "json"
  result.toFormat = toFormat
  result.success = false

  var data: JsonNode
  try:
    data = parseJson(input)
  except JsonParsingError:
    result.error = "Invalid JSON input: " & getCurrentExceptionMsg()
    return result

  case toFormat.toLowerAscii()
  of "csv":
    let csv = jsonToCsv(data)
    if csv.len == 0:
      result.error = "Input must be a JSON array of objects for CSV conversion"
      return result
    result.output = csv
    result.success = true
    svc.stats.successfulConversions += 1
  of "yaml":
    result.output = jsonToYaml(data)
    result.success = true
    svc.stats.successfulConversions += 1
  else:
    result.error = "Unsupported target format: " & toFormat & ". Supported: csv, yaml"
