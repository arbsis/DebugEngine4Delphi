// **************************************************************************************************
// Delphi DebugEngine.
// Unit DebugEngine.Linux.Modules
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
/// Loaded modules enumeration (dl_iterate_phdr) and address => module mapping.
/// Each module lazily owns an ELF symbol table reader (see DebugEngine.Linux.Elf).
/// </summary>
unit DebugEngine.Linux.Modules;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.SyncObjs,
  Posix.SysTypes,
  DebugEngine.Linux.Posix,
  DebugEngine.Linux.Elf;

type
  TLinuxSegment = record
    StartAddress: UIntPtr; // Run time address.
    EndAddress: UIntPtr;
    Flags: Cardinal; // PF_R / PF_W / PF_X
    function IsExecutable: Boolean;
    function Contains(Address: UIntPtr): Boolean;
  end;

  TLinuxModule = class(TObject)
  private
    FPath: string;
    FIsMainProgram: Boolean;
    FLoadBias: UIntPtr; // dlpi_addr: 0 for non-PIE executables.
    FStartAddress: UIntPtr; // Lowest PT_LOAD address.
    FEndAddress: UIntPtr; // Highest PT_LOAD end address.
    FSegments: TArray<TLinuxSegment>;
    FSymbols: TElfSymbolTable;
    FSymbolsLock: TCriticalSection;
    function GetBaseName: string;
    function GetSymbols: TElfSymbolTable;
  public
    constructor Create(const APath: string; AIsMainProgram: Boolean; ALoadBias: UIntPtr);
    destructor Destroy; override;
    function ContainsAddress(Address: Pointer): Boolean;
    /// <summary> Convert a run time address into the link-time address used by the ELF symbol table and addr2line. </summary>
    function ToLinkTimeAddress(Address: Pointer): UInt64;
    function ToRunTimeAddress(LinkAddress: UInt64): Pointer;
    property Path: string read FPath;
    property BaseName: string read GetBaseName;
    property IsMainProgram: Boolean read FIsMainProgram;
    property LoadBias: UIntPtr read FLoadBias;
    property StartAddress: UIntPtr read FStartAddress;
    property EndAddress: UIntPtr read FEndAddress;
    property Segments: TArray<TLinuxSegment> read FSegments;
    /// <summary> ELF symbol table of the module (loaded on first access, may fail => Loaded = False). </summary>
    property Symbols: TElfSymbolTable read GetSymbols;
  end;

  TLinuxModules = class(TObject)
  private
    FList: TObjectList<TLinuxModule>;
    FLock: TCriticalSection;
    function GetCount: Integer;
    function GetItem(Index: Integer): TLinuxModule;
  public
    constructor Create;
    destructor Destroy; override;
    /// <summary> (Re)enumerate loaded modules with dl_iterate_phdr. </summary>
    procedure Refresh;
    function ModuleFromAddress(Address: Pointer): TLinuxModule;
    function MainModule: TLinuxModule;
    function FindByPath(const Path: string): TLinuxModule;
    property Count: Integer read GetCount;
    property Items[Index: Integer]: TLinuxModule read GetItem; default;
  end;

/// <summary> Global (lazily created) module list. </summary>
function GlobalModules: TLinuxModules;

/// <summary> Full path of the running executable (/proc/self/exe). </summary>
function GetExecutablePath: string;

/// <summary> Raw content of /proc/self/maps. </summary>
function ReadProcSelfMaps: string;

implementation

uses
  Posix.Unistd;

var
  GModules: TLinuxModules = nil;
  GModulesLock: TCriticalSection = nil;

function GetExecutablePath: string;
var
  Buf: array [0 .. 4095] of Byte;
  N: Integer;
begin
  N := readlink('/proc/self/exe', @Buf[0], SizeOf(Buf) - 1);
  if N > 0 then
  begin
    Buf[N] := 0;
    Result := string(UTF8String(MarshaledAString(@Buf[0])));
  end
  else
    Result := ParamStr(0);
end;

function ReadProcSelfMaps: string;
var
  FS: TFileStream;
  Buf: TBytes;
  N, Total: Integer;
begin
  Result := '';
  try
    { /proc files report size 0: read until EOF. }
    FS := TFileStream.Create('/proc/self/maps', fmOpenRead or fmShareDenyNone);
    try
      SetLength(Buf, 65536);
      Total := 0;
      repeat
        if Total = Length(Buf) then
          SetLength(Buf, Length(Buf) * 2);
        N := FS.Read(Buf[Total], Length(Buf) - Total);
        Inc(Total, N);
      until N <= 0;
      Result := TEncoding.UTF8.GetString(Buf, 0, Total);
    finally
      FS.Free;
    end;
  except
    // ignore
  end;
end;

{ TLinuxSegment }

function TLinuxSegment.IsExecutable: Boolean;
begin
  Result := Flags and PF_X <> 0;
end;

function TLinuxSegment.Contains(Address: UIntPtr): Boolean;
begin
  Result := (Address >= StartAddress) and (Address < EndAddress);
end;

{ TLinuxModule }

