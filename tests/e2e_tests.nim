import std/[unittest, os, osproc, strutils, tables, json]
import support

proc grimDefault(): string =
  let home = getEnv("HOME")
  if home.len > 0:
    return home / "nim/grimoire/grim"
  return "/nim/grimoire/grim"

suite "e2e grim":
  test "skipped unless GRIM_E2E=1 and grim exists":
    if getEnv("GRIM_E2E") != "1":
      echo "skip e2e (set GRIM_E2E=1)"
      return
    let grimBin = if getEnv("GRIM_BIN").len > 0: getEnv("GRIM_BIN") else: grimDefault()
    if not fileExists(grimBin):
      echo "skip e2e (grim not found at ", grimBin
      return
    var env = newStringTable(modeCaseInsensitive)
    env["GRIM_BIN"] = grimBin
    let (_, run) = sandbox(initTable[string, string]())
    let res = run(@["doctor"], extraEnv = env)
    check res.code == 0
    let report = parseJson(res.stdout)
    check report["grim"].kind != JNullVal
