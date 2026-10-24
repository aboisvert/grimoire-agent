import std/[strutils, tables, os, json, times]
import failure
import grim

type Assignment* = object
  name*: string
  reference*: string

proc validEnvName(name: string): bool =
  if name.len == 0:
    return false
  if not (name[0] in {'A' .. 'Z', 'a' .. 'z', '_'}):
    return false
  for i in 1 ..< name.len:
    if name[i] notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}:
      return false
  true

proc isSecretReference*(reference: string): bool =
  reference.startsWith("op://") or reference.startsWith("grim://")

proc parseAssignment*(assignment: string): Assignment =
  let eq = assignment.find('=')
  if eq < 1:
    raise newException(
      ValueError, "Expected NAME=grim://reference or NAME=op://reference, received: " & assignment)
  let name = assignment[0 ..< eq]
  let reference = assignment[eq + 1 .. ^1]
  if not validEnvName(name):
    raise newException(ValueError, "Invalid environment variable name: " & name)
  if not isSecretReference(reference):
    raise newException(ValueError, "Secret reference must start with grim:// or op://: " & name)
  Assignment(name: name, reference: reference)

proc unquote*(value: string): string =
  if value.len >= 2 and (
      (value[0] == '"' and value[^1] == '"') or (value[0] == '\'' and value[^1] == '\'')):
    value[1 .. ^2]
  else:
    value

type EnvLineKind = enum
  elLiteral
  elReference

type EnvLine = object
  case kind: EnvLineKind
  of elLiteral:
    literal: string
  of elReference:
    name: string
    reference: string

proc parseEnv*(content: string): seq[EnvLine] =
  for original in content.splitLines():
    let trimmed = original.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"):
      result.add EnvLine(kind: elLiteral, literal: original)
      continue
    var assignment = trimmed
    if assignment.startsWith("export "):
      assignment = assignment[7 .. ^1].strip()
    let eq = assignment.find('=')
    if eq < 1:
      result.add EnvLine(kind: elLiteral, literal: original)
      continue
    let name = assignment[0 ..< eq].strip()
    let reference = unquote(assignment[eq + 1 .. ^1].strip())
    if validEnvName(name) and isSecretReference(reference):
      result.add EnvLine(kind: elReference, name: name, reference: reference)
    else:
      result.add EnvLine(kind: elLiteral, literal: original)

proc renderEnv*(assignments: seq[Assignment]): string =
  var lines: seq[string] = @[]
  for a in assignments:
    lines.add a.name & "=" & a.reference
  lines.join("\n") & "\n"

proc quoteEnvValue*(value: string): string =
  "\"" & value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r") & "\""

proc resolveEnv*(
    content: string,
    resolve: proc(refs: seq[string]): seq[string],
): tuple[content: string, count: int] =
  let parsed = parseEnv(content)
  var refs: seq[string] = @[]
  for line in parsed:
    if line.kind == elReference and line.reference notin refs:
      refs.add line.reference
  let resolved = resolve(refs)
  if resolved.len != refs.len:
    raise newException(ValueError, "Secret resolver returned an unexpected number of values")
  var values = initTable[string, string]()
  for i, r in refs:
    values[r] = resolved[i]
  var outLines: seq[string] = @[]
  var count = 0
  for line in parsed:
    if line.kind == elLiteral:
      outLines.add line.literal
    else:
      inc count
      var v = values[line.reference]
      if v.endsWith("\n"):
        v = v[0 .. ^2]
      outLines.add line.name & "=" & quoteEnvValue(v)
  (outLines.join("\n"), count)

proc readReference*(reference: string): string =
  grimOp(@["read", reference])

proc readMany*(references: seq[string]): seq[string] =
  if references.len == 0:
    return @[]
  var extra = initTable[string, string]()
  for i, r in references:
    extra["GRIM_AGENT_SECRET_" & $i] = r
  let agent = getAppFilename()
  let runOut = grimOp(
    @["run", "--no-masking", "--", agent, "--dump-resolved", $references.len],
    GrimCallOptions(extraEnv: extra),
  )
  let values = parseJson(runOut)
  if values.kind != JArray or values.len != references.len:
    raise fail("grim returned an invalid secret batch")
  result = @[]
  for v in values:
    if v.kind != JString:
      raise fail("grim returned an invalid secret batch")
    result.add v.getStr()

proc runAssignments*(assignments: seq[Assignment], command: seq[string]): int =
  var extra = initTable[string, string]()
  for a in assignments:
    extra[a.name] = a.reference
  grimExec(@["run"], command, extra)

proc runEnvFile*(file: string, command: seq[string]): int =
  grimExec(@["run", "--env-file=" & file], command)

proc writeEnvFile*(file: string, assignments: seq[Assignment]) =
  writeFile(file, renderEnv(assignments))
  stderr.writeLine("Wrote ", assignments.len, " secret references to ", file)

proc resolveFile*(file: string, target: string) =
  let content = readFile(file)
  let resolved = resolveEnv(content, readMany)
  let dir = parentDir(target)
  let base = splitFile(target).name
  let tmp = joinPath(dir, "." & base & ".tmp." & $getTime().toUnix())
  writeFile(tmp, resolved.content)
  when not defined(windows):
    discard execShellCmd("chmod 600 " & tmp)
  moveFile(tmp, target)
  when not defined(windows):
    discard execShellCmd("chmod 600 " & target)
  stderr.writeLine(
    "Resolved ", resolved.count, " secret references into ", target,
    "; this file now contains plaintext secrets")
