program DETest;

{ Console smoke test for DebugEngine (Win32/Win64).
  Build with detailed map (-GD) and run from any directory; exit code = number of failures. }

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  DebugEngine.Core in '..\..\src\DebugEngine.Core.pas',
  DebugEngine.AsmRegUtils in '..\..\src\DebugEngine.AsmRegUtils.pas',
  DebugEngine.DebugInfo in '..\..\src\DebugEngine.DebugInfo.pas',
  DebugEngine.DebugUtils in '..\..\src\DebugEngine.DebugUtils.pas',
  DebugEngine.Disasm in '..\..\src\DebugEngine.Disasm.pas',
  DebugEngine.HookException in '..\..\src\DebugEngine.HookException.pas',
  DebugEngine.Trace in '..\..\src\DebugEngine.Trace.pas',
  DebugEngine.MapParser in '..\..\src\DebugEngine.MapParser.pas',
  DebugEngine.CrashLog in '..\..\src\DebugEngine.CrashLog.pas';

var
  Pass, Fail: Integer;

procedure Check(const Name: string; Cond: Boolean; const Detail: string = '');
begin
  if Cond then
  begin
    Inc(Pass);
    Writeln('[PASS] ', Name, '  ', Detail);
  end
  else
  begin
    Inc(Fail);
    Writeln('[FAIL] ', Name, '  ', Detail);
  end;
end;

{ ---- Stack trace ---- }
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
  SL := TStringList.Create;
  try
    Level1(SL);
    S := SL.Text;
    Writeln(S);
    Check('StackTrace has frames', SL.Count >= 3, IntToStr(SL.Count) + ' frames');
    Check('StackTrace resolves Level3/Level2/Level1',
      (Pos('Level3', S) > 0) and (Pos('Level2', S) > 0) and (Pos('Level1', S) > 0));
  finally
    SL.Free;
  end;
end;

{ ---- Exception hook ---- }
procedure RaiseAV;
var
  P: PDWORD;
begin
  P := nil;
  P^ := 1;
end;

procedure TestExceptionHook;
var
  S: string;
begin
  S := '';
  try
    RaiseAV;
  except
    on E: Exception do
      S := E.StackTrace;
  end;
  Writeln(S);
  Check('E.StackTrace non-empty', S <> '');
  Check('E.StackTrace contains RaiseAV', Pos('RaiseAV', S) > 0);
end;

{ ---- Address / symbol info ---- }
procedure TestAddressInfo;
var
  Info: TAddressInfo;
  P: Pointer;
  Size: Integer;
begin
  P := @TestStackTrace;
  if not GetAddressInfo(P, Info) then
  begin
    Check('GetAddressInfo', False);
    Exit;
  end;
  Check('GetAddressInfo', True);
  Writeln('  MapLocation=', MapLocationToStr(Info.DebugSource.Module.MapLocation),
    ' Symbol=', Info.SymbolName, ' Line=', Info.LineNumber, ' Unit=', Info.UnitName);
  Check('Symbol name correct', Pos('TestStackTrace', Info.SymbolName) > 0, Info.SymbolName);
  Check('Line number > 0', Info.LineNumber > 0);

  P := GetSymbolAddress(0, '', 'TestAddressInfo');
  Check('GetSymbolAddress(TestAddressInfo)', P = @TestAddressInfo, Format('%p', [P]));
  P := GetSymbolAddress(0, 'System', 'MemoryManager');
  Check('GetSymbolAddress(System.MemoryManager)', P <> nil, Format('%p', [P]));
  P := GetSymbolAddress(GetModuleHandle(user32), '', 'MessageBoxA');
  { GetProcAddress may return an app-compat shim (apphelp.dll); the export table address is the real one. }
  Check('GetSymbolAddress(user32.MessageBoxA)', (P = GetProcAddress(GetModuleHandle(user32), 'MessageBoxA')) or
    (GetModuleHandleFromAddress(P) = GetModuleHandle(user32)), Format('got=%p GetProcAddress=%p', [P, GetProcAddress(GetModuleHandle(user32), 'MessageBoxA')]));

  Size := GetSizeOfFunction(@TestAddressInfo);
  Check('GetSizeOfFunction > 0', Size > 0, IntToStr(Size) + ' bytes');
end;

{ ---- Registers ---- }
procedure TestRegisters;
var
  Regs: TLegacyRegisters;
  Vec: TVectorRegisters;
  Flags: TRflags;
  MX: TMXCSR;
  FPU: TFPURegisters;
