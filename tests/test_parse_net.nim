## test_parse_net.nim - Comprehensive tests for ParseNet
##
## Tests for models, services, clients, and integration scenarios.

import std/[unittest, json, strutils, tables]

# Import project modules (path configured via nim.cfg)
import models
import services
import clients

# ============================================================
# Models Tests
# ============================================================

suite "Models - FieldType":
  test "fieldTypeFromString converts known types":
    check fieldTypeFromString("string") == ftString
    check fieldTypeFromString("number") == ftNumber
    check fieldTypeFromString("boolean") == ftBoolean
    check fieldTypeFromString("array") == ftArray
    check fieldTypeFromString("object") == ftObject

  test "fieldTypeFromString defaults to string for unknown":
    check fieldTypeFromString("unknown") == ftString
    check fieldTypeFromString("") == ftString

suite "Models - Schema Parsing":
  test "parseSchema extracts name and description":
    let node = %*{
      "name": "UserProfile",
      "description": "A user profile schema",
      "fields": []
    }
    let schema = parseSchema(node)
    check schema.name == "UserProfile"
    check schema.description == "A user profile schema"
    check schema.fields.len == 0

  test "parseSchema parses fields correctly":
    let node = %*{
      "name": "Test",
      "fields": [
        {"name": "username", "type": "string", "required": true},
        {"name": "age", "type": "number", "required": false}
      ]
    }
    let schema = parseSchema(node)
    check schema.fields.len == 2
    check schema.fields[0].name == "username"
    check schema.fields[0].fieldType == ftString
    check schema.fields[0].required == true
    check schema.fields[1].name == "age"
    check schema.fields[1].fieldType == ftNumber
    check schema.fields[1].required == false

  test "parseSchema handles nested object properties":
    let node = %*{
      "name": "Nested",
      "fields": [
        {
          "name": "address",
          "type": "object",
          "required": true,
          "properties": [
            {"name": "street", "type": "string", "required": true},
            {"name": "city", "type": "string", "required": true}
          ]
        }
      ]
    }
    let schema = parseSchema(node)
    check schema.fields[0].properties.len == 2
    check schema.fields[0].properties[0].name == "street"

suite "Models - JSON Serialization":
  test "schemaToJson roundtrip":
    let schema = Schema(
      id: "schema_1",
      name: "Test",
      description: "Test schema",
      fields: @[SchemaField(name: "title", fieldType: ftString, required: true)],
      createdAt: "2026-01-01T00:00:00Z"
    )
    let j = schemaToJson(schema)
    check j["id"].getStr() == "schema_1"
    check j["name"].getStr() == "Test"
    check j["fields"].len == 1

  test "validationErrorToJson produces correct structure":
    let err = ValidationError(
      field: "email",
      message: "Required field missing",
      expected: "string",
      actual: "missing"
    )
    let j = validationErrorToJson(err)
    check j["field"].getStr() == "email"
    check j["message"].getStr() == "Required field missing"

  test "statsToJson computes success rate":
    let stats = Stats(
      totalValidations: 10,
      totalRepairs: 5,
      totalConversions: 5,
      successfulValidations: 8,
      successfulRepairs: 4,
      successfulConversions: 4
    )
    let j = statsToJson(stats)
    check j["total_validations"].getInt() == 10
    check j["success_rate"].getFloat() == 80.0

  test "statsToJson handles zero totals":
    let stats = Stats()
    let j = statsToJson(stats)
    check j["success_rate"].getFloat() == 0.0

# ============================================================
# SchemaService Tests
# ============================================================

suite "SchemaService":
  test "register and retrieve schema":
    var svc = newSchemaService()
    let body = %*{
      "name": "UserProfile",
      "description": "User profile schema",
      "fields": [
        {"name": "name", "type": "string", "required": true},
        {"name": "email", "type": "string", "required": true}
      ]
    }
    let schema = svc.registerSchema(body)
    check schema.id == "schema_1"
    check schema.name == "UserProfile"
    check schema.createdAt.len > 0

    let retrieved = svc.getSchema("schema_1")
    check retrieved.name == "UserProfile"
    check retrieved.fields.len == 2

  test "list schemas returns all registered":
    var svc = newSchemaService()
    discard svc.registerSchema(%*{"name": "S1", "fields": []})
    discard svc.registerSchema(%*{"name": "S2", "fields": []})
    discard svc.registerSchema(%*{"name": "S3", "fields": []})
    let schemas = svc.listSchemas()
    check schemas.len == 3

  test "delete schema removes it":
    var svc = newSchemaService()
    discard svc.registerSchema(%*{"name": "ToDelete", "fields": []})
    check svc.deleteSchema("schema_1") == true
    check svc.listSchemas().len == 0

  test "delete nonexistent schema returns false":
    var svc = newSchemaService()
    check svc.deleteSchema("nonexistent") == false

  test "get nonexistent schema raises KeyError":
    var svc = newSchemaService()
    expect(KeyError):
      discard svc.getSchema("nonexistent")

  test "auto-incrementing IDs":
    var svc = newSchemaService()
    let s1 = svc.registerSchema(%*{"name": "A", "fields": []})
    let s2 = svc.registerSchema(%*{"name": "B", "fields": []})
    check s1.id == "schema_1"
    check s2.id == "schema_2"

