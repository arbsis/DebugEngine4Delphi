// **************************************************************************************************
// Delphi DebugEngine.
// Unit DebugEngine.DebugInfo
// https://github.com/MahdiSafsafi/DebugEngine

// The contents of this file are subject to the Mozilla Public License Version 1.1 (the "License");
// you may not use this file except in compliance with the License. You may obtain a copy of the
// License at http://www.mozilla.org/MPL/
//
// Software distributed under the License is distributed on an "AS IS" basis, WITHOUT WARRANTY OF
// ANY KIND, either express or implied. See the License for the specific language governing rights
// and limitations under the License.
//
// The Original Code is DebugEngine.DebugInfo.pas.
//
//
// The Initial Developer of the Original Code is Mahdi Safsafi.
// Portions created by Mahdi Safsafi . are Copyright (C) 2016-2019 Mahdi Safsafi.
// All Rights Reserved.
//
// **************************************************************************************************

// ===================> CHANGE LOG <===================
// [4/28/17]:
// - Changed MAX_SEGMENT_UNITS from (1000) to (10000).

unit DebugEngine.DebugInfo;

interface

{$I DebugEngine.inc}
{ .$DEFINE DEVMODE }

uses
  WinApi.Windows,
  WinApi.ImageHlp,
  WinApi.PsApi,
  System.SysUtils,
  System.Classes,
  DebugEngine.MapParser;

const
  { Re-exported from DebugEngine.MapParser for backward compatibility. }
  DelphiMapFileExtension = DebugEngine.MapParser.DelphiMapFileExtension;
  SMapFileExtension = DebugEngine.MapParser.SMapFileExtension;
  SMapResType = 'SMAP';
  SMapResName = 'Map';
  SMapSignature = DebugEngine.MapParser.SMapSignature;
  SMapVersion = DebugEngine.MapParser.SMapVersion;

  DelphiDebugSection = '.debug';

  SDebugSection = '.SDEBUG';

  SEGMENT_NAME_LENGTH = DebugEngine.MapParser.SEGMENT_NAME_LENGTH;

{$REGION 'MapTypes'}

type
  { Aliases re-exported from DebugEngine.MapParser for backward compatibility. }
  PSMapChar = DebugEngine.MapParser.PSMapChar;
  SMapChar = DebugEngine.MapParser.SMapChar;
  TMapNotification = DebugEngine.MapParser.TMapNotification;
  TSMapOptions = DebugEngine.MapParser.TSMapOptions;
  TMapLocation = DebugEngine.MapParser.TMapLocation;
  TSMapHeader = DebugEngine.MapParser.TSMapHeader;
  PSMapHeader = DebugEngine.MapParser.PSMapHeader;
  TSMapSegment = DebugEngine.MapParser.TSMapSegment;
  PSMapSegment = DebugEngine.MapParser.PSMapSegment;
  TSMapUnit = DebugEngine.MapParser.TSMapUnit;
  PSMapUnit = DebugEngine.MapParser.PSMapUnit;
  TSMapSymbol = DebugEngine.MapParser.TSMapSymbol;
  PSMapSymbol = DebugEngine.MapParser.PSMapSymbol;
  TSMapSourceLocation = DebugEngine.MapParser.TSMapSourceLocation;
  PSMapSourceLocation = DebugEngine.MapParser.PSMapSourceLocation;
  TSMapLineNumber = DebugEngine.MapParser.TSMapLineNumber;
  PSMapLineNumber = DebugEngine.MapParser.PSMapLineNumber;
  TRuntimeSegment = DebugEngine.MapParser.TRuntimeSegment;
  PRuntimeSegment = DebugEngine.MapParser.PRuntimeSegment;
  TLineNumberSource = DebugEngine.MapParser.TLineNumberSource;
  PLineNumberSource = DebugEngine.MapParser.PLineNumberSource;
  TCustomTxtMapParser = DebugEngine.MapParser.TCustomTxtMapParser;
  TAddressInfoMask = DebugEngine.MapParser.TAddressInfoMask;

const
  moCompress = DebugEngine.MapParser.moCompress;
  mlNone = DebugEngine.MapParser.mlNone;
  mlSection = DebugEngine.MapParser.mlSection;
  mlResource = DebugEngine.MapParser.mlResource;
  mlDisk = DebugEngine.MapParser.mlDisk;
  aimNone = DebugEngine.MapParser.aimNone;
  aimAddress = DebugEngine.MapParser.aimAddress;
  aimSymbolName = DebugEngine.MapParser.aimSymbolName;

