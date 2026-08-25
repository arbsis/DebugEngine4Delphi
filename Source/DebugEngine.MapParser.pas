// **************************************************************************************************
// Delphi DebugEngine.
// Unit DebugEngine.MapParser
// https://github.com/MahdiSafsafi/DebugEngine

// The contents of this file are subject to the Mozilla Public License Version 1.1 (the "License");
// you may not use this file except in compliance with the License. You may obtain a copy of the
// License at http://www.mozilla.org/MPL/
//
// Software distributed under the License is distributed on an "AS IS" basis, WITHOUT WARRANTY OF
// ANY KIND, either express or implied. See the License for the specific language governing rights
// and limitations under the License.
//
// The Original Code is DebugEngine.MapParser.pas.
//
// The Initial Developer of the Original Code is Mahdi Safsafi.
// Portions created by Mahdi Safsafi . are Copyright (C) 2016-2019 Mahdi Safsafi.
// All Rights Reserved.
//
// **************************************************************************************************

{ Platform independent part of DebugEngine.DebugInfo:
  - Delphi text map parser (TCustomTxtMapParser).
  - Delphi map => SMAP converter (ConvertMapToSMap).
  - SMAP reader (TSMapReader) that resolves addresses to symbol/unit/line.
  This unit uses only System.* units so it can be shared by the Windows
  (DebugEngine.DebugInfo) and the Linux (DebugEngine.Linux.DebugInfo) implementations. }

unit DebugEngine.MapParser;

interface

uses
  System.SysUtils,
  System.Classes,
  System.ZLib,
  System.RegularExpressions;

const
  DelphiMapFileExtension = '.map';
  SMapFileExtension = '.smap';
  SMapResType = 'SMAP';
  SMapResName = 'Map';
  SMapSignature = $50414D53; { SMAP }
  SMapVersion = $01;

  SEGMENT_NAME_LENGTH = 8;

{$REGION 'MapTypes'}

type
  PSMapChar = PAnsiChar;
  SMapChar = AnsiChar;

  TMapNotification = (mnNone, mnSegments, mnUnits, mnPublicsByName, mnPublicsByValue, mnLineLocations);

  { SMap options }
  TSMapOptions = set of (moCompress);
  {
    moCompress => Compress (ZIP) smap data.
  }

  { TMapLocation }
  TMapLocation = (mlNone, mlSection, mlResource, mlDisk);

  {
    - mlNone = There is no map associated with module.
    - mlSection = Map was inserted into SDEBUG section.
    - mlResource = Map was inserted into PE resource.
    - mlDisk = Remote map (Delphi map) found next the PE.

  }

  { TSMapHeader }
  TSMapHeader = packed record
    Signature: Cardinal; // SMAP signature.
    Version: Byte; // SMAP version.
    Flags: Cardinal; // SMAP options/flags.
    Size: Cardinal; // Size of smap file without counting align block.
    cSize: Cardinal; // Size of compressed smap file.
    NumberOfSegments: Byte; // Number of segments.
    NumberOfUnits: Word; // Number of units.
    NumberOfSymbols: Cardinal; // Number of Symbols.
    NumberOfSourceLocations: Word; // Number of source locations.
    OffsetToUnits: Cardinal; // Offset from header to first unit struct (TSMapUnit).
    OffsetToSymbols: Cardinal; // Offset from header to first symbol struct (TSMapSymbol).
    OffsetToSourceLocations: Cardinal; // Offset from header to first source location struct (TSMapSourceLocation).
  end;

  PSMapHeader = ^TSMapHeader;

  TSMapSegment = packed record
    SegId: Byte; // Segment id.
    SegStartAddress: Cardinal; // Segment start offset.
    SegLength: Cardinal; // Segment SegLength.
    SegName: array [0 .. SEGMENT_NAME_LENGTH - 1] of SMapChar; // Segment name.
  end;

  PSMapSegment = ^TSMapSegment;

  TSMapUnit = packed record
    UnitSegId: Byte; // Segment id.
    UnitOffset: Cardinal; // Unit offset start address.
    UnitLength: Cardinal; // Unit SegLength.
    UnitNameLength: Word; // Unit name SegLength.
    { Unit name follows TSMapUnit struct }
    { Next unit = ThisUnit + (SizeOf(TSMapUnit) + UnitNameLength). }
    UnitName: array [0 .. 0] of SMapChar; // Unit name.
  end;

  PSMapUnit = ^TSMapUnit;

  TSMapSymbol = packed record
    SymbolSegId: Byte;
    SymbolOffset: Cardinal;
    SymbolNameLength: Word;
    SymbolName: array [0 .. 0] of SMapChar;
  end;

  PSMapSymbol = ^TSMapSymbol;

  TSMapSourceLocation = packed record
    SegId: Byte;
    NumberOfLineNumbers: Word;
    SourceLocationLength: Word;
    SourceLocation: array [0 .. 0] of SMapChar;
  end;

  PSMapSourceLocation = ^TSMapSourceLocation;

  TSMapLineNumber = packed record
    Offset: Cardinal;
    LineNumber: Cardinal;
  end;

  PSMapLineNumber = ^TSMapLineNumber;

  TRuntimeSegment = record
    SegId: Cardinal;
    SegStartAddress: Pointer;
    SegEndAddress: Pointer;
    SegLength: Cardinal;
  end;

  PRuntimeSegment = ^TRuntimeSegment;

  TLineNumberSource = record
    Line: PSMapLineNumber;
    Source: PSMapSourceLocation;
  end;

  PLineNumberSource = ^TLineNumberSource;

