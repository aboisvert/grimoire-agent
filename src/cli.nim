import std/[strutils, options, json]
import failure
import version
import auth
import discover
import envcmd
import create
import passwordcmd
import serviceaccount
import doctor
import grim
import arguments

proc printJson*(node: JsonNode) =
  echo pretty(node, indent = 2)

proc parseFlagValue(args: var seq[string], i: var int, key: string): string =
  let arg = args[i]
  if arg.startsWith(key & "="):
    return arg[(key.len + 1) .. ^1]
  if arg == key and i + 1 < args.len:
    inc i
    return args[i]
  raise newException(ValueError, "Missing value for " & key)

proc takeBool(args: var seq[string], i: var int, key: string): bool =
  if args[i] == key:
    true
  elif args[i].startsWith(key & "=true"):
    true
  elif args[i].startsWith(key & "=false"):
    false
  else:
    false

proc runCli*(args: seq[string]) =
  if args.len == 0:
    raise fail("No command specified")
  var rest = args
  var desktop = false
  var filtered: seq[string] = @[]
  var i = 0
  while i < rest.len:
    if rest[i] == "--desktop":
      desktop = true
    elif rest[i] == "--version" or rest[i] == "-v":
      echo grimAgentVersion
      return
    elif rest[i] == "--help" or rest[i] == "-h":
      echo "grim-agent — find, create, and use secrets without exposing them by default"
      return
    else:
      filtered.add rest[i]
    inc i
  rest = filtered
  if rest.len == 0:
    raise fail("No command specified")
  let cmd = rest[0]
  if cmd != "doctor":
    resolveCredentials(desktop)
  case cmd
  of "find":
    var queries: seq[string] = @[]
    var vault: Option[string] = none(string)
    var account: Option[string] = none(string)
    i = 1
    while i < rest.len:
      if rest[i] == "--vault":
        inc i
        vault = some(rest[i])
      elif rest[i] == "--account":
        inc i
        account = some(rest[i])
      elif rest[i].startsWith("--"):
        raise fail("Unknown flag: " & rest[i])
      else:
        queries.add rest[i]
      inc i
    if queries.len == 0:
      raise fail("At least one query is required")
    printJson(find(queries, Scope(vault: vault, account: account)))
  of "inventory":
    var vault: Option[string] = none(string)
    var account: Option[string] = none(string)
    i = 1
    while i < rest.len:
      if rest[i] == "--vault":
        inc i
        vault = some(rest[i])
      elif rest[i] == "--account":
        inc i
        account = some(rest[i])
      else:
        raise fail("Unknown argument: " & rest[i])
      inc i
    printJson(%*{"items": inventory(Scope(vault: vault, account: account))})
  of "audit":
    var vault: Option[string] = none(string)
    var account: Option[string] = none(string)
    i = 1
    while i < rest.len:
      if rest[i] == "--vault":
        inc i
        vault = some(rest[i])
      elif rest[i] == "--account":
        inc i
        account = some(rest[i])
      else:
        raise fail("Unknown argument: " & rest[i])
      inc i
    printJson(audit(Scope(vault: vault, account: account)))
  of "read":
    if rest.len != 2:
      raise fail("Usage: grim-agent read REFERENCE")
    let value = readReference(rest[1])
    stdout.write(value)
  of "run":
    var envs: seq[Assignment] = @[]
    var cmdStart = -1
    i = 1
    while i < rest.len:
      if rest[i] == "--":
        cmdStart = i + 1
        break
      elif rest[i] == "--env":
        inc i
        envs.add parseAssignment(rest[i])
      else:
        raise fail("Unknown argument: " & rest[i])
      inc i
    if cmdStart < 0 or cmdStart >= rest.len:
      raise fail("Usage: grim-agent run --env NAME=grim://ref|op://ref ... -- COMMAND...")
    let code = runAssignments(envs, decodeTrailingArguments(rest[cmdStart .. ^1]))
    quit(code)
  of "env":
    if rest.len < 2:
      raise fail("Usage: grim-agent env write|resolve|run ...")
    case rest[1]
    of "write":
      if rest.len < 4:
        raise fail("Usage: grim-agent env write FILE NAME=grim://ref|op://ref ...")
      var assigns: seq[Assignment] = @[]
      for a in rest[3 .. ^1]:
        assigns.add parseAssignment(a)
      writeEnvFile(rest[2], assigns)
    of "resolve":
      var output = ""
      var inPlace = false
      var file = ""
      i = 2
      while i < rest.len:
        if rest[i] == "--output":
          inc i
          output = rest[i]
        elif rest[i] == "--in-place":
          inPlace = true
        elif rest[i].startsWith("--"):
          raise fail("Unknown flag: " & rest[i])
        elif file.len == 0:
          file = rest[i]
        else:
          raise fail("Unexpected argument: " & rest[i])
        inc i
      if inPlace == (output.len > 0):
        raise fail("Choose exactly one of --output or --in-place")
      resolveFile(file, if output.len > 0: output else: file)
    of "run":
      var cmdStart = -1
      i = 2
      while i < rest.len:
        if rest[i] == "--":
          cmdStart = i + 1
          break
        inc i
      if cmdStart < 0:
        raise fail("Usage: grim-agent env run FILE -- COMMAND...")
      let code = runEnvFile(rest[2], decodeTrailingArguments(rest[cmdStart .. ^1]))
      quit(code)
    else:
      raise fail("Unknown env subcommand: " & rest[1])
  of "create":
    if rest.len < 2 or rest[1] != "api-credential":
      raise fail("Usage: grim-agent create api-credential ...")
    var title = ""
    var vault = ""
    var account: Option[string] = none(string)
    var url: Option[string] = none(string)
    var notes: Option[string] = none(string)
    var clipboard = false
    var stdinFlag = false
    i = 2
    while i < rest.len:
      if rest[i] == "--title":
        inc i
        title = rest[i]
      elif rest[i] == "--vault":
        inc i
        vault = rest[i]
      elif rest[i] == "--account":
        inc i
        account = some(rest[i])
      elif rest[i] == "--url":
        inc i
        url = some(rest[i])
      elif rest[i] == "--notes":
        inc i
        notes = some(rest[i])
      elif rest[i] == "--clipboard":
        clipboard = true
      elif rest[i] == "--stdin":
        stdinFlag = true
      else:
        raise fail("Unknown flag: " & rest[i])
      inc i
    if clipboard == stdinFlag:
      raise fail("Choose exactly one of --clipboard or --stdin")
    let src = if clipboard: Source.clipboard else: stdinSource
    printJson(create.apiCredential(
      Destination(title: title, vault: vault, account: account, url: url, notes: notes), src))
  of "password":
    if rest.len < 2:
      raise fail("Usage: grim-agent password ITEM ...")
    let item = rest[1]
    var vault = ""
    var account: Option[string] = none(string)
    var clipboard = false
    var stdinFlag = false
    var apply = false
    var repair = false
    i = 2
    while i < rest.len:
      if rest[i] == "--vault":
        inc i
        vault = rest[i]
      elif rest[i] == "--account":
        inc i
        account = some(rest[i])
      elif rest[i] == "--clipboard":
        clipboard = true
      elif rest[i] == "--stdin":
        stdinFlag = true
      elif rest[i] == "--apply":
        apply = true
      elif rest[i] == "--repair-imported-fields":
        repair = true
      else:
        raise fail("Unknown flag: " & rest[i])
      inc i
    if clipboard == stdinFlag:
      raise fail("Choose exactly one of --clipboard or --stdin")
    printJson(passwordCmd(PasswordOptions(
      item: item, vault: vault, account: account,
      source: if clipboard: Source.clipboard else: stdinSource,
      apply: apply, repairImportedFields: repair,
    )))
  of "service-account":
    if rest.len < 2:
      raise fail("Usage: grim-agent service-account setup|connect|...")
    case rest[1]
    of "setup":
      var name = "grimoire-agent Automation"
      var vault = "Automation"
      var saveVault = ""
      var account: Option[string] = none(string)
      var createVault = false
      var write = false
      var expiresIn: Option[string] = none(string)
      i = 2
      while i < rest.len:
        if rest[i] == "--name":
          inc i
          name = rest[i]
        elif rest[i] == "--vault":
          inc i
          vault = rest[i]
        elif rest[i] == "--save-vault":
          inc i
          saveVault = rest[i]
        elif rest[i] == "--account":
          inc i
          account = some(rest[i])
        elif rest[i] == "--create-vault":
          createVault = true
        elif rest[i] == "--write":
          write = true
        elif rest[i] == "--expires-in":
          inc i
          expiresIn = some(rest[i])
        else:
          raise fail("Unknown flag: " & rest[i])
        inc i
      printJson(setup(SetupOptions(
        name: name, vault: vault, saveVault: saveVault, account: account,
        createVault: createVault, write: write, expiresIn: expiresIn,
      )))
    of "connect":
      var name = "grimoire-agent Automation"
      var clipboard = false
      var stdinFlag = false
      i = 2
      while i < rest.len:
        if rest[i] == "--name":
          inc i
          name = rest[i]
        elif rest[i] == "--clipboard":
          clipboard = true
        elif rest[i] == "--stdin":
          stdinFlag = true
        else:
          raise fail("Unknown flag: " & rest[i])
        inc i
      if clipboard == stdinFlag:
        raise fail("Choose exactly one of --clipboard or --stdin")
      printJson(connect(if clipboard: Source.clipboard else: stdinSource, name))
    of "status":
      printJson(status())
    of "recover":
      var name = "grimoire-agent Automation"
      i = 2
      while i < rest.len:
        if rest[i] == "--name":
          inc i
          name = rest[i]
        else:
          raise fail("Unknown flag: " & rest[i])
        inc i
      printJson(recover(name))
    of "forget":
      printJson(forget())
    else:
      raise fail("Unknown service-account subcommand: " & rest[1])
  of "doctor":
    printJson(doctor.doctor())
  else:
    raise fail("Unknown command: " & cmd)
