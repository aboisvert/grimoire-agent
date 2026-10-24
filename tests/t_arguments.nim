import std/[unittest, strutils]
import arguments

suite "trailing arguments":
  test "round-trip after --":
    let args = @["run", "--env", "X=op://a/b/c", "--", "mytool", "--flag", "value"]
    let norm = normalizeTrailingArguments(args)
    check norm.len == 6
    let decoded = decodeTrailingArguments(norm[3 .. ^1])
    check decoded == @["mytool", "--flag", "value"]

  test "env run after normalize":
    let args = @["env", "run", ".env", "--", "bash", "-lc", "echo hi"]
    let norm = normalizeTrailingArguments(args)
    check norm.len == 6
    check norm[0 .. 2] == @["env", "run", ".env"]
    check norm[3].startsWith(trailingArgumentPrefix)
    let decoded = decodeTrailingArguments(norm[3 .. ^1])
    check decoded == @["bash", "-lc", "echo hi"]
