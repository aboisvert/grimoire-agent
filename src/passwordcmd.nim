import std/[strutils, json, options]
import failure
import grim

type PasswordOptions* = object
  item*: string
  vault*: string
  account*: Option[string]
  source*: Source
  apply*: bool
  repairImportedFields*: bool

proc builtInPasswords(item: JsonNode): seq[JsonNode] =
  for field in item["fields"]:
    if field["id"].getStr() == "password" and
        ("purpose" in field and field["purpose"].getStr() == "PASSWORD") and
        field["type"].getStr() == "CONCEALED" and
        "section" notin field:
      result.add field

proc editedTemplate(raw: string, password: string, repair: bool): string =
  let value = parseJson(raw)
  if ("passkeys" in value and value["passkeys"].len > 0):
    raise fail(
      "Cannot safely edit this login template: passkeys or unnamed imported fields require review; nothing was changed")
  var idx = 0
  for field in value["fields"]:
    inc idx
    let hasId = "id" in field and field["id"].getStr().len > 0
    let hasLabel = "label" in field and field["label"].getStr().len > 0
    if not hasId and not hasLabel:
      if not repair:
        raise fail(
          "Cannot safely edit this login template: passkeys or unnamed imported fields require review; nothing was changed")
      field["id"] = %("imported_field_" & $idx)
      field["label"] = %("Imported field " & $idx)
      field["type"] = %"CONCEALED"
    if field["id"].getStr() == "password" and ("purpose" in field and field["purpose"].getStr() == "PASSWORD") and
        "section" notin field:
      field["value"] = %password
  for field in value["fields"]:
    if "type" in field and field["type"].getStr() == "PASSKEY":
      raise fail(
        "Cannot safely edit this login template: passkeys or unnamed imported fields require review; nothing was changed")
  $value

proc passwordCmd*(options: PasswordOptions): JsonNode =
  if options.item.strip.len == 0 or options.vault.strip.len == 0:
    raise fail("An item and explicit vault are required")
  let input = privateInput(options.source, "password", "nothing was changed")
  let inspectFailure = "Could not inspect login; nothing was changed (1Password details suppressed)"
  let raw = grimOp(
    @[
      "item", "get", options.item, "--vault", options.vault, "--format", "json", "--reveal",
    ],
    GrimCallOptions(account: options.account, failure: some(inspectFailure)),
  )
  let item = parseJson(raw)
  let current = builtInPasswords(item)
  if item["category"].getStr() != "LOGIN" or current.len != 1:
    raise fail("Expected a Login with exactly one built-in password; nothing was changed")
  var receipt = %*{
    "id": item["id"],
    "title": item["title"],
    "vault": item["vault"]["name"],
    "ref": "op://" & item["vault"]["id"].getStr() & "/" & item["id"].getStr() & "/password",
  }
  if not options.apply:
    receipt["matches"] = %(current[0]["value"].getStr() == input)
    return receipt
  if current[0]["value"].getStr() == input:
    receipt["changed"] = %false
    receipt["verified"] = %true
    return receipt
  let editBody = editedTemplate(raw, input, options.repairImportedFields)
  let uncertain = "Password update is unverified; check this item before retrying (1Password details suppressed)"
  discard grimOp(
    @["item", "edit", item["id"].getStr(), "--vault", item["vault"]["id"].getStr(), "--format", "json"],
    GrimCallOptions(
      account: options.account,
      input: some(editBody),
      failure: some(uncertain & "; edit request failed"),
    ),
  )
  let raw2 = grimOp(
    @[
      "item", "get", item["id"].getStr(), "--vault", item["vault"]["id"].getStr(), "--format", "json", "--reveal",
    ],
    GrimCallOptions(account: options.account, failure: some(uncertain & "; read-back failed")),
  )
  let stored = parseJson(raw2)
  let passwords = builtInPasswords(stored)
  if stored["id"].getStr() != item["id"].getStr() or
      stored["vault"]["id"].getStr() != item["vault"]["id"].getStr() or
      stored["title"].getStr() != item["title"].getStr() or
      stored["category"].getStr() != item["category"].getStr() or
      passwords.len != 1 or passwords[0]["value"].getStr() != input:
    raise fail(uncertain & "; read-back did not match")
  receipt["changed"] = %true
  receipt["verified"] = %true
  receipt
