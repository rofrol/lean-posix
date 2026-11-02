import Lake
open Lake DSL

package «lean-posix»

/-- The bindings, `Posix.*`: no C file, each a C expression that declares what it
calls. -/
@[default_target]
lean_lib Posix

/-- `lake test`: each binding against the system it binds. -/
@[test_driver]
lean_exe tests where
  srcDir := "Tests"
  root := `Main
