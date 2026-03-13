## clients.nim - MockClaudeClient for AI-powered repair suggestions
##
## Provides deterministic repair suggestions for malformed LLM outputs.

import std/[json, strutils]

type
  RepairSuggestion* = object
    issue*: string
    suggestion*: string
    confidence*: float

  MockClaudeClient* = object
    model*: string
    callCount*: int

proc newMockClaudeClient*(model: string = "claude-3-mock"): MockClaudeClient =
  result.model = model
  result.callCount = 0

proc analyzeAndSuggest*(client: var MockClaudeClient, malformedText: string): seq[RepairSuggestion] =
  ## Analyze malformed text and return deterministic repair suggestions
  client.callCount += 1
  result = @[]

  # Check for markdown code fences
  if "```" in malformedText:
    result.add(RepairSuggestion(
      issue: "Markdown code fences detected",
      suggestion: "Remove ```json and ``` markers wrapping the JSON content",
      confidence: 0.95
    ))

  # Check for trailing commas
  if ",}" in malformedText or ",]" in malformedText:
    result.add(RepairSuggestion(
      issue: "Trailing commas found",
      suggestion: "Remove trailing commas before closing braces/brackets",
      confidence: 0.98
    ))

  # Check for single quotes
  if "'" in malformedText:
    result.add(RepairSuggestion(
      issue: "Single quotes used instead of double quotes",
      suggestion: "Replace single quotes with double quotes for JSON compliance",
      confidence: 0.90
    ))

  # Check for unquoted keys
  # Simple heuristic: look for patterns like `word:` not preceded by `"`
  var lines = malformedText.splitLines()
  for line in lines:
    let trimmed = line.strip()
    if trimmed.len > 0 and not trimmed.startsWith("\"") and not trimmed.startsWith("{") and
       not trimmed.startsWith("}") and not trimmed.startsWith("[") and
       not trimmed.startsWith("]") and not trimmed.startsWith("//") and
       not trimmed.startsWith("```"):
      if ":" in trimmed:
        let colonPos = trimmed.find(':')
        if colonPos > 0:
          let beforeColon = trimmed[0..<colonPos].strip()
          if not beforeColon.startsWith("\"") and not beforeColon.startsWith("'"):
            result.add(RepairSuggestion(
              issue: "Unquoted key detected: " & beforeColon,
              suggestion: "Add double quotes around key: \"" & beforeColon & "\"",
              confidence: 0.85
            ))
            break  # Only report once

  # Check for JavaScript-style comments
  if "//" in malformedText or "/*" in malformedText:
    result.add(RepairSuggestion(
      issue: "JavaScript-style comments found",
      suggestion: "Remove comments as they are not valid in JSON",
      confidence: 0.92
    ))

  # Check for undefined/NaN/Infinity
  if "undefined" in malformedText or "NaN" in malformedText or "Infinity" in malformedText:
    result.add(RepairSuggestion(
      issue: "JavaScript-specific values found (undefined/NaN/Infinity)",
      suggestion: "Replace with JSON-compatible values (null for undefined, 0 for NaN)",
      confidence: 0.88
    ))

  # If no issues found, still return a generic suggestion
  if result.len == 0:
    result.add(RepairSuggestion(
      issue: "No obvious structural issues detected",
      suggestion: "The text may already be valid JSON or requires manual inspection",
      confidence: 0.50
    ))

proc suggestionToJson*(s: RepairSuggestion): JsonNode =
  result = %*{
    "issue": s.issue,
    "suggestion": s.suggestion,
    "confidence": s.confidence
  }

proc suggestionsToJson*(suggestions: seq[RepairSuggestion]): JsonNode =
  result = newJArray()
  for s in suggestions:
    result.add(suggestionToJson(s))
