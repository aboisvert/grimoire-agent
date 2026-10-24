import std/[os, osproc, strutils, streams, tables, options, json, times, strtabs, terminal]
import failure

type GrimEnvironment* = Table[string, string]

var credentialsEnv*: GrimEnvironment = initTable[string, string]()

const serviceAccountSuppressed* =
  "1Password operation failed with service-account authentication (exit %d; details suppressed)"

proc grimBin*(): string =
  let fromEnv = getEnv("GRIM_BIN")
  if fromEnv.len > 0:
    return fromEnv
  when defined(windows):
    let found = findExe("grim")
    if found.len > 0:
      return found
    return "grim-not-found-on-PATH"
  else:
    let found = findExe("grim")
    if found.len > 0:
      return found
    return "grim-not-found-on-PATH"

proc windows*(): bool =
  when defined(windows):
    true
  else:
    false

type GrimCallOptions* = object
  account*: Option[string]
  failure*: Option[string]
  input*: Option[string]
  extraEnv*: GrimEnvironment

type ProcessOutput* = object
  stdout*: string
  stderr*: string
  exitCode*: int

proc captureOutput(
    command: string,
    args: openArray[string],
    env: StringTableRef,
    stdinData = "",
    ignoreStderr = false,
): ProcessOutput =
  var opts = {poUsePath}
  if ignoreStderr:
    incl opts, poStdErrToStdOut
  let p = startProcess(command = command, args = @args, env = env, options = opts)
  if stdinData.len > 0:
    p.inputStream.write(stdinData)
    p.inputStream.flush()
  p.inputStream.close()
  let outText = p.outputStream.readAll()
  let code = p.waitForExit()
  ProcessOutput(stdout: outText, stderr: "", exitCode: code)

proc mergedEnv(extra: GrimEnvironment): StringTableRef =
  result = newStringTable(modeCaseInsensitive)
  for k, v in envPairs():
    result[k] = v
  for k, v in credentialsEnv.pairs:
    if v.len == 0:
      if k in result:
        result.del(k)
    else:
      result[k] = v
  for k, v in extra.pairs:
    if v.len == 0:
      if k in result:
        result.del(k)
    else:
      result[k] = v

proc grimOp*(args: openArray[string], options: GrimCallOptions = GrimCallOptions()): string =
  var argv: seq[string] = @args
  if options.account.isSome:
    argv.add "--account"
    argv.add options.account.get
  let env = mergedEnv(options.extraEnv)
  let bin = grimBin()
  let input = options.input.get("")
  var procOut: ProcessOutput
  if input.len > 0 and not windows():
    let shArgs = @["-c", "cat | exec " & bin & " \"$@\"", "grim-agent"] & argv
    procOut = captureOutput("sh", shArgs, env, stdinData = input)
  elif input.len > 0:
    procOut = captureOutput(bin, argv, env, stdinData = input)
  else:
    procOut = captureOutput(bin, argv, env)
  if procOut.exitCode == 0:
    return procOut.stdout
  if options.failure.isSome:
    raise fail(options.failure.get)
  if credentialsEnv.hasKey("OP_SERVICE_ACCOUNT_TOKEN") and
      credentialsEnv["OP_SERVICE_ACCOUNT_TOKEN"].len > 0:
    raise fail(serviceAccountSuppressed.replace("%d", $procOut.exitCode))
  let err = procOut.stderr.strip()
  if err.len > 0:
    raise fail(err)
  raise fail("grim exited with " & $procOut.exitCode)

proc grimJson*(args: openArray[string], options: GrimCallOptions = GrimCallOptions()): JsonNode =
  let text = grimOp(args, options)
  try:
    return parseJson(text)
  except JsonParsingError:
    if options.failure.isSome:
      raise fail(options.failure.get)
    raise fail("grim returned invalid JSON")

proc grimExec*(
    args: openArray[string],
    command: seq[string],
    extraEnv: GrimEnvironment = initTable[string, string](),
): int =
  var argv = @args
  var child = command
  if credentialsEnv.hasKey("OP_SERVICE_ACCOUNT_TOKEN") and
      credentialsEnv["OP_SERVICE_ACCOUNT_TOKEN"].len > 0:
    when defined(windows):
      discard "TODO windows without-token"
    else:
      child = @["env", "-u", "OP_SERVICE_ACCOUNT_TOKEN"] & child
  argv.add "--"
  argv.add child
  let env = mergedEnv(extraEnv)
  let bin = grimBin()
  var p = startProcess(
    command = bin,
    args = argv,
    env = env,
    options = {poUsePath, poParentStreams},
  )
  p.waitForExit()

type Source* = enum
  clipboard
  stdinSource

proc privateInput*(source: Source, noun, outcome: string): string =
  when defined(macosx):
    discard
  else:
    if source == clipboard and not defined(windows):
      raise fail("--clipboard requires macOS or Windows; use --stdin on other platforms; " & outcome)
  if source == stdinSource and isatty(stdin):
    raise fail("Pipe the " & noun & " to --stdin; interactive input is not supported; " & outcome)
  let message = "Could not read the " & noun & " (details suppressed); " & outcome
  var text = ""
  if source == clipboard:
    when defined(macosx):
      let clipOut = captureOutput("pbpaste", [], newStringTable(), ignoreStderr = true)
      if clipOut.exitCode != 0:
        raise fail(message)
      text = clipOut.stdout
    elif defined(windows):
      raise fail("--clipboard on Windows is not implemented yet; use --stdin; " & outcome)
    else:
      raise fail(message)
  else:
    text = stdin.readAll()
  if text.strip.len == 0:
    raise fail("The " & noun & " input is empty; " & outcome)
  text

proc localProbeEnv(): StringTableRef =
  result = newStringTable(modeCaseInsensitive)
  for k, v in envPairs():
    result[k] = v
  for key in ["OP_SERVICE_ACCOUNT_TOKEN", "OP_ACCOUNT", "OP_CONNECT_HOST", "OP_CONNECT_TOKEN"]:
    if key in result:
      result.del(key)

proc captureLocal*(args: openArray[string], timeoutSec = 5): Option[string] =
  let bin = grimBin()
  try:
    var p = startProcess(
      command = bin,
      args = @args,
      env = localProbeEnv(),
      options = {poUsePath, poStdErrToStdOut},
    )
    p.inputStream.close()
    let deadline = getTime() + timeoutSec.seconds
    while p.running:
      if getTime() > deadline:
        p.close()
        return none(string)
      sleep(10)
    let verOut = p.outputStream.readAll()
    let code = p.waitForExit()
    if code != 0:
      return none(string)
    return some(verOut.strip())
  except OSError:
    return none(string)
