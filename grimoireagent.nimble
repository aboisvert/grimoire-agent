# Package

version       = "0.1.0"
author        = "Alex Boisvert"
description   = "1Password-style agent CLI over grim (grimoire)"
license       = "MIT"
srcDir        = "src"
bin           = @["grim_agent"]
namedBin      = {"grim_agent": "grim-agent"}.toTable

requires "nim >= 2.2.0"
task test, "Run unit and integration tests":
  exec "nim c --path:src -o:grim-agent src/grim_agent.nim"
  exec "nim c -r --path:src --path:tests tests/all_tests.nim"

task e2e, "Run opt-in tests against real grim (GRIM_E2E=1)":
  exec "nim c --path:src -o:grim-agent src/grim_agent.nim"
  exec "nim c -r --path:src --path:tests tests/e2e_tests.nim"