{$ENDREGION 'MapTypes'}

  TAddressInfoMask = (
    { aimNone = No mask will be applied.
      GetAddressInfo function will query all info :
      - SymbolAddress.
      - SymbolName.
      - UnitName.
      - DebugSource.
      - LineNumber.
      - SourceLocation.
    }
    aimNone,

    { aimAddress = GetAddressInfo function will query only :
      - SymbolAddress.
      - DebugSource.
    }
    aimAddress,

    { aimSymbolName =  GetAddressInfo function will query only :
      - SymbolAddress.
      - SymbolName.
      - UnitName.
      - DebugSource.
    }
    aimSymbolName);

  /// <summary> Platform independent address information resolved from a SMAP. </summary>
  TSMapAddressInfo = record
    SymbolAddress: Pointer;
    LineNumber: Cardinal;
    SymbolName: string;
    UnitName: string;
    SourceLocation: string;
    SymbolIndex: Integer;
  end;

  PSMapAddressInfo = ^TSMapAddressInfo;

  /// <summary> Callback used by <see cref="TSMapReader"/> to translate a map segment into
  /// a run time address. Return False to drop the segment. </summary>
  TSMapResolveSegmentEvent = reference to function(SegId: Integer; const SegName: string; SegStartAddress: NativeUInt; SegLength: Cardinal;
    out RtStartAddress: Pointer): Boolean;

  TCustomTxtMapParser = class(TObject)
  private
    FLines: TStringList;
  protected
    /// <summary> Get notified when <see cref="Parse"/> function is about to process a new region.
    /// </summary>
    /// <returns>
    /// Return <c>True</c> to keep processing actual region.
    /// <para></para>
    /// Return <c>False</c> to exclude actual region.
    /// </returns>
    /// <remarks> This function must be implemented in all descendants class.
    /// </remarks>
    function Notify(Notification: TMapNotification): Boolean; virtual; abstract;
    procedure ProcessSegment(SegId: Integer; SegOffset: Cardinal; SegLength: Cardinal; const SegName, SegClass: string); virtual; abstract;
    procedure ProcessUnit(SegId: Integer; UnitOffset: Cardinal; UnitLength: Cardinal; const SegClass, SegName, Group, UnitName: string; ACBP, ALIGN: Integer); virtual; abstract;
    procedure ProcessPublicsByName(SegId: Integer; SymbolOffset: Cardinal; const SymbolName: string); virtual; abstract;
    procedure ProcessPublicsByValue(SegId: Integer; SymbolOffset: Cardinal; const SymbolName: string); virtual; abstract;
    procedure ProcessLocation(const UnitName, Source, SegmentName: string); virtual; abstract;
    procedure ProcessLine(LineNumber, SegId, Offset: Integer); virtual; abstract;
  public
    /// <summary> Start parsing map file.
    /// </summary>
    function Parse: Boolean;
    constructor Create(const MapFileName: string); virtual;
    destructor Destroy; override;
  end;

  /// <summary> SMAP reader: loads a SMAP (compressed or not) and resolves addresses. </summary>
  TSMapReader = class(TObject)
  private
    FMapStream: TMemoryStream;
    FRTSegments: TList;
    FUnits: TList;
    FSymbols: TList;
    FLineSources: TList;
    FOnResolveSegment: TSMapResolveSegmentEvent;
    function GetRTSegmentFromSegIndex(SegIndex: Integer): PRuntimeSegment;
    function GetRTSegmentFromAddress(Address: Pointer): PRuntimeSegment;
    function GetUnit(Address: Pointer; PRtSeg: PRuntimeSegment): PSMapUnit;
    function GetLineNumberSource(Address: Pointer; PRtSeg: PRuntimeSegment): PLineNumberSource;
    function GetSymbolCount: Integer;
    function GetSegmentCount: Integer;
    function GetRTSegment(Index: Integer): PRuntimeSegment;
  protected
    procedure Clear;
    function UnZip: Boolean;
    function ProcessMap: Boolean;
  public
    function LoadFromStream(Stream: TStream): Boolean;
    function LoadFromFile(const MapFileName: string): Boolean;
    function GetAddressInfo(Address: Pointer; out Info: TSMapAddressInfo; Mask: TAddressInfoMask): Boolean;
    function GetSymbolAddress(const UnitName, SymbolName: string): Pointer;
    function GetAddressFromIndex(Index: Integer): Pointer;
    constructor Create(const AOnResolveSegment: TSMapResolveSegmentEvent); virtual;
    destructor Destroy; override;
    property MapStream: TMemoryStream read FMapStream;
    property SymbolCount: Integer read GetSymbolCount;
    property SegmentCount: Integer read GetSegmentCount;
    property RTSegments[Index: Integer]: PRuntimeSegment read GetRTSegment;
  end;

{$REGION 'PublicFunctions'}

  /// <summary>  Convert Delphi map file to SMAP file format.
  /// </summary>
  /// <param name="MapFile"> Delphi map file name.
  /// </param>
  /// <param name="Options"> See
  /// <see cref="TSMapOptions" />
  /// </param>
  /// <returns> If the function succeeds, the return value is the converted map file (smap) size.
  /// <para></para>
  /// If the function fails, the return value is zero.
  /// </returns>
  /// <remarks> The converted map (SMAP) file will exist in the same MapFile folder.
  /// </remarks>
function ConvertMapToSMap(const MapFile: string; const Options: TSMapOptions = [moCompress]): Integer; overload;

/// <summary>  Convert Delphi map data to SMAP data format.
/// </summary>
/// <param name="SrcPtr"> Pointer to a buffer that holds Delphi map data.
/// </param>
/// <param name="DstPtr"> Pointer to a buffer that will hold converted map.
/// </param>
/// <param name="Options"> See
/// <see cref="TSMapOptions" />
/// </param>
/// <returns> If the function succeeds, the return value is the converted map data (smap) size.
/// <para></para>
/// If the function fails, the return value is zero.
/// </returns>
/// <remarks> It's true that the smap size will be less than the original map size.
/// However, it's recommended to set DstPtr size equal to the SrcPtr size.
/// </remarks>
function ConvertMapToSMap(const SrcPtr, DstPtr: Pointer; Options: TSMapOptions): Integer; overload;

/// <summary> Convert Delphi map data to SMAP data format.
/// </summary>
/// <param name="SrcStream"> Memory stream that holds Delphi map data.
/// </param>
/// <param name="DstStream"> Memory stream that will hold converted map data.
/// </param>
/// <param name="Options"> See
/// <see cref="TSMapOptions" />
/// </param>
/// <returns> If the function succeeds, the return value is the converted map data (smap) size.
/// <para></para>
/// If the function fails, the return value is zero.
/// </returns>
/// <remarks> The function sets DstStream size to the result.
/// </remarks>
function ConvertMapToSMap(SrcStream, DstStream: TMemoryStream; Options: TSMapOptions): Integer; overload;

function ALIGN(Value, Alignment: Cardinal): Cardinal;
function IsAddressInRange(Address: Pointer; const SegStartAddress, SegEndAddress: Pointer): Boolean;
function MapLocationToStr(Location: TMapLocation): string;
function SMapOptionsToRaw(const Options): Cardinal;
function RawToSMapOptions(Options: Cardinal): TSMapOptions;
function SMapCharsToStr(P: PSMapChar; MaxLength: Integer): string;

