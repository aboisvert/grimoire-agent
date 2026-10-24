import std/unittest
import envcmd

suite "env parse":
  test "parseAssignment accepts op and grim references":
    let op = parseAssignment("OPENAI_API_KEY=op://Automation/OpenAI API Key/credential")
    check op.name == "OPENAI_API_KEY"
    check op.reference == "op://Automation/OpenAI API Key/credential"
    let grim = parseAssignment("DB_PASSWORD=grim://Work/Production DB/value")
    check grim.name == "DB_PASSWORD"
    check grim.reference == "grim://Work/Production DB/value"

  test "parseEnv collects grim and op references for resolve":
    let content =
      "LITERAL=plain\nFIRST=op://Personal/First/credential\nSECOND=grim://Work/Second/value\n"
    let (_, count) = resolveEnv(
      content,
      proc(refs: seq[string]): seq[string] =
        check refs == @[
          "op://Personal/First/credential",
          "grim://Work/Second/value",
        ]
        var values: seq[string] = @[]
        for r in refs:
          values.add "resolved"
        values,
    )
    check count == 2

  test "parseAssignment rejects non-reference values":
    expect ValueError:
      discard parseAssignment("X=not-a-reference")