# ============================================================
# ValidationService Tests
# ============================================================

suite "ValidationService":
  test "valid data passes validation":
    var svc = newValidationService()
    let schema = Schema(
      id: "s1", name: "Test",
      fields: @[
        SchemaField(name: "name", fieldType: ftString, required: true),
        SchemaField(name: "age", fieldType: ftNumber, required: true)
      ]
    )
    let data = %*{"name": "Alice", "age": 30}
    let vr = svc.validate(data, schema)
    check vr.valid == true
    check vr.errors.len == 0

  test "missing required field fails":
    var svc = newValidationService()
    let schema = Schema(
      id: "s1", name: "Test",
      fields: @[
        SchemaField(name: "name", fieldType: ftString, required: true),
        SchemaField(name: "email", fieldType: ftString, required: true)
      ]
    )
    let data = %*{"name": "Alice"}
    let vr = svc.validate(data, schema)
    check vr.valid == false
    check vr.errors.len == 1
    check vr.errors[0].field == "email"

  test "type mismatch detected":
    var svc = newValidationService()
    let schema = Schema(
      id: "s1", name: "Test",
      fields: @[SchemaField(name: "age", fieldType: ftNumber, required: true)]
    )
    let data = %*{"age": "not a number"}
    let vr = svc.validate(data, schema)
    check vr.valid == false
    check vr.errors[0].message == "Type mismatch"

  test "validates all field types":
    var svc = newValidationService()
    let schema = Schema(
      id: "s1", name: "AllTypes",
      fields: @[
        SchemaField(name: "str", fieldType: ftString, required: true),
        SchemaField(name: "num", fieldType: ftNumber, required: true),
        SchemaField(name: "flag", fieldType: ftBoolean, required: true),
        SchemaField(name: "items", fieldType: ftArray, required: true),
        SchemaField(name: "meta", fieldType: ftObject, required: true)
      ]
    )
    let data = %*{
      "str": "hello",
      "num": 42,
      "flag": true,
      "items": [1, 2, 3],
      "meta": {"key": "value"}
    }
    let vr = svc.validate(data, schema)
    check vr.valid == true

  test "nested object validation":
    var svc = newValidationService()
    let schema = Schema(
      id: "s1", name: "Nested",
      fields: @[
        SchemaField(
          name: "address", fieldType: ftObject, required: true,
          properties: @[
            SchemaField(name: "street", fieldType: ftString, required: true),
            SchemaField(name: "city", fieldType: ftString, required: true)
          ]
        )
      ]
    )
    let data = %*{"address": {"street": "123 Main St"}}
    let vr = svc.validate(data, schema)
    check vr.valid == false
    check vr.errors.len == 1
    check vr.errors[0].field == "address.city"

  test "optional fields don't fail when missing":
    var svc = newValidationService()
    let schema = Schema(
      id: "s1", name: "Test",
      fields: @[
        SchemaField(name: "name", fieldType: ftString, required: true),
        SchemaField(name: "bio", fieldType: ftString, required: false)
      ]
    )
    let data = %*{"name": "Alice"}
    let vr = svc.validate(data, schema)
    check vr.valid == true

  test "non-object root fails validation":
    var svc = newValidationService()
    let schema = Schema(id: "s1", name: "Test", fields: @[])
    let data = %*[1, 2, 3]
    let vr = svc.validate(data, schema)
    check vr.valid == false
    check vr.errors[0].field == "<root>"

  test "null required field fails":
    var svc = newValidationService()
    let schema = Schema(
      id: "s1", name: "Test",
      fields: @[SchemaField(name: "name", fieldType: ftString, required: true)]
    )
    let data = %*{"name": newJNull()}
    let vr = svc.validate(data, schema)
    check vr.valid == false

  test "stats are updated":
    var svc = newValidationService()
    let schema = Schema(id: "s1", name: "Test", fields: @[])
    discard svc.validate(%*{}, schema)
    discard svc.validate(%*{}, schema)
    check svc.stats.totalValidations == 2
    check svc.stats.successfulValidations == 2

# ============================================================
# RepairService Tests
# ============================================================