{$ENDREGION 'PublicFunctions'}

implementation

{$B-}   // Force B-!
{$REGION 'GLOBAL'}
const

  { Regular expressions patterns used by TCustomTxtMapParser }

  HintSegmentRegExPattern = '^\s*Start\s+Length\s+Name\s+Class\s*$';
  HintUnitRegExPattern = '^\s*Detailed\smap\sof\ssegments\s*$';
  HintPublicsByNameRegExPattern = '^\s*Address\s+Publics\s+by\s+Name\s*$';
  HintPublicsByValueRegExPattern = '^\s*Address\s+Publics\s+by\s+Value\s*$';

  SegmentRegExPattern = '^\s(\d{4}):([0-9A-F]{8})\s([0-9A-F]{8})H\s(\.\w+)\s+(\w+)$';
  UnitRegExPattern = '^\s(\d{4}):([0-9A-F]{8})\s([0-9A-F]{8})\sC=(\w+)\s+S=(\.\w+)\s+G=\(*(\w+)\)*\s+M=(\S+)(?:\s+(ALIGN|ACBP)=(\w+))*\s*$';
  SymbolRegExPattern = '^\s(\d{4}):([0-9A-F]{8})\s+(.+)$';
  LocationRegExPattern = '^\s*^Line\snumbers\sfor\s(.+?)\((.+?)\)\ssegment\s+(\.\w+)\s*$';
  LineRegExPattern = '\s+(\d+)\s(\d{4}):([0-9A-F]{8})';

var
  RegxLock: TObject = nil;
  RegularExpressionsCompiled: Boolean = False;

  { Hint Regular expressions for TCustomTxtMapParser parser. }
  HintSegmentRegEx: TRegEx;
  HintUnitRegEx: TRegEx;
  HintPublicsByNameRegEx: TRegEx;
  HintPublicsByValueRegEx: TRegEx;

  { Regular expressions for TCustomTxtMapParser parser. }
  SegmentRegEx: TRegEx;
  UnitRegEx: TRegEx;
  SymbolRegEx: TRegEx;
  LocationRegEx: TRegEx;
  LineRegEx: TRegEx;

procedure CompileRegularExpressions;
begin
  if RegularExpressionsCompiled then
    Exit;

  HintSegmentRegEx := TRegEx.Create(HintSegmentRegExPattern, [roCompiled, roSingleLine, roIgnoreCase]);
  HintUnitRegEx := TRegEx.Create(HintUnitRegExPattern, [roCompiled, roSingleLine, roIgnoreCase]);
  HintPublicsByNameRegEx := TRegEx.Create(HintPublicsByNameRegExPattern, [roCompiled, roSingleLine, roIgnoreCase]);
  HintPublicsByValueRegEx := TRegEx.Create(HintPublicsByValueRegExPattern, [roCompiled, roSingleLine, roIgnoreCase]);

  SegmentRegEx := TRegEx.Create(SegmentRegExPattern, [roCompiled, roSingleLine]);
  UnitRegEx := TRegEx.Create(UnitRegExPattern, [roCompiled, roSingleLine]);
  SymbolRegEx := TRegEx.Create(SymbolRegExPattern, [roCompiled, roSingleLine]);
  LocationRegEx := TRegEx.Create(LocationRegExPattern, [roCompiled, roSingleLine]);
  LineRegEx := TRegEx.Create(LineRegExPattern, [roCompiled, roSingleLine]);

  RegularExpressionsCompiled := True;
end;

procedure NeedCompiledRegularExpressions;
begin
  if RegularExpressionsCompiled then
    Exit; // No need to enter the lock.
  TMonitor.Enter(RegxLock);
  try
    CompileRegularExpressions;
  finally
    TMonitor.Exit(RegxLock);
  end;
end;

{$ENDREGION 'GLOBAL'}
{$REGION 'Misc'}

function MapLocationToStr(Location: TMapLocation): string;
begin
  Result := EmptyStr;
  case Location of
    mlSection: Result := 'Section';
    mlResource: Result := 'Resource';
    mlDisk: Result := 'Disk'
  else Result := 'none';
  end;
end;

function ALIGN(Value, Alignment: Cardinal): Cardinal;
begin
  Result := Value;
  if Value mod Alignment = 0 then
    Exit;
  Result := (Result + Alignment - 1) div Alignment * Alignment;
end;

function IsAddressInRange(Address: Pointer; const SegStartAddress, SegEndAddress: Pointer): Boolean;
begin
  Result := (NativeUInt(Address) >= NativeUInt(SegStartAddress)) and (NativeUInt(Address) < NativeUInt(SegEndAddress));
end;

function SMapOptionsToRaw(const Options): Cardinal;
begin
  { Convert SMapOptions type to a raw dword value. }

{$IF SizeOf(TSMapOptions) = 1}
  Result := PByte(@Options)^;
{$ELSEIF SizeOf(TSMapOptions) = 2}
  Result := PWord(@Options)^;
{$ELSEIF SizeOf(TSMapOptions) = 4}
  Result := PCardinal(@Options)^;
{$ELSE}
{$MESSAGE Fatal 'Error size of TSMapOptions > 4 bytes.'}
{$ENDIF}
end;

function RawToSMapOptions(Options: Cardinal): TSMapOptions;
begin
  { Convert a raw dword type to SMapOptions. }

{$IF SizeOf(TSMapOptions) = 1}
  PByte(@Result)^ := Byte(Options);
{$ELSEIF SizeOf(TSMapOptions) = 2}
  PWord(@Result)^ := Word(Options);
{$ELSEIF SizeOf(TSMapOptions) = 4}
  PCardinal(@Result)^ := Options;
{$ELSE}
{$MESSAGE Fatal 'Error size of TSMapOptions > 4 bytes.'}
{$ENDIF}
end;

function SMapCharsToStr(P: PSMapChar; MaxLength: Integer): string;
var
  L: Integer;
  S: AnsiString;
