import Lake
open Lake DSL

package «lean-posix»

/-- The bindings, `Posix.*`: most are a C expression that declares what it calls;
`termCtl`, the kqueue, pty and descriptor bindings are C functions of
`c/term.c`, `c/kqueue.c`, `c/pty.c` and `c/fd.c`,
linked from `leanposixc`. -/
@[default_target]
lean_lib Posix

/-- `c/*.c`, compiled with the Lean toolchain's clang against the macOS SDK (Xcode
or the Command Line Tools, found by `xcrun --show-sdk-path` at build time) and
Lean's headers, every warning an error: `c/term.c`, the terminal behind
`Posix.termCtl`, `c/kqueue.c`, `c/pty.c` and `c/fd.c`, the bindings of
`Posix/Kqueue.lean`, `Posix/Pty.lean` and `Posix/Fd.lean`, and
`c/abi.c`, which links nothing and fails the build when a
number or struct layout an inline expression writes by hand differs from the
SDK's. The SDK's path and build version are part of each object's trace, so
another SDK compiles and checks them again. A default target, so `lake build`
checks them too; Lake links this library into every executable of a package that
requires lean-posix. -/
@[default_target]
extern_lib leanposixc pkg := do
  let lean ← getLeanInstall
  let xcrun (arg : String) : JobM String := do
    return (← captureProc { cmd := "xcrun", args := #[arg] }).trimAscii.toString
  let sdk ← xcrun "--show-sdk-path"
  let sdkBuild ← xcrun "--show-sdk-build-version"
  let sdkTrace : JobM BuildTrace := do
    addPureTrace s!"{sdk} {sdkBuild}" "macOS SDK"
    getLeanTrace
  let weakArgs := #["-I", lean.includeDir.toString, "-I", (lean.includeDir / "clang").toString,
    "-isysroot", sdk]
  let traceArgs := #["-O2", "-fPIC", "-Wall", "-Wextra", "-Werror"]
  let dir := pkg.dir / "c"
  let srcs := ((← dir.readDir).filter (·.fileName.endsWith ".c")).qsort (·.fileName < ·.fileName)
  let objs ← srcs.mapM fun src => do
    buildO (pkg.buildDir / "c" / ((src.fileName.dropEnd 2).toString ++ ".o")) (← inputTextFile src.path)
      weakArgs traceArgs lean.cc sdkTrace
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "leanposixc") objs

/-- `lake test`: each binding against the system it binds. -/
@[test_driver]
lean_exe tests where
  srcDir := "Tests"
  root := `Main

/-- `lake exe spawnstress ROUNDS SPAWNS THREADS`: a diagnostic stress run of
`trySpawn` while other threads call into libSystem, not a test
(`Diag/SpawnStress.lean`). -/
lean_exe spawnstress where
  srcDir := "Diag"
  root := `SpawnStress