{$ENDREGION 'MapTypes'}

type

  TModule = class;
  TDebugInfoBase = class;
  TDebugInfoMapBase = class;

  TAddressInfo = record
    SymbolAddress: Pointer;
    LineNumber: Cardinal;
    SymbolName: string;
    UnitName: string;
    SourceLocation: string;
    DebugSource: TDebugInfoBase;
    SymbolIndex: Integer; // Export Index.
  end;

  PAddressInfo = ^TAddressInfo;


{$REGION 'DebugClass'}

  TModule = class(TObject)
  private
    FModule: THandle;
    FStartAddress: Pointer;
    FEndAddress: Pointer;
    FSize: Cardinal;
    FBaseName: string;
    FFileName: string;
    FBorlandModule: Boolean;
    FMapLocation: TMapLocation;
    FDebugInfo: TDebugInfoBase;
    function GetMapLocation: TMapLocation;
    function GetDiskMapBaseName: string;
    function GetImageBase: NativeUInt;
    function GetIsBorlandModule: Boolean;
  protected
    procedure CreateDebugInfo;
    procedure InitializeModule;
  public
    constructor Create(ModuleHandle: THandle); virtual;
    destructor Destroy; override;
    function IsAddressInModuleRange(Address: Pointer): Boolean;
    property ModuleHandle: THandle read FModule;
    property SegStartAddress: Pointer read FStartAddress;
    property SegEndAddress: Pointer read FEndAddress;
    property Size: Cardinal read FSize;
    property BaseName: string read FBaseName;
    property FileName: string read FFileName;
    property MapLocation: TMapLocation read FMapLocation;
    property ImageBase: NativeUInt read GetImageBase;
    property IsBorlandModule: Boolean read FBorlandModule;
    property DebugInfo: TDebugInfoBase read FDebugInfo;
  end;

  TDebugInfoBase = class(TObject)
  private
    FModule: TModule;
  public
    /// <summary>
    /// All descendants class must implement this function.
    /// </summary>
    function GetAddressInfo(Address: Pointer; out Info: TAddressInfo; Mask: TAddressInfoMask): Boolean; virtual; abstract;
    function GetSymbolAddress(const UnitName, SymbolName: string): Pointer; virtual; abstract;
    function GetAddressFromIndex(Index: Integer): Pointer; virtual; abstract;
    constructor Create(Module: TModule); virtual;
    destructor Destroy; override;
    property Module: TModule read FModule;
  end;

  TDebugInfoExport = class(TDebugInfoBase)
  private type
    TExportInfo = record
      Address: Pointer;
      Ord: Word;
      Hint: Word;
      Name: string;
    end;

    PExportInfo = ^TExportInfo;
  private
    FExportList: TList;
  protected
    procedure CreateExportList;
  public
    function GetSymbolAddress(const UnitName, SymbolName: string): Pointer; override;
    function GetAddressInfo(Address: Pointer; out Info: TAddressInfo; Mask: TAddressInfoMask): Boolean; override;
    function GetAddressFromIndex(Index: Integer): Pointer; override;
    constructor Create(Module: TModule); override;
    destructor Destroy; override;
  end;

  TDebugInfoMapBase = class(TDebugInfoBase)
  private
    FMapStream: TMemoryStream;
  protected
    function ProcessMap: Boolean; virtual; abstract;
  public
    function LoadFromStream(Stream: TStream): Boolean;
    function LoadFromFile(const MapFileName: string): Boolean;
    constructor Create(Module: TModule); override;
    destructor Destroy; override;
    property MapStream: TMemoryStream read FMapStream;
  end;


  TDebugInfoSMap = class(TDebugInfoMapBase)
  private
    FReader: TSMapReader;
    function ResolveSegment(SegId: Integer; const SegName: string; SegStartAddress: NativeUInt; SegLength: Cardinal;
      out RtStartAddress: Pointer): Boolean;
  protected
    function ProcessMap: Boolean; override;
  public
    function GetAddressInfo(Address: Pointer; out Info: TAddressInfo; Mask: TAddressInfoMask): Boolean; override;
    function GetSymbolAddress(const UnitName, SymbolName: string): Pointer; override;
    function GetAddressFromIndex(Index: Integer): Pointer; override;
    constructor Create(Module: TModule); override;
    destructor Destroy; override;
    property Reader: TSMapReader read FReader;
  end;

  TModules = class(TObject)
  private
    FModulesList: TList;
    function GetModuleFromAddress(Address: Pointer): TModule;
    function GetModuleFromModuleHandle(ModuleHandle: THandle; RegisterNoExists: Boolean): TModule;
  protected
    function AddModule(ModuleHandle: THandle): TModule;
  public
    constructor Create; virtual;
    destructor Destroy; override;
    property ModuleFromAddress[Address: Pointer]: TModule read GetModuleFromAddress;
  end;
{$ENDREGION 'DebugClass'}

  // ---------------------------------------------------------------------------------------------------------------------------
{$REGION 'PublicFunctions'}


