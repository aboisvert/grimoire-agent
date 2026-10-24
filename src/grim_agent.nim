import std/[strutils, os, json]
import failure
import arguments
import cli

proc dumpResolved(count: int) =
  var values = newJArray()
  for i in 0 ..< count:
    let key = "GRIM_AGENT_SECRET_" & $i
    values.add %getEnv(key)
  stdout.write($values)

proc main() =
  let raw = commandLineParams()
  if raw.len >= 2 and raw[0] == "--dump-resolved":
    dumpResolved(parseInt(raw[1]))
    return
  let args = normalizeTrailingArguments(raw)
  try:
    runCli(args)
  except Failure as e:
    grimAgentError(e.message)
  except ValueError as e:
    grimAgentError(e.msg)
  except CatchableError as e:
    grimAgentError(e.msg)

main()
