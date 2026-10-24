import std/[strutils, json, os, options]
import version
import auth
import grim

const installGrim* =
  "Install or build grim from grimoire (~/nim/grimoire): nim c -o:grim src/grim.nim"
const perShell* =
  "Desktop approvals last per terminal session. Agents without a terminal may be asked again in every new shell: batch lookups into one command, or run `grim-agent service-account setup` for no prompts."

proc doctor*(): JsonNode =
  let grimVer = captureLocal(@["--version"])
  var accounts: Option[int] = none(int)
  if grimVer.isSome:
    let accText = captureLocal(@["account", "list", "--format", "json"])
    if accText.isSome:
      try:
        accounts = some(parseJson(accText.get).len)
      except:
        accounts = some(0)
  var authMode = ""
  if getEnv("OP_SERVICE_ACCOUNT_TOKEN").len > 0:
    authMode = "environment service account"
  else:
    try:
      if readSettings().isSome:
        authMode = "saved service account"
      else:
        authMode = "desktop app"
    except:
      authMode = "saved service account (settings unreadable; use --desktop)"
  var notes: seq[string] = @[]
  if grimVer.isNone:
    notes.add installGrim
  if authMode == "desktop app" and accounts.get(0) == 0 and grimVer.isSome:
    notes.add "No grim accounts are visible. Initialize GRIM_HOME with a GPG recipient."
  if authMode == "desktop app" and grimVer.isSome:
    notes.add perShell
  var doc = %*{
    "grim-agent": grimAgentVersion,
    "platform": hostOS & "-" & hostCPU,
    "nim": NimVersion,
    "auth": authMode,
  }
  if grimVer.isSome:
    doc["grim"] = %grimVer.get
  else:
    doc["grim"] = newJNull()
  if accounts.isSome:
    doc["accounts"] = %accounts.get
  else:
    doc["accounts"] = newJNull()
  if notes.len > 0:
    doc["notes"] = %notes
  doc
