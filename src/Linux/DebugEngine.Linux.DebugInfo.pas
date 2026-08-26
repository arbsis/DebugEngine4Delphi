// **************************************************************************************************
// Delphi DebugEngine.
// Unit DebugEngine.Linux.DebugInfo
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
/// Address => symbol / unit / source line resolution for Linux.
/// Sources, combined from richest to poorest:
///   1. DWARF line info through the external 'addr2line' tool (binutils), when available and the
///      module was linked with debug information (-V). Gives file:line and inlined frames.
///   2. ELF symbol table (.symtab / .dynsym) read by DebugEngine.Linux.Elf. Gives symbol + offset.
///   3. dladdr (dynamic symbols only).
/// </summary>
unit DebugEngine.Linux.DebugInfo;

{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.SyncObjs,
  DebugEngine.Linux.Posix,
  DebugEngine.Linux.Elf,
  DebugEngine.Linux.Modules;

type
  TLinuxSymbolSource = (ssNone, ssElfSymtab, ssDladdr, ssAddr2Line);
  TLinuxSymbolSources = set of TLinuxSymbolSource;

  TLinuxAddressInfo = record
    Address: Pointer;
    Module: TLinuxModule; // nil if unknown.
    ModulePath: string;
    ModuleBaseName: string;
    LinkTimeAddress: UInt64; // Address - load bias (what addr2line / readelf show).
    SymbolAddress: Pointer;
    SymbolName: string; // Demangled.
    RawSymbolName: string; // Mangled.
    SymbolOffset: UInt64; // Address - SymbolAddress.
    UnitName: string;
    SourceFile: string;
    LineNumber: Cardinal;
    Inlined: TArray<string>; // Extra "function at file:line" entries from addr2line -i.
    Sources: TLinuxSymbolSources;
    function HasSymbol: Boolean;
    function HasLine: Boolean;
    /// <summary> 'Unit.Func+0x12 (file.pas:123)' style short description. </summary>
    function ToString: string;
  end;

  TLinuxAddressInfoMask = (laimFull, laimSymbolOnly);

  /// <summary> Options controlling how addresses are resolved. </summary>
  TLinuxDebugInfoOptions = record
    UseAddr2Line: Boolean; // Default True (auto-disabled when the tool is not found).
    Addr2LinePath: string; // Empty => search PATH.
    Addr2LineTimeoutMs: Integer; // Reserved.
  end;

var
  LinuxDebugInfoOptions: TLinuxDebugInfoOptions = (UseAddr2Line: True; Addr2LinePath: ''; Addr2LineTimeoutMs: 5000);

/// <summary> Resolve one address. </summary>
function GetAddressInfo(Address: Pointer; out Info: TLinuxAddressInfo; Mask: TLinuxAddressInfoMask = laimFull): Boolean;

/// <summary> Resolve many addresses at once: addr2line is invoked once per module for all of them. </summary>
function GetAddressInfoList(const Addresses: TArray<Pointer>; Mask: TLinuxAddressInfoMask = laimFull): TArray<TLinuxAddressInfo>;

/// <summary> Find the run time address of a symbol by (demangled or mangled) name in the main program. </summary>
function GetSymbolAddress(const SymbolName: string): Pointer;

/// <summary> Path of the addr2line tool or '' when not available. </summary>
function Addr2LinePath: string;

/// <summary> Human readable description of the available symbol sources for the main program. </summary>
function DescribeDebugInfoSources: string;

implementation

uses
  System.StrUtils,
  Posix.Dlfcn;

type
  TAddr2LineResult = record
    Func: string;
    Location: string; // file:line
    Inlined: TArray<string>;
  end;

var
  GAddr2LinePath: string = '';
  GAddr2LineChecked: Boolean = False;
  GCacheLock: TCriticalSection = nil;
  GAddr2LineCache: TDictionary<string, TAddr2LineResult> = nil; // key: path|linkaddr

{ TLinuxAddressInfo }

function TLinuxAddressInfo.HasSymbol: Boolean;
begin
  Result := SymbolName <> '';
end;

function TLinuxAddressInfo.HasLine: Boolean;
begin
  Result := LineNumber > 0;
end;

function TLinuxAddressInfo.ToString: string;
begin
  if HasSymbol then
    Result := Format('%s+0x%x', [SymbolName, SymbolOffset])
  else
    Result := Format('0x%x', [LinkTimeAddress]);
  if HasLine then
    Result := Result + Format(' (%s:%d)', [SourceFile, LineNumber]);
  if ModuleBaseName <> '' then
    Result := Result + ' [' + ModuleBaseName + ']';
end;

{$REGION 'addr2line'}

function FindInPath(const Exe: string): string;
var
  PathEnv: string;
  Dir: string;
begin
  PathEnv := GetEnvironmentVariable('PATH');
  for Dir in PathEnv.Split([':']) do
    if (Dir <> '') and FileExists(IncludeTrailingPathDelimiter(Dir) + Exe) then
      Exit(IncludeTrailingPathDelimiter(Dir) + Exe);
  Result := '';
end;

function Addr2LinePath: string;
begin
  if not GAddr2LineChecked then
  begin
    if (LinuxDebugInfoOptions.Addr2LinePath <> '') and FileExists(LinuxDebugInfoOptions.Addr2LinePath) then
      GAddr2LinePath := LinuxDebugInfoOptions.Addr2LinePath
    else
    begin
      GAddr2LinePath := FindInPath('addr2line');
      if (GAddr2LinePath = '') and FileExists('/usr/bin/addr2line') then
        GAddr2LinePath := '/usr/bin/addr2line';
    end;
    GAddr2LineChecked := True;
  end;
  Result := GAddr2LinePath;
end;

function RunCommand(const Cmd: string): TStringList;
var
  F: PFILE;
  Buf: array [0 .. 4095] of Byte;
  Line: UTF8String;
  U: UTF8String;
begin
  Result := TStringList.Create;
  U := UTF8String(Cmd);
  F := popen(MarshaledAString(U), 'r');
  if F = nil then
    Exit;
  try
    while fgets(@Buf[0], SizeOf(Buf), F) <> nil do
    begin
      Line := UTF8String(MarshaledAString(@Buf[0]));
      Result.Add(string(Line).TrimRight([#10, #13]));
    end;
  finally
    pclose(F);
  end;
end;

function ShellQuote(const S: string): string;
begin
  Result := '''' + S.Replace('''', '''\''''') + '''';
end;

/// Cleans addr2line function names: 'Hello::Foo()' => 'Hello.Foo'; 'System::Sysutils::Format(...)' => 'System.Sysutils.Format'.
function CleanAddr2LineFunc(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  I := Result.IndexOf('(');
  if I > 0 then
    Result := Result.Substring(0, I);
  Result := Result.Replace('::', '.').Trim;
end;

/// Run addr2line for a set of link-time addresses of one module and fill the cache.
procedure Addr2LineBatch(const ModulePath: string; const LinkAddresses: TArray<UInt64>);
var
  Cmd: string;
  A: UInt64;
  Lines: TStringList;
  I, N: Integer;
  Pending: TList<UInt64>;
  R: TAddr2LineResult;
  Key, L, Func, Loc: string;
  P: Integer;
begin
  Pending := TList<UInt64>.Create;
  try
    GCacheLock.Enter;
    try
      for A in LinkAddresses do
        if not GAddr2LineCache.ContainsKey(ModulePath + '|' + IntToHex(A, 1)) and not Pending.Contains(A) then
          Pending.Add(A);
    finally
      GCacheLock.Leave;
    end;
    if Pending.Count = 0 then
      Exit;
    { -f function names, -C demangle, -i inlined frames, -p pretty ("func at file:line"), -a print address }
    Cmd := ShellQuote(Addr2LinePath) + ' -e ' + ShellQuote(ModulePath) + ' -f -C -i -p -a';
    for A in Pending do
      Cmd := Cmd + ' 0x' + IntToHex(A, 1);
    Cmd := Cmd + ' 2>/dev/null';
    Lines := RunCommand(Cmd);
    try
      { Output with -a -p -i:
          0x0000000000473b2c: Hello::Foo() at ./hello.dpr:8
           (inlined by) Hello::Bar() at ./hello.dpr:20
        One block per requested address, in order. }
      N := -1;
      R.Func := '';
      R.Location := '';
      R.Inlined := nil;
      for I := 0 to Lines.Count - 1 do
      begin
        L := Lines[I];
        if L.StartsWith('0x') then
        begin
          if N >= 0 then
          begin
            GCacheLock.Enter;
            try
              GAddr2LineCache.AddOrSetValue(ModulePath + '|' + IntToHex(Pending[N], 1), R);
            finally
              GCacheLock.Leave;
            end;
          end;
          Inc(N);
          R.Func := '';
          R.Location := '';
          R.Inlined := nil;
          P := L.IndexOf(':');
          if P > 0 then
            L := L.Substring(P + 1).Trim
          else
            L := '';
          if L <> '' then
          begin
            P := L.LastIndexOf(' at ');
            if P > 0 then
            begin
              Func := L.Substring(0, P);
              Loc := L.Substring(P + 4).Trim;
            end
            else
            begin
              Func := L;
              Loc := '';
            end;
            if Func <> '??' then
              R.Func := CleanAddr2LineFunc(Func);
            if (Loc <> '') and not Loc.StartsWith('??') then
              R.Location := Loc;
          end;
        end
        else if L.Trim.StartsWith('(inlined by)') and (N >= 0) then
          R.Inlined := R.Inlined + [L.Trim.Substring(Length('(inlined by)')).Trim.Replace('::', '.')];
      end;
      if N >= 0 then
      begin
        GCacheLock.Enter;
        try
          GAddr2LineCache.AddOrSetValue(ModulePath + '|' + IntToHex(Pending[N], 1), R);
        finally
          GCacheLock.Leave;
        end;
      end;
      { Addresses the tool did not answer for: cache an empty result to avoid retrying. }
      GCacheLock.Enter;
      try
        for A in Pending do
        begin
          Key := ModulePath + '|' + IntToHex(A, 1);
          if not GAddr2LineCache.ContainsKey(Key) then
          begin
            R.Func := '';
            R.Location := '';
            R.Inlined := nil;
            GAddr2LineCache.Add(Key, R);
          end;
        end;
      finally
        GCacheLock.Leave;
      end;
    finally
      Lines.Free;
    end;
  finally
    Pending.Free;
  end;
end;

function Addr2LineLookup(const ModulePath: string; LinkAddress: UInt64; out R: TAddr2LineResult): Boolean;
begin
  GCacheLock.Enter;
  try
    Result := GAddr2LineCache.TryGetValue(ModulePath + '|' + IntToHex(LinkAddress, 1), R);
  finally
    GCacheLock.Leave;
  end;
end;

{$ENDREGION}

procedure ResolveCore(var Info: TLinuxAddressInfo; Mask: TLinuxAddressInfoMask);
var
  Sym: TElfSymbol;
  DlInfo: dl_info;
  R: TAddr2LineResult;
  Loc: string;
  P: Integer;
begin
  Info.Module := GlobalModules.ModuleFromAddress(Info.Address);
  if Assigned(Info.Module) then
  begin
    Info.ModulePath := Info.Module.Path;
    Info.ModuleBaseName := Info.Module.BaseName;
    Info.LinkTimeAddress := Info.Module.ToLinkTimeAddress(Info.Address);
    { 1. ELF symbol table }
    if Info.Module.Symbols.Loaded and Info.Module.Symbols.FindSymbol(Info.LinkTimeAddress, Sym) then
    begin
      Info.RawSymbolName := Sym.Name;
      Info.SymbolName := Sym.DemangledName;
      Info.SymbolAddress := Info.Module.ToRunTimeAddress(Sym.Address);
      Info.SymbolOffset := Info.LinkTimeAddress - Sym.Address;
      Info.UnitName := UnitNameOfDemangled(Info.SymbolName);
      Include(Info.Sources, ssElfSymtab);
    end;
  end
  else
    Info.LinkTimeAddress := UInt64(Info.Address);

  { 2. dladdr (fills gaps: module name and dynamic symbols) }
  FillChar(DlInfo, SizeOf(DlInfo), 0);
  if dladdr(NativeUInt(Info.Address), DlInfo) <> 0 then
  begin
    if (Info.ModulePath = '') and (DlInfo.dli_fname <> nil) then
    begin
      Info.ModulePath := string(UTF8String(DlInfo.dli_fname));
      Info.ModuleBaseName := ExtractFileName(Info.ModulePath);
      Info.LinkTimeAddress := UInt64(UIntPtr(Info.Address) - UIntPtr(DlInfo.dli_fbase));
      Include(Info.Sources, ssDladdr);
    end;
    if (Info.SymbolName = '') and (DlInfo.dli_sname <> nil) then
    begin
      Info.RawSymbolName := string(UTF8String(DlInfo.dli_sname));
      Info.SymbolName := DemangleName(Info.RawSymbolName);
      Info.SymbolAddress := DlInfo.dli_saddr;
      Info.SymbolOffset := UIntPtr(Info.Address) - UIntPtr(DlInfo.dli_saddr);
      Info.UnitName := UnitNameOfDemangled(Info.SymbolName);
      Include(Info.Sources, ssDladdr);
    end;
  end;

  { 3. addr2line (already batched by the caller => cache lookup) }
  if (Mask = laimFull) and (Info.ModulePath <> '') and Addr2LineLookup(Info.ModulePath, Info.LinkTimeAddress, R) then
  begin
    if R.Func <> '' then
    begin
      if Info.SymbolName = '' then
      begin
        Info.SymbolName := R.Func;
        Info.UnitName := UnitNameOfDemangled(R.Func);
      end;
      Include(Info.Sources, ssAddr2Line);
    end;
    if R.Location <> '' then
    begin
      Loc := R.Location;
      { strip " (discriminator N)" }
      P := Loc.IndexOf(' (');
      if P > 0 then
        Loc := Loc.Substring(0, P);
      P := Loc.LastIndexOf(':');
      if P > 0 then
      begin
        Info.SourceFile := Loc.Substring(0, P);
        Info.LineNumber := StrToIntDef(Loc.Substring(P + 1), 0);
      end;
      Include(Info.Sources, ssAddr2Line);
    end;
    Info.Inlined := R.Inlined;
  end;
end;

function GetAddressInfoList(const Addresses: TArray<Pointer>; Mask: TLinuxAddressInfoMask): TArray<TLinuxAddressInfo>;
var
  I: Integer;
  PerModule: TDictionary<string, TList<UInt64>>;
  M: TLinuxModule;
  Pair: TPair<string, TList<UInt64>>;
  L: TList<UInt64>;
begin
  SetLength(Result, Length(Addresses));
  for I := 0 to High(Addresses) do
  begin
    Result[I] := Default (TLinuxAddressInfo);
    Result[I].Address := Addresses[I];
  end;
  { Batch addr2line per module. }
  if (Mask = laimFull) and LinuxDebugInfoOptions.UseAddr2Line and (Addr2LinePath <> '') then
  begin
    PerModule := TDictionary<string, TList<UInt64>>.Create;
    try
      for I := 0 to High(Addresses) do
      begin
        M := GlobalModules.ModuleFromAddress(Addresses[I]);
        if not Assigned(M) then
          Continue;
        if not M.Symbols.Loaded or not M.Symbols.HasDebugLine then
          Continue; // No DWARF => addr2line would answer ??:0
        if not PerModule.TryGetValue(M.Path, L) then
        begin
          L := TList<UInt64>.Create;
          PerModule.Add(M.Path, L);
        end;
        L.Add(M.ToLinkTimeAddress(Addresses[I]));
      end;
      for Pair in PerModule do
        Addr2LineBatch(Pair.Key, Pair.Value.ToArray);
    finally
      for Pair in PerModule do
        Pair.Value.Free;
      PerModule.Free;
    end;
  end;
  for I := 0 to High(Result) do
    ResolveCore(Result[I], Mask);
end;

function GetAddressInfo(Address: Pointer; out Info: TLinuxAddressInfo; Mask: TLinuxAddressInfoMask): Boolean;
var
  A: TArray<TLinuxAddressInfo>;
begin
  A := GetAddressInfoList([Address], Mask);
  Info := A[0];
  Result := Info.HasSymbol or (Info.ModulePath <> '');
end;

function GetSymbolAddress(const SymbolName: string): Pointer;
var
  M: TLinuxModule;
  Sym: TElfSymbol;
begin
  Result := nil;
  M := GlobalModules.MainModule;
  if Assigned(M) and M.Symbols.Loaded and M.Symbols.FindSymbolByName(SymbolName, Sym) then
    Result := M.ToRunTimeAddress(Sym.Address);
end;

function DescribeDebugInfoSources: string;
var
  M: TLinuxModule;
  T: TElfSymbolTable;
begin
  M := GlobalModules.MainModule;
  if not Assigned(M) then
    Exit('no main module?');
  T := M.Symbols;
  Result := Format('exe=%s pie=%s symtab=%s(%d symbols) dynsym=%s debug_line=%s debug_info=%s addr2line=%s', [M.Path, BoolToStr(T.IsPIE, True),
    BoolToStr(T.HasSymtab, True), T.Symbols.Count, BoolToStr(T.HasDynsym, True), BoolToStr(T.HasDebugLine, True), BoolToStr(T.HasDebugInfo, True),
    IfThen(Addr2LinePath = '', 'not found', Addr2LinePath)]);
  if not T.Loaded then
    Result := Result + ' (symbol table load error: ' + T.LoadError + ')';
end;

initialization

GCacheLock := TCriticalSection.Create;
GAddr2LineCache := TDictionary<string, TAddr2LineResult>.Create;

finalization

GAddr2LineCache.Free;
GCacheLock.Free;

end.
