import std/[strutils, json, options, re]
import failure
import grim

type Destination* = object
  title*: string
  vault*: string
  account*: Option[string]
  url*: Option[string]
  notes*: Option[string]

proc titleTaken*(vault, title: string, account: Option[string], failureMsg: string): bool =
  let items = grimJson(
    @["item", "list", "--vault", vault, "--format", "json"],
    GrimCallOptions(account: account, failure: some(failureMsg)),
  )
  for item in items:
    if item["title"].getStr().strip().toLowerAscii() == title.toLowerAscii():
      return true
  false

proc storeApiCredential*(dest: Destination, credential: string): JsonNode =
  let title = dest.title.strip()
  let vault = dest.vault.strip()
  if title.len == 0 or vault.len == 0 or credential.strip.len == 0:
    raise fail("A title, explicit vault, and non-empty credential are required; nothing was created")
  if titleTaken(
      vault, title, dest.account,
      "Could not check for an existing title; nothing was created (1Password details suppressed)"):
    raise fail(
      "An item with this title already exists in the selected vault; nothing was created or overwritten. Use grim-agent find to inspect it")

  var fields = newJArray()
  fields.add(%*{
    "id": "credential",
    "type": "CONCEALED",
    "label": "credential",
    "value": credential,
  })
  if dest.notes.isSome:
    fields.add(%*{
      "id": "notesPlain",
      "type": "STRING",
      "purpose": "NOTES",
      "label": "notesPlain",
      "value": dest.notes.get,
    })
  var tpl = %*{
    "title": title,
    "category": "API_CREDENTIAL",
    "fields": fields,
  }
  if dest.url.isSome:
    var urlEntry = newJObject()
    urlEntry["href"] = %dest.url.get
    urlEntry["primary"] = %true
    var urlArr = newJArray()
    urlArr.add urlEntry
    tpl["urls"] = urlArr

  let unverified =
    "Creation is unverified. Do not retry creation; inspect the destination by title with grim-agent find first. Item reference: op://VAULT/ID/credential (1Password details suppressed)"
  let receipt = grimJson(
    @["item", "create", "-", "--vault", vault, "--format", "json"],
    GrimCallOptions(
      account: dest.account,
      input: some($tpl),
      failure: some(
        "Creation may have succeeded, but its receipt could not be verified. Do not retry creation; inspect the destination with grim-agent find first (1Password details suppressed)"),
    ),
  )
  let refPath = "op://" & receipt["vault"]["id"].getStr() & "/" & receipt["id"].getStr() & "/credential"
  let unverifiedRef = unverified.replace("op://VAULT/ID/credential", refPath)
  if receipt["title"].getStr() != title or receipt["category"].getStr() != "API_CREDENTIAL":
    raise fail(unverifiedRef)
  let vname = receipt["vault"]["name"].getStr()
  let vid = receipt["vault"]["id"].getStr()
  if vname != vault and vid != vault:
    raise fail(unverifiedRef)

  let stored = grimJson(
    @[
      "item", "get", receipt["id"].getStr(), "--vault", vid, "--format", "json", "--reveal",
    ],
    GrimCallOptions(account: dest.account, failure: some(unverifiedRef)),
  )
  var credFields: seq[JsonNode] = @[]
  for field in stored["fields"]:
    if field["id"].getStr() == "credential":
      credFields.add field
  var storedNotes = ""
  for field in stored["fields"]:
    if field["id"].getStr() == "notesPlain" and "section" notin field:
      storedNotes = field["value"].getStr("")
  var urlOk = dest.url.isNone
  if dest.url.isSome and "urls" in stored:
    for u in stored["urls"]:
      if u["href"].getStr() == dest.url.get:
        urlOk = true
  let matches =
    stored["id"].getStr() == receipt["id"].getStr() and
      stored["vault"]["id"].getStr() == vid and
      stored["vault"]["name"].getStr() == vname and
      stored["title"].getStr() == title and
      stored["category"].getStr() == "API_CREDENTIAL" and
      credFields.len == 1 and
      credFields[0]["type"].getStr() == "CONCEALED" and
      "section" notin credFields[0] and
      credFields[0]["value"].getStr() == credential and
      (dest.notes.isNone or storedNotes == dest.notes.get) and urlOk
  if not matches:
    raise fail(unverifiedRef)
  %*{
    "id": receipt["id"],
    "title": title,
    "vault": if vname.len > 0: vname else: vault,
    "kind": "api-credential",
    "field": "credential",
    "ref": refPath,
    "verified": true,
  }

proc apiCredential*(dest: Destination, source: Source): JsonNode =
  let title = dest.title.strip()
  let vault = dest.vault.strip()
  if title.len == 0 or vault.len == 0:
    raise fail("A non-empty --title and explicit --vault are required")
  var input = privateInput(source, "credential", "nothing was created")
  if input.endsWith("\n") or input.endsWith("\r\n"):
    input = input.replace(re"\r?\n$", "")
  storeApiCredential(dest, input)
