# Package
version       = "0.1.0"
author        = "ParseNet Team"
description   = "AI Structured Output Parser Service"
license       = "MIT"
srcDir        = "src"
bin           = @["parse_net"]
binDir        = "."

# Dependencies
requires "nim >= 2.0.0"
requires "jester >= 0.6.0"

# Tasks
task test, "Run tests":
  exec "nim c -r tests/test_parse_net.nim"
