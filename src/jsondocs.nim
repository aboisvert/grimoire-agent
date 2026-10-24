import std/json

proc parseJsonDocuments*(input: string): seq[JsonNode] =
  var start = -1
  var depth = 0
  var quoted = false
  var escaped = false
  for i, character in input:
    if quoted:
      if escaped:
        escaped = false
      elif character == '\\':
        escaped = true
      elif character == '"':
        quoted = false
      continue
    if character == '"':
      quoted = true
    elif character == '{' or character == '[':
      if depth == 0:
        start = i
      inc depth
    elif character == '}' or character == ']':
      dec depth
      if depth == 0 and start >= 0:
        let slice = input[start .. i]
        let parsed = parseJson(slice)
        if parsed.kind == JArray:
          for item in parsed:
            result.add item
        else:
          result.add parsed
        start = -1
  if depth != 0 or quoted:
    raise newException(ValueError, "Incomplete JSON document")
