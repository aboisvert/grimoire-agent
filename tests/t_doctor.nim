import std/[unittest, os, json, strutils, tables]
import support

const fakeGrim = r"""#!/bin/sh
printf '%s\n' "$*" >> "$HOME/grim.log"
case "$1" in
  --version) printf 'grim 0.1.0\n' ;;
  account) printf '%s' '[{"id":"grimoire","name":"grimoire"}]' ;;
  *) exit 71 ;;
esac
"""

suite "doctor":
  test "reports grim without authenticating":
    var fakes = initTable[string, string]()
    fakes["grim"] = fakeGrim
    let (home, run) = sandbox(fakes)
    let res = run(@["doctor"])
    check res.code == 0
    let report = parseJson(res.stdout)
    check report["grim"].getStr == "grim 0.1.0"
    check report["accounts"].getInt == 1
    check report["auth"].getStr == "desktop app"
    let log = readFile(home / "grim.log").strip.splitLines()
    check log == @["--version", "account list --format json"]

  test "notes when grim missing":
    let (_, run) = sandbox(initTable[string, string]())
    let res = run(@["doctor"])
    check res.code == 0
    let report = parseJson(res.stdout)
    check report["grim"].kind == JNull
    check "grimoire" in report["notes"][0].getStr
