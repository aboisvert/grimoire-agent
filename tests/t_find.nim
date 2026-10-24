import std/[unittest, os, json, strutils, tables]
import support

const fakeGrim = r"""#!/bin/sh
printf '%s\n' "$*" >> "$HOME/grim.log"
if [ "$1" = "--version" ]; then printf 'grim test\n'; exit 0; fi
if [ "$1" = "account" ]; then printf '[]'; exit 0; fi
if [ "$1 $2" = "item list" ]; then
  printf '%s' '[{"id":"1","title":"Cloud API","category":"API_CREDENTIAL","vault":{"id":"v1","name":"Personal"},"version":2},{"id":"2","title":"Cloud Login","category":"LOGIN","vault":{"id":"v2","name":"Work"},"version":3},{"id":"3","title":"Database","category":"DATABASE","vault":{"id":"v2","name":"Work"},"version":4}]'
  exit 0
fi
if [ "$1 $2 $3" = "item get -" ]; then
  cat > "$HOME/input"
  printf '%s\n%s\n%s' '{"id":"1","title":"Cloud API","category":"API_CREDENTIAL","vault":{"name":"Personal"},"fields":[{"id":"credential","label":"credential","type":"CONCEALED","reference":"op://Personal/Cloud API/credential"}]}' '{"id":"2","title":"Cloud Login","category":"LOGIN","vault":{"name":"Work"},"fields":[{"id":"password","label":"password","type":"CONCEALED","purpose":"PASSWORD","reference":"op://Work/Cloud Login/password"}]}' '{"id":"3","title":"Database","category":"DATABASE","vault":{"name":"Work"},"fields":[{"id":"password","label":"password","type":"CONCEALED","purpose":"PASSWORD","reference":"op://Work/Database/password"}]}'
  exit 0
fi
exit 71
"""

proc grimFake(): Table[string, string] =
  var t = initTable[string, string]()
  t["grim"] = fakeGrim
  t

suite "find":
  test "batches list and get":
    let (home, run) = sandbox(grimFake())
    let res = run(@["find", "database", "cloud api", "cloud"])
    check res.code == 0
    let log = readFile(home / "grim.log").strip.splitLines()
    check log == @["item list --format json", "item get - --format json"]
    let body = parseJson(res.stdout)
    check body["matches"].len == 3

  test "suggestions on miss":
    let (_, run) = sandbox(grimFake())
    let res = run(@["find", "databse"])
    let body = parseJson(res.stdout)
    check body["matches"].len == 0
    check body["suggestions"].len == 1
    check body["suggestions"][0]["title"].getStr == "Database"
