import std/[unittest, os, json, strutils, tables]
import support

const fakeGrimRun = r"""#!/bin/sh
printf '%s\n' "$*" >> "$HOME/grim.log"
[ "$1" = "run" ] || exit 71
i=0
while [ $i -lt 32 ]; do
  eval "v=\$GRIM_AGENT_SECRET_$i"
  if [ -n "$v" ]; then printf '%s\n' "$v" >> "$HOME/references"; fi
  i=$((i+1))
done
while [ "$1" != "--" ]; do shift; done
shift
while [ "$1" != "--dump-resolved" ]; do shift; done
shift
count="$1"
shift
# Child is grim-agent --dump-resolved N; simulate resolved values
printf '%s' '["first \"secret\"","second\nsecret"]'
exit 0
"""

suite "env resolve":
  test "one grim run for all references":
    var fakes = initTable[string, string]()
    fakes["grim"] = fakeGrimRun
    let (home, run) = sandbox(fakes)
    let tplFile = home / ".env.tpl"
    let output = home / ".env"
    writeFile(
      tplFile,
      "# Development\nFIRST=op://Personal/First/credential\nSECOND=op://Work/Second/password\nFIRST_AGAIN=op://Personal/First/credential\n",
    )
    let res = run(@["env", "resolve", tplFile, "--output", output])
    check res.code == 0
    check ("Resolved 3 secret references" in res.stderr) or
      ("Resolved 3 secret references" in res.stdout)
    let log = readFile(home / "grim.log").strip.splitLines()
    check log.len == 1
    check log[0].startsWith("run --no-masking")
    let refs = readFile(home / "references").strip.splitLines()
    check refs == @[
      "op://Personal/First/credential",
      "op://Work/Second/password",
    ]
    let outText = readFile(output)
    check "FIRST=\"first \\\"secret\\\"\"" in outText
    check "SECOND=\"second\\nsecret\"" in outText