suite "RepairService":
  test "strip markdown code fences":
    var svc = newRepairService()
    let text = "```json\n{\"name\": \"Alice\"}\n```"
    let rr = svc.repair(text)
    check rr.success == true
    check rr.parsedJson["name"].getStr() == "Alice"
    check rr.actions.len > 0

  test "fix trailing commas in object":
    var svc = newRepairService()
    let text = """{"name": "Alice", "age": 30,}"""
    let rr = svc.repair(text)
    check rr.success == true
    check rr.parsedJson["name"].getStr() == "Alice"

  test "fix trailing commas in array":
    var svc = newRepairService()
    let text = """[1, 2, 3,]"""
    let rr = svc.repair(text)
    check rr.success == true
    check rr.parsedJson.len == 3

  test "fix single quotes to double quotes":
    var svc = newRepairService()
    let text = "{'name': 'Alice', 'age': 30}"
    let rr = svc.repair(text)
    check rr.success == true
    check rr.parsedJson["name"].getStr() == "Alice"

  test "valid JSON passes through unchanged":
    var svc = newRepairService()
    let text = """{"valid": true, "count": 42}"""
    let rr = svc.repair(text)
    check rr.success == true
    check rr.actions.len == 0

  test "combined repairs: fences + trailing comma":
    var svc = newRepairService()
    let text = "```json\n{\"items\": [1, 2, 3,],}\n```"
    let rr = svc.repair(text)
    check rr.success == true

  test "replace JavaScript undefined/NaN":
    var svc = newRepairService()
    let text = """{"value": null, "count": 0}"""
    let rr = svc.repair(text)
    check rr.success == true

  test "stats track repairs":
    var svc = newRepairService()
    discard svc.repair("""{"ok": true}""")
    discard svc.repair("""{"ok": false}""")
    check svc.stats.totalRepairs == 2
    check svc.stats.successfulRepairs == 2

# ============================================================
# MockClaudeClient Tests
# ============================================================

suite "MockClaudeClient":
  test "detects markdown code fences":
    var client = newMockClaudeClient()
    let suggestions = client.analyzeAndSuggest("```json\n{}\n```")
    check suggestions.len > 0
    var found = false
    for s in suggestions:
      if "code fences" in s.issue.toLowerAscii():
        found = true
        break
    check found == true

  test "detects trailing commas":
    var client = newMockClaudeClient()
    let suggestions = client.analyzeAndSuggest("""{"a": 1,}""")
    var found = false
    for s in suggestions:
      if "trailing" in s.issue.toLowerAscii():
        found = true
        break
    check found == true

  test "detects single quotes":
    var client = newMockClaudeClient()
    let suggestions = client.analyzeAndSuggest("{'key': 'value'}")
    var found = false
    for s in suggestions:
      if "single quotes" in s.issue.toLowerAscii():
        found = true
        break
    check found == true

  test "detects JavaScript comments":
    var client = newMockClaudeClient()
    let suggestions = client.analyzeAndSuggest("""{"a": 1} // comment""")
    var found = false
    for s in suggestions:
      if "comment" in s.issue.toLowerAscii():
        found = true
        break
    check found == true

  test "increments call count":
    var client = newMockClaudeClient()
    check client.callCount == 0
    discard client.analyzeAndSuggest("{}")
    check client.callCount == 1
    discard client.analyzeAndSuggest("{}")
    check client.callCount == 2

  test "returns generic suggestion for clean input":
    var client = newMockClaudeClient()
    let suggestions = client.analyzeAndSuggest("{}")
    check suggestions.len == 1
    check "no obvious" in suggestions[0].issue.toLowerAscii()

  test "suggestionToJson produces valid JSON":
    let sug = RepairSuggestion(
      issue: "Test issue",
      suggestion: "Test fix",
      confidence: 0.95
    )
    let j = suggestionToJson(sug)
    check j["issue"].getStr() == "Test issue"
    check j["confidence"].getFloat() == 0.95

# ============================================================
# ConvertService Tests
# ============================================================

suite "ConvertService - JSON to CSV":
  test "converts array of objects to CSV":
    var svc = newConvertService()
    let input = """[{"name":"Alice","age":30},{"name":"Bob","age":25}]"""
    let cr = svc.convert(input, "csv")
    check cr.success == true
    let lines = cr.output.splitLines()
    check lines.len == 3
    check "name" in lines[0]
    check "age" in lines[0]
    check "Alice" in lines[1]
    check "Bob" in lines[2]

  test "handles CSV-unsafe characters":
    var svc = newConvertService()
    let input = """[{"text":"hello, world","num":1}]"""
    let cr = svc.convert(input, "csv")
    check cr.success == true
    check "\"hello, world\"" in cr.output

  test "rejects non-array input for CSV":
    var svc = newConvertService()
    let input = """{"name": "Alice"}"""
    let cr = svc.convert(input, "csv")
    check cr.success == false
    check cr.error.len > 0

  test "rejects invalid JSON":
    var svc = newConvertService()
    let cr = svc.convert("not json", "csv")
    check cr.success == false

