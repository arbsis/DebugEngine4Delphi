program DebugEngineLinuxDemo;

{ DebugEngine for Linux - console demo / smoke test.

  Build (Delphi 13, Linux64) with a detailed map and debug information so that addr2line can
  resolve source lines:  -GD -V   (Project options: Linking > Map file: Detailed, Debug information).

  Run:   ./DebugEngineLinuxDemo            => runs all scenarios, writes DebugEngineLinuxDemo.crash.log
         ./DebugEngineLinuxDemo -noaddr2line => same without the external addr2line tool (ELF symbols only)
         ./DebugEngineLinuxDemo -signal    => additionally installs fatal signal handlers and forces a
                                              SIGSEGV outside of any try/except (report + process dies)
  Exit code = number of failed checks. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.StrUtils,
  DebugEngine.Linux.Elf in '..\..\src\Linux\DebugEngine.Linux.Elf.pas',
  DebugEngine.Linux.Modules in '..\..\src\Linux\DebugEngine.Linux.Modules.pas',
  DebugEngine.Linux.DebugInfo in '..\..\src\Linux\DebugEngine.Linux.DebugInfo.pas',
  DebugEngine.Linux.Trace in '..\..\src\Linux\DebugEngine.Linux.Trace.pas',
  DebugEngine.Linux.Registers in '..\..\src\Linux\DebugEngine.Linux.Registers.pas',
  DebugEngine.Linux.SysInfo in '..\..\src\Linux\DebugEngine.Linux.SysInfo.pas',
  DebugEngine.Linux.HookException in '..\..\src\Linux\DebugEngine.Linux.HookException.pas';

var
  Pass, Fail: Integer;

procedure Check(const Name: string; Cond: Boolean; const Detail: string = '');
begin
  if Cond then
    Inc(Pass)
  else
    Inc(Fail);
  Writeln(Format('[%s] %s  %s', [IfThen(Cond, 'PASS', 'FAIL'), Name, Detail]));
end;

procedure Banner(const S: string);
begin
  Writeln;
  Writeln('==== ', S, ' ', StringOfChar('=', 60 - Length(S)));
end;

{ ---- nested stack trace ---- }

procedure Level3(SL: TStrings);
begin
  StackTrace(SL);
end;

procedure Level2(SL: TStrings);
begin
  Level3(SL);
end;

procedure Level1(SL: TStrings);
begin
  Level2(SL);
end;

procedure TestStackTrace;
var
  SL: TStringList;
  S: string;
begin
  Banner('StackTrace');
  SL := TStringList.Create;
  try
    Level1(SL);
    S := SL.Text;
    Writeln(S);
    Check('frames captured', SL.Count >= 4, IntToStr(SL.Count) + ' frames');
    Check('Level1/2/3 resolved', (Pos('Level3', S) > 0) and (Pos('Level2', S) > 0) and (Pos('Level1', S) > 0));
    if LinuxDebugInfoOptions.UseAddr2Line then
      Check('source lines resolved (needs addr2line + -V)', Pos('.dpr:', S) > 0, IfThen(Addr2LinePath = '', 'addr2line not found', Addr2LinePath))
    else
      Writeln('[N/A ] source lines (addr2line disabled)');
  finally
    SL.Free;
  end;
end;

{ ---- exception hook ---- }

procedure RaiseAV;
var
  P: PInteger;
begin
  P := nil;
  P^ := 1;
end;

procedure RaiseCustom;
begin
  raise EInvalidOperation.Create('custom exception for the demo');
end;

procedure TestExceptionHook;
var
  S: string;
begin
  Banner('Exception.StackTrace hook');
  S := '';
  try
    RaiseAV;
  except
    on E: Exception do
    begin
      S := E.StackTrace;
      Writeln(E.ClassName, ': ', E.Message);
      Writeln(S);
    end;
  end;
  Check('AV: E.StackTrace not empty', S <> '');
  Check('AV: contains RaiseAV', Pos('RaiseAV', S) > 0);
  S := '';
  try
    RaiseCustom;
  except
    on E: Exception do
    begin
      S := E.StackTrace;
      Writeln(E.ClassName, ': ', E.Message);
      Writeln(S);
    end;
  end;
  Check('raise: E.StackTrace not empty', S <> '');
  Check('raise: contains RaiseCustom', Pos('RaiseCustom', S) > 0);
end;

{ ---- address info ---- }

procedure TestAddressInfo;
var
  Info: TLinuxAddressInfo;
  P: Pointer;
begin
  Banner('GetAddressInfo / GetSymbolAddress');
  Writeln('  ', DescribeDebugInfoSources);
  P := @TestStackTrace;
  Check('GetAddressInfo', GetAddressInfo(P, Info));
  Writeln(Format('  %p => module=%s symbol=%s raw=%s unit=%s src=%s:%d sources=%d', [P, Info.ModuleBaseName, Info.SymbolName, Info.RawSymbolName,
    Info.UnitName, Info.SourceFile, Info.LineNumber, Byte(Info.Sources)]));
  Check('symbol name', Pos('TestStackTrace', Info.SymbolName) > 0, Info.SymbolName);
  Check('unit name', Info.UnitName <> '', Info.UnitName);
  if LinuxDebugInfoOptions.UseAddr2Line then
    Check('line number (addr2line)', Info.LineNumber > 0, IntToStr(Info.LineNumber))
  else
    Writeln('[N/A ] line number (addr2line disabled)');
  P := GetSymbolAddress('Debugenginelinuxdemo.TestAddressInfo');
  Check('GetSymbolAddress(demangled)', P = @TestAddressInfo, Format('%p', [P]));
  P := GetSymbolAddress('_ZN20Debugenginelinuxdemo15TestAddressInfoEv');
  Check('GetSymbolAddress(mangled)', P = @TestAddressInfo, Format('%p', [P]));
  Check('Demangle', DemangleName('_ZN6System8Sysutils6FormatERKN6System13UnicodeStringERKN6System5TVarRecEi') = 'System.Sysutils.Format',
    DemangleName('_ZN6System8Sysutils6FormatERKN6System13UnicodeStringERKN6System5TVarRecEi'));
end;

{ ---- registers ---- }

procedure TestRegisters;
var
  Regs: TLinuxRegisters;
  SL: TStringList;
begin
  Banner('Registers (getcontext)');
  Check('SnapshotOfRegisters', SnapshotOfRegisters(Regs));
  Check('RSP <> 0', Regs.RSP <> 0);
  Check('RIP in main module', (GlobalModules.MainModule <> nil) and GlobalModules.MainModule.ContainsAddress(Pointer(Regs.RIP)), Format('RIP=%x', [Regs.RIP]));
  SL := TStringList.Create;
  try
    RegistersToStrings(Regs, SL, False);
    Writeln(SL.Text);
  finally
    SL.Free;
  end;
end;

{ ---- sysinfo ---- }

procedure TestSysInfo;
var
  SL: TStringList;
begin
  Banner('System / process / threads / modules');
  SL := TStringList.Create;
  try
    SystemInfoToStrings(SL);
    Check('SystemInfo', SL.Count > 5, IntToStr(SL.Count) + ' lines');
    ProcessInfoToStrings(SL);
    Check('ProcessInfo', Pos('VmRSS', SL.Text) > 0);
    ThreadsToStrings(SL);
    Check('Threads', Pos('TID', SL.Text) > 0);
    ModulesToStrings(SL);
    Check('Modules', GlobalModules.Count >= 2, IntToStr(GlobalModules.Count) + ' modules');
    Writeln(SL.Text);
  finally
    SL.Free;
  end;
end;

{ ---- crash log ---- }

procedure Worker;
begin
  RaiseAV;
end;

procedure TestCrashLog;
var
  LogFile, Report: string;
begin
  Banner('Crash log');
  LogFile := ChangeFileExt(ParamStr(0), '.crash.log');
  if FileExists(LogFile) then
    DeleteFile(LogFile);
  try
    Worker;
  except
    on E: Exception do
      Report := WriteCrashLog(E, LogFile, AllCrashReportSections);
  end;
  Check('crash log written', FileExists(LogFile), LogFile);
  Check('report has exception', Pos('EAccessViolation', Report) > 0);
  Check('report has stack with Worker', Pos('Worker', Report) > 0);
  Check('report has registers', Pos('RIP=', Report) > 0);
  Check('report has threads', Pos('thread(s)', Report) > 0);
  Check('report has modules', Pos('module(s)', Report) > 0);
  Check('report has system', Pos('Kernel', Report) > 0);
  Check('report has environment', Pos('PATH=', Report) > 0);
  Check('report has memory map', Pos('r-xp', Report) > 0);
  Writeln(Format('  report: %d bytes, %d lines', [Length(Report), Report.CountChar(#10)]));
end;

procedure TestSignal;
begin
  Banner('Fatal signal (SIGSEGV outside try/except)');
  InstallSignalHandlers(ChangeFileExt(ParamStr(0), '.signal.log'));
  Writeln('  forcing SIGSEGV... report goes to stderr and ', ChangeFileExt(ParamStr(0), '.signal.log'));
  RaiseAV; // Not caught: RTL converts to an exception after our handler logged the fault context.
end;

begin
  Writeln('DebugEngine Linux demo - Delphi ', CompilerVersion:0:1, ' ', SizeOf(Pointer) * 8, ' bit');
  if FindCmdLineSwitch('noaddr2line') then
    LinuxDebugInfoOptions.UseAddr2Line := False;
  try
//    TestStackTrace;
    TestExceptionHook;
//    TestAddressInfo;
//    TestRegisters;
    TestSysInfo;  //esse
//    TestCrashLog;
    if FindCmdLineSwitch('signal') then
      TestSignal;
  except
    on E: Exception do
    begin
      Inc(Fail);
      Writeln('[FAIL] unhandled ', E.ClassName, ': ', E.Message);
      Writeln(E.StackTrace);
    end;
  end;
  Writeln;
  Writeln('PASS=', Pass, ' FAIL=', Fail);
  Halt(Fail);
end.