begin
  FillChar(Regs, SizeOf(Regs), 0);
  Check('SnapshotOfLegacyRegisters', SnapshotOfLegacyRegisters(Regs));
{$IFDEF CPUX64}
  Check('  RSP <> 0', Regs.RSP.AsRSP <> 0, Format('rsp=%x', [Regs.RSP.AsRSP]));
{$ELSE}
  Check('  ESP <> 0', Regs.ESP.AsESP <> 0, Format('esp=%x', [Regs.ESP.AsESP]));
{$ENDIF}
  FillChar(Vec, SizeOf(Vec), 0);
  Check('SnapshotOfVectorRegisters', SnapshotOfVectorRegisters(Vec));
  FillChar(FPU, SizeOf(FPU), 0);
  Check('SnapshotOfFPURegisters', SnapshotOfFPURegisters(FPU));
  Flags := SnapshotOfRFlagsRegister;
  Check('SnapshotOfRFlagsRegister', True, Format('flags=%x', [NativeUInt(Flags)]));
  MX := SnapshotOfMXCSRRegister;
  Check('SnapshotOfMXCSRRegister', True, Format('mxcsr=%x', [Cardinal(MX)]));
end;

{ ---- Try blocks ---- }
var
  TryCount: Integer;

function EnumTryCB(var Info: TTryBlockInfo; UserData: Pointer): Boolean;
begin
  Inc(TryCount);
  Result := True;
end;

procedure TestTryBlocks;
var
  SL: TStringList;
begin
  TryCount := 0;
{$IFDEF CPUX64}
  { EnumTryBlocks is table based (x64 only). }
  Check('EnumTryBlocks', EnumTryBlocks(0, EnumTryCB, nil));
  Check('EnumTryBlocks found blocks', TryCount > 0, IntToStr(TryCount) + ' blocks');
{$ELSE}
  Writeln('[N/A ] EnumTryBlocks (x64 only)');
{$ENDIF}
  SL := TStringList.Create;
  try
{$IFDEF CPUX86}
    { TraceTryBlocks is stack based (x86 only). }
    try
      TraceTryBlocks(SL);
      Writeln(SL.Text);
      Check('TraceTryBlocks', SL.Count > 0, IntToStr(SL.Count) + ' lines');
    except
      on E: Exception do
        Check('TraceTryBlocks', False, E.ClassName + ': ' + E.Message);
    end;
{$ELSE}
    Writeln('[N/A ] TraceTryBlocks (x86 only)');
{$ENDIF}
  finally
    SL.Free;
  end;
end;

{ ---- Disasm ---- }
var
  InsCount: Integer;

procedure DisasmCB(var Info: TDisasmInfo; UserData: Pointer);
begin
  Inc(InsCount);
  if InsCount <= 5 then
    Writeln('  ', Info.InstStr, '   ', Info.Comment);
end;

procedure TestDisasm;
var
  PEnd: Pointer;
begin
  InsCount := 0;
  PEnd := nil;
  Check('DisasmAndCommentFunction', DisasmAndCommentFunction(@TestAddressInfo, PEnd, DisasmCB, nil));
  Check('Disasm instructions > 0', InsCount > 0, IntToStr(InsCount) + ' instructions');
end;

{ ---- Map -> SMap -> PE ---- }
procedure TestSMap;
var
  App, Base, MapFile, SMapFile, Foo: string;
  N: Integer;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Code: DWORD;
begin
  App := ParamStr(0);
  Base := ChangeFileExt(App, '');
  MapFile := Base + DelphiMapFileExtension;
  SMapFile := Base + SMapFileExtension;
  Foo := ExtractFilePath(App) + 'foo.exe';
  Check('Map file exists', FileExists(MapFile), MapFile);
  N := ConvertMapToSMap(MapFile, []);
  Check('ConvertMapToSMap', N > 0, IntToStr(N));
  CopyFile(PChar(App), PChar(Foo), False);
  Check('InsertDebugInfo', InsertDebugInfo(Foo, SMapFile, True));
  DeleteFile(PChar(PChar(ChangeFileExt(Foo, DelphiMapFileExtension))));
  { Run foo.exe with -child: it must resolve symbols from the embedded section. }
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  if CreateProcess(nil, PChar('"' + Foo + '" -child'), nil, nil, False, 0, nil, nil, SI, PI) then
  begin
    WaitForSingleObject(PI.hProcess, 60000);
    GetExitCodeProcess(PI.hProcess, Code);
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
    Check('foo.exe (embedded smap) resolved symbols', Code = 0, 'exit=' + IntToStr(Code));
  end
  else
    Check('Run foo.exe', False);
end;

{ ---- Crash log ---- }
procedure CrashWorker;
begin
  raise EInvalidOperation.Create('crash log test');
end;

