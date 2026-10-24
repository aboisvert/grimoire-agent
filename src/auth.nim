import std/[os, json, strutils, streams, options, tables, osproc, times, re]
import failure
import grim

const storageMacos* = "macos-keychain"
const storageWindows* = "windows-dpapi"

type Vault* = object
  id*: string
  name*: string

type Settings* = object
  name*: string
  vaults*: seq[Vault]
  tokenRef*: Option[string]

proc desktopEnvironment*(): GrimEnvironment =
  var e = initTable[string, string]()
  e["OP_SERVICE_ACCOUNT_TOKEN"] = ""
  e["OP_CONNECT_HOST"] = ""
  e["OP_CONNECT_TOKEN"] = ""
  e

proc serviceEnvironment*(token: string): GrimEnvironment =
  var e = initTable[string, string]()
  e["OP_SERVICE_ACCOUNT_TOKEN"] = token
  e["OP_ACCOUNT"] = ""
  e["OP_CONNECT_HOST"] = ""
  e["OP_CONNECT_TOKEN"] = ""
  e

proc storageKind*(): string =
  when defined(windows):
    storageWindows
  else:
    storageMacos

proc settingsPath*(): string =
  let home =
    if getEnv("HOME").len > 0:
      getEnv("HOME")
    else:
      getEnv("USERPROFILE")
  joinPath(home, ".config", "grimoire-agent", "service-account.json")

proc readSettings*(): Option[Settings] =
  let file = settingsPath()
  if not fileExists(file):
    return none(Settings)
  try:
    let raw = readFile(file)
    let j = parseJson(raw)
    var s: Settings
    s.name = j["name"].getStr()
    for v in j["vaults"]:
      s.vaults.add Vault(id: v["id"].getStr(), name: v["name"].getStr())
    if "tokenRef" in j and j["tokenRef"].kind != JNull:
      s.tokenRef = some(j["tokenRef"].getStr())
    return some(s)
  except:
    raise fail(
      "Could not read service-account settings; use --desktop for administrative access")

proc saveSettings*(value: Settings) =
  let file = settingsPath()
  let dir = parentDir(file)
  createDir(dir)
  let mode = 0o700
  when not defined(windows):
    discard # chmod dir best-effort via temp write
  var j = %*{"name": value.name, "vaults": %[]}
  for v in value.vaults:
    j["vaults"].add(%*{"id": v.id, "name": v.name})
  if value.tokenRef.isSome:
    j["tokenRef"] = %value.tokenRef.get
  let tmp = file & ".tmp." & $getTime().toUnix()
  writeFile(tmp, pretty(j) & "\n")
  when not defined(windows):
    discard execShellCmd("chmod 600 " & tmp)
  moveFile(tmp, file)
  when not defined(windows):
    discard execShellCmd("chmod 600 " & file)

const keychainScriptSource = staticRead("../assets/keychain.jxa.js")

proc ensureKeychainScript*(): string =
  let path = joinPath(getTempDir(), "grimoire-agent-keychain.jxa")
  writeFile(path, keychainScriptSource)
  path

proc keychainCapture(operation, message: string, token = ""): string =
  when not defined(macosx):
    if not defined(windows):
      raise fail("Saved service accounts require macOS Keychain; use OP_SERVICE_ACCOUNT_TOKEN on other platforms")
    raise fail("Windows DPAPI storage is not implemented yet")
  else:
    let script = ensureKeychainScript()
    var args = @["-l", "JavaScript", script, operation, "grimoire-agent", "service-account"]
    var p = startProcess(command = "osascript", args = args, options = {poUsePath, poStdErrToStdOut})
    if token.len > 0:
      p.inputStream.write(token)
      p.inputStream.flush()
    p.inputStream.close()
    let outputText = p.outputStream.readAll()
    let code = p.waitForExit()
    if code != 0:
      raise fail(message)
    return outputText

proc keychainToken*(): string =
  when not defined(macosx):
    raise fail(
      "Saved service accounts require macOS Keychain; use OP_SERVICE_ACCOUNT_TOKEN on other platforms")
  let raw = keychainCapture(
    "get",
    "Could not read the saved service-account token; unlock Keychain or use --desktop. Desktop authentication was not attempted",
  )
  raw.replace(re"\r?\n$", "")

proc saveToken*(token: string) =
  when not defined(macosx):
    raise fail("Saving a service account requires macOS Keychain")
  discard keychainCapture("add", "Keychain storage failed; account creation must not be retried", token)
  if keychainToken() != token:
    raise fail("Keychain read-back did not match; account creation must not be retried")

proc keychainExists*(): string =
  keychainCapture("exists", "Could not check Keychain; nothing was created").strip()

proc removeKeychainToken*() =
  discard keychainCapture("remove", "Could not remove the local Keychain token")

proc requireEmpty*() =
  when not defined(macosx):
    raise fail("Service-account setup requires macOS Keychain")
  if readSettings().isSome:
    raise fail(
      "A service account is already configured; inspect it with service-account status before using service-account forget")
  let ex = keychainExists()
  if ex == "found":
    raise fail(
      "A service-account token already exists in Keychain; use service-account recover or forget before setup")
  if ex != "missing":
    raise fail("Could not check Keychain; nothing was created")

proc forgetLocal*(): JsonNode =
  when not defined(macosx):
    raise fail("Local service-account storage requires macOS Keychain")
  removeKeychainToken()
  let ex = keychainExists()
  if ex != "missing":
    raise fail("Could not verify removal of the local Keychain token")
  let file = settingsPath()
  if fileExists(file):
    removeFile(file)
  return %*{"forgotten": true, "remoteRevoked": false}

proc visibleVaults*(token: string): seq[Vault] =
  let prev = credentialsEnv
  credentialsEnv = serviceEnvironment(token)
  try:
    let j = grimJson(@["vault", "list", "--format", "json"], GrimCallOptions(
      failure: some("The service-account token could not list its vaults (1Password details suppressed)")))
    var vaults: seq[Vault]
    for v in j:
      vaults.add Vault(id: v["id"].getStr(), name: v["name"].getStr())
    return vaults
  finally:
    credentialsEnv = prev

proc resolveCredentials*(desktop: bool) =
  if desktop:
    credentialsEnv = desktopEnvironment()
    return
  let envToken = getEnv("OP_SERVICE_ACCOUNT_TOKEN")
  if envToken.len > 0:
    credentialsEnv = serviceEnvironment(envToken)
    return
  let saved = readSettings()
  if saved.isNone:
    credentialsEnv = initTable[string, string]()
    return
  credentialsEnv = serviceEnvironment(keychainToken())

proc asDesktop*(body: proc(): JsonNode): JsonNode =
  let prev = credentialsEnv
  credentialsEnv = desktopEnvironment()
  try:
    result = body()
  finally:
    credentialsEnv = prev

proc asDesktopVoid*(body: proc()) =
  let prev = credentialsEnv
  credentialsEnv = desktopEnvironment()
  try:
    body()
  finally:
    credentialsEnv = prev
