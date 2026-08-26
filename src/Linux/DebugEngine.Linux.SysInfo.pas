// **************************************************************************************************
// Delphi DebugEngine.
// Unit DebugEngine.Linux.SysInfo
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
/// System / process / thread / module / environment information collectors for crash logs (Linux).
/// Everything is read from libc calls and the /proc file system; nothing here can raise.
/// </summary>
unit DebugEngine.Linux.SysInfo;

{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  System.SysUtils,
  System.Classes;

/// <summary> Kernel, distribution, CPU, memory, uptime, load average, page size, CPU count, locale. </summary>
procedure SystemInfoToStrings(SL: TStrings);

/// <summary> PID/PPID/TID, user, executable, cwd, command line, start time, memory (VmRSS...), state, limits. </summary>
procedure ProcessInfoToStrings(SL: TStrings);

/// <summary> All threads of the process from /proc/self/task (tid, name, state, CPU time, current marker). </summary>
procedure ThreadsToStrings(SL: TStrings);

/// <summary> Loaded modules (dl_iterate_phdr) with load bias, address range and symbol sources. </summary>
procedure ModulesToStrings(SL: TStrings);

/// <summary> /proc/self/maps (memory map). </summary>
procedure MemoryMapToStrings(SL: TStrings);

/// <summary> Environment variables (sorted). </summary>
procedure EnvironmentToStrings(SL: TStrings);

/// <summary> Read a whole /proc (or any) text file; '' on failure. </summary>
function ReadTextFile(const FileName: string): string;

/// <summary> Value of "Key:" in a /proc status-like file. </summary>
function ProcStatusValue(const Content, Key: string): string;

/// <summary> Current thread id (gettid). </summary>
function CurrentThreadId: Integer;

implementation

uses
  System.IOUtils,
  System.DateUtils,
  System.StrUtils,
  System.Generics.Collections,
  Posix.Unistd,
  Posix.SysUtsname,
  Posix.Pwd,
  Posix.Time,
  DebugEngine.Linux.Posix,
  DebugEngine.Linux.Modules;

function ReadTextFile(const FileName: string): string;
var
  FS: TFileStream;
  Buf: TBytes;
  N, Total: Integer;
begin
  Result := '';
  try
    FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Buf, 16384);
      Total := 0;
      repeat
        if Total = Length(Buf) then
          SetLength(Buf, Length(Buf) * 2);
        N := FS.Read(Buf[Total], Length(Buf) - Total);
        if N > 0 then
          Inc(Total, N);
      until N <= 0;
      Result := TEncoding.UTF8.GetString(Buf, 0, Total);
    finally
      FS.Free;
    end;
  except
    Result := '';
  end;
end;

function ProcStatusValue(const Content, Key: string): string;
var
  L: string;
