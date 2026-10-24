import std/[os, osproc, strutils, streams, json, times, tables, strtabs, random]

type AgentResult* = object
  code*: int
  stdout*: string
  stderr*: string

proc repoRoot*(): string =
  currentSourcePath().parentDir().parentDir()

proc agentBin*(): string =
  repoRoot() / "grim-agent"

proc makeTempDir(prefix: string): string =
  let base = getTempDir() / (prefix & "-" & $getTime().toUnix() & "-" & $rand(100000))
  createDir(base)
  base

proc writeExecutable(path, content: string) =
  writeFile(path, content)
  when defined(windows):
    discard
  else:
    discard execShellCmd("chmod 755 '" & path.replace("'", "'\\''") & "'")

proc sandbox*(fakes: Table[string, string]): (string, proc(
    args: openArray[string], input = "", extraEnv: Table[string, string] = initTable[string, string]()): AgentResult) =
  let home = makeTempDir("grim-agent-test")
  let callsFile = home / "calls"
  for command, script in fakes.pairs:
    writeExecutable(home / command, script)
  when not defined(windows):
    discard execShellCmd("ln -sf /bin/sh '" & (home / "sh").replace("'", "'\\''") & "'")
    discard execShellCmd("ln -sf /bin/cat '" & (home / "cat").replace("'", "'\\''") & "'")

  proc runAgent(
      args: openArray[string],
      input = "",
      extraEnv: Table[string, string] = initTable[string, string]()): AgentResult =
    writeFile(callsFile, "")
    var env = newStringTable(modeCaseInsensitive)
    env["HOME"] = home
    env["PATH"] = home
    env["TEST_CALLS"] = callsFile
    for k, v in extraEnv.pairs:
      env[k] = v
    var p = startProcess(
      command = agentBin(),
      args = @args,
      env = env,
      options = {poStdErrToStdOut},
    )
    if input.len > 0:
      p.inputStream.write(input)
      p.inputStream.flush()
    p.inputStream.close()
    let outputText = p.outputStream.readAll()
    let code = p.waitForExit()
    AgentResult(code: code, stdout: outputText, stderr: "")

  (home, runAgent)

proc readCalls*(home: string): seq[JsonNode] =
  let file = home / "calls"
  if not fileExists(file):
    return @[]
  result = @[]
  for line in readFile(file).splitLines():
    if line.len > 0:
      result.add parseJson(line)