begin
  L := 0;
  while (L < MaxLength) and (P[L] <> #0) do
    Inc(L);
  SetString(S, P, L);
  Result := string(S);
end;

{$ENDREGION 'Misc'}
{$REGION 'MapParser'}
{ TCustomTxtMapParser }

constructor TCustomTxtMapParser.Create(const MapFileName: string);
begin
  FLines := TStringList.Create;
  if FileExists(MapFileName) then
    FLines.LoadFromFile(MapFileName);
end;

destructor TCustomTxtMapParser.Destroy;
begin
  FLines.Free;
  inherited;
end;

function TCustomTxtMapParser.Parse: Boolean;
var
  I: Integer;
  S: string;
  Match: TMatch;
  Notification: TMapNotification;
  ALIGN: Integer;
  ACBP: Integer;
  Matches: TMatchCollection;
  KeepProcess: Boolean;
label ProcessSegmentsLabel;
label ProcessUnitsLabel;
label ProcessPublicsByNameLabel;
label ProcessPublicsByValueLabel;
label ProcessLineLocationsLabel;

begin
  Result := FLines.Count > 0;
  if not Result then
    Exit;

  NeedCompiledRegularExpressions;

  Notification := mnNone;
  KeepProcess := False;
  for I := 0 to FLines.Count - 1 do
  begin
    S := FLines[I];
    if S.Trim.IsEmpty then
      Continue; // KeepProcess Next valid line.

    case Notification of
      mnSegments: goto ProcessSegmentsLabel;
      mnUnits: goto ProcessUnitsLabel;
      mnPublicsByName: goto ProcessPublicsByNameLabel;
      mnPublicsByValue: goto ProcessPublicsByValueLabel;
      mnLineLocations: goto ProcessLineLocationsLabel;
    end;

    Match := HintSegmentRegEx.Match(S);
    if Match.Success then
    begin
      KeepProcess := Notify(mnSegments);
      Notification := mnSegments;
    end;
    Continue;
  ProcessSegmentsLabel: // Process Segments.
    if KeepProcess then
    begin
      Match := SegmentRegEx.Match(S);
      if Match.Success then
      begin
        with Match do
          ProcessSegment(StrToInt(Groups[1].Value), StrToInt('$' + Groups[2].Value), StrToInt('$' + Groups[3].Value), Groups[4].Value, Groups[5].Value);
        Continue;
      end;
    end;
    Match := HintUnitRegEx.Match(S);
    if Match.Success then
    begin
      KeepProcess := Notify(mnUnits);
      Notification := mnUnits;
    end;
    Continue;

  ProcessUnitsLabel: // Process Units.
    if KeepProcess then
    begin
      Match := UnitRegEx.Match(S);
      if Match.Success then
      begin
        ALIGN := 0;
        ACBP := 0;
        with Match do
        begin
          if Groups.Count > 8 then
          begin
            if SameText(Groups[8].Value, 'ALIGN') then
              ALIGN := StrToInt('$' + Groups[9].Value)
            else if SameText(Groups[8].Value, 'ACBP') then
              ACBP := StrToInt('$' + Groups[9].Value);
          end;
          ProcessUnit(StrToInt(Groups[1].Value), StrToInt('$' + Groups[2].Value), StrToInt('$' + Groups[3].Value), Groups[4].Value, Groups[5].Value, Groups[6].Value, Groups[7].Value, ACBP, ALIGN);
        end;
        Continue;
      end;
    end;
    Match := HintPublicsByNameRegEx.Match(S);
    if Match.Success then
    begin
      KeepProcess := Notify(mnPublicsByName);
      Notification := mnPublicsByName;
    end;
    Continue;

  ProcessPublicsByNameLabel: // Process publics by name.
    if KeepProcess then
    begin
      Match := SymbolRegEx.Match(S);
      if Match.Success then
      begin
        with Match do
          ProcessPublicsByName(StrToInt(Groups[1].Value), StrToInt('$' + Groups[2].Value), Groups[3].Value);
        Continue;
      end;
    end;
    Match := HintPublicsByValueRegEx.Match(S);
    if Match.Success then
    begin
      KeepProcess := Notify(mnPublicsByValue);
      Notification := mnPublicsByValue;
    end;
    Continue;

  ProcessPublicsByValueLabel: // Process publics by value.
    if KeepProcess then
    begin
      Match := SymbolRegEx.Match(S);
      if Match.Success then
      begin
        with Match do
          ProcessPublicsByValue(StrToInt(Groups[1].Value), StrToInt('$' + Groups[2].Value), Groups[3].Value);
        Continue;
      end;
    end;

  ProcessLineLocationsLabel: // Process line locations.
    if (Notification = mnLineLocations) and not KeepProcess then
      Continue;
    Match := LocationRegEx.Match(S);
    if Match.Success then
    begin
      if Notification <> mnLineLocations then
      begin
        KeepProcess := Notify(mnLineLocations);
        Notification := mnLineLocations;
      end;
      if not KeepProcess then
        Continue;
      with Match do
        ProcessLocation(Groups[1].Value, Groups[2].Value, Groups[3].Value);
      Continue;
    end;
    Matches := LineRegEx.Matches(S);
    if Matches.Count > 0 then
    begin
      for Match in Matches do
      begin
        with Match do
          ProcessLine(StrToInt(Groups[1].Value), StrToInt(Groups[2].Value), StrToInt('$' + Groups[3].Value));
      end;
    end;
  end;

end;
{$ENDREGION 'MapParser'}
{$REGION 'MapConverter'}

const
  HintArrayLength = 4;
  HintArrayCharsLength = 8;
  MAX_SEGMENTS = 31;
  MAX_SEGMENT_UNITS = 10000;

type
  THintArray = array [0 .. HintArrayLength - 1] of array [0 .. HintArrayCharsLength - 1] of SMapChar;

  { ==> First item is used as a cashe <==
    ==> Last item is used as segment's units count and not PSMapUnit !!! <== }
  TSegmentsUnits = array [0 .. MAX_SEGMENTS - 1] of array [0 .. MAX_SEGMENT_UNITS] of PSMapUnit;
  PSegmentsUnits = ^TSegmentsUnits;

const
  CharToHexArray: array [SMapChar] of ShortInt = ( //
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, //
    $00, $01, $02, $03, $04, $05, $06, $07, $08, $09, //
    -1, -1, -1, -1, -1, -1, -1, //
    $0A, $0B, $0C, $0D, $0E, $0F, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, $0A, $0B, $0C, $0D, $0E, $0F, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1);

  HintSegArray: THintArray = ('Start', 'Length', 'Name', 'Class');
  HintUnitArray: THintArray = ('Detailed', 'map', 'of', 'segments');
  HintPublicsByValueArray: THintArray = ('Address', 'Publics', 'by', 'Value');
  HintLineNumbersArray: THintArray = ('Line', 'numbers', 'for', '');

function ConvertMapToSMap(const SrcPtr, DstPtr: Pointer; Options: TSMapOptions): Integer;
var
  LCurrPos: PSMapChar;
  PSegsUnits: PSegmentsUnits;
{$REGION 'LocalFunctions'}
  procedure NextBeginOfLine;
  begin
    while not(LCurrPos^ in [#00, #10, #13]) do
      Inc(LCurrPos);
    while LCurrPos^ in [#00, #10, #13, ' '] do
      Inc(LCurrPos);
  end;

  function ReadDecValue: Integer;
  begin
    Result := 0;
    while PByte(LCurrPos)^ in [$30 .. $39] do
    begin
      Result := (Result * 10) + (PByte(LCurrPos)^ - $30);
      Inc(LCurrPos);
    end;
  end;

  function ReadHexValue: Cardinal;
  var
    L: ShortInt;
  begin
    Result := 0;
    while True do
    begin
      L := CharToHexArray[LCurrPos^];
      if L = -1 then
        Break;
      Result := (Result shl $04) or Byte(L);
      Inc(LCurrPos);
    end;
  end;

  function ReachedHint(const HintArray: THintArray): Boolean;
  var
    I: Integer;
    J: Integer;
    C: SMapChar;
    P: PSMapChar;
  begin
    P := LCurrPos;
    for I := 0 to HintArrayLength - 1 do
    begin
      while P^ = ' ' do
        Inc(P);
      for J := 0 to HintArrayCharsLength - 1 do
      begin
        C := HintArray[I][J];
        if (C = #00) then
          Break;
        if (C <> P^) then
          Exit(False);
        Inc(P);
      end;
    end;
    Result := True;
  end;

  function GetUnit(Seg: Integer; Offset: Cardinal): PSMapUnit;
  var
    n: Integer;
    I: Integer;
  begin
    n := Integer(PSegsUnits^[Seg][MAX_SEGMENT_UNITS]);
    Assert(n and $FFFF0000 = $00000000);
    for I := 0 to n do
    begin
      Result := PSegsUnits^[Seg][I];
      if not Assigned(Result) then
        Continue;
      with Result^ do
        if (Offset >= UnitOffset) and (Offset < UnitOffset + UnitLength) then
        begin
          PSegsUnits^[Seg][0] := Result; // Cashe this unit.
          Exit;
        end;
    end;
    Result := nil;
  end;

{$ENDREGION 'LocalFunctions'}

{ TODO: exit if ReachedHint returns False. }
var
  PHeader: PSMapHeader;
  PTmpHeader: PSMapHeader;
  PSegment: PSMapSegment;
  PUnit: PSMapUnit;
  PSymbol: PSMapSymbol;
  PSrc: PSMapSourceLocation;
  PLine: PSMapLineNumber;
  L: Integer;
  Buffer: Pointer;
begin
  Result := 0;

  LCurrPos := SrcPtr;
  PHeader := DstPtr;
  PSegsUnits := AllocMem(SizeOf(TSegmentsUnits));

  with PHeader^ do
  begin
    Signature := SMapSignature;
    Version := SMapVersion;
    Flags := SMapOptionsToRaw(Options);
  end;
  PSegment := PSMapSegment(PByte(PHeader) + SizeOf(TSMapHeader));
  // First segment.

  { Initialize datas and make the compiler happy :) }
  PUnit := nil;
  // PSymbol := nil;
  PLine := nil;

  NextBeginOfLine;
  if ReachedHint(HintSegArray) then
  begin
    NextBeginOfLine;
    repeat
      Inc(PHeader^.NumberOfSegments);
      with PSegment^ do
      begin
        SegId := ReadDecValue;
        Inc(LCurrPos); // Skip ":".
        SegStartAddress := ReadHexValue;
        while (LCurrPos^ = ' ') do
          Inc(LCurrPos);
        SegLength := ReadHexValue;
        while (LCurrPos^ <> '.') do
          // Go to segment name.
          Inc(LCurrPos);
        L := 0;
        while (LCurrPos^ <> ' ') do
        begin
          SegName[L] := LCurrPos^;
          Inc(L);
          Inc(LCurrPos);
        end;
      end;
      Inc(PSegment); // Next segment.
      NextBeginOfLine;
    until LCurrPos^ <> '0';
  end;
  if ReachedHint(HintUnitArray) then
  begin
    NextBeginOfLine;
    PUnit := PSMapUnit(PSegment);
    PHeader^.OffsetToUnits := Cardinal(NativeUInt(PUnit) - NativeUInt(PHeader));

    while LCurrPos^ = '0' do
    begin
      Inc(PHeader^.NumberOfUnits);
      with PUnit^ do
      begin
        UnitSegId := ReadDecValue;
        L := Integer(PSegsUnits^[UnitSegId][MAX_SEGMENT_UNITS]);
        PSegsUnits^[UnitSegId][MAX_SEGMENT_UNITS] := Pointer(L + 1);
        PSegsUnits^[UnitSegId][L] := PUnit;
        Inc(LCurrPos); // Skip ":".
        UnitOffset := ReadHexValue;
        while LCurrPos^ = ' ' do
          Inc(LCurrPos);
        UnitLength := ReadHexValue;
        { Go to unit name. }
        while not((LCurrPos^ = ' ') and ((LCurrPos + 1)^ = 'M') and ((LCurrPos + 2)^ = '=')) do
          Inc(LCurrPos);
        Inc(LCurrPos, 3); // Skip " M=".
        L := 0;
        while not((LCurrPos + L)^ in [' ', #13, #10]) do
          Inc(L); // Unit name SegLength.
        Move(LCurrPos^, Pointer(@UnitName[0])^, L);
        UnitNameLength := L;
      end;
      NextBeginOfLine;
      Inc(PUnit);
      Inc(PByte(PUnit), L);
    end;
  end;

  repeat
    NextBeginOfLine;
    { Limit ReachedHint call ! }
    while LCurrPos^ <> 'A' do
      NextBeginOfLine;
  until ReachedHint(HintPublicsByValueArray);

  NextBeginOfLine;
  PSymbol := PSMapSymbol(PUnit);
  PHeader^.OffsetToSymbols := Cardinal(NativeUInt(PSymbol) - NativeUInt(PHeader));
  while LCurrPos^ = '0' do
  begin
    Inc(PHeader^.NumberOfSymbols);
    with PSymbol^ do
    begin
      SymbolSegId := ReadDecValue;
      Inc(LCurrPos); // Skip":".
      SymbolOffset := ReadHexValue;
      while LCurrPos^ = ' ' do
        Inc(LCurrPos);
      PUnit := GetUnit(SymbolSegId, SymbolOffset);

      L := 0;
      while not((LCurrPos + L)^ in [' ', #13, #10]) do
        Inc(L);
      if Assigned(PUnit) then
        with PUnit^ do
        begin
          Inc(LCurrPos, UnitNameLength + 1);
          Dec(L, UnitNameLength + 1);
        end;
      Move(LCurrPos^, Pointer(@SymbolName[0])^, L);
      SymbolNameLength := L;
    end;
    NextBeginOfLine;
    Inc(PSymbol);
    Inc(PByte(PSymbol), L);
  end;

  PSrc := PSMapSourceLocation(PSymbol);
  PHeader^.OffsetToSourceLocations := Cardinal(NativeUInt(PSrc) - NativeUInt(PHeader));
  { Maps linked without debug information have no "Line numbers for" sections: the end of the
    SMAP is then the end of the symbols (PLine must not stay nil). }
  PLine := PSMapLineNumber(PSrc);

  while (LCurrPos^ = 'L') // Limit ReachedHint call !
    and (ReachedHint(HintLineNumbersArray)) do
  begin
    Inc(PHeader^.NumberOfSourceLocations);
    while LCurrPos^ <> '(' do
      Inc(LCurrPos);
    Inc(LCurrPos);
    L := 0;
    while (LCurrPos + L)^ <> ')' do
      Inc(L);
    Move(LCurrPos^, Pointer(@PSrc^.SourceLocation[0])^, L);
    Inc(LCurrPos, L);
    PSrc^.SourceLocationLength := L;

    PLine := PSMapLineNumber(PByte(PSrc) + SizeOf(TSMapSourceLocation) + L);
    NextBeginOfLine;
    while LCurrPos^ in ['0' .. '9'] do
    begin
      Inc(PSrc^.NumberOfLineNumbers);
      with PLine^ do
      begin
        LineNumber := ReadDecValue;
        while LCurrPos^ = ' ' do
          Inc(LCurrPos);
        PSrc^.SegId := ReadDecValue;
        Inc(LCurrPos); // Skip ":"
        Offset := ReadHexValue;
      end;
      Inc(PLine);
      while LCurrPos^ = ' ' do
        Inc(LCurrPos);
      if LCurrPos^ in [#13, #10] then
        NextBeginOfLine;
    end;
    PSrc := PSMapSourceLocation(PLine);
  end;
  FreeMem(PSegsUnits);
  PTmpHeader := PHeader;
  { Skip header => We don't want to compress smap header. }
  Inc(PHeader);
  { Calculate new smap size before compression. }
  Result := Integer(NativeUInt(PLine) - NativeUInt(PHeader));
  PTmpHeader^.Size := Result + SizeOf(TSMapHeader);
  if moCompress in Options then
  begin
    { Compress smap. }
    System.ZLib.ZCompress(PHeader, Result, Buffer, Result);
    { Copy compressed data to smap. }
    Move(Buffer^, PHeader^, Result);
    FreeMem(Buffer);
  end;
  { Set size of compressed smap. }
  Inc(Result, SizeOf(TSMapHeader));
  PTmpHeader^.cSize := Result;
  { Align size => Result is always 4 bytes aligned. }
  Result := ((Result + 3) div 4) * 4;
end;


function ConvertMapToSMap(const MapFile: string; const Options: TSMapOptions = [moCompress]): Integer;
var
  SrcStream: TMemoryStream;
  DstStream: TMemoryStream;
begin
  Result := 0;
  if not FileExists(MapFile) then
    Exit;
  SrcStream := TMemoryStream.Create;
  DstStream := TMemoryStream.Create;
  try
    SrcStream.LoadFromFile(MapFile);
    if SrcStream.Size = 0 then
      Exit;
    { Make sure the source buffer is null terminated: the converter scans until #0. }
    SrcStream.Size := SrcStream.Size + 1;
    PByte(SrcStream.Memory)[SrcStream.Size - 1] := 0;
    Result := ConvertMapToSMap(SrcStream, DstStream, Options);
    if Result > 0 then
      DstStream.SaveToFile(ChangeFileExt(MapFile, SMapFileExtension));
  finally
    SrcStream.Free;
    DstStream.Free;
  end;
end;

function ConvertMapToSMap(SrcStream, DstStream: TMemoryStream; Options: TSMapOptions): Integer;
begin
  if (not Assigned(SrcStream)) or (not Assigned(DstStream)) then
    Exit(0);
  if DstStream.Size < SrcStream.Size then
    DstStream.SetSize(SrcStream.Size);
  Result := ConvertMapToSMap(SrcStream.Memory, DstStream.Memory, Options);
  DstStream.SetSize(Result);
  DstStream.Seek(0, soEnd);
end;

{$ENDREGION 'MapConverter'}

{$REGION 'SMapReader'}
{ TSMapReader }

function LineSortCompare(Item1, Item2: Pointer): Integer;
begin
  Result := NativeUInt(PLineNumberSource(Item1)^.Source^.SegId) - NativeUInt(PLineNumberSource(Item2)^.Source^.SegId);
  if Result = 0 then
    Result := NativeUInt(PLineNumberSource(Item1)^.Line^.Offset) - NativeUInt(PLineNumberSource(Item2)^.Line^.Offset);
end;

constructor TSMapReader.Create(const AOnResolveSegment: TSMapResolveSegmentEvent);
begin
  inherited Create;
  FOnResolveSegment := AOnResolveSegment;
  FMapStream := TMemoryStream.Create;
  FRTSegments := TList.Create;
  FUnits := TList.Create;
  FSymbols := TList.Create;
  FLineSources := TList.Create;
end;

destructor TSMapReader.Destroy;
begin
  Clear;
  FRTSegments.Free;
  FUnits.Free;
  FSymbols.Free;
  FLineSources.Free;
  FMapStream.Free;
  inherited;
end;

procedure TSMapReader.Clear;
var
  I: Integer;
begin
  for I := 0 to FRTSegments.Count - 1 do
    if Assigned(FRTSegments[I]) then
      FreeMem(FRTSegments[I]);
  for I := 0 to FLineSources.Count - 1 do
    if Assigned(FLineSources[I]) then
      Dispose(PLineNumberSource(FLineSources[I]));
  FRTSegments.Clear;
  FUnits.Clear;
  FSymbols.Clear;
  FLineSources.Clear;
  FMapStream.Clear;
end;

function TSMapReader.GetSymbolCount: Integer;
begin
  Result := FSymbols.Count;
end;

function TSMapReader.GetSegmentCount: Integer;
begin
  Result := FRTSegments.Count;
end;

function TSMapReader.GetRTSegment(Index: Integer): PRuntimeSegment;
begin
  Result := FRTSegments[Index];
end;

function TSMapReader.LoadFromFile(const MapFileName: string): Boolean;
var
  LStream: TFileStream;
begin
  Result := FileExists(MapFileName);
  if Result then
  begin
    LStream := TFileStream.Create(MapFileName, fmOpenRead or fmShareDenyWrite);
    try
      Result := LoadFromStream(LStream);
    finally
      LStream.Free;
    end;
  end;
end;

function TSMapReader.LoadFromStream(Stream: TStream): Boolean;
begin
  Clear;
  FMapStream.LoadFromStream(Stream);
  Result := FMapStream.Size > SizeOf(TSMapHeader);
  if Result then
    Result := ProcessMap;
end;

function TSMapReader.GetAddressFromIndex(Index: Integer): Pointer;
var
  PSymbol: PSMapSymbol;
  PRtSegment: PRuntimeSegment;
begin
  if (Index > -1) and (Index < FSymbols.Count) then
  begin
    PSymbol := FSymbols[Index];
    PRtSegment := GetRTSegmentFromSegIndex(PSymbol^.SymbolSegId);
    if not Assigned(PRtSegment) then
      Exit(nil);
    Result := Pointer(NativeUInt(PRtSegment^.SegStartAddress) + PSymbol^.SymbolOffset);
    Exit;
  end;
  Result := nil;
end;

function TSMapReader.GetAddressInfo(Address: Pointer; out Info: TSMapAddressInfo; Mask: TAddressInfoMask): Boolean;
var
  PRtSeg: PRuntimeSegment;
  PSymbol: PSMapSymbol;
  PUnit: PSMapUnit;
  PLineSource: PLineNumberSource;
  PSourceLocation: PSMapSourceLocation;
  SymbolAddress: Pointer;
  I: Integer;
begin
  Result := False;
  PRtSeg := GetRTSegmentFromAddress(Address);
  if not Assigned(PRtSeg) then
    Exit;
  for I := FSymbols.Count - 1 downto 0 do
  begin
    PSymbol := FSymbols[I];
    if PSymbol^.SymbolSegId = PRtSeg^.SegId then
    begin
      SymbolAddress := Pointer(PByte(PRtSeg^.SegStartAddress) + PSymbol^.SymbolOffset);
      if (NativeUInt(SymbolAddress) < NativeUInt(PRtSeg^.SegEndAddress)) and (NativeUInt(Address) >= NativeUInt(SymbolAddress)) then
      begin
        Result := True;
        FillChar(Info, SizeOf(Info), #00);
        Info.SymbolAddress := SymbolAddress;
        Info.SymbolIndex := I;
        if Mask = aimAddress then
          Exit;
        Info.SymbolName := string(PSMapChar(@PSymbol^.SymbolName[0]));
        SetLength(Info.SymbolName, PSymbol^.SymbolNameLength);
        PUnit := GetUnit(SymbolAddress, PRtSeg);
        if Assigned(PUnit) then
        begin
          Info.UnitName := string(PSMapChar(@PUnit^.UnitName[0]));
          SetLength(Info.UnitName, PUnit^.UnitNameLength);
        end;
        if Mask = aimSymbolName then
          Exit;
        PLineSource := GetLineNumberSource(Address, PRtSeg);
        { The line must belong to the symbol: otherwise (unit without line numbers) the nearest
          preceding line of another unit would be reported. }
        if Assigned(PLineSource) and (NativeUInt(PByte(PRtSeg^.SegStartAddress) + PLineSource^.Line^.Offset) < NativeUInt(SymbolAddress)) then
          PLineSource := nil;
        if Assigned(PLineSource) then
        begin
          Info.LineNumber := PLineSource^.Line^.LineNumber;
          PSourceLocation := PLineSource^.Source;
          Info.SourceLocation := string(PSMapChar(@PSourceLocation^.SourceLocation[0]));
          SetLength(Info.SourceLocation, PSourceLocation^.SourceLocationLength);
        end;
        Exit;
      end;
    end;
  end;
end;

function TSMapReader.GetLineNumberSource(Address: Pointer; PRtSeg: PRuntimeSegment): PLineNumberSource;
var
  LineNumberAddress: NativeUInt;
  I: Integer;
begin
  for I := FLineSources.Count - 1 downto 0 do
  begin
    Result := FLineSources[I];
    if Result^.Source^.SegId = PRtSeg^.SegId then
    begin
      LineNumberAddress := NativeUInt(PRtSeg^.SegStartAddress) + Result^.Line^.Offset;
      if NativeUInt(Address) >= NativeUInt(LineNumberAddress) then
        Exit;
    end;
  end;
  Result := nil;
end;

function TSMapReader.GetRTSegmentFromAddress(Address: Pointer): PRuntimeSegment;
var
  I: Integer;
begin
  for I := 0 to FRTSegments.Count - 1 do
  begin
    Result := FRTSegments[I];
    with Result^ do
      if Assigned(Result) and IsAddressInRange(Address, SegStartAddress, SegEndAddress) then
        Exit;
  end;
  Result := nil;
end;

function TSMapReader.GetRTSegmentFromSegIndex(SegIndex: Integer): PRuntimeSegment;
var
  I: Integer;
begin
  for I := 0 to FRTSegments.Count - 1 do
  begin
    Result := FRTSegments[I];
    if Assigned(Result) and (Result^.SegId = Cardinal(SegIndex)) then
      Exit;
  end;
  Result := nil;
end;

function TSMapReader.GetSymbolAddress(const UnitName, SymbolName: string): Pointer;
var
  I: Integer;
  PSymbol: PSMapSymbol;
  S: string;
  PUnit: PSMapUnit;
  RtSeg: PRuntimeSegment;
begin
  Result := nil;
  for I := 0 to FSymbols.Count - 1 do
  begin
    PSymbol := FSymbols[I];
    S := string(PSMapChar(@PSymbol^.SymbolName[0]));
    if SameText(S, SymbolName) then
    begin
      RtSeg := GetRTSegmentFromSegIndex(PSymbol^.SymbolSegId);
      if Assigned(RtSeg) then
      begin
        Result := Pointer(NativeUInt(RtSeg^.SegStartAddress) + PSymbol^.SymbolOffset);
        if UnitName <> EmptyStr then
        begin
          PUnit := GetUnit(Result, RtSeg);
          if Assigned(PUnit) then
          begin
            S := string(PSMapChar(@PUnit^.UnitName[0]));
            if not SameText(S, UnitName) then
            begin
              Result := nil;
              Continue;
            end;
          end;
        end;
      end;
      Exit;
    end;
  end;
end;

function TSMapReader.GetUnit(Address: Pointer; PRtSeg: PRuntimeSegment): PSMapUnit;
var
  I: Integer;
begin
  for I := 0 to FUnits.Count - 1 do
  begin
    Result := FUnits[I];
    with Result^, PRtSeg^ do
      if (UnitSegId = SegId) and IsAddressInRange(Address, Pointer(NativeUInt(SegStartAddress) + UnitOffset), Pointer(NativeUInt(SegStartAddress) + UnitOffset + UnitLength)) then
        Exit;
  end;
  Result := nil;
end;

function TSMapReader.ProcessMap: Boolean;
var
  J: Integer;
  function RegisterSegment(PSegment: PSMapSegment): PRuntimeSegment;
  var
    RtStart: Pointer;
  begin
    Result := nil;
    if not Assigned(FOnResolveSegment) then
      Exit;
    if not FOnResolveSegment(PSegment^.SegId, SMapCharsToStr(@PSegment^.SegName[0], SEGMENT_NAME_LENGTH), PSegment^.SegStartAddress,
      PSegment^.SegLength, RtStart) then
      Exit;
    GetMem(Result, SizeOf(TRuntimeSegment));
    Result^.SegId := PSegment^.SegId;
    Result^.SegLength := PSegment^.SegLength;
    Result^.SegStartAddress := RtStart;
    Result^.SegEndAddress := Pointer(PByte(RtStart) + Result^.SegLength);
    FRTSegments.Add(Result);
  end;

var
  PHeader: PSMapHeader;
  PSegment: PSMapSegment;
  PUnit: PSMapUnit;
  PSymbol: PSMapSymbol;
  PSource: PSMapSourceLocation;
  PLine: PSMapLineNumber;
  PLineSource: PLineNumberSource;
  I: Integer;
  Options: TSMapOptions;
begin
  PHeader := FMapStream.Memory;
  if PHeader^.Signature = SMapSignature then
  begin
    Options := RawToSMapOptions(PHeader^.Flags);
    if (moCompress in Options) and (not UnZip) then
      Exit(False);

    PHeader := FMapStream.Memory; // Memory pointer may get changed !
    PSegment := PSMapSegment(PByte(PHeader) + SizeOf(TSMapHeader));
    PUnit := PSMapUnit(PByte(PHeader) + PHeader^.OffsetToUnits);
    PSymbol := PSMapSymbol(PByte(PHeader) + PHeader^.OffsetToSymbols);
    PSource := PSMapSourceLocation(PByte(PHeader) + PHeader^.OffsetToSourceLocations);
    PLine := PSMapLineNumber(PByte(PSource) + SizeOf(TSMapSourceLocation) + PSource^.SourceLocationLength);

    { ===> Segments <=== }
    for I := 1 to PHeader^.NumberOfSegments do
    begin
      RegisterSegment(PSegment);
      Inc(PSegment);
    end;
    { ===> Units <=== }
    for I := 1 to PHeader^.NumberOfUnits do
    begin
      FUnits.Add(PUnit);
      PUnit := PSMapUnit(PByte(PUnit) + SizeOf(TSMapUnit) + PUnit^.UnitNameLength);
    end;
    { ===> Symbols <=== }
    for I := 1 to PHeader^.NumberOfSymbols do
    begin
      FSymbols.Add(PSymbol);
      PSymbol := PSMapSymbol(PByte(PSymbol) + SizeOf(TSMapSymbol) + PSymbol^.SymbolNameLength);
    end;
    { ===> SourceLocations & LineNumber <=== }
    for I := 1 to PHeader^.NumberOfSourceLocations do
    begin
      for J := 1 to PSource^.NumberOfLineNumbers do
      begin
        New(PLineSource);
        PLineSource^.Line := PLine;
        PLineSource^.Source := PSource;
        FLineSources.Add(PLineSource);
        Inc(PLine);
      end;
      PSource := Pointer(PLine);
      PLine := PSMapLineNumber(PByte(PSource) + SizeOf(TSMapSourceLocation) + PSource^.SourceLocationLength);
    end;
    FLineSources.Sort(LineSortCompare);
  end;
  Result := True;
end;

function TSMapReader.UnZip: Boolean;
var
  SMapHeader: TSMapHeader;
  P: Pointer;
  Buffer: Pointer;
  BufferSize: Integer;
begin
  P := FMapStream.Memory;
  { Save smap header. }
  SMapHeader := PSMapHeader(P)^;
  { We don't want to decompress smap header cause it was
    not compressed. => So Skip it. }
  Inc(PByte(P), SizeOf(TSMapHeader));
  { Decompress }
  ZDecompress(P, SMapHeader.cSize - SizeOf(TSMapHeader), Buffer, BufferSize);
  { Restore smap header. }
  FMapStream.Write(Pointer(@SMapHeader)^, SizeOf(TSMapHeader));
  { Copy decompressed data. }
  FMapStream.Write(Buffer^, BufferSize);
  FreeMem(Buffer);
  { Check if size of decompressed data = size of original smap before it gets compressed. }
  Inc(BufferSize, SizeOf(TSMapHeader));
  Result := Integer(SMapHeader.Size) = BufferSize;
  // ZDecompress uses size as signed !
end;

{$ENDREGION 'SMapReader'}

initialization

RegxLock := TObject.Create;

finalization

if Assigned(RegxLock) then
  RegxLock.Free;

end.
