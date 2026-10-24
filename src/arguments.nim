import std/[base64, strutils]

const trailingArgumentPrefix* = "\0"

proc normalizeTrailingArguments*(args: seq[string]): seq[string] =
  let sep = args.find("--")
  if sep < 0:
    return args
  result = args[0 ..< sep]
  for value in args[(sep + 1) .. ^1]:
    let encoded = encode(value)
    result.add trailingArgumentPrefix & encoded

proc decodeTrailingArguments*(values: seq[string]): seq[string] =
  for value in values:
    if value.startsWith(trailingArgumentPrefix):
      let b64 = value[trailingArgumentPrefix.len .. ^1]
      result.add decode(b64)
    else:
      result.add value
