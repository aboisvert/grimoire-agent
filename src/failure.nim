type Failure* = object of CatchableError
  message*: string

proc fail*(message: string): ref Failure =
  newException(Failure, message)

proc grimAgentError*(message: string) =
  stderr.writeLine("grim-agent: ", message)
  quit(1)
