# DebugEngine

**English** | [Português (Brasil)](README.pt-BR.md)

DebugEngine is a Delphi library of debugging and diagnostics utilities: symbolized stack traces,
`Exception.StackTrace` hooks, crash logs, Delphi debug info (map) handling, CPU register snapshots,
try-block enumeration, disassembly with debug-info comments and PE utilities.

It was born as the internal framework of a commercial error-log plugin and is shared here in the
hope that it is useful. All public functions are XML documented in the source.

- Original author: Mahdi Safsafi — https://github.com/MahdiSafsafi/DebugEngine
- License: [MPL 1.1](LICENSE)

---

## Table of contents

1. [What is it for?](#what-is-it-for)
2. [Supported compilers and platforms](#supported-compilers-and-platforms)
3. [Features](#features)
4. [Repository layout](#repository-layout)
5. [Installation](#installation)
6. [Usage — Windows](#usage--windows)
7. [Usage — Linux](#usage--linux)
8. [Debug information: map, SMAP and embedding](#debug-information-map-smap-and-embedding)
9. [Demos and tests](#demos-and-tests)
10. [DD command line tool](#dd-command-line-tool)
11. [Delphi 13 notes and known limitations](#delphi-13-notes-and-known-limitations)
12. [Contributing](#contributing)

---

## What is it for?

Typical uses:

- **Error logging**: make `E.StackTrace` return a readable call stack (`address  module  unit  file:line  symbol`)
  for every exception, and write complete crash reports (stack, registers, threads, modules, process and system info).
- **Post-mortem diagnostics**: resolve any code address to `unit / symbol / line`, find the address of a symbol by name,
  compute the size of a function.
- **Shipping symbols with your binary**: convert the Delphi `.map` to the compact binary **SMAP** format and embed it
  in the executable (section or resource) so that traces are symbolized on the customer's machine without shipping the map.
- **Low level inspection** (Windows): snapshot of legacy/FPU/MMX/SSE/AVX registers, enumeration of `try..except/finally`
  blocks, disassembly of a function annotated with debug info, PE header/section helpers.

---

## Supported compilers and platforms

| Platform | Compiler | Status | Implementation |
|---|---|---|---|
| Windows 32-bit | `dcc32` (Delphi 10.2 … **13**) | ✅ Full feature set | `Source/*.pas` |
| Windows 64-bit | `dcc64` (Delphi 10.2 … **13**) | ✅ Full feature set | `Source/*.pas` |
| Windows 64-bit "modern" (`Win64x`) | Delphi 13 | ✅ Same as Win64 (shares compiler and RTL in Delphi 13) | `Source/*.pas` |
| Linux 64-bit | `dcclinux64` (Delphi 13) | ✅ Stack traces, symbols, crash logs, registers, system info | `Source/Linux/*.pas` |
| macOS / iOS / Android | — | ❌ Not supported | — |

The Windows implementation relies on inline assembly, the PE format, Delphi map files and the Windows
exception model. The Linux implementation is pure Pascal (no asm) built on ELF, DWARF (`addr2line`) and glibc.

Verified with Delphi 13 (Studio 37.0): Win32, Win64, Win64x and Linux64 (Ubuntu 22.04). Older versions back to
10.2 Tokyo are expected to work for Windows (the project originates from that version).

---

## Features

### Windows (`Source/`)

| Area | What you get | Unit |
|---|---|---|
| Stack trace | `StackTrace(SL)`: smart EBP/RBP walk, broken-chain repair, unwind tables on x64, `Halt` / dynamic-method call detection | `DebugEngine.Trace` |
| Exception hook | `E.StackTrace` filled automatically for every exception (installed in `initialization`); addresses captured at raise (x64: OS unwinder `RtlCaptureStackBackTrace`, also through the kernel exception dispatcher; x86: EBP chain), symbols resolved lazily, RTL raise frames trimmed; `GetExceptionStackAddresses(E)` | `DebugEngine.HookException` |
| Crash log | `WriteCrashLog` / `BuildCrashReport`: madExcept-like header (date/time, computer, user, OS, uptimes, CPU, memory, disk, display, process, executable, version, compiler, callstack crc, exception) + Exception / Threads / Modules / Registers / Environment sections | `DebugEngine.CrashLog` |
| Debug info | `GetAddressInfo`, `GetSymbolAddress`, `GetNextSymbolAddress`, `GetSizeOfFunction`; loads SMAP from section, resource, `.smap` or the `.map` next to the module (converted **in memory**, no temporary file); falls back to PE exports | `DebugEngine.DebugInfo` |
| Map / SMAP | Delphi `.map` text parser, `ConvertMapToSMap` (optionally zlib compressed), `TSMapReader` (platform independent) | `DebugEngine.MapParser` |
| Embedding | `InsertDebugInfo` (SMAP into a `.SDEBUG` section or an RCDATA resource), `RemoveDebugInfo` / `RestoreDebugInfo` (strip/restore Delphi's own `.debug` data) | `DebugEngine.DebugUtils` |
| Try blocks | `EnumTryBlocks` (x64, from `.pdata`/unwind info), `TraceTryBlocks` (x86, SEH chain) | `DebugEngine.Core`, `DebugEngine.Trace` |
| Registers | `SnapshotOfLegacyRegisters`, `SnapshotOfFPURegisters`, `SnapshotOfMMXRegisters`, `SnapshotOfVectorRegisters` (XMM/YMM/ZMM), `SnapshotOfRFlagsRegister`, `SnapshotOfMXCSRRegister` with typed helpers | `DebugEngine.AsmRegUtils` |
| Disassembler | `DisasmAndCommentFunction` (UnivDisasm based), call-target resolution, Delphi string detection | `DebugEngine.Disasm`, `Source/UnivDisasm` |
| PE utils | Headers, sections, `PeFindSection`, module ↔ address helpers | `DebugEngine.PeUtils` |

### Linux (`Source/Linux/`)

| Area | What you get | Unit |
|---|---|---|
| Stack trace | `StackTrace(SL)`, `CaptureStackTrace`, `ResolveStackTrace` (glibc `backtrace`, DWARF unwinding) | `DebugEngine.Linux.Trace` |
| Exception hook | `E.StackTrace` for every exception (auto installed); RTL raise frames trimmed, exact fault address kept | `DebugEngine.Linux.HookException` |
| Crash log | `WriteCrashLog` / `BuildCrashReport`: exception, stack (+inlined frames), raw backtrace, registers, threads, modules, process, system, debug-info sources, memory map, environment | `DebugEngine.Linux.HookException` |
| Fatal signals | Optional `InstallSignalHandlers`: logs SIGSEGV/SIGBUS/SIGFPE/SIGILL/SIGABRT with the **faulting** registers (RIP, CR2, TRAPNO, ERR, `si_code` decoded) then chains to the RTL handler | `DebugEngine.Linux.HookException` |
| Debug info | `GetAddressInfo`, `GetSymbolAddress`: ELF `.symtab`/`.dynsym` + `dladdr` + `addr2line` (file:line, inlining) with per-module batching and cache | `DebugEngine.Linux.DebugInfo` |
| ELF | ELF64 symbol table reader, Itanium demangler (`_ZN5Hello3FooEv` → `Hello.Foo`) | `DebugEngine.Linux.Elf` |
| Modules | `dl_iterate_phdr` enumeration, load bias, address → module, `/proc/self/maps` | `DebugEngine.Linux.Modules` |
| Registers | `SnapshotOfRegisters` (`getcontext`) and `RegistersFromContext` (signal `ucontext`): GP, EFLAGS decoded, segment, FPU, MXCSR decoded, ST/XMM | `DebugEngine.Linux.Registers` |
| System info | Kernel, distro, CPU, memory, uptime, load; PID/TID/user/cmdline/VmRSS/limits; threads from `/proc/self/task`; environment | `DebugEngine.Linux.SysInfo` |

---

## Repository layout

```
Source/                    Windows units (DebugEngine.*.pas) + platform independent DebugEngine.MapParser.pas
Source/Linux/              Linux units (DebugEngine.Linux.*.pas)
Source/UnivDisasm/         x86/x64 disassembler used by DebugEngine.Disasm (Windows)
Demo/                      VCL demo (Windows) - DebugEngineDemo.dproj
Demo/Simple/               Minimal Windows example (one exception -> madExcept-like log) - DebugEngineSimple.dproj
Demo/Linux/                Console demo / smoke test (Linux) - DebugEngineLinuxDemo.dproj
Demo/Linux/Simple/         Minimal Linux example (one exception -> log) - DebugEngineLinuxSimple.dproj
Tests/Win/                 Console smoke test (Win32/Win64) - DETest.dproj
Tools/Source/DD/           DD command line tool (map -> smap, insert / remove debug info); binaries in Tools/bin, Tools/bin64
Script/                    Perl generators for the RFLAGS / MXCSR helpers
```

---

## Installation

There is no package to install: add the source folders to your project's search path.

- **Windows**: `Source` and `Source\UnivDisasm`.
- **Linux**: `Source\Linux` (and `Source` if you want `DebugEngine.MapParser`).

Project options that matter:

| Option | Windows | Linux | Why |
|---|---|---|---|
| Linking → Map file = **Detailed** (`-GD`) | required for symbols/lines | recommended | Windows: source of the SMAP. Linux: not used for symbols, harmless. |
| Linking → Debug information (`-V`) | optional | **required for file:line** | Linux: DWARF consumed by `addr2line`. |
| Compiling → Stack frames (`-$W+`) | recommended | — | Better EBP-chain traces on Win32. |
| Optimization off in Debug builds | recommended | recommended | More faithful frames. |

---

## Usage — Windows

### 1. Stack trace inside exceptions (zero code)

```pascal
uses
  DebugEngine.HookException; // installs Exception.GetExceptionStackInfoProc & co.

try
  DoSomething;
except
  on E: Exception do
    Log(E.ClassName + ': ' + E.Message + sLineBreak + E.StackTrace);
end;
```

Output (one line per frame):

```
$00AE7FF6    DETest.exe    DETest    DETest.dpr    52    +1    Level3
$00AE800A    DETest.exe    DETest    DETest.dpr    57    +1    Level2
$0090B180    DETest.exe    System.SysUtils    System.SysUtils.pas    24513    +3    Exception.RaisingException
```

### 2. Crash log (madExcept-like)

```pascal
uses DebugEngine.HookException, DebugEngine.CrashLog;

except
  on E: Exception do
    WriteCrashLog(E, ChangeFileExt(ParamStr(0), '.log'), [crsHeader, crsException, crsThreads, crsModules]);
end;
```

```
date/time          : 2026-08-21, 12:24:12, 157ms
computer name      : ARB
user name          : music
registered owner   : ...
operating system   : Windows 11 x64 build 26200
system language    : English
system up time     : 3 hours 30 minutes
program up time    : 0 seconds
processors         : 16x 13th Gen Intel(R) Core(TM) i7-1360P
physical memory    : 2928/16068 MB (free/total)
free disk space    : (E:) 10.49 GB
display mode       : 1920x1080, 32 bit
process id         : $71ec
allocated memory   : 6.42 MB
largest free block : 128771.88 GB
executable         : DebugEngineSimple.exe
exec. date/time    : 2026-08-21 12:24
version            :
compiled with      : Delphi 13 (Win64)
DebugEngine version: 2.0.0
callstack crc      : $63315acf, $527d4532, $976c0643
exception number   : 1
exception class    : EArgumentException
exception message  : Invalid customer id: 0

---- Exception -------------------------------------------------------------
  Class         : EArgumentException
  Message       : Invalid customer id: 0
  Address       : $00007FF6388A4155 DebugEngineSimple.exe DebugEngineSimple DebugEngineSimple.dpr:49 LoadCustomer+0x45
  Stack at raise (Exception.StackTrace):
    $00007FF6388A4155  DebugEngineSimple.exe  DebugEngineSimple  DebugEngineSimple.dpr:49  LoadCustomer+0x45
    $00007FF6388A41AE  DebugEngineSimple.exe  DebugEngineSimple  DebugEngineSimple.dpr:53  ProcessOrder+0xE
    $00007FF6388A41CA  DebugEngineSimple.exe  DebugEngineSimple  DebugEngineSimple.dpr:58  RunBatch+0xA
  Thread        : tid=31400  main thread=True
```

Sections: `crsHeader`, `crsException`, `crsThreads`, `crsModules`, `crsRegisters`, `crsEnvironment`
(`DefaultCrashReportSections` = header + exception, `AllCrashReportSections` = everything).

### 3. Stack trace anywhere

```pascal
uses DebugEngine.Trace;

var SL := TStringList.Create;
StackTrace(SL);          // current call stack
TraceTryBlocks(SL);      // x86: active try blocks on the stack
```

### 4. Address / symbol information

```pascal
uses DebugEngine.DebugInfo;

var Info: TAddressInfo;
if GetAddressInfo(@TMyForm.Button1Click, Info) then
  Writeln(Info.UnitName, ' ', Info.SymbolName, ' ', Info.SourceLocation, ':', Info.LineNumber);

P := GetSymbolAddress(0, 'System', 'MemoryManager');       // private variable of the RTL
P := GetSymbolAddress(GetModuleHandle(user32), '', 'MessageBoxA'); // exported API
Size := GetSizeOfFunction(@MyProc);
```

Symbols are searched in this order: `.SDEBUG` section → `SMAP` resource → `MyApp.smap` (if not older than the `.map`) →
`MyApp.map` next to the executable (converted in memory, nothing is written to disk) → PE export table.

### 5. Registers

```pascal
uses DebugEngine.AsmRegUtils;

var Regs: TLegacyRegisters;
SnapshotOfLegacyRegisters(Regs);      // Regs.RSP.AsRSP, Regs.RAX.AsEAX, ...
var Vec: TVectorRegisters;
SnapshotOfVectorRegisters(Vec);       // XMM/YMM/ZMM depending on CPU support
Flags := SnapshotOfRFlagsRegister;    // Flags.CF, Flags.ZF, ... via record helper
```

### 6. Try blocks and disassembly

```pascal
uses DebugEngine.Core, DebugEngine.Disasm;

EnumTryBlocks(0, MyTryCallback, nil);                      // x64: every try/finally/except of the module
DisasmAndCommentFunction(@MyProc, EndAddr, MyDisasmCallback, nil); // instructions + comments (calls, strings, symbols)
```

---

## Usage — Linux

### 1. Stack trace inside exceptions (zero code)

```pascal
uses
  DebugEngine.Linux.HookException; // auto installs the hook

except
  on E: Exception do
    Writeln(E.StackTrace);
end;
```

```
$00000000005EC120  MyApp  Myapp  MyApp.dpr:89   Myapp.RaiseAV+0x10
$00000000005EC1B7  MyApp  Myapp  MyApp.dpr:104  Myapp.TestExceptionHook+0x46
$00000000005EDB91  MyApp  Myapp  MyApp.dpr:242  Myapp.initialization+0x120
```

### 2. Full crash log

```pascal
except
  on E: Exception do
    WriteCrashLog(E, '/var/log/myapp.crash.log');              // DefaultCrashReportSections
    // WriteCrashLog(E, FileName, AllCrashReportSections);      // + memory map + vector registers
end;
```

The report contains, in sections: **Exception** (class, message, inner exceptions, resolved address, thread),
**Stack trace**, **Raw backtrace_symbols**, **Registers**, **Threads**, **Process**, **System**, **Debug info sources**,
**Modules**, optionally **Memory map** and **Environment**.

### 3. Fatal signals outside `try/except`

```pascal
InstallSignalHandlers('/var/log/myapp.signal.log'); // SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT
```

The handler writes the report (to the file and to stderr) with the registers **at the fault** and then chains
to the previous handler, so the Delphi RTL still converts the signal into `EAccessViolation` etc.

### 4. Address / symbol information

```pascal
uses DebugEngine.Linux.DebugInfo;

var Info: TLinuxAddressInfo;
if GetAddressInfo(@MyProc, Info) then
  Writeln(Info.SymbolName, ' ', Info.SourceFile, ':', Info.LineNumber, ' ', Info.ModuleBaseName);

P := GetSymbolAddress('Myunit.MyProc');                // demangled or mangled name
LinuxDebugInfoOptions.UseAddr2Line := False;          // symbols only, no external tool
```

### 5. Registers and system info

```pascal
uses DebugEngine.Linux.Registers, DebugEngine.Linux.SysInfo;

var R: TLinuxRegisters;
SnapshotOfRegisters(R);  RegistersToStrings(R, SL);
SystemInfoToStrings(SL); ProcessInfoToStrings(SL); ThreadsToStrings(SL); ModulesToStrings(SL);
```

Requirements and limits:
- `addr2line` (package `binutils`) is used when present for `file:line` and inlined frames; otherwise symbols come
  from the ELF symbol table (no lines).
- Stack traces cover the current thread only (no `ptrace`).
- x86_64 only (register layouts follow glibc x86_64).
- Not available on Linux: try-block enumeration, disassembler, PE/SMAP embedding.

---

## Debug information: map, SMAP and embedding

On Windows, DebugEngine reads Delphi's detailed `.map` and converts it into **SMAP**, a compact binary form
(optionally zlib compressed) that can live:

1. in a `.SDEBUG` **section** of the executable (preferred, `InsertDebugInfo(..., True)`),
2. in an **RCDATA resource** named `Map` of type `SMAP` (`InsertDebugInfo(..., False)`),
3. as `MyApp.smap` / `MyApp.map` next to the executable (found automatically at run time).

```pascal
uses DebugEngine.MapParser, DebugEngine.DebugUtils;

ConvertMapToSMap('MyApp.map', [moCompress]);              // => MyApp.smap
InsertDebugInfo('MyApp.exe', 'MyApp.smap', True);        // embed into a new section
RemoveDebugInfo('MyApp.exe', nil);                       // strip Delphi's own debug data (.debug) if linked with it
```

The same can be done from the build with the [DD tool](#dd-command-line-tool) as a post-build step.

### Deploying a Release exe with symbols embedded (no .map next to the exe)

Add a **Post-Build event** to the project (works in the IDE and with MSBuild - see
`Demo/Simple/DebugEngineSimple.dproj` for a live example):

```
"..\..\Tools\bin\DD.exe" -c -p ".\$(Platform)\$(Config)\MyApp.map"
"..\..\Tools\bin\DD.exe" -i -s ".\$(Platform)\$(Config)\MyApp.exe" ".\$(Platform)\$(Config)\MyApp.smap"
```

The detailed `.map` (4.5 MB in the demo) becomes a compressed SMAP (~250 KB, line numbers included)
inside a `.SDEBUG` section of the executable: ship the exe alone and stack traces stay fully
symbolized. Keep *Linking > Debug information* enabled in the Release configuration so the map
carries line numbers, and do not ship the `.map`/`.smap` files.


---

## Demos and tests

| Project | Platform | What it shows |
|---|---|---|
| [Demo/Simple/DebugEngineSimple.dproj](Demo/Simple/DebugEngineSimple.dproj) | Win32 / Win64 (console) | **Start here**: one exception raised a few calls deep, caught and logged with `WriteCrashLog` (madExcept-like header + Exception, Threads, Modules) to console and `.log` |
| [Demo/DebugEngineDemo.dproj](Demo/DebugEngineDemo.dproj) | Win32 / Win64 (VCL) | Buttons for each feature: stack trace, `E.StackTrace`, address info, symbol address, registers (via RTTI), vector registers, try blocks, disassembly, SMAP insert/remove |
| [Demo/Linux/Simple/DebugEngineLinuxSimple.dproj](Demo/Linux/Simple/DebugEngineLinuxSimple.dproj) | Linux64 (console) | **Start here**: one exception raised a few calls deep, caught and logged with `WriteCrashLog` using only the Exception, Stack trace, System, Process, Threads and Modules sections (console + `.log` file) |
| [Demo/Linux/DebugEngineLinuxDemo.dproj](Demo/Linux/DebugEngineLinuxDemo.dproj) | Linux64 (console) | Nested stack trace, AV and `raise` with `E.StackTrace`, `GetAddressInfo`/`GetSymbolAddress`/demangler, registers, system/process/threads/modules, crash log. `-signal` forces a SIGSEGV outside `try/except`; `-noaddr2line` disables the external tool. Exit code = failures |
| [Tests/Win/DETest.dproj](Tests/Win/DETest.dproj) | Win32 / Win64 (console) | Smoke test of the whole Windows API including SMAP embedding in a copied executable. Exit code = failures |

Run the Linux demo on a machine (or WSL) with the binary built with `-GD -V`:

```
$ ./DebugEngineLinuxDemo
...
PASS=30 FAIL=0
$ cat DebugEngineLinuxDemo.crash.log
```

---

## DD command line tool

`Tools/bin/DD.exe` (32-bit) and `Tools/bin64/DD.exe` (64-bit), source in `Tools/Source/DD`.

```
DD [Command][Options][AppFile,MapFile]
  -c  Convert Delphi map to smap          DD -c -p MyApp.map
  -i  Insert smap into the application    DD -i -s MyApp.exe MyApp.smap
  -r  Remove Delphi debug info            DD -r MyApp.exe
  -p  Compress the smap
  -s  Insert into a new section when possible (otherwise resource)
```

Typical post-build event: `DD -c -p "$(OUTPUTDIR)$(OUTPUTNAME).map"` then `DD -i -s "$(OUTPUTPATH)" "$(OUTPUTDIR)$(OUTPUTNAME).smap"`.

---

## Delphi 13 notes and known limitations

- **ASLR / 64-bit image base (fixed)**: the SMAP loader maps each map segment to the PE section of the same name.
  Previous versions computed addresses from the in-memory `ImageBase`, which the Windows loader rewrites under
  `DYNAMICBASE` (default in recent Delphi) and which truncates the `$140000000` base of 64-bit images; symbol
  resolution silently failed on Delphi 12/13 builds.
- **No temporary `.smap` (changed)**: loading symbols from a `.map` next to the executable no longer writes a `.smap`; the
  conversion happens in memory. A `.smap` is only created by `ConvertMapToSMap` / the DD tool, and is ignored when older than the `.map`.
- **Maps without line numbers (fixed)**: a `.map` linked with *Debug information* off (typical Release) crashed the SMAP converter
  (garbage size => out of memory / access violations, every frame shown as `??`). Now converts fine (symbols, no lines). A failure
  while loading debug info falls back to the export table instead of raising.
- **Map lookup path (fixed)**: the `.map`/`.smap` next to the module is now located by full module path, not relative
  to the current directory.
- **Refactor**: `ConvertMapToSMap`, `MapLocationToStr` and the SMAP types moved to `DebugEngine.MapParser`
  (aliases are kept in `DebugEngine.DebugInfo` for types/constants; add `DebugEngine.MapParser` to `uses` to call the functions).
- `EnumTryBlocks` is x64 only; `TraceTryBlocks` is x86 only (by design of the two exception models).
- Win64x in Delphi 13 uses the same compiler and RTL as Win64, so inline assembly is accepted.
- MSBuild may report *"command line too long"* (MSB6003) on machines with a very long global Library Path; this is
  an environment limit, not a project issue — build from the IDE or call `dcc64`/`dcclinux64` directly.

---

## Contributing

Issues and pull requests are welcome.
