type Failure* = object of CatchableError

proc fail*(message: string): ref Failure =
  newException(Failure, message)

proc grimAgentError*(message: string) =
  stderr.writeLine("grim-agent: ", message)
  quit(1)