/// <summary> Retrieve address info.
/// </summary>
/// <param name="Address"> Address to obtain information on.
/// </param>
/// <param name= "Info"> Info record output for the specified address.
/// </param>
/// <param name= "Mask"> Query only specified info.
/// This is very useful when processing too many address.
/// Use this mask to boost function speed.
/// For more information see <see cref="TAddressInfoMask"/>.
/// </param>
/// <returns> If the function succeeds, the return value is True.
/// </returns>
function GetAddressInfo(Address: Pointer; out Info: TAddressInfo; const Mask: TAddressInfoMask = aimNone): Boolean;

/// <summary> Retrieve address of symbol from symbol name.
/// </summary>
/// <param name="ModuleHandle"> Module handle where the symbol is located.
/// </param>
/// <param name="UnitName"> Unit name where the symbol was declared.
/// </param>
/// <param name="SymbolName"> Symbol name.
/// </param>
/// <returns> If the function succeeds, the return value is the address of the symbol. Otherwise it returns nil.
/// </returns>
/// <remarks>
/// <para> If <c>ModuleHandle</c> was not specified (0), the function will use the current module handle.
/// </para>
/// <para> <c>UnitName</c> parameter is optional. It's useful when the symbol is declared in more than unit.
/// </para>
/// </remarks>
function GetSymbolAddress(ModuleHandle: THandle; const UnitName, SymbolName: string): Pointer;

/// <summary> Retrieve next symbol address from the current symbol address.
/// </summary>
/// <param name="Address"> Address of the current symbol.
/// </param>
/// <returns> If the function succeeds, the return value is the next address of the current symbol. Otherwise it returns nil.
/// </returns>
function GetNextSymbolAddress(Address: Pointer): Pointer;

/// <summary> Retrieve the size of a function in bytes.
/// </summary>
/// <param name="Address"> Address of the function.
/// </param>
/// <returns> If the function succeeds, the return value is the size of function (opcodes size). Otherwise it returns 0.
/// </returns>
function GetSizeOfFunction(Address: Pointer): Integer;

{$ENDREGION 'PublicFunctions'}
// ------------------------------------------------------------------------------------
{$REGION 'MiscFunctions'}
{ Basically those functions were not designed for public use,
  However, I think that it is better to keep them public. }

function GetModuleBaseName(Module: HMODULE): string;
function GetModuleFileName(Module: HMODULE): string;
function GetModuleHandleFromAddress(Address: Pointer): THandle;

{$ENDREGION 'MiscFunctions'}

implementation

uses
  DebugEngine.PeUtils;

{$B-}   // Force B-!
{$REGION 'InternalDebugUtils'}
{$IFDEF DEVMODE}

procedure Bp;
asm
  int 3
end;

{$ENDIF DEVMODE}
{$ENDREGION 'InternalDebugUtils'}
{$REGION 'GLOBAL'}
const
  PAGE_EXECUTE_MASK = PAGE_EXECUTE or PAGE_EXECUTE_READ or PAGE_EXECUTE_READWRITE or PAGE_EXECUTE_WRITECOPY;

  { Place all global variables here ! }
var

  GlobalModules: TModules = nil;

  GlobalLock: TObject = nil;

procedure NeedGlobalModules;
begin
  if Assigned(GlobalModules) then
    Exit;
  TMonitor.Enter(GlobalLock);
  try
    if not Assigned(GlobalModules) then
      GlobalModules := TModules.Create;
  finally
    TMonitor.Exit(GlobalLock);
  end;