constructor TLinuxModule.Create(const APath: string; AIsMainProgram: Boolean; ALoadBias: UIntPtr);
begin
  inherited Create;
  FPath := APath;
  FIsMainProgram := AIsMainProgram;
  FLoadBias := ALoadBias;
  FStartAddress := High(UIntPtr);
  FEndAddress := 0;
  FSymbolsLock := TCriticalSection.Create;
end;

destructor TLinuxModule.Destroy;
begin
  FSymbols.Free;
  FSymbolsLock.Free;
  inherited;
end;

function TLinuxModule.GetBaseName: string;
begin
  Result := ExtractFileName(FPath);
end;

function TLinuxModule.GetSymbols: TElfSymbolTable;
begin
  FSymbolsLock.Enter;
  try
    if not Assigned(FSymbols) then
    begin
      FSymbols := TElfSymbolTable.Create(FPath);
      FSymbols.Load;
    end;
    Result := FSymbols;
  finally
    FSymbolsLock.Leave;
  end;
end;

function TLinuxModule.ContainsAddress(Address: Pointer): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FSegments) do
    if FSegments[I].Contains(UIntPtr(Address)) then
      Exit(True);
  Result := False;
end;

function TLinuxModule.ToLinkTimeAddress(Address: Pointer): UInt64;
begin
  Result := UInt64(UIntPtr(Address) - FLoadBias);
end;

function TLinuxModule.ToRunTimeAddress(LinkAddress: UInt64): Pointer;
begin
  Result := Pointer(UIntPtr(LinkAddress) + FLoadBias);
end;

{ TLinuxModules }

constructor TLinuxModules.Create;
begin
  inherited Create;
  FList := TObjectList<TLinuxModule>.Create(True);
  FLock := TCriticalSection.Create;
  Refresh;
end;

destructor TLinuxModules.Destroy;
begin
  FList.Free;
  FLock.Free;
  inherited;
end;

function PhdrCallback(Info: Pdl_phdr_info; Size: size_t; Data: Pointer): Integer; cdecl;
var
  List: TObjectList<TLinuxModule>;
  Module: TLinuxModule;
  Path: string;
  I: Integer;
  Ph: PElf64_Phdr;
  Seg: TLinuxSegment;
  IsMain: Boolean;
begin
  Result := 0;
  List := TObjectList<TLinuxModule>(Data);
  Path := string(UTF8String(Info^.dlpi_name));
  IsMain := List.Count = 0; // The first entry is always the main program.
  if IsMain and (Path = '') then
    Path := GetExecutablePath;
  if Path = '' then
    Exit; // vdso / anonymous
  Module := TLinuxModule.Create(Path, IsMain, Info^.dlpi_addr);
  Ph := Info^.dlpi_phdr;
  for I := 0 to Info^.dlpi_phnum - 1 do
  begin
    if Ph^.p_type = PT_LOAD then
    begin
      Seg.StartAddress := Info^.dlpi_addr + Ph^.p_vaddr;
      Seg.EndAddress := Seg.StartAddress + Ph^.p_memsz;
      Seg.Flags := Ph^.p_flags;
      Module.FSegments := Module.FSegments + [Seg];
      if Seg.StartAddress < Module.FStartAddress then
        Module.FStartAddress := Seg.StartAddress;
      if Seg.EndAddress > Module.FEndAddress then
        Module.FEndAddress := Seg.EndAddress;
    end;
    Inc(Ph);
  end;
  if Length(Module.FSegments) = 0 then
    Module.Free
  else
    List.Add(Module);
end;

procedure TLinuxModules.Refresh;
begin
  FLock.Enter;
  try
    FList.Clear;
    dl_iterate_phdr(@PhdrCallback, FList);
  finally
    FLock.Leave;
  end;
end;

function TLinuxModules.GetCount: Integer;
begin
  Result := FList.Count;
end;

function TLinuxModules.GetItem(Index: Integer): TLinuxModule;
begin
  Result := FList[Index];
end;

function TLinuxModules.MainModule: TLinuxModule;
begin
  if FList.Count > 0 then
    Result := FList[0]
  else
    Result := nil;
end;

function TLinuxModules.FindByPath(const Path: string): TLinuxModule;
var
  M: TLinuxModule;
begin
  for M in FList do
    if SameText(M.Path, Path) then
      Exit(M);
  Result := nil;
end;

function TLinuxModules.ModuleFromAddress(Address: Pointer): TLinuxModule;
var
  M: TLinuxModule;
  Pass: Integer;
begin
  for Pass := 0 to 1 do
  begin
    FLock.Enter;
    try
      for M in FList do
        if M.ContainsAddress(Address) then
          Exit(M);
    finally
      FLock.Leave;
    end;
    { Not found: maybe a library was loaded after the last enumeration. }
    if Pass = 0 then
      Refresh;
  end;
  Result := nil;
end;

function GlobalModules: TLinuxModules;
begin
  if not Assigned(GModules) then
  begin
    GModulesLock.Enter;
    try
      if not Assigned(GModules) then
        GModules := TLinuxModules.Create;
    finally
      GModulesLock.Leave;
    end;
  end;
  Result := GModules;
end;

initialization

GModulesLock := TCriticalSection.Create;

finalization

GModules.Free;
GModulesLock.Free;

end.
