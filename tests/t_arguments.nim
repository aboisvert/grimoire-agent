import std/unittest
import arguments

suite "trailing arguments":
  test "round-trip after --":
    let args = @["run", "--env", "X=op://a/b/c", "--", "mytool", "--flag", "value"]
    let norm = normalizeTrailingArguments(args)
    check norm.len == 6
    let decoded = decodeTrailingArguments(norm[3 .. ^1])
    check decoded == @["mytool", "--flag", "value"]