end;

{$ENDREGION 'GLOBAL'}

function GetAddressInfo(Address: Pointer; out Info: TAddressInfo; const Mask: TAddressInfoMask = aimNone): Boolean;
var
  LModule: TModule;
begin
  NeedGlobalModules;
  try
    LModule := GlobalModules.ModuleFromAddress[Address];
    if Assigned(LModule) and Assigned(LModule.DebugInfo) then
    begin
      Result := LModule.DebugInfo.GetAddressInfo(Address, Info, Mask);
      Exit;
    end;
  except
    // Do nothing.
  end;
  Result := False;
end;

function GetSymbolAddress(ModuleHandle: THandle; const UnitName, SymbolName: string): Pointer;
var
  Module: TModule;
begin
  Result := nil;
  if ModuleHandle = 0 then
    ModuleHandle := GetModuleHandle(nil);

  NeedGlobalModules;
  Module := GlobalModules.GetModuleFromModuleHandle(ModuleHandle, True);
  if Assigned(Module) then
    Result := Module.DebugInfo.GetSymbolAddress(UnitName, SymbolName);
end;

function GetNextSymbolAddress(Address: Pointer): Pointer;
var
  Info: TAddressInfo;
begin
  if GetAddressInfo(Address, Info, aimAddress) and (Assigned(Info.DebugSource)) then
  begin
    Result := Info.DebugSource.GetAddressFromIndex(Info.SymbolIndex + 1);
    Exit;
  end;
  Result := nil;
end;

function GetSizeOfFunction(Address: Pointer): Integer;
var
  mbi: TMemoryBasicInformation;
  NextAddress: Pointer;
begin
  { SizeOfFunction = NextAdjacentAddress - StartAddress of the function. }
  if (VirtualQuery(Address, mbi, SizeOf(TMemoryBasicInformation)) > 0) and (mbi.Protect and PAGE_EXECUTE_MASK <> $00) then
  begin
    NextAddress := GetNextSymbolAddress(Address);
    if Assigned(NextAddress) then
    begin
      Result := NativeUInt(NextAddress) - NativeUInt(Address);
      Exit;
    end;
  end;
  Result := 0;
end;

{$REGION 'Misc'}


function GetModuleFileName(Module: HMODULE): string;
var
  Buffer: array of Char;
  nSize: Cardinal;
label DoItAgain;
begin
  nSize := MAX_PATH;
DoItAgain: SetLength(Buffer, nSize);
  if WinApi.Windows.GetModuleFileName(Module, @Buffer[0], nSize) = 0 then
    Exit(EmptyStr);
  if GetLastError = ERROR_INSUFFICIENT_BUFFER then
  begin
    { Insufficient buffer length => Realloc memory and try again. }
    Inc(nSize, nSize);
    goto DoItAgain;
  end;
  Result := String(PChar(@Buffer[0]));
end;

function GetModuleBaseName(Module: HMODULE): string;
var
  Buffer: array [0 .. MAX_PATH] of Char;
  nSize: Cardinal;
begin
  Result := EmptyStr;
  nSize := MAX_PATH - 1;
  if WinApi.PsApi.GetModuleBaseName(GetCurrentProcess, Module, @Buffer[0], nSize) > 0 then
    Result := String(PChar(@Buffer[0]));
end;

function GetModuleHandleFromAddress(Address: Pointer): THandle;
var
  mbi: TMemoryBasicInformation;
begin
  if (VirtualQuery(Address, mbi, SizeOf(TMemoryBasicInformation)) > 0) and (mbi.State = MEM_COMMIT) then
    Exit(HMODULE(mbi.AllocationBase));
  Result := 0;
end;

{$ENDREGION 'Misc'}
{$REGION 'DebugInfo'}
{ TModule }

constructor TModule.Create(ModuleHandle: THandle);
begin
  FModule := ModuleHandle;
  FStartAddress := nil;
  FEndAddress := nil;
  FDebugInfo := nil;
  FSize := 0;
  FBaseName := EmptyStr;
  FFileName := EmptyStr;
  FMapLocation := mlNone;

  InitializeModule;
  try
    CreateDebugInfo;
  except
    { A broken / foreign map must never bring the host application down: fall back to the
      export table so that at least exported symbols resolve. }
    FreeAndNil(FDebugInfo);
    FMapLocation := mlNone;
    FDebugInfo := TDebugInfoExport.Create(Self);
  end;
