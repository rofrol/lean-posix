import Lake
open Lake DSL

package «lean-posix»

/-- The bindings, `Posix.*`: C functions of `c/*.c`, linked from `leanposixc`. -/
@[default_target]
lean_lib Posix

/-- The macOS SDK's path, from `xcrun --show-sdk-path`, and a trace of it and its
build version, so another SDK compiles again. -/
def macSdk : JobM (String × JobM BuildTrace) := do
  let xcrun (arg : String) : JobM String := do
    return (← captureProc { cmd := "xcrun", args := #[arg] }).trimAscii.toString
  let sdk ← xcrun "--show-sdk-path"
  let sdkBuild ← xcrun "--show-sdk-build-version"
  return (sdk, do addPureTrace s!"{sdk} {sdkBuild}" "macOS SDK"; getLeanTrace)

/-- `c/*.c`, compiled with the Lean toolchain's clang against the macOS SDK (Xcode
or the Command Line Tools, found by `xcrun --show-sdk-path` at build time) and
Lean's headers, every warning an error: `c/term.c`, `c/kqueue.c`, `c/pty.c`,
`c/fd.c`, `c/lock.c`, `c/process.c` and `c/spawn.c`, the bindings of
`Posix/Term.lean`, `Posix/Kqueue.lean`, `Posix/Pty.lean`, `Posix/Fd.lean`,
`Posix/Lock.lean`, `Posix/Process.lean` and `Posix/Spawn.lean`, and `c/abi.c`, which
links nothing and fails the build when a
number or struct layout an inline expression writes by hand differs from the
SDK's. The SDK's path and build version are part of each object's trace, so
another SDK compiles and checks them again. A default target, so `lake build`
checks them too; Lake links this library into every executable of a package that
requires lean-posix. -/
@[default_target]
extern_lib leanposixc pkg := do
  let lean ← getLeanInstall
  let (sdk, sdkTrace) ← macSdk
  let weakArgs := #["-I", lean.includeDir.toString, "-I", (lean.includeDir / "clang").toString,
    "-isysroot", sdk]
  let traceArgs := #["-O2", "-fPIC", "-Wall", "-Wextra", "-Werror"]
  let dir := pkg.dir / "c"
  let srcs := ((← dir.readDir).filter (·.fileName.endsWith ".c")).qsort (·.fileName < ·.fileName)
  let objs ← srcs.mapM fun src => do
    buildO (pkg.buildDir / "c" / ((src.fileName.dropEnd 2).toString ++ ".o")) (← inputTextFile src.path)
      weakArgs traceArgs lean.cc sdkTrace
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "leanposixc") objs

/-- `lean-posix-ctty`, the helper through which `Posix.trySpawn ... (ctty := true)`
starts a program on a controlling terminal, and `(record := some fd)` one that
records its identity first (`helper/ctty.c`, which states its protocol;
`docs/decisions/0001-ctty-helper.md`, `0002-spawn-record.md`): a C executable linked with
libSystem only, compiled and linked with the Lean toolchain's clang and its own
compiler headers (`stdbool.h`, which `libproc.h` includes) against the macOS SDK,
every warning an error. It is written to the bin directory of the
workspace's root package, `.lake/build/bin`, next to that package's executables,
where `trySpawn` looks for it (next to `IO.appPath`). A package that spawns with
`ctty` or `record` builds it (`lake build lean-posix/lean-posix-ctty`, or through `needs`) and
installs it next to its executables. A default target here, and needed by
`tests`. -/
@[default_target]
target «lean-posix-ctty» pkg : System.FilePath := do
  let lean ← getLeanInstall
  let (sdk, sdkTrace) ← macSdk
  let obj ← buildO (pkg.buildDir / "helper" / "ctty.o") (← inputTextFile (pkg.dir / "helper" / "ctty.c"))
    #["-I", (lean.includeDir / "clang").toString, "-isysroot", sdk] #["-O2", "-Wall", "-Wextra", "-Werror"]
    lean.cc sdkTrace
  let exe := (← getRootPackage).binDir / "lean-posix-ctty"
  obj.mapM fun o => do
    addTrace (← sdkTrace)
    addPlatformTrace
    buildFileUnlessUpToDate' exe (compileExe exe #[o.toString, "-isysroot", sdk] lean.cc)
    return exe

/-- `lake test`: each binding against the system it binds. -/
@[test_driver]
lean_exe tests where
  srcDir := "Tests"
  root := `Main
  needs := #[«lean-posix-ctty»]

/-- `lake exe spawnstress ROUNDS SPAWNS THREADS`: a diagnostic stress run of
`trySpawn` while other threads call into libSystem, not a test
(`Diag/SpawnStress.lean`). -/
lean_exe spawnstress where
  srcDir := "Diag"
  root := `SpawnStress
