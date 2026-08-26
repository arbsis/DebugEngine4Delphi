// **************************************************************************************************
// Delphi DebugEngine.
// Unit DebugEngine.Linux.Posix
// https://github.com/MahdiSafsafi/DebugEngine
//
// The contents of this file are subject to the Mozilla Public License Version 1.1 (the "License");
// you may not use this file except in compliance with the License. You may obtain a copy of the
// License at http://www.mozilla.org/MPL/
//
// Software distributed under the License is distributed on an "AS IS" basis, WITHOUT WARRANTY OF
// ANY KIND, either express or implied. See the License for the specific language governing rights
// and limitations under the License.
//
// **************************************************************************************************

/// <summary>
/// glibc imports that are not (or not completely) wrapped by the Delphi Posix.* units:
/// backtrace (execinfo.h), getcontext (ucontext.h), dl_iterate_phdr (link.h), popen (stdio.h),
/// getrlimit (sys/resource.h) and gettid. x86_64 Linux only (structure layouts are glibc x86_64).
/// </summary>
unit DebugEngine.Linux.Posix;

{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

{$IFNDEF LINUX}
{$MESSAGE FATAL 'DebugEngine.Linux.* units are Linux only.'}
{$ENDIF}

uses
  Posix.Base,
  Posix.SysTypes,
  Posix.Signal;

const
  libc = 'libc.so.6';

{$REGION 'execinfo.h'}
function backtrace(Buffer: PPointer; Size: Integer): Integer; cdecl; external libc name 'backtrace';
function backtrace_symbols(Buffer: PPointer; Size: Integer): PPAnsiChar; cdecl; external libc name 'backtrace_symbols';
procedure free(P: Pointer); cdecl; external libc name 'free';
{$ENDREGION}

{$REGION 'ucontext.h (x86_64)'}
const
  NGREG = 23;
  { Indices into gregset_t }
  REG_R8 = 0;
  REG_R9 = 1;
  REG_R10 = 2;
  REG_R11 = 3;
  REG_R12 = 4;
  REG_R13 = 5;
  REG_R14 = 6;
  REG_R15 = 7;
  REG_RDI = 8;
  REG_RSI = 9;
  REG_RBP = 10;
  REG_RBX = 11;
  REG_RDX = 12;
  REG_RAX = 13;
  REG_RCX = 14;
  REG_RSP = 15;
  REG_RIP = 16;
  REG_EFL = 17;
  REG_CSGSFS = 18;
  REG_ERR = 19;
  REG_TRAPNO = 20;
  REG_OLDMASK = 21;
  REG_CR2 = 22;

type
  greg_t = Int64;
  gregset_t = array [0 .. NGREG - 1] of greg_t;

  _libc_fpxreg = packed record
    significand: array [0 .. 3] of Word;
    exponent: Word;
    __glibc_reserved1: array [0 .. 2] of Word;
  end;

  _libc_xmmreg = packed record
    element: array [0 .. 3] of Cardinal;
  end;

  _libc_fpstate = packed record
    cwd: Word;
    swd: Word;
    ftw: Word;
    fop: Word;
    rip: UInt64;
    rdp: UInt64;
    mxcsr: Cardinal;
    mxcr_mask: Cardinal;
    _st: array [0 .. 7] of _libc_fpxreg;
    _xmm: array [0 .. 15] of _libc_xmmreg;
    __glibc_reserved1: array [0 .. 23] of Cardinal;
  end;

  P_libc_fpstate = ^_libc_fpstate;

  mcontext_t = record
    gregs: gregset_t;
    fpregs: P_libc_fpstate;
    __reserved1: array [0 .. 7] of UInt64;
  end;

  Pucontext_t = ^ucontext_t;

  ucontext_t = record
    uc_flags: UIntPtr;
    uc_link: Pucontext_t;
    uc_stack: stack_t;
    uc_mcontext: mcontext_t;
    uc_sigmask: sigset_t;
    __fpregs_mem: _libc_fpstate;
    __ssp: array [0 .. 3] of UInt64;
  end;

function getcontext(var ucp: ucontext_t): Integer; cdecl; external libc name 'getcontext';
{$ENDREGION}

{$REGION 'elf.h / link.h'}
const
  PT_LOAD = 1;
  PT_DYNAMIC = 2;
  PT_GNU_EH_FRAME = $6474E550;
  PF_X = 1;
  PF_W = 2;
  PF_R = 4;

type
  Elf64_Phdr = record
    p_type: Cardinal;
    p_flags: Cardinal;
    p_offset: UInt64;
    p_vaddr: UInt64;
    p_paddr: UInt64;
    p_filesz: UInt64;
    p_memsz: UInt64;
    p_align: UInt64;
  end;

  PElf64_Phdr = ^Elf64_Phdr;

  dl_phdr_info = record
    dlpi_addr: UIntPtr; // Base address (load bias) of the object.
    dlpi_name: MarshaledAString; // Null terminated name (empty for the main program).
    dlpi_phdr: PElf64_Phdr; // Program headers.
    dlpi_phnum: Word; // Number of program headers.
    { Newer glibc adds: dlpi_adds, dlpi_subs, dlpi_tls_modid, dlpi_tls_data. Not used. }
  end;

  Pdl_phdr_info = ^dl_phdr_info;

  Tdl_iterate_phdr_callback = function(Info: Pdl_phdr_info; Size: size_t; Data: Pointer): Integer; cdecl;

function dl_iterate_phdr(Callback: Tdl_iterate_phdr_callback; Data: Pointer): Integer; cdecl; external libc name 'dl_iterate_phdr';
{$ENDREGION}

{$REGION 'stdio.h'}
type
  PFILE = Pointer;

function popen(const Command: MarshaledAString; const Mode: MarshaledAString): PFILE; cdecl; external libc name 'popen';
function pclose(Stream: PFILE): Integer; cdecl; external libc name 'pclose';
function fgets(S: MarshaledAString; Size: Integer; Stream: PFILE): MarshaledAString; cdecl; external libc name 'fgets';
{$ENDREGION}

{$REGION 'sys/resource.h'}
const
  RLIMIT_CPU = 0;
  RLIMIT_FSIZE = 1;
  RLIMIT_DATA = 2;
  RLIMIT_STACK = 3;
  RLIMIT_CORE = 4;
  RLIMIT_NOFILE = 7;
  RLIMIT_AS = 9;
  RLIM_INFINITY = UInt64(-1);

type
  rlimit = record
    rlim_cur: UInt64;
    rlim_max: UInt64;
  end;

function getrlimit(Resource: Integer; var Limits: rlimit): Integer; cdecl; external libc name 'getrlimit';
{$ENDREGION}

{$REGION 'misc'}
function gettid: Integer; cdecl; external libc name 'gettid';
function getpagesize: Integer; cdecl; external libc name 'getpagesize';
function get_nprocs: Integer; cdecl; external libc name 'get_nprocs';
function sysconf(Name: Integer): Int64; cdecl; external libc name 'sysconf';
{$ENDREGION}

implementation

end.
