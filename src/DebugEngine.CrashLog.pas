// **************************************************************************************************
// Delphi DebugEngine.
// Unit DebugEngine.CrashLog
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
/// Windows crash / exception report builder (madExcept-like text layout):
///   - header: date/time, computer, user, OS, uptimes, CPU, memory, disk, display, process, executable,
///     version, compiler, callstack crc, exception number/class/message;
///   - sections (same layout as DebugEngine.Linux.HookException): Exception (with the symbolized stack
///     captured at raise), Threads, Modules, Registers, Environment.
/// Symbols come from DebugEngine.DebugInfo (embedded SMAP, .smap or the .map next to the executable,
/// converted in memory - no temporary file). Requires DebugEngine.HookException for the raise stack.
/// </summary>
unit DebugEngine.CrashLog;

{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  System.SysUtils,
  System.Classes;

type
  TCrashReportSection = (crsHeader, crsException, crsThreads, crsModules, crsRegisters, crsEnvironment);
  TCrashReportSections = set of TCrashReportSection;

const
  AllCrashReportSections = [crsHeader, crsException, crsThreads, crsModules, crsRegisters, crsEnvironment];
  DefaultCrashReportSections = [crsHeader, crsException];
  DebugEngineVersion = '2.0.0';

/// <summary> Build the text report for E (may be nil for a plain diagnostic report). </summary>
function BuildCrashReport(E: Exception; Sections: TCrashReportSections = DefaultCrashReportSections): string;

/// <summary> Build and append the report to FileName (UTF-8, created when needed). Returns the report. </summary>
function WriteCrashLog(E: Exception; const FileName: string; Sections: TCrashReportSections = DefaultCrashReportSections): string;

/// <summary> Format one address as '$address  module  unit  file:line  symbol+offset'. </summary>
function FormatFrame(Address: Pointer): string;

/// <summary> Symbolized stack of E (one line per frame, FormatFrame layout). '' if E has no stack info. </summary>
function ExceptionStackText(E: Exception): string;

/// <summary> Number of reports built so far in this process (the "exception number" of the header). </summary>
function CrashReportCount: Integer;

implementation

uses
  Winapi.Windows,
  Winapi.PsAPI,
  Winapi.TlHelp32,
  System.IOUtils,
  System.DateUtils,
  System.Win.Registry,
  DebugEngine.DebugInfo,
  DebugEngine.HookException,
  DebugEngine.AsmRegUtils;

var
  GReportCount: Integer = 0;

{$REGION 'Helpers'}

function CrashReportCount: Integer;
begin
  Result := GReportCount;
end;

function Crc32(const Data; Len: Integer): Cardinal;
const
  Poly = $EDB88320;
var
  P: PByte;
  I, J: Integer;
  C: Cardinal;
begin
  Result := $FFFFFFFF;
  P := @Data;
  for I := 0 to Len - 1 do
  begin
    C := (Result xor P^) and $FF;
    for J := 0 to 7 do
      if C and 1 <> 0 then
        C := (C shr 1) xor Poly
      else
        C := C shr 1;
    Result := (Result shr 8) xor C;
    Inc(P);
  end;
  Result := not Result;
end;

function IfThenStr(Cond: Boolean; const A, B: string): string;
begin
  if Cond then
    Result := A
  else
    Result := B;
end;

function FormatDuration(Seconds: Int64): string;
var
  D, H, M, S: Int64;
begin
  D := Seconds div 86400;
  H := (Seconds mod 86400) div 3600;
  M := (Seconds mod 3600) div 60;
  S := Seconds mod 60;
  Result := '';
  if D > 0 then
    Result := Result + Format('%d day%s ', [D, IfThenStr(D <> 1, 's', '')]);
  if (H > 0) or (D > 0) then
    Result := Result + Format('%d hour%s ', [H, IfThenStr(H <> 1, 's', '')]);
  if (M > 0) or (H > 0) or (D > 0) then
    Result := Result + Format('%d minute%s ', [M, IfThenStr(M <> 1, 's', '')]);
  if (D = 0) and (H = 0) then
    Result := Result + Format('%d second%s', [S, IfThenStr(S <> 1, 's', '')]);
  Result := Result.Trim;
end;

function ComputerName: string;
var
  Buf: array [0 .. MAX_COMPUTERNAME_LENGTH + 1] of Char;
  N: DWORD;
begin
  N := Length(Buf);
  if GetComputerName(Buf, N) then
    Result := string(Buf)
  else
    Result := '';
end;

function UserName: string;
var
  Buf: array [0 .. 256] of Char;
  N: DWORD;
begin
  N := Length(Buf);
  if GetUserName(Buf, N) then
    Result := string(Buf)
  else
    Result := '';
end;

function RegistryString(Root: HKEY; const Key, Name: string): string;
var
  R: TRegistry;
begin
  Result := '';
  R := TRegistry.Create(KEY_READ or KEY_WOW64_64KEY);
  try
    try
      R.RootKey := Root;
      if R.OpenKeyReadOnly(Key) and R.ValueExists(Name) then
        Result := R.ReadString(Name).Trim;
    except
      Result := '';
    end;
  finally
    R.Free;
  end;
end;

function OperatingSystem: string;
const
  Arch: array [TOSVersion.TArchitecture] of string = ('x86', 'x64', 'arm32', 'arm64');
begin
  Result := Format('%s %s build %d', [TOSVersion.Name, Arch[TOSVersion.Architecture], TOSVersion.Build]);
  if TOSVersion.ServicePackMajor > 0 then
    Result := Result + Format(' SP%d', [TOSVersion.ServicePackMajor]);
end;

function SystemLanguage: string;
var
  Buf: array [0 .. 127] of Char;
begin
  if GetLocaleInfo(LOCALE_SYSTEM_DEFAULT, LOCALE_SENGLANGUAGE, Buf, Length(Buf)) > 0 then
    Result := string(Buf)
  else
    Result := '';
end;

function ProgramUpTimeSeconds: Int64;
var
  C, E, K, U: TFileTime;
  St: TSystemTime;
  Start: TDateTime;
begin
  Result := 0;
  if GetProcessTimes(GetCurrentProcess, C, E, K, U) and FileTimeToSystemTime(C, St) then
  begin
    Start := EncodeDateTime(St.wYear, St.wMonth, St.wDay, St.wHour, St.wMinute, St.wSecond, St.wMilliseconds);
    Result := SecondsBetween(TTimeZone.Local.ToUniversalTime(Now), Start);
  end;
end;

function CpuName: string;
begin
  Result := RegistryString(HKEY_LOCAL_MACHINE, 'HARDWARE\DESCRIPTION\System\CentralProcessor\0', 'ProcessorNameString');
  if Result = '' then
    Result := RegistryString(HKEY_LOCAL_MACHINE, 'HARDWARE\DESCRIPTION\System\CentralProcessor\0', 'Identifier');
end;

function PhysicalMemory: string;
var
  M: TMemoryStatusEx;
begin
  FillChar(M, SizeOf(M), 0);
  M.dwLength := SizeOf(M);
  if GlobalMemoryStatusEx(M) then
    Result := Format('%d/%d MB (free/total)', [M.ullAvailPhys div (1024 * 1024), M.ullTotalPhys div (1024 * 1024)])
  else
    Result := '';
end;

function FreeDiskSpace: string;
var
  Root: string;
  FreeB, TotalB, TotalFree: Int64;
begin
  Root := TPath.GetPathRoot(ParamStr(0));
  if GetDiskFreeSpaceEx(PChar(Root), FreeB, TotalB, @TotalFree) then
    Result := Format('(%s) %.2f GB', [Root.TrimRight(['\']), FreeB / (1024 * 1024 * 1024)])
  else
    Result := '';
end;

function DisplayMode: string;
var
  DC: HDC;
  Bits: Integer;
begin
  Bits := 0;
  DC := GetDC(0);
  if DC <> 0 then
  try
    Bits := GetDeviceCaps(DC, BITSPIXEL);
  finally
    ReleaseDC(0, DC);
  end;
  Result := Format('%dx%d, %d bit', [GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN), Bits]);
end;

function AllocatedMemory: string;
var
  St: TMemoryManagerState;
  Total: UInt64;
  I: Integer;
begin
{$WARN SYMBOL_PLATFORM OFF}
  GetMemoryManagerState(St);
{$WARN SYMBOL_PLATFORM ON}
  Total := 0;
  for I := 0 to High(St.SmallBlockTypeStates) do
    Inc(Total, UInt64(St.SmallBlockTypeStates[I].UseableBlockSize) * St.SmallBlockTypeStates[I].AllocatedBlockCount);
  Inc(Total, St.TotalAllocatedMediumBlockSize);
  Inc(Total, St.TotalAllocatedLargeBlockSize);
  Result := Format('%.2f MB', [Total / (1024 * 1024)]);
end;

function LargestFreeBlock: string;
var
  Si: TSystemInfo;
  Addr: NativeUInt;
  Mbi: TMemoryBasicInformation;
  Largest: NativeUInt;
begin
  GetSystemInfo(Si);
  Addr := NativeUInt(Si.lpMinimumApplicationAddress);
  Largest := 0;
  while (Addr < NativeUInt(Si.lpMaximumApplicationAddress)) and (VirtualQuery(Pointer(Addr), Mbi, SizeOf(Mbi)) = SizeOf(Mbi)) do
  begin
    if (Mbi.State = MEM_FREE) and (Mbi.RegionSize > Largest) then
      Largest := Mbi.RegionSize;
    if NativeUInt(Mbi.BaseAddress) + Mbi.RegionSize <= Addr then
      Break; // overflow guard
    Addr := NativeUInt(Mbi.BaseAddress) + Mbi.RegionSize;
  end;
  if Largest >= 1024 * 1024 * 1024 then
    Result := Format('%.2f GB', [Largest / (1024 * 1024 * 1024)])
  else
    Result := Format('%.2f MB', [Largest / (1024 * 1024)]);
end;

function FileVersion(const FileName: string): string;
var
  Size, Handle: DWORD;
  Buf: TBytes;
  P: Pointer;
  Len: Cardinal;
  Info: PVSFixedFileInfo;
begin
  Result := '';
  Size := GetFileVersionInfoSize(PChar(FileName), Handle);
  if Size = 0 then
    Exit;
  SetLength(Buf, Size);
  if GetFileVersionInfo(PChar(FileName), 0, Size, @Buf[0]) and VerQueryValue(@Buf[0], '\', P, Len) then
  begin
    Info := P;
    Result := Format('%d.%d.%d.%d', [HiWord(Info^.dwFileVersionMS), LoWord(Info^.dwFileVersionMS), HiWord(Info^.dwFileVersionLS),
      LoWord(Info^.dwFileVersionLS)]);
  end;
end;

function CompiledWith: string;
const
  V = CompilerVersion;
begin
  if V >= 37.0 then
    Result := 'Delphi 13'
  else if V >= 36.0 then
    Result := 'Delphi 12'
  else if V >= 35.0 then
    Result := 'Delphi 11'
  else if V >= 34.0 then
    Result := 'Delphi 10.4'
  else if V >= 33.0 then
    Result := 'Delphi 10.3'
  else if V >= 32.0 then
    Result := 'Delphi 10.2'
  else if V >= 31.0 then
    Result := 'Delphi 10.1'
  else if V >= 30.0 then
    Result := 'Delphi 10'
  else
    Result := Format('Delphi (compiler %.1f)', [V]);
{$IFDEF CPUX64}
  Result := Result + ' (Win64)';
{$ELSE}
  Result := Result + ' (Win32)';
{$ENDIF}
end;

function ModuleBaseNameOf(Address: Pointer): string;
var
  H: THandle;
begin
  H := GetModuleHandleFromAddress(Address);
  if H <> 0 then
    Result := GetModuleBaseName(H)
  else
    Result := '';
end;

{$ENDREGION}

function FormatFrame(Address: Pointer): string;
var
  Info: TAddressInfo;
  Module, UnitName, Loc, Sym: string;
begin
  Module := '';
  UnitName := '';
  Loc := '';
  Sym := '??';
  if GetAddressInfo(Address, Info) then
  begin
    if Assigned(Info.DebugSource) and Assigned(Info.DebugSource.Module) then
      Module := Info.DebugSource.Module.BaseName;
    UnitName := Info.UnitName;
    if Info.LineNumber > 0 then
      Loc := Format('%s:%d', [ExtractFileName(Info.SourceLocation), Info.LineNumber]);
    if Info.SymbolName <> '' then
      Sym := Format('%s+0x%x', [Info.SymbolName, NativeUInt(Address) - NativeUInt(Info.SymbolAddress)]);
  end;
  if Module = '' then
    Module := ModuleBaseNameOf(Address);
  Result := Format('$%.' + IntToStr(SizeOf(Pointer) * 2) + 'x  %-24s  %-28s  %-28s  %s', [NativeUInt(Address), Module, UnitName, Loc, Sym]);
end;

function ExceptionStackText(E: Exception): string;
var
  Addrs: TExceptionStackAddresses;
  SL: TStringList;
  A: Pointer;
begin
  Result := '';
  Addrs := GetExceptionStackAddresses(E);
  if Length(Addrs) = 0 then
    Exit;
  SL := TStringList.Create;
  try
    for A in Addrs do
      SL.Add(FormatFrame(A));
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

function StackCrcs(const Addrs: TExceptionStackAddresses): string;
var
  Offsets: TArray<NativeUInt>;
  I, N: Integer;
  H: THandle;
  function CrcOf(Count: Integer): string;
  begin
    if Count > Length(Offsets) then
      Count := Length(Offsets);
    if Count <= 0 then
      Exit('$00000000');
    Result := '$' + IntToHex(Crc32(Offsets[0], Count * SizeOf(NativeUInt)), 8).ToLower;
  end;

begin
  { Use module relative offsets so that the crc is stable across ASLR relocations. }
  SetLength(Offsets, Length(Addrs));
  N := 0;
  for I := 0 to High(Addrs) do
  begin
    H := GetModuleHandleFromAddress(Addrs[I]);
    if H = 0 then
      Continue; // skip unknown frames
    Offsets[N] := NativeUInt(Addrs[I]) - NativeUInt(H);
    Inc(N);
  end;
  SetLength(Offsets, N);
  { Full stack, first frame, first 3 frames (same idea as madExcept's three crcs). }
  Result := Format('%s, %s, %s', [CrcOf(N), CrcOf(1), CrcOf(3)]);
end;

{$REGION 'Sections'}

procedure AddHeader(SL: TStrings; const Title: string);
begin
  SL.Add('');
  SL.Add('---- ' + Title + ' ' + StringOfChar('-', 70 - Length(Title)));
end;

procedure HeaderToStrings(SL: TStrings; E: Exception; const Addrs: TExceptionStackAddresses; Number: Integer);
  procedure Line(const Key, Value: string);
  begin
    SL.Add(Format('%-19s: %s', [Key, Value]));
  end;

  function Safe(const F: TFunc<string>): string;
  begin
    try
      Result := F;
    except
      on Ex: Exception do
        Result := '(unavailable: ' + Ex.Message + ')';
    end;
  end;

begin
  Line('date/time', FormatDateTime('yyyy-mm-dd, hh:nn:ss, zzz"ms"', Now));
  Line('computer name', Safe(ComputerName));
  Line('user name', Safe(UserName));
  Line('registered owner', Safe(
    function: string
    begin
      Result := RegistryString(HKEY_LOCAL_MACHINE, 'SOFTWARE\Microsoft\Windows NT\CurrentVersion', 'RegisteredOwner');
    end));
  Line('operating system', Safe(OperatingSystem));
  Line('system language', Safe(SystemLanguage));
  Line('system up time', Safe(
    function: string
    begin
      Result := FormatDuration(GetTickCount64 div 1000);
    end));
  Line('program up time', Safe(
    function: string
    begin
      Result := FormatDuration(ProgramUpTimeSeconds);
    end));
  Line('processors', Safe(
    function: string
    begin
      Result := Format('%dx %s', [TThread.ProcessorCount, CpuName]).Trim;
    end));
  Line('physical memory', Safe(PhysicalMemory));
  Line('free disk space', Safe(FreeDiskSpace));
  Line('display mode', Safe(DisplayMode));
  Line('process id', '$' + IntToHex(GetCurrentProcessId, 1).ToLower);
  Line('thread id', '$' + IntToHex(GetCurrentThreadId, 1).ToLower + IfThenStr(MainThreadID = GetCurrentThreadId, ' (main)', ''));
  Line('allocated memory', Safe(AllocatedMemory));
  Line('largest free block', Safe(LargestFreeBlock));
  Line('executable', ExtractFileName(ParamStr(0)));
  Line('exec. date/time', Safe(
    function: string
    begin
      Result := FormatDateTime('yyyy-mm-dd hh:nn', TFile.GetLastWriteTime(ParamStr(0)));
    end));
  Line('version', Safe(
    function: string
    begin
      Result := FileVersion(ParamStr(0));
    end));
  Line('compiled with', CompiledWith);
  Line('DebugEngine version', DebugEngineVersion);
  if Length(Addrs) > 0 then
    Line('callstack crc', StackCrcs(Addrs));
  Line('exception number', IntToStr(Number));
  if Assigned(E) then
  begin
    Line('exception class', E.ClassName);
    Line('exception message', E.Message.Replace(#13#10, ' ').Replace(#10, ' '));
  end;
end;

procedure ExceptionToStrings(SL: TStrings; E: Exception; const Addrs: TExceptionStackAddresses);
var
  Inner: Exception;
  I: Integer;
  A: Pointer;
begin
  if Assigned(E) then
  begin
    SL.Add(Format('  Class         : %s', [E.ClassName]));
    SL.Add(Format('  Message       : %s', [E.Message]));
    if Length(Addrs) > 0 then
      SL.Add(Format('  Address       : %s', [FormatFrame(Addrs[0]).Replace('  ', ' ')]))
    else if ExceptAddr() <> nil then
      SL.Add(Format('  Address       : %s', [FormatFrame(ExceptAddr()).Replace('  ', ' ')]));
    Inner := E.InnerException;
    I := 0;
    while Assigned(Inner) and (I < 10) do
    begin
      SL.Add(Format('  Inner[%d]      : %s: %s', [I, Inner.ClassName, Inner.Message]));
      Inner := Inner.InnerException;
      Inc(I);
    end;
  end;
  if Length(Addrs) > 0 then
  begin
    SL.Add('  Stack at raise (Exception.StackTrace):');
    for A in Addrs do
      SL.Add('    ' + FormatFrame(A));
  end
  else
    SL.Add('  Stack at raise : (not available - is DebugEngine.HookException in the uses clause?)');
  SL.Add(Format('  Thread        : tid=%d  main thread=%s', [GetCurrentThreadId, BoolToStr(MainThreadID = GetCurrentThreadId, True)]));
end;

procedure ThreadsToStrings(SL: TStrings);
var
  Snap: THandle;
  Te: TThreadEntry32;
  Pid, Cur: DWORD;
  Count: Integer;
  Lines: TStringList;
begin
  Pid := GetCurrentProcessId;
  Cur := GetCurrentThreadId;
  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  if Snap = INVALID_HANDLE_VALUE then
  begin
    SL.Add('  (unavailable)');
    Exit;
  end;
  Lines := TStringList.Create;
  try
    Count := 0;
    Te.dwSize := SizeOf(Te);
    if Thread32First(Snap, Te) then
      repeat
        if Te.th32OwnerProcessID = Pid then
        begin
          Inc(Count);
          Lines.Add(Format('  TID %-7d ($%-6s) priority=%d%s', [Te.th32ThreadID, IntToHex(Te.th32ThreadID, 1).ToLower, Te.tpBasePri,
            IfThenStr(Te.th32ThreadID = Cur, '  <== current (log written from here)', IfThenStr(Te.th32ThreadID = MainThreadID, '  (main)', ''))]));
        end;
        Te.dwSize := SizeOf(Te);
      until not Thread32Next(Snap, Te);
    SL.Add(Format('  %d thread(s):', [Count]));
    SL.AddStrings(Lines);
    SL.Add('  Note: the stack trace in this log belongs to the current thread only.');
  finally
    Lines.Free;
    CloseHandle(Snap);
  end;
end;

procedure ModulesToStrings(SL: TStrings);
var
  Mods: array [0 .. 1023] of HMODULE;
  Needed: DWORD;
  I, N: Integer;
  Mi: TModuleInfo;
  Path, Ver: string;
  Buf: array [0 .. MAX_PATH] of Char;
begin
  if not EnumProcessModules(GetCurrentProcess, @Mods[0], SizeOf(Mods), Needed) then
  begin
    SL.Add('  (unavailable)');
    Exit;
  end;
  N := Needed div SizeOf(HMODULE);
  if N > Length(Mods) then
    N := Length(Mods);
  SL.Add(Format('  %d module(s):', [N]));
  for I := 0 to N - 1 do
  begin
    FillChar(Mi, SizeOf(Mi), 0);
    GetModuleInformation(GetCurrentProcess, Mods[I], @Mi, SizeOf(Mi));
    if GetModuleFileNameEx(GetCurrentProcess, Mods[I], Buf, Length(Buf)) > 0 then
      Path := string(Buf)
    else
      Path := '?';
    Ver := FileVersion(Path);
    SL.Add(Format('  %.' + IntToStr(SizeOf(Pointer) * 2) + 'x-%.' + IntToStr(SizeOf(Pointer) * 2) + 'x  %-14s %s%s', [NativeUInt(Mi.lpBaseOfDll),
      NativeUInt(Mi.lpBaseOfDll) + Mi.SizeOfImage, Ver, Path, IfThenStr(I = 0, '  (main)', '')]));
  end;
end;

procedure RegistersToStrings(SL: TStrings);
var
  R: TLegacyRegisters;
begin
  FillChar(R, SizeOf(R), 0);
  if not SnapshotOfLegacyRegisters(R) then
  begin
    SL.Add('  (unavailable)');
    Exit;
  end;
{$IFDEF CPUX64}
  SL.Add(Format('  RAX=%.16x  RBX=%.16x  RCX=%.16x  RDX=%.16x', [R.RAX.AsRAX, R.RBX.AsRBX, R.RCX.AsRCX, R.RDX.AsRDX]));
  SL.Add(Format('  RSI=%.16x  RDI=%.16x  RBP=%.16x  RSP=%.16x', [R.RSI.AsRSI, R.RDI.AsRDI, R.RBP.AsRBP, R.RSP.AsRSP]));
  SL.Add(Format('  R8 =%.16x  R9 =%.16x  R10=%.16x  R11=%.16x', [R.R8.AsR8, R.R9.AsR9, R.R10.AsR10, R.R11.AsR11]));
  SL.Add(Format('  R12=%.16x  R13=%.16x  R14=%.16x  R15=%.16x', [R.R12.AsR12, R.R13.AsR13, R.R14.AsR14, R.R15.AsR15]));
{$ELSE}
  SL.Add(Format('  EAX=%.8x  EBX=%.8x  ECX=%.8x  EDX=%.8x', [R.EAX.AsEAX, R.EBX.AsEBX, R.ECX.AsECX, R.EDX.AsEDX]));
  SL.Add(Format('  ESI=%.8x  EDI=%.8x  EBP=%.8x  ESP=%.8x', [R.ESI.AsESI, R.EDI.AsEDI, R.EBP.AsEBP, R.ESP.AsESP]));
{$ENDIF}
  SL.Add(Format('  EFLAGS=%.8x  MXCSR=%.8x', [NativeUInt(SnapshotOfRFlagsRegister), Cardinal(SnapshotOfMXCSRRegister)]));
  SL.Add('  (snapshot taken while building the report, not at the exception)');
end;

procedure EnvironmentToStrings(SL: TStrings);
var
  P, Start: PChar;
  Env: TStringList;
  I: Integer;
begin
  Env := TStringList.Create;
  try
    P := GetEnvironmentStrings;
    if Assigned(P) then
    try
      Start := P;
      while P^ <> #0 do
      begin
        if P^ <> '=' then // skip the hidden "=C:=..." entries
          Env.Add(string(P));
        Inc(P, StrLen(P) + 1);
      end;
      P := Start;
    finally
      FreeEnvironmentStrings(P);
    end;
    Env.Sort;
    for I := 0 to Env.Count - 1 do
      SL.Add('  ' + Env[I]);
  finally
    Env.Free;
  end;
end;

{$ENDREGION}

function BuildCrashReport(E: Exception; Sections: TCrashReportSections): string;
var
  SL: TStringList;
  Addrs: TExceptionStackAddresses;
  Number: Integer;
begin
  Number := AtomicIncrement(GReportCount);
  Addrs := GetExceptionStackAddresses(E);
  SL := TStringList.Create;
  try
    if crsHeader in Sections then
      HeaderToStrings(SL, E, Addrs, Number);
    if crsException in Sections then
    begin
      AddHeader(SL, 'Exception');
      ExceptionToStrings(SL, E, Addrs);
    end;
    if crsRegisters in Sections then
    begin
      AddHeader(SL, 'Registers');
      try
        RegistersToStrings(SL);
      except
        on Ex: Exception do
          SL.Add('  (failed: ' + Ex.Message + ')');
      end;
    end;
    if crsThreads in Sections then
    begin
      AddHeader(SL, 'Threads');
      try
        ThreadsToStrings(SL);
      except
        on Ex: Exception do
          SL.Add('  (failed: ' + Ex.Message + ')');
      end;
    end;
    if crsModules in Sections then
    begin
      AddHeader(SL, 'Modules');
      try
        ModulesToStrings(SL);
      except
        on Ex: Exception do
          SL.Add('  (failed: ' + Ex.Message + ')');
      end;
    end;
    if crsEnvironment in Sections then
    begin
      AddHeader(SL, 'Environment');
      try
        EnvironmentToStrings(SL);
      except
        on Ex: Exception do
          SL.Add('  (failed: ' + Ex.Message + ')');
      end;
    end;
    SL.Add('');
    SL.Add(StringOfChar('=', 76));
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

function WriteCrashLog(E: Exception; const FileName: string; Sections: TCrashReportSections): string;
begin
  Result := BuildCrashReport(E, Sections);
  try
    TFile.AppendAllText(FileName, Result + sLineBreak, TEncoding.UTF8);
  except
    // The report is still returned to the caller.
  end;
end;

end.