suite "ConvertService - JSON to YAML":
  test "converts object to YAML-like text":
    var svc = newConvertService()
    let input = """{"name":"Alice","age":30}"""
    let cr = svc.convert(input, "yaml")
    check cr.success == true
    check "name: Alice" in cr.output
    check "age: 30" in cr.output

  test "converts nested object to YAML":
    var svc = newConvertService()
    let input = """{"user":{"name":"Alice","role":"admin"}}"""
    let cr = svc.convert(input, "yaml")
    check cr.success == true
    check "user:" in cr.output
    check "name: Alice" in cr.output

  test "converts array to YAML":
    var svc = newConvertService()
    let input = """["apple","banana","cherry"]"""
    let cr = svc.convert(input, "yaml")
    check cr.success == true
    check "- apple" in cr.output
    check "- banana" in cr.output

  test "unsupported format returns error":
    var svc = newConvertService()
    let cr = svc.convert("""{"a":1}""", "xml")
    check cr.success == false
    check "Unsupported" in cr.error

  test "stats track conversions":
    var svc = newConvertService()
    discard svc.convert("""[{"a":1}]""", "csv")
    discard svc.convert("""{"a":1}""", "yaml")
    check svc.stats.totalConversions == 2
    check svc.stats.successfulConversions == 2

# ============================================================
# Integration Tests (Full pipeline)
# ============================================================

suite "Integration - Parse Pipeline":
  test "full pipeline: repair then validate":
    var schemaSvc = newSchemaService()
    var validSvc = newValidationService()
    var repairSvc = newRepairService()

    # Register schema
    let schema = schemaSvc.registerSchema(%*{
      "name": "UserProfile",
      "fields": [
        {"name": "name", "type": "string", "required": true},
        {"name": "email", "type": "string", "required": true},
        {"name": "age", "type": "number", "required": false}
      ]
    })

    # Malformed input with code fences and trailing comma
    let malformed = "```json\n{\"name\": \"Alice\", \"email\": \"alice@test.com\", \"age\": 30,}\n```"

    # Step 1: Repair
    let repairRes = repairSvc.repair(malformed)
    check repairRes.success == true

    # Step 2: Validate
    let valRes = validSvc.validate(repairRes.parsedJson, schema)
    check valRes.valid == true
    check valRes.schemaId == schema.id

  test "pipeline with validation failure":
    var schemaSvc = newSchemaService()
    var validSvc = newValidationService()
    var repairSvc = newRepairService()

    let schema = schemaSvc.registerSchema(%*{
      "name": "Product",
      "fields": [
        {"name": "name", "type": "string", "required": true},
        {"name": "price", "type": "number", "required": true}
      ]
    })

    # Valid JSON but missing required field
    let input = """{"name": "Widget"}"""
    let repairRes = repairSvc.repair(input)
    check repairRes.success == true

    let valRes = validSvc.validate(repairRes.parsedJson, schema)
    check valRes.valid == false
    check valRes.errors.len == 1

  test "repair and convert to CSV":
    var repairSvc = newRepairService()
    var convertSvc = newConvertService()

    let malformed = "```json\n[{\"name\": \"Alice\", \"score\": 95,}, {\"name\": \"Bob\", \"score\": 87,}]\n```"
    let repairRes = repairSvc.repair(malformed)
    check repairRes.success == true

    let convertRes = convertSvc.convert(repairRes.repaired, "csv")
    check convertRes.success == true
    check "name" in convertRes.output
    check "Alice" in convertRes.output

  test "repair and convert to YAML":
    var repairSvc = newRepairService()
    var convertSvc = newConvertService()

    let malformed = "{'name': 'Alice', 'role': 'admin'}"
    let repairRes = repairSvc.repair(malformed)
    check repairRes.success == true

    let convertRes = convertSvc.convert(repairRes.repaired, "yaml")
    check convertRes.success == true
    check "name: Alice" in convertRes.output

  test "convertResultToJson produces correct structure":
    let cr = ConvertResult(
      input: "test",
      output: "output_val",
      fromFormat: "json",
      toFormat: "csv",
      success: true,
      error: ""
    )
    let j = convertResultToJson(cr)
    check j["success"].getBool() == true
    check j["from_format"].getStr() == "json"
    check j.hasKey("error") == false

  test "convertResultToJson includes error when present":
    let cr = ConvertResult(
      input: "test",
      output: "",
      fromFormat: "json",
      toFormat: "csv",
      success: false,
      error: "Failed to convert"
    )
    let j = convertResultToJson(cr)
    check j["error"].getStr() == "Failed to convert"

# Print summary
echo "\nAll tests passed!"
