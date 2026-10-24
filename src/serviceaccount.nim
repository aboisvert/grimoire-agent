import std/[strutils, json, options, re, sequtils, sets]
import failure
import grim
import auth
import create

const manageUrl* = "https://start.1password.com/developer-tools/active"
const builtInVaults = ["personal", "private", "employee", "shared"].toHashSet()

type SetupOptions* = object
  name*: string
  vault*: string
  saveVault*: string
  account*: Option[string]
  createVault*: bool
  write*: bool
  expiresIn*: Option[string]

proc parseToken(raw: string): string =
  let token = raw.replace(re"\r?\n$", "")
  if token.match(re"^ops_[^\s]+$"):
    return token
  raise fail("No valid service-account token was received (details suppressed)")

proc selectVault(vaults: seq[Vault], value: string): seq[Vault] =
  for v in vaults:
    if v.id == value or v.name == value:
      result.add v

proc setup*(options: SetupOptions): JsonNode =
  let name = options.name.strip()
  let vaultName = options.vault.strip()
  let saveVaultName = options.saveVault.strip()
  if name.len == 0 or vaultName.len == 0 or saveVaultName.len == 0 or
      name.startsWith("-") or vaultName.startsWith("-") or
      name.contains('\n') or vaultName.contains('\n') or saveVaultName.contains('\n'):
    raise fail("A non-empty account name, automation vault, and backup vault are required")
  if vaultName.toLowerAscii() in builtInVaults:
    raise fail(
      "Choose a dedicated automation vault; built-in personal/shared vaults cannot be granted to service accounts")
  if options.expiresIn.isSome and not options.expiresIn.get.match(re"^[1-9]\d*[smhdw]$"):
    raise fail("--expires-in must be a positive duration such as 90d")
  requireEmpty()

  proc adminJson(args: openArray[string], failureMsg: string): JsonNode =
    var prev = credentialsEnv
    credentialsEnv = desktopEnvironment()
    try:
      grimJson(args, GrimCallOptions(account: options.account, failure: some(failureMsg)))
    finally:
      credentialsEnv = prev

  let vaultsJson = adminJson(
    @["vault", "list", "--format", "json"],
    "Could not read administrator vault metadata; nothing was created",
  )
  var vaults: seq[Vault] = @[]
  for v in vaultsJson:
    vaults.add Vault(id: v["id"].getStr(), name: v["name"].getStr())
  let backups = selectVault(vaults, saveVaultName)
  if backups.len != 1:
    raise fail("The backup vault must resolve to one existing vault; nothing was created")
  let backup = backups[0]
  let title = "1Password " & name & " Service Account Token"
  proc titleTakenDesktop(): bool =
    var prev = credentialsEnv
    credentialsEnv = desktopEnvironment()
    try:
      create.titleTaken(
        backup.id, title, options.account,
        "Could not check the token backup destination; nothing was created")
    finally:
      credentialsEnv = prev
  if titleTakenDesktop():
    raise fail(
      "A token backup with this title already exists; inspect it before creating another service account")

  let selected = selectVault(vaults, vaultName)
  if selected.len > 1:
    raise fail("Automation vault name is ambiguous; specify its ID")
  var vault = if selected.len == 1: selected[0] else: Vault()
  if selected.len == 0:
    if not options.createVault:
      raise fail("Automation vault does not exist; use --create-vault to create it")
    let created = adminJson(
      @["vault", "create", vaultName, "--format", "json"],
      "Vault creation is unverified; inspect your vaults before retrying",
    )
    vault = Vault(id: created["id"].getStr(), name: created["name"].getStr())
    if vault.name != vaultName:
      raise fail("The created vault name did not match; inspect your vaults before retrying")
  if vault.name.toLowerAscii() in builtInVaults or vault.id == backup.id:
    raise fail("Use a dedicated automation vault and a separate backup vault for its service-account token")

  let grant = vault.id & ":read_items" & (if options.write: ",write_items" else: "")
  let uncertain =
    "Service-account creation is unverified. Do not retry setup; inspect service accounts in 1Password (details suppressed)"
  var createArgs = @[
    "service-account", "create", name, "--vault", grant, "--raw",
  ]
  if options.expiresIn.isSome:
    createArgs.add "--expires-in"
    createArgs.add options.expiresIn.get
  var tokenRaw = ""
  block:
    var prev = credentialsEnv
    credentialsEnv = desktopEnvironment()
    try:
      tokenRaw = grimOp(
        createArgs,
        GrimCallOptions(account: options.account, failure: some(uncertain)),
      )
    finally:
      credentialsEnv = prev
  let token = parseToken(tokenRaw)
  saveToken(token)
  var settings = Settings(name: name, vaults: @[vault])
  saveSettings(settings)
  let visible = visibleVaults(token)
  if visible.len != 1 or visible[0].id != vault.id:
    raise fail(
      "The created account's vault access did not match. Its token is saved locally; inspect service-account status, do not repeat setup")
  var savedRef: JsonNode
  block:
    var prev = credentialsEnv
    credentialsEnv = desktopEnvironment()
    try:
      savedRef = create.storeApiCredential(
        Destination(title: title, vault: backup.id, account: options.account),
        token,
      )
    finally:
      credentialsEnv = prev
  settings.tokenRef = some(savedRef["ref"].getStr())
  saveSettings(settings)
  %*{
    "configured": true,
    "name": name,
    "vaults": visible.mapIt(%*{"id": it.id, "name": it.name}),
    "write": options.write,
    "tokenRef": savedRef["ref"],
    "storage": storageKind(),
    "verified": true,
  }

proc connect*(source: Source, name: string): JsonNode =
  if name.strip.len == 0:
    raise fail("A non-empty account name is required")
  requireEmpty()
  let token = parseToken(privateInput(source, "service-account token", "nothing was saved"))
  let vaults = visibleVaults(token)
  saveToken(token)
  saveSettings(Settings(name: name.strip(), vaults: vaults))
  %*{
    "configured": true,
    "name": name.strip(),
    "vaults": vaults.mapIt(%*{"id": it.id, "name": it.name}),
    "storage": storageKind(),
    "verified": true,
  }

proc status*(): JsonNode =
  let saved = readSettings()
  if saved.isNone:
    return %*{"configured": false, "manageUrl": manageUrl}
  let vaults = visibleVaults(keychainToken())
  var statusJson = %*{
    "configured": true,
    "name": saved.get.name,
    "vaults": vaults.mapIt(%*{"id": it.id, "name": it.name}),
    "storage": storageKind(),
    "verified": true,
    "manageUrl": manageUrl,
  }
  if saved.get.tokenRef.isSome:
    statusJson["tokenRef"] = %saved.get.tokenRef.get
  statusJson

proc recover*(name: string): JsonNode =
  if name.strip.len == 0:
    raise fail("A non-empty account name is required")
  let saved = readSettings()
  let vaults = visibleVaults(keychainToken())
  var s = Settings(
    name: if saved.isSome: saved.get.name else: name.strip(),
    vaults: vaults,
  )
  if saved.isSome and saved.get.tokenRef.isSome:
    s.tokenRef = saved.get.tokenRef
  saveSettings(s)
  %*{
    "configured": true,
    "vaults": vaults.mapIt(%*{"id": it.id, "name": it.name}),
    "storage": storageKind(),
    "verified": true,
  }

proc forget*(): JsonNode =
  forgetLocal()