begin
  for L in Content.Split([#10]) do
    if L.StartsWith(Key + ':') then
      Exit(L.Substring(Key.Length + 1).Trim.Replace(#9, ' '));
  Result := '';
end;

function CurrentThreadId: Integer;
begin
  Result := gettid;
end;

function OsRelease: string;
var
  L: string;
begin
  Result := '';
  for L in ReadTextFile('/etc/os-release').Split([#10]) do
    if L.StartsWith('PRETTY_NAME=') then
      Exit(L.Substring(12).Trim(['"']));
end;

function CpuModel: string;
var
  L: string;
begin
  Result := '';
  for L in ReadTextFile('/proc/cpuinfo').Split([#10]) do
    if L.StartsWith('model name') then
      Exit(L.Substring(L.IndexOf(':') + 1).Trim);
end;

function Utf8Field(const A: array of UTF8Char): string;
begin
  Result := string(UTF8String(MarshaledAString(@A[0])));
end;

function FormatKB(const V: string): string;
var
  N: Int64;
begin
  { '123456 kB' => '123456 kB (120.6 MB)' }
  Result := V;
  if TryStrToInt64(V.Replace('kB', '').Trim, N) then
    Result := Format('%s (%.1f MB)', [V, N / 1024]);
end;

procedure SystemInfoToStrings(SL: TStrings);
var
  U: utsname;
  S, MemInfo: string;
  Up: Double;
begin
  if uname(U) = 0 then
  begin
    SL.Add(Format('  Kernel        : %s %s %s', [Utf8Field(U.sysname), Utf8Field(U.release), Utf8Field(U.machine)]));
    SL.Add(Format('  Version       : %s', [Utf8Field(U.version)]));
    SL.Add(Format('  Host name     : %s', [Utf8Field(U.nodename)]));
  end;
  S := OsRelease;
  if S <> '' then
    SL.Add('  Distribution  : ' + S);
  S := CpuModel;
  if S <> '' then
    SL.Add('  CPU           : ' + S);
  SL.Add(Format('  CPUs online   : %d', [get_nprocs]));
  SL.Add(Format('  Page size     : %d', [getpagesize]));
  MemInfo := ReadTextFile('/proc/meminfo');
  if MemInfo <> '' then
  begin
    SL.Add('  MemTotal      : ' + FormatKB(ProcStatusValue(MemInfo, 'MemTotal')));
    SL.Add('  MemAvailable  : ' + FormatKB(ProcStatusValue(MemInfo, 'MemAvailable')));
    SL.Add('  SwapFree      : ' + FormatKB(ProcStatusValue(MemInfo, 'SwapFree')));
  end;
  S := ReadTextFile('/proc/uptime').Trim;
  if (S <> '') and TryStrToFloat(S.Split([' '])[0], Up, TFormatSettings.Invariant) then
    SL.Add(Format('  Uptime        : %.0f s (%.1f h)', [Up, Up / 3600]));
  S := ReadTextFile('/proc/loadavg').Trim;
  if S <> '' then
    SL.Add('  Load average  : ' + S);
  SL.Add(Format('  Local time    : %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)]));
  SL.Add(Format('  UTC time      : %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss', TTimeZone.Local.ToUniversalTime(Now))]));
  SL.Add(Format('  Compiler      : Delphi %.1f (%d bit)', [CompilerVersion, SizeOf(Pointer) * 8]));
  SL.Add(Format('  Locale        : LANG=%s LC_ALL=%s', [GetEnvironmentVariable('LANG'), GetEnvironmentVariable('LC_ALL')]));
end;

function RLimitToStr(Res: Integer): string;
var
  R: rlimit;
  function V(X: UInt64): string;
  begin
    if X = RLIM_INFINITY then
      Result := 'unlimited'
    else
      Result := UIntToStr(X);
  end;

begin
  if getrlimit(Res, R) = 0 then
    Result := Format('cur=%s max=%s', [V(R.rlim_cur), V(R.rlim_max)])
  else
    Result := '?';
end;

procedure ProcessInfoToStrings(SL: TStrings);
var
  Status, Cmd, S: string;
  Pw: Ppasswd;
  I: Integer;
begin
  SL.Add(Format('  PID / PPID    : %d / %d', [getpid, getppid]));
  SL.Add(Format('  Current TID   : %d', [gettid]));
  Pw := getpwuid(geteuid);
  if Assigned(Pw) then
    SL.Add(Format('  User          : %s (uid=%d gid=%d)', [string(UTF8String(Pw^.pw_name)), geteuid, getegid]))
  else
    SL.Add(Format('  User          : uid=%d gid=%d', [geteuid, getegid]));
  SL.Add('  Executable    : ' + GetExecutablePath);
  SL.Add('  Working dir   : ' + GetCurrentDir);
  Cmd := ReadTextFile('/proc/self/cmdline');
  if Cmd <> '' then
  begin
    S := '';
    for I := 1 to Length(Cmd) do
      if Cmd[I] = #0 then
        S := S + ' '
      else
        S := S + Cmd[I];
    SL.Add('  Command line  : ' + S.Trim);
  end
  else
  begin
    S := '';
    for I := 0 to ParamCount do
      S := S + ParamStr(I) + ' ';
    SL.Add('  Command line  : ' + S.Trim);
  end;
  Status := ReadTextFile('/proc/self/status');
  if Status <> '' then
  begin
    SL.Add('  State         : ' + ProcStatusValue(Status, 'State'));
    SL.Add('  Threads       : ' + ProcStatusValue(Status, 'Threads'));
    SL.Add('  VmPeak        : ' + FormatKB(ProcStatusValue(Status, 'VmPeak')));
    SL.Add('  VmSize        : ' + FormatKB(ProcStatusValue(Status, 'VmSize')));
    SL.Add('  VmHWM         : ' + FormatKB(ProcStatusValue(Status, 'VmHWM')));
    SL.Add('  VmRSS         : ' + FormatKB(ProcStatusValue(Status, 'VmRSS')));
    SL.Add('  VmData        : ' + FormatKB(ProcStatusValue(Status, 'VmData')));
    SL.Add('  VmStk         : ' + FormatKB(ProcStatusValue(Status, 'VmStk')));
    SL.Add('  VmSwap        : ' + FormatKB(ProcStatusValue(Status, 'VmSwap')));
    SL.Add('  FDSize        : ' + ProcStatusValue(Status, 'FDSize'));
    SL.Add('  voluntary_ctxt_switches    : ' + ProcStatusValue(Status, 'voluntary_ctxt_switches'));
    SL.Add('  nonvoluntary_ctxt_switches : ' + ProcStatusValue(Status, 'nonvoluntary_ctxt_switches'));
  end;
  SL.Add('  RLIMIT_STACK  : ' + RLimitToStr(RLIMIT_STACK));
  SL.Add('  RLIMIT_CORE   : ' + RLimitToStr(RLIMIT_CORE));
  SL.Add('  RLIMIT_NOFILE : ' + RLimitToStr(RLIMIT_NOFILE));
  SL.Add('  RLIMIT_AS     : ' + RLimitToStr(RLIMIT_AS));
  SL.Add('  RLIMIT_DATA   : ' + RLimitToStr(RLIMIT_DATA));
  SL.Add(Format('  IsConsole     : %s  IsLibrary: %s', [BoolToStr(IsConsole, True), BoolToStr(IsLibrary, True)]));
end;

procedure ThreadsToStrings(SL: TStrings);
var
  Dirs: TArray<string>;
  D, Stat, Comm, State, Name: string;
  Tid, Cur: Integer;
  Fields: TArray<string>;
  P1, P2: Integer;
  UTime, STime: Int64;
  Ticks: Int64;
  List: TList<Integer>;
begin
  Cur := gettid;
  try
    Dirs := TDirectory.GetDirectories('/proc/self/task');
  except
    SL.Add('  (cannot read /proc/self/task)');
    Exit;
  end;
  Ticks := sysconf(2); // _SC_CLK_TCK
  if Ticks <= 0 then
    Ticks := 100;
  List := TList<Integer>.Create;
  try
    for D in Dirs do
      if TryStrToInt(ExtractFileName(D), Tid) then
        List.Add(Tid);
    List.Sort;
    SL.Add(Format('  %d thread(s):', [List.Count]));
    for Tid in List do
    begin
      D := '/proc/self/task/' + IntToStr(Tid);
      Comm := ReadTextFile(D + '/comm').Trim;
      Stat := ReadTextFile(D + '/stat');
      State := '?';
      UTime := 0;
      STime := 0;
      { stat: pid (comm) state ppid ... ; comm may contain spaces/parentheses => split after last ')' }
      P1 := Stat.IndexOf('(');
      P2 := Stat.LastIndexOf(')');
      if (P1 >= 0) and (P2 > P1) then
      begin
        Name := Stat.Substring(P1 + 1, P2 - P1 - 1);
        Fields := Stat.Substring(P2 + 2).Split([' ']);
        if Length(Fields) > 12 then
        begin
          State := Fields[0];
          UTime := StrToInt64Def(Fields[11], 0);
          STime := StrToInt64Def(Fields[12], 0);
        end;
      end
      else
        Name := Comm;
      SL.Add(Format('  TID %-7d %-16s state=%s utime=%.2fs stime=%.2fs%s', [Tid, Name, State, UTime / Ticks, STime / Ticks,
        IfThen(Tid = Cur, '  <== current (log written from here)', '')]));
    end;
  finally
    List.Free;
  end;
  SL.Add('  Note: the stack trace in this log belongs to the current thread only.');
end;

procedure ModulesToStrings(SL: TStrings);
var
  I: Integer;
  M: TLinuxModule;
  Src: string;
begin
  GlobalModules.Refresh;
  SL.Add(Format('  %d module(s):', [GlobalModules.Count]));
  for I := 0 to GlobalModules.Count - 1 do
  begin
    M := GlobalModules[I];
    if not FileExists(M.Path) then
      Src := 'virtual (no file)'
    else if M.Symbols.Loaded then
      Src := Format('symtab=%s(%d) dwarf=%s%s', [BoolToStr(M.Symbols.HasSymtab, True), M.Symbols.Symbols.Count, BoolToStr(M.Symbols.HasDebugLine, True),
        IfThen(M.Symbols.IsPIE, ' pie', '')])
    else
      Src := 'symbols: ' + M.Symbols.LoadError;
    SL.Add(Format('  %.16x-%.16x bias=%.x %s  [%s]%s', [M.StartAddress, M.EndAddress, M.LoadBias, M.Path, Src, IfThen(M.IsMainProgram, ' (main)', '')]));
  end;
end;

procedure MemoryMapToStrings(SL: TStrings);
var
  L: string;
begin
  for L in ReadProcSelfMaps.Split([#10]) do
    if L.Trim <> '' then
      SL.Add('  ' + L);
end;

procedure EnvironmentToStrings(SL: TStrings);
var
  Env: TStringList;
  I: Integer;
  S: string;
begin
  Env := TStringList.Create;
  try
    { /proc/self/environ is NUL separated. }
    for S in ReadTextFile('/proc/self/environ').Split([#0]) do
      if S <> '' then
        Env.Add(S);
    Env.Sort;
    for I := 0 to Env.Count - 1 do
      SL.Add('  ' + Env[I]);
  finally
    Env.Free;
  end;
end;

end.