end;

{ A pre-converted .smap is used only when it is not older than the .map it was generated from:
  a stale .smap left by a previous build would silently produce wrong symbols. }
function UseDiskSMap(const SMapFileName: string): Boolean;
var
  MapFileName: string;
  MapTime, SMapTime: TDateTime;
begin
  Result := FileExists(SMapFileName);
  if not Result then
    Exit;
  MapFileName := ChangeFileExt(SMapFileName, DelphiMapFileExtension);
  if FileExists(MapFileName) and FileAge(MapFileName, MapTime) and FileAge(SMapFileName, SMapTime) then
    Result := SMapTime >= MapTime;
end;

procedure TModule.CreateDebugInfo;
var
  MapFileName: string;
  NtHeaders: PImageNtHeaders;
  Section: PImageSectionHeader;
  MS: TMemoryStream;
  SrcStream: TMemoryStream;
  P: Pointer;
  ResInfo: HRSRC;
  ResSize: DWORD;
  hRes: HGLOBAL;
begin
  case FMapLocation of
    mlDisk:
      begin
        { Load from disk. A ready made .smap (generated by ConvertMapToSMap or the DD tool) is
          preferred; otherwise the Delphi .map is converted in memory: no temporary file is written. }
        FDebugInfo := TDebugInfoSMap.Create(Self);
        MapFileName := ChangeFileExt(GetDiskMapBaseName, SMapFileExtension);
        if UseDiskSMap(MapFileName) then
          TDebugInfoSMap(FDebugInfo).LoadFromFile(MapFileName)
        else
        begin
          MapFileName := ChangeFileExt(GetDiskMapBaseName, DelphiMapFileExtension);
          SrcStream := TMemoryStream.Create;
          MS := TMemoryStream.Create;
          try
            SrcStream.LoadFromFile(MapFileName);
            { The converter scans until #0. }
            SrcStream.Size := SrcStream.Size + 1;
            PByte(SrcStream.Memory)[SrcStream.Size - 1] := 0;
            if ConvertMapToSMap(SrcStream, MS, []) > 0 then
            begin
              SrcStream.Clear; // Release the text map before parsing the SMAP.
              MS.Position := 0;
              TDebugInfoSMap(FDebugInfo).LoadFromStream(MS);
            end;
          finally
            SrcStream.Free;
            MS.Free;
          end;
        end;
      end;
    mlSection:
      begin
        { Load from SDEBUG section. }
        NtHeaders := PeMapImageNtHeaders(Pointer(FModule));
        Section := PeFindSection(NtHeaders, SDebugSection);
        P := Pointer(NativeUInt(FModule) + Section^.VirtualAddress);
        FDebugInfo := TDebugInfoSMap.Create(Self);
        MS := TMemoryStream.Create;
        try
          MS.Write(P^, Section^.Misc.VirtualSize);
          MS.Seek(0, soFromBeginning);
          TDebugInfoSMap(FDebugInfo).LoadFromStream(MS);
        finally
          MS.Free;
        end;
      end;
    mlResource:
      begin
        { Load from resource. }
        ResInfo := FindResource(FModule, SMapResName, SMapResType);
        ResSize := SizeofResource(FModule, ResInfo);
        hRes := LoadResource(FModule, ResInfo);
        P := LockResource(hRes);
        FDebugInfo := TDebugInfoSMap.Create(Self);
        MS := TMemoryStream.Create;
        try
          MS.Write(P^, ResSize);
          MS.Seek(0, soFromBeginning);
          TDebugInfoSMap(FDebugInfo).LoadFromStream(MS);
        finally
          MS.Free;
        end;
      end;
    mlNone:
      begin
        { There is no map => Get info from export directory }
        FDebugInfo := TDebugInfoExport.Create(Self);
      end;
  end;
end;

destructor TModule.Destroy;
begin
  if Assigned(FDebugInfo) then
    FDebugInfo.Free;
  inherited;
end;

function TModule.GetImageBase: NativeUInt;
var
  NtHeaders: PImageNtHeaders;
begin
  NtHeaders := PeMapImageNtHeaders(Pointer(FModule));
  Result := NtHeaders^.OptionalHeader.ImageBase;
end;

function TModule.GetIsBorlandModule: Boolean;
var
  CurModule: PLibModule;
begin
  CurModule := System.LibModuleList;
  while Assigned(CurModule) do
  begin
    if (CurModule^.Instance = FModule) then
      Exit(True);
    CurModule := CurModule^.Next;
  end;
  Result := False;
end;

function TModule.GetMapLocation: TMapLocation;
var
  MapFileName: string;
begin
  { SDEBUG }
  if Assigned(PeFindSection(PeMapImageNtHeaders(Pointer(FModule)), SDebugSection)) then
    Exit(mlSection);

  { SMAP }
  if FindResource(FModule, SMapResName, SMapResType) <> 0 then
    Exit(mlResource);

  { Delphi map or pre-converted smap next to the module }
  { Leave this test the last one. }
  MapFileName := ChangeFileExt(GetDiskMapBaseName, DelphiMapFileExtension);
  if FileExists(MapFileName) or FileExists(ChangeFileExt(MapFileName, SMapFileExtension)) then
    Exit(mlDisk);

  { No map associated with module }
  Result := mlNone;
end;

function TModule.GetDiskMapBaseName: string;
begin
  { Prefer the full module path: the map file lives next to the module.
    Fall back to the bare module name (relative to the current directory)
    to keep the historical behaviour. }
  Result := FFileName;
  if (Result = '') or not(FileExists(ChangeFileExt(Result, DelphiMapFileExtension)) or FileExists(ChangeFileExt(Result, SMapFileExtension))) then
    Result := FBaseName;
end;

function TModule.IsAddressInModuleRange(Address: Pointer): Boolean;
begin
  Result := IsAddressInRange(Address, FStartAddress, FEndAddress);
end;

procedure TModule.InitializeModule;
var
  NtHeaders: PImageNtHeaders;
begin
  FStartAddress := Pointer(FModule);
  NtHeaders := PeMapImageNtHeaders(Pointer(FModule));
  if Assigned(NtHeaders) then
  begin
    FSize := NtHeaders^.OptionalHeader.SizeOfImage;
    FEndAddress := Pointer(NativeUInt(FStartAddress) + FSize);
    FBaseName := GetModuleBaseName(FModule);
    FFileName := GetModuleFileName(FModule);
    FBorlandModule := GetIsBorlandModule;
    FMapLocation := GetMapLocation;
  end;
end;

{ TDebugInfoBase }

constructor TDebugInfoBase.Create(Module: TModule);
begin
  FModule := Module;
end;

destructor TDebugInfoBase.Destroy;
begin

  inherited;
end;

{ TDebugInfoMapBase }

constructor TDebugInfoMapBase.Create(Module: TModule);
begin
  inherited;
  FMapStream := TMemoryStream.Create;
end;

destructor TDebugInfoMapBase.Destroy;
begin
  FMapStream.Free;
  inherited;
end;

function TDebugInfoMapBase.LoadFromFile(const MapFileName: string): Boolean;
var
  LStream: TFileStream;
begin
  Result := FileExists(MapFileName);
  if Result then
  begin
    LStream := TFileStream.Create(MapFileName, fmOpenRead);
    try
      Result := LoadFromStream(LStream);
    finally
      LStream.Free;
    end;
  end;
end;

function TDebugInfoMapBase.LoadFromStream(Stream: TStream): Boolean;
begin
  FMapStream.Clear;
  FMapStream.LoadFromStream(Stream);
  Result := FMapStream.Size > 1;
  if Result then
    Result := ProcessMap;
end;

{ TDebugInfoSMap }

constructor TDebugInfoSMap.Create(Module: TModule);
begin
  inherited;
  FReader := TSMapReader.Create(ResolveSegment);
end;

destructor TDebugInfoSMap.Destroy;
begin
  FReader.Free;
  inherited;
end;

function TDebugInfoSMap.ResolveSegment(SegId: Integer; const SegName: string; SegStartAddress: NativeUInt; SegLength: Cardinal;
  out RtStartAddress: Pointer): Boolean;
var
  Section: PImageSectionHeader;
begin
  { Map the segment to the PE section that has the same name.
    This is robust against ASLR (the loader patches the in-memory ImageBase)
    and against 64-bit image bases that do not fit in a Cardinal
    (e.g. $140000000 used by recent Delphi versions). }
  Section := nil;
  if SegName <> '' then
    Section := PeFindSection(PeMapImageNtHeaders(Pointer(FModule.ModuleHandle)), SegName);
  if Assigned(Section) then
    RtStartAddress := Pointer(NativeUInt(FModule.ModuleHandle) + Section^.VirtualAddress)
  else
    { Fallback: module could be loaded at a different address space
      specified by Delphi. So we need to fix segment start address. }
    RtStartAddress := Pointer((SegStartAddress - FModule.ImageBase) + FModule.ModuleHandle);
  Result := FModule.IsAddressInModuleRange(RtStartAddress);
end;

function TDebugInfoSMap.ProcessMap: Boolean;
begin
  FMapStream.Position := 0;
  Result := FReader.LoadFromStream(FMapStream);
  { The reader keeps its own copy. }
  FMapStream.Clear;
end;

function TDebugInfoSMap.GetAddressFromIndex(Index: Integer): Pointer;
begin
  Result := FReader.GetAddressFromIndex(Index);
end;

function TDebugInfoSMap.GetAddressInfo(Address: Pointer; out Info: TAddressInfo; Mask: TAddressInfoMask): Boolean;
var
  SInfo: TSMapAddressInfo;
begin
  Result := FReader.GetAddressInfo(Address, SInfo, Mask);
  if Result then
  begin
    FillChar(Info, SizeOf(Info), #00);
    Info.DebugSource := Self;
    Info.SymbolAddress := SInfo.SymbolAddress;
    Info.SymbolIndex := SInfo.SymbolIndex;
    Info.SymbolName := SInfo.SymbolName;
    Info.UnitName := SInfo.UnitName;
    Info.LineNumber := SInfo.LineNumber;
    Info.SourceLocation := SInfo.SourceLocation;
  end;
end;

function TDebugInfoSMap.GetSymbolAddress(const UnitName, SymbolName: string): Pointer;
begin
  Result := FReader.GetSymbolAddress(UnitName, SymbolName);
end;

{ TDebugInfoExport }

function ExportFunctionsSortCompare(Item1, Item2: Pointer): Integer;
begin
  Result := NativeUInt(TDebugInfoExport.PExportInfo(Item1)^.Address) - NativeUInt(TDebugInfoExport.PExportInfo(Item2)^.Address);
end;

constructor TDebugInfoExport.Create(Module: TModule);
begin
  inherited;
  FExportList := TList.Create;
  CreateExportList;
end;

destructor TDebugInfoExport.Destroy;
var
  I: Integer;
  P: Pointer;
begin
  for I := 0 to FExportList.Count - 1 do
  begin
    P := FExportList[I];
    if Assigned(P) then
    begin
      // FinalizeRecord(P, TypeInfo(TExportInfo));
      Finalize(PExportInfo(P)^);
      Dispose(FExportList[I]);
    end;
  end;
  FExportList.Free;
  inherited;
end;

procedure TDebugInfoExport.CreateExportList;
  function RvaToVa(Rva: Cardinal): Pointer;
  begin
    { All modules are loaded into the process address space ! }
    Result := Pointer(Rva + FModule.ModuleHandle);
  end;

var
  NtHeaders: PImageNtHeaders;
  EntryData: PImageExportDirectory;
  Info: PExportInfo;
  POrd: PWord;
  P: PDWORD;
  ExportSize: DWORD;
  nFunctions: DWORD;
  nNames: DWORD;
  I: Integer;
begin
  NtHeaders := PeMapImageNtHeaders(Pointer(FModule.ModuleHandle));
  ExportSize := NtHeaders^.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].Size;
  EntryData := ImageDirectoryEntryToData(Pointer(FModule.ModuleHandle), True, IMAGE_DIRECTORY_ENTRY_EXPORT, ExportSize);

  if not Assigned(EntryData) then
    Exit;

  with EntryData^ do
  begin
    nFunctions := NumberOfFunctions;
    nNames := NumberOfNames;
    POrd := RvaToVa(AddressOfNameOrdinals);
    P := RvaToVa(AddressOfFunctions);
  end;

  { Functions address. }
  for I := 0 to nFunctions - 1 do
  begin
    // Don't forget to dispose info when destroying !
    New(Info);
    with Info^ do
    begin
      Hint := I; // In case there is no name.
      Address := RvaToVa(P^);
      Ord := EntryData^.Base + Word(I);
      Name := EmptyStr;
    end;
    Inc(P);
    FExportList.Add(Info);
  end;

  { Functions names. }
  P := RvaToVa(EntryData^.AddressOfNames);
  for I := 0 to nNames - 1 do
  begin
    Info := FExportList[POrd^];
    Info^.Name := string(PAnsiChar(RvaToVa(P^)));
    Inc(P);
    Inc(POrd);
  end;

  { We must sort exported functions by address value. }
  FExportList.Sort(ExportFunctionsSortCompare);
end;

function TDebugInfoExport.GetAddressFromIndex(Index: Integer): Pointer;
begin
  if (Index > -1) and (Index < FExportList.Count) then
  begin
    Result := PExportInfo(FExportList[Index])^.Address;
    Exit;
  end;
  Result := nil;
end;

function TDebugInfoExport.GetAddressInfo(Address: Pointer; out Info: TAddressInfo; Mask: TAddressInfoMask): Boolean;
var
  I: Integer;
  ExportInfo: PExportInfo;
begin
  if FModule.IsAddressInModuleRange(Address) then
  begin
    for I := FExportList.Count - 1 downto 0 do
    begin
      ExportInfo := FExportList[I];
      if (NativeUInt(Address) >= NativeUInt(ExportInfo^.Address)) then
      begin
        Result := True;
        FillChar(Info, SizeOf(Info), #00);
        Info.DebugSource := Self;
        Info.SymbolAddress := ExportInfo^.Address;
        Info.SymbolIndex := I;
        if Mask = aimAddress then
          Exit;
        if ExportInfo^.Name.IsEmpty then
          Info.SymbolName := ChangeFileExt(FModule.FBaseName, '.') + IntToStr(ExportInfo^.Hint)
        else
          Info.SymbolName := ExportInfo^.Name;
        Exit;
      end;
    end;
  end;
  Result := False;
end;

function TDebugInfoExport.GetSymbolAddress(const UnitName, SymbolName: string): Pointer;
var
  I: Integer;
  PExport: PExportInfo;
begin
  for I := 0 to FExportList.Count - 1 do
  begin
    PExport := FExportList[I];
    if SameText(PExport^.Name, SymbolName) then
      Exit(PExport^.Address);
  end;
  Result := nil;
end;

{ TModules }

constructor TModules.Create;
begin
  FModulesList := TList.Create;
end;

destructor TModules.Destroy;
var
  I: Integer;
begin
  for I := 0 to FModulesList.Count - 1 do
    TObject(FModulesList[I]).Free;
  FModulesList.Free;
  inherited;
end;

function TModules.AddModule(ModuleHandle: THandle): TModule;
begin
  Result := TModule.Create(ModuleHandle);
  FModulesList.Add(Result);
end;

function TModules.GetModuleFromAddress(Address: Pointer): TModule;
var
  ModuleHandle: THandle;
begin
  ModuleHandle := GetModuleHandleFromAddress(Address);
  Result := GetModuleFromModuleHandle(ModuleHandle, True);
end;

function TModules.GetModuleFromModuleHandle(ModuleHandle: THandle; RegisterNoExists: Boolean): TModule;
  function GetModule: TModule;
  var
    I: Integer;
  begin
    for I := 0 to FModulesList.Count - 1 do
    begin
      Result := FModulesList[I];
      if Result.ModuleHandle = ModuleHandle then
        Exit;
    end;
    Result := nil;
  end;

begin
  if ModuleHandle = 0 then
    Exit(nil);

  Result := GetModule;
  if Assigned(Result) then
    Exit;

  TMonitor.Enter(GlobalLock);
  try
    { Try again => Maybe another thread had already registered the current module. }
    Result := GetModule;
    if Assigned(Result) then
      Exit;
    if RegisterNoExists then
      Result := AddModule(ModuleHandle);
  finally
    TMonitor.Exit(GlobalLock);
  end;
end;

{$ENDREGION 'DebugInfo'}

initialization

{$IFDEF DEVMODE}
  ReportMemoryLeaksOnShutdown := True;
{$ENDIF DEVMODE}
GlobalLock := TObject.Create;

finalization

if Assigned(GlobalLock) then
  GlobalLock.Free;

if Assigned(GlobalModules) then
  GlobalModules.Free;

end.
