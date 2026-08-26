// **************************************************************************************************
// Delphi DebugEngine.
// Unit DebugEngine.Linux.HookException
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
/// - Hooks Exception.StackTrace (Exception.GetExceptionStackInfoProc & co) so that every Delphi
///   exception carries a symbolized stack trace (installed automatically in initialization).
/// - BuildCrashReport / WriteCrashLog: aggregate exception, stack, registers, threads, modules,
///   process, system, memory map and environment into one text report.
/// - Optional fatal signal handlers (SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT) that write the same
///   report with the *faulting* registers, then chain to the previous handler (the Delphi RTL
///   converts these signals into exceptions, that behaviour is preserved).
/// </summary>
unit DebugEngine.Linux.HookException;

{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  System.SysUtils,
  System.Classes,
  DebugEngine.Linux.Posix,
  DebugEngine.Linux.Registers;

type
  TCrashReportSection = (crsException, crsStackTrace, crsRawBacktrace, crsRegisters, crsVectorRegisters, crsThreads, crsModules, crsProcess, crsSystem,
    crsMemoryMap, crsEnvironment, crsDebugInfoSources);
  TCrashReportSections = set of TCrashReportSection;

const
  AllCrashReportSections = [crsException, crsStackTrace, crsRawBacktrace, crsRegisters, crsVectorRegisters, crsThreads, crsModules, crsProcess, crsSystem,
    crsMemoryMap, crsEnvironment, crsDebugInfoSources];
  DefaultCrashReportSections = AllCrashReportSections - [crsMemoryMap, crsVectorRegisters];

type
  /// <summary> Extra context handed to the report builder. </summary>
  TCrashContext = record
    Title: string; // e.g. 'Unhandled exception' or 'Fatal signal SIGSEGV'
    Signal: Integer; // 0 when not a signal.
    SignalCode: Integer; // si_code
    FaultAddress: Pointer; // si_addr
    Registers: TLinuxRegisters; // Faulting registers (signal) or snapshot.
    StackAddresses: TArray<Pointer>; // Captured stack (when empty the current stack is captured).
    FirstAddress: Pointer; // Exact PC of the fault / exception (prepended to the stack).
    class function Empty: TCrashContext; static;
  end;

procedure InstallExceptionHook;
procedure RemoveExceptionHook;

/// <summary> Build a full text report. E may be nil (signal / manual report). </summary>
function BuildCrashReport(E: Exception; const Context: TCrashContext; Sections: TCrashReportSections = DefaultCrashReportSections): string;

/// <summary> Build and append a report to FileName (created if needed). Returns the report. </summary>
function WriteCrashLog(E: Exception; const FileName: string; Sections: TCrashReportSections = DefaultCrashReportSections): string; overload;
function WriteCrashLog(E: Exception; const FileName: string; const Context: TCrashContext; Sections: TCrashReportSections): string; overload;

/// <summary> Install handlers for fatal signals that write a report to LogFileName and then chain to the
/// previous handler. Set LogFileName = '' to write to stderr only. </summary>
procedure InstallSignalHandlers(const LogFileName: string; Sections: TCrashReportSections = DefaultCrashReportSections);
procedure RemoveSignalHandlers;

/// <summary> Stack addresses attached to an exception by the hook (nil when E has no stack info). </summary>
function GetExceptionStackAddresses(E: Exception): TArray<Pointer>;

/// <summary> Exact exception address attached to E by the hook (nil for software raises). </summary>
function GetExceptionAddress(E: Exception): Pointer;

function SignalName(Sig: Integer): string;
function SignalCodeName(Sig, Code: Integer): string;

implementation

uses
  System.IOUtils,
  Posix.Signal,
  Posix.Unistd,
  DebugEngine.Linux.Trace,
  DebugEngine.Linux.DebugInfo,
  DebugEngine.Linux.SysInfo,
  DebugEngine.Linux.Modules;

type
  PStackInfo = ^TStackInfo;

  TStackInfo = record
    Addresses: TArray<Pointer>;
    ExceptionAddress: Pointer;
    Text: string; // Lazily formatted.
  end;

var
  GHookInstalled: Boolean = False;

{ TCrashContext }

class function TCrashContext.Empty: TCrashContext;
begin
  Result := Default (TCrashContext);
end;

{$REGION 'Exception hook'}

function GetExceptionStackInfo(P: PExceptionRecord): Pointer;
var
  Info: PStackInfo;
begin
  New(Info);
  Info^.Text := '';
  { For hardware exceptions (signals) ExceptionAddress is the faulting PC. For software raises it
    is not a code address on this platform: only keep it when it points into executable code. }
  Info^.ExceptionAddress := P^.ExceptionAddress;
  if not IsCodeAddress(Info^.ExceptionAddress) then
    Info^.ExceptionAddress := nil;
  Info^.Addresses := CaptureStackTrace(1);
  Result := Info;
end;

function GetStackInfoString(Info: Pointer): string;
var
  SI: PStackInfo;
  SL: TStringList;
begin
  SI := Info;
  if not Assigned(SI) then
    Exit('');
  if SI^.Text = '' then
  begin
    SL := TStringList.Create;
    try
      StackTraceFromAddresses(SI^.Addresses, SL, SI^.ExceptionAddress, True);
      SI^.Text := SL.Text;
    finally
      SL.Free;
    end;
  end;
  Result := SI^.Text;
end;

procedure CleanUpStackInfo(Info: Pointer);
begin
  if Assigned(Info) then
    Dispose(PStackInfo(Info));
end;

procedure InstallExceptionHook;
begin
  if GHookInstalled then
    Exit;
  Exception.GetExceptionStackInfoProc := GetExceptionStackInfo;
  Exception.GetStackInfoStringProc := GetStackInfoString;
  Exception.CleanUpStackInfoProc := CleanUpStackInfo;
  GHookInstalled := True;
end;

procedure RemoveExceptionHook;
begin
  if not GHookInstalled then
    Exit;
  Exception.GetExceptionStackInfoProc := nil;
  Exception.GetStackInfoStringProc := nil;
  Exception.CleanUpStackInfoProc := nil;
  GHookInstalled := False;
end;

function GetExceptionStackAddresses(E: Exception): TArray<Pointer>;
begin
  if Assigned(E) and Assigned(E.StackInfo) then
    Result := PStackInfo(E.StackInfo)^.Addresses
  else
    Result := nil;
end;

function GetExceptionAddress(E: Exception): Pointer;
begin
  if Assigned(E) and Assigned(E.StackInfo) then
    Result := PStackInfo(E.StackInfo)^.ExceptionAddress
  else
    Result := nil;
end;

{$ENDREGION}
{$REGION 'Signals'}

function SignalName(Sig: Integer): string;
begin
  case Sig of
    SIGSEGV: Result := 'SIGSEGV';
    SIGBUS: Result := 'SIGBUS';
    SIGFPE: Result := 'SIGFPE';
    SIGILL: Result := 'SIGILL';
    SIGABRT: Result := 'SIGABRT';
    SIGTRAP: Result := 'SIGTRAP';
    SIGQUIT: Result := 'SIGQUIT';
    SIGTERM: Result := 'SIGTERM';
    SIGINT: Result := 'SIGINT';
  else
    Result := 'SIG' + IntToStr(Sig);
  end;
end;

function SignalCodeName(Sig, Code: Integer): string;
begin
  Result := IntToStr(Code);
  case Sig of
    SIGSEGV:
      case Code of
        1: Result := 'SEGV_MAPERR (address not mapped)';
        2: Result := 'SEGV_ACCERR (invalid permissions)';
      end;
    SIGBUS:
      case Code of
        1: Result := 'BUS_ADRALN (invalid alignment)';
        2: Result := 'BUS_ADRERR (nonexistent physical address)';
        3: Result := 'BUS_OBJERR (object specific hardware error)';
      end;
    SIGFPE:
      case Code of
        1: Result := 'FPE_INTDIV (integer divide by zero)';
        2: Result := 'FPE_INTOVF (integer overflow)';
        3: Result := 'FPE_FLTDIV (float divide by zero)';
        4: Result := 'FPE_FLTOVF (float overflow)';
        5: Result := 'FPE_FLTUND (float underflow)';
        6: Result := 'FPE_FLTRES (inexact result)';
        7: Result := 'FPE_FLTINV (invalid operation)';
        8: Result := 'FPE_FLTSUB (subscript out of range)';
      end;
    SIGILL:
      case Code of
        1: Result := 'ILL_ILLOPC (illegal opcode)';
        2: Result := 'ILL_ILLOPN (illegal operand)';
        3: Result := 'ILL_ILLADR (illegal addressing mode)';
        4: Result := 'ILL_ILLTRP (illegal trap)';
        5: Result := 'ILL_PRVOPC (privileged opcode)';
        6: Result := 'ILL_PRVREG (privileged register)';
        7: Result := 'ILL_COPROC (coprocessor error)';
        8: Result := 'ILL_BADSTK (internal stack error)';
      end;
  end;
end;

const
  HandledSignals: array [0 .. 4] of Integer = (SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT);

var
  GSignalLogFile: string = '';
  GSignalSections: TCrashReportSections = DefaultCrashReportSections;
  GSignalHandlersInstalled: Boolean = False;
  GOldActions: array [0 .. High(HandledSignals)] of sigaction_t;
  GInSignalHandler: Integer = 0;

procedure ChainToPreviousHandler(Index, Sig: Integer; Info: Psiginfo_t; Context: Pointer);
var
  Old: sigaction_t;
  HandlerValue: NativeInt;
begin
  Old := GOldActions[Index];
  HandlerValue := PNativeInt(@Old._u.sa_handler)^; // SIG_DFL = 0, SIG_IGN = 1, else a function pointer.
  if HandlerValue = 1 then
    Exit; // SIG_IGN
  if HandlerValue = 0 then
  begin
    { SIG_DFL: restore the default action and re-raise so that the process terminates
      (and dumps core) exactly as it would have without us. }
    sigaction(Sig, @Old, nil);
    kill(getpid, Sig);
    Exit;
  end;
  if Old.sa_flags and SA_SIGINFO <> 0 then
    Old._u.sa_sigaction(Sig, Info, Context)
  else
    Old._u.sa_handler(Sig);
end;

procedure FatalSignalHandler(Sig: Integer; Info: Psiginfo_t; Context: Pointer); cdecl;
var
  Ctx: TCrashContext;
  Report: string;
  I, Index: Integer;
  Buf: UTF8String;
begin
  Index := -1;
  for I := 0 to High(HandledSignals) do
    if HandledSignals[I] = Sig then
      Index := I;
  { Re-entrancy guard: a fault while producing the report must not loop forever. }
  if AtomicIncrement(GInSignalHandler) = 1 then
  try
    Ctx := TCrashContext.Empty;
    Ctx.Signal := Sig;
    Ctx.Title := 'Fatal signal ' + SignalName(Sig);
    if Assigned(Info) then
    begin
      Ctx.SignalCode := Info^.si_code;
      Ctx.FaultAddress := Info^._sifields._sigfault.si_addr;
    end;
    if RegistersFromContext(Context, Ctx.Registers) then
      Ctx.FirstAddress := Pointer(Ctx.Registers.RIP);
    { The current stack (inside the handler) still contains the faulting frames below the kernel
      signal frame: backtrace walks through it thanks to the restorer's unwind info. Drop the
      handler + restorer frames: everything up to the faulting PC (which is prepended as exact). }
    Ctx.StackAddresses := CaptureStackTrace(1);
    if Assigned(Ctx.FirstAddress) then
      for I := 0 to High(Ctx.StackAddresses) do
        if Ctx.StackAddresses[I] = Ctx.FirstAddress then
        begin
          Ctx.StackAddresses := Copy(Ctx.StackAddresses, I + 1, MaxInt);
          Break;
        end;
    Report := BuildCrashReport(nil, Ctx, GSignalSections);
    if GSignalLogFile <> '' then
    try
      TFile.AppendAllText(GSignalLogFile, Report + sLineBreak, TEncoding.UTF8);
    except
      // ignore
    end;
    Buf := UTF8String(Report + sLineBreak);
    __write(STDERR_FILENO, @Buf[Low(Buf)], Length(Buf));
  except
    // ignore: never raise from a signal handler.
  end;
  AtomicDecrement(GInSignalHandler);
  if Index >= 0 then
    ChainToPreviousHandler(Index, Sig, Info, Context);
end;

procedure InstallSignalHandlers(const LogFileName: string; Sections: TCrashReportSections);
var
  Act: sigaction_t;
  I: Integer;
begin
  GSignalLogFile := LogFileName;
  GSignalSections := Sections;
  if GSignalHandlersInstalled then
    Exit;
  for I := 0 to High(HandledSignals) do
  begin
    FillChar(Act, SizeOf(Act), 0);
    Act._u.sa_sigaction := FatalSignalHandler;
    Act.sa_flags := SA_SIGINFO or SA_NODEFER or SA_ONSTACK;
    sigemptyset(Act.sa_mask);
    sigaction(HandledSignals[I], @Act, @GOldActions[I]);
  end;
  GSignalHandlersInstalled := True;
end;

procedure RemoveSignalHandlers;
var
  I: Integer;
begin
  if not GSignalHandlersInstalled then
    Exit;
  for I := 0 to High(HandledSignals) do
    sigaction(HandledSignals[I], @GOldActions[I], nil);
  GSignalHandlersInstalled := False;
end;

{$ENDREGION}
{$REGION 'Report'}

procedure AddHeader(SL: TStrings; const Title: string);
begin
  SL.Add('');
  SL.Add('---- ' + Title + ' ' + StringOfChar('-', 70 - Length(Title)));
end;

function BuildCrashReport(E: Exception; const Context: TCrashContext; Sections: TCrashReportSections): string;
var
  SL: TStringList;
  Regs: TLinuxRegisters;
  Stack: TArray<Pointer>;
  First: Pointer;
  Raw: TArray<string>;
  I: Integer;
  Title, S: string;
  Info: TLinuxAddressInfo;
  Inner: Exception;
begin
  SL := TStringList.Create;
  try
    Title := Context.Title;
    if Title = '' then
      if Assigned(E) then
        Title := 'Exception report'
      else
        Title := 'Diagnostic report';
    SL.Add(StringOfChar('=', 76));
    SL.Add(Format('%s  -  %s', [Title, FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now)]));
    SL.Add(StringOfChar('=', 76));

    if crsException in Sections then
    begin
      AddHeader(SL, 'Exception');
      if Context.Signal <> 0 then
      begin
        SL.Add(Format('  Signal        : %d (%s)', [Context.Signal, SignalName(Context.Signal)]));
        SL.Add(Format('  Code          : %s', [SignalCodeName(Context.Signal, Context.SignalCode)]));
        SL.Add(Format('  Fault address : %p', [Context.FaultAddress]));
      end;
      if Assigned(E) then
      begin
        SL.Add(Format('  Class         : %s', [E.ClassName]));
        SL.Add(Format('  Message       : %s', [E.Message]));
        First := Context.FirstAddress;
        if not Assigned(First) then
          First := ExceptAddr();
        if Assigned(First) then
        begin
          if GetAddressInfo(First, Info) then
            SL.Add(Format('  Address       : %p  %s', [First, Info.ToString]))
          else
            SL.Add(Format('  Address       : %p', [First]));
        end;
        Inner := E.InnerException;
        I := 0;
        while Assigned(Inner) and (I < 10) do
        begin
          SL.Add(Format('  Inner[%d]      : %s: %s', [I, Inner.ClassName, Inner.Message]));
          Inner := Inner.InnerException;
          Inc(I);
        end;
        if E.StackInfo <> nil then
        begin
          SL.Add('  Stack at raise (Exception.StackTrace):');
          for S in E.StackTrace.Split([#10]) do
            if S.Trim <> '' then
              SL.Add('    ' + S.TrimRight([#13]));
        end;
      end
      else if Assigned(Context.FirstAddress) then
      begin
        if GetAddressInfo(Context.FirstAddress, Info) then
          SL.Add(Format('  Address       : %p  %s', [Context.FirstAddress, Info.ToString]))
        else
          SL.Add(Format('  Address       : %p', [Context.FirstAddress]));
      end;
      SL.Add(Format('  Thread        : tid=%d  main thread=%s', [CurrentThreadId, BoolToStr(MainThreadID = TThread.CurrentThread.ThreadID, True)]));
    end;

    Stack := Context.StackAddresses;
    if Length(Stack) = 0 then
      Stack := CaptureStackTrace(1);

    if crsStackTrace in Sections then
    begin
      AddHeader(SL, 'Stack trace (current thread)');
      SL.Add(Format('  %-18s  %-24s  %-28s  %-28s  %s', ['Address', 'Module', 'Unit', 'Source:line', 'Symbol+offset']));
      StackTraceFromAddresses(Stack, SL, Context.FirstAddress, Assigned(E));
    end;

    if crsRawBacktrace in Sections then
    begin
      AddHeader(SL, 'Raw backtrace_symbols');
      Raw := RawBacktraceSymbols(Stack);
      for I := 0 to High(Raw) do
        SL.Add('  ' + Raw[I]);
    end;

    if crsRegisters in Sections then
    begin
      if Context.Registers.Valid then
      begin
        AddHeader(SL, 'Registers (at fault)');
        RegistersToStrings(Context.Registers, SL, crsVectorRegisters in Sections);
      end
      else
      begin
        AddHeader(SL, 'Registers (snapshot while building the report)');
        SnapshotOfRegisters(Regs);
        RegistersToStrings(Regs, SL, crsVectorRegisters in Sections);
      end;
    end;

    if crsThreads in Sections then
    begin
      AddHeader(SL, 'Threads');
      ThreadsToStrings(SL);
    end;

    if crsProcess in Sections then
    begin
      AddHeader(SL, 'Process');
      ProcessInfoToStrings(SL);
    end;

    if crsSystem in Sections then
    begin
      AddHeader(SL, 'System');
      SystemInfoToStrings(SL);
    end;

    if crsDebugInfoSources in Sections then
    begin
      AddHeader(SL, 'Debug info sources');
      SL.Add('  ' + DescribeDebugInfoSources);
    end;

    if crsModules in Sections then
    begin
      AddHeader(SL, 'Modules');
      ModulesToStrings(SL);
    end;

    if crsMemoryMap in Sections then
    begin
      AddHeader(SL, 'Memory map (/proc/self/maps)');
      MemoryMapToStrings(SL);
    end;

    if crsEnvironment in Sections then
    begin
      AddHeader(SL, 'Environment');
      EnvironmentToStrings(SL);
    end;

    SL.Add('');
    SL.Add(StringOfChar('=', 76));
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

function WriteCrashLog(E: Exception; const FileName: string; const Context: TCrashContext; Sections: TCrashReportSections): string;
begin
  Result := BuildCrashReport(E, Context, Sections);
  try
    TFile.AppendAllText(FileName, Result + sLineBreak, TEncoding.UTF8);
  except
    // The report is still returned to the caller.
  end;
end;

function WriteCrashLog(E: Exception; const FileName: string; Sections: TCrashReportSections): string;
var
  Ctx: TCrashContext;
begin
  Ctx := TCrashContext.Empty;
  if Assigned(E) then
  begin
    Ctx.Title := 'Exception ' + E.ClassName;
    Ctx.StackAddresses := GetExceptionStackAddresses(E);
    Ctx.FirstAddress := GetExceptionAddress(E);
  end;
  Result := WriteCrashLog(E, FileName, Ctx, Sections);
end;

{$ENDREGION}

initialization

InstallExceptionHook;

finalization

RemoveSignalHandlers;
RemoveExceptionHook;

end.