{ ---- Map without line numbers (linked with debug information off) ---- }
procedure TestMapWithoutLines;
var
  SL: TStringList;
  I: Integer;
  Src, Dst: TMemoryStream;
  Reader: TSMapReader;
  N: Integer;
begin
  { Strip every "Line numbers for ..." section from our own map and convert the result. }
  SL := TStringList.Create;
  Src := TMemoryStream.Create;
  Dst := TMemoryStream.Create;
  try
    SL.LoadFromFile(ChangeFileExt(ParamStr(0), DelphiMapFileExtension));
    for I := SL.Count - 1 downto 0 do
      if SL[I].TrimLeft.StartsWith('Line numbers for') then
        SL.Delete(I);
    SL.SaveToStream(Src);
    Src.Size := Src.Size + 1;
    PByte(Src.Memory)[Src.Size - 1] := 0;
    N := ConvertMapToSMap(Src, Dst, []);
    Check('Map without line numbers: converted', (N > 0) and (N < Src.Size), Format('%d bytes (map %d)', [N, Src.Size]));
    Reader := TSMapReader.Create(
      function(SegId: Integer; const SegName: string; SegStartAddress: NativeUInt; SegLength: Cardinal; out RtStartAddress: Pointer): Boolean
      begin
        RtStartAddress := Pointer(SegStartAddress);
        Result := True;
      end);
    try
      Dst.Position := 0;
      Check('Map without line numbers: loaded', Reader.LoadFromStream(Dst) and (Reader.SymbolCount > 1000), IntToStr(Reader.SymbolCount) + ' symbols');
    finally
      Reader.Free;
    end;
  finally
    SL.Free;
    Src.Free;
    Dst.Free;
  end;
end;

procedure TestCrashLog;
var
  Report, LogFile: string;
  Addrs: TExceptionStackAddresses;
begin
  LogFile := ChangeFileExt(ParamStr(0), '.crash.log');
  if FileExists(LogFile) then
    DeleteFile(LogFile);
  Report := '';
  try
    CrashWorker;
  except
    on E: Exception do
    begin
      Addrs := GetExceptionStackAddresses(E);
      Report := WriteCrashLog(E, LogFile, AllCrashReportSections);
    end;
  end;
  Check('Crash log: addresses captured', Length(Addrs) >= 2, IntToStr(Length(Addrs)) + ' frames');
  Check('Crash log: raise machinery trimmed', (Length(Addrs) >= 2) and (Pos('RaisingException', Report) = 0));
  Check('Crash log: header', Pos('exception class', Report) > 0);
  Check('Crash log: CrashWorker in stack', Pos('CrashWorker', Report) > 0);
  Check('Crash log: threads', Pos('thread(s)', Report) > 0);
  Check('Crash log: modules', Pos('module(s)', Report) > 0);
  Check('Crash log: file written', FileExists(LogFile));
  Check('No temporary .smap written by the map loader', not FileExists(ChangeFileExt(ParamStr(0), SMapFileExtension)));
end;

function ChildCheck: Integer;
var
  Info: TAddressInfo;
begin
  Result := 1;
  if GetAddressInfo(@ChildCheck, Info) and (Pos('ChildCheck', Info.SymbolName) > 0) then
  begin
    Writeln('child: ', MapLocationToStr(Info.DebugSource.Module.MapLocation), ' ', Info.SymbolName);
    if Info.DebugSource.Module.MapLocation in [mlSection, mlResource] then
      Result := 0;
  end;
end;

procedure ChildMode;
begin
  { Strings are released before Halt so that the leak report stays clean. }
  Halt(ChildCheck);
end;

procedure Main;
begin
  if FindCmdLineSwitch('child') then
    ChildMode;
  { Remove a .smap left by a previous run so that the map loader path is exercised. }
  System.SysUtils.DeleteFile(ChangeFileExt(ParamStr(0), SMapFileExtension));
  Writeln('DebugEngine test - ', SizeOf(Pointer) * 8, ' bit, compiler ', CompilerVersion:0:1);
  try
    TestStackTrace;
    TestExceptionHook;
    TestAddressInfo;
    TestRegisters;
    TestTryBlocks;
    TestDisasm;
    TestMapWithoutLines;
    TestCrashLog; { before TestSMap: that one creates the .smap on purpose }
    TestSMap;
  except
    on E: Exception do
    begin
      Inc(Fail);
      Writeln('[FAIL] unhandled ', E.ClassName, ': ', E.Message);
    end;
  end;
  Writeln;
  Writeln('PASS=', Pass, ' FAIL=', Fail);
  ExitCode := Fail; { no Halt inside Main: temporaries must be released before the leak check }
end;

begin
  Main;
end.
