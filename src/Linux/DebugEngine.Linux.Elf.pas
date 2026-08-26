// **************************************************************************************************
// Delphi DebugEngine.
// Unit DebugEngine.Linux.Elf
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
/// Minimal ELF64 reader: loads the symbol table (.symtab, falling back to .dynsym) of an ELF file
/// and resolves link-time addresses to symbols. Also provides a small Itanium C++ ABI demangler
/// good enough for the names emitted by the Delphi Linux compiler
/// (e.g. _ZN5Hello3FooEv => Hello.Foo).
/// </summary>
unit DebugEngine.Linux.Elf;

{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.Generics.Defaults;

const
  { e_type }
  ET_EXEC = 2;
  ET_DYN = 3;
  { sh_type }
  SHT_SYMTAB = 2;
  SHT_STRTAB = 3;
  SHT_DYNSYM = 11;
  { st_info }
  STT_NOTYPE = 0;
  STT_OBJECT = 1;
  STT_FUNC = 2;
  STT_SECTION = 3;
  STT_FILE = 4;
  STB_LOCAL = 0;
  STB_GLOBAL = 1;
  STB_WEAK = 2;
  SHN_UNDEF = 0;

type
  Elf64_Ehdr = packed record
    e_ident: array [0 .. 15] of Byte;
    e_type: Word;
    e_machine: Word;
    e_version: Cardinal;
    e_entry: UInt64;
    e_phoff: UInt64;
    e_shoff: UInt64;
    e_flags: Cardinal;
    e_ehsize: Word;
    e_phentsize: Word;
    e_phnum: Word;
    e_shentsize: Word;
    e_shnum: Word;
    e_shstrndx: Word;
  end;

  Elf64_Shdr = packed record
    sh_name: Cardinal;
    sh_type: Cardinal;
    sh_flags: UInt64;
    sh_addr: UInt64;
    sh_offset: UInt64;
    sh_size: UInt64;
    sh_link: Cardinal;
    sh_info: Cardinal;
    sh_addralign: UInt64;
    sh_entsize: UInt64;
  end;

  Elf64_Sym = packed record
    st_name: Cardinal;
    st_info: Byte;
    st_other: Byte;
    st_shndx: Word;
    st_value: UInt64;
    st_size: UInt64;
  end;

  TElfSymbol = record
    Address: UInt64; // Link-time address.
    Size: UInt64;
    Name: string; // Raw (mangled) name.
    SymType: Byte; // STT_*
    Binding: Byte; // STB_*
    function DemangledName: string;
  end;

  PElfSymbol = ^TElfSymbol;

  TElfSymbolTable = class(TObject)
  private
    FFileName: string;
    FLoaded: Boolean;
    FIsPIE: Boolean;
    FHasSymtab: Boolean;
    FHasDynsym: Boolean;
    FHasDebugLine: Boolean;
    FHasDebugInfo: Boolean;
    FSectionNames: TStringList;
    FSymbols: TList<TElfSymbol>;
    FLoadError: string;
    function LoadSymbols(Stream: TStream; const Ehdr: Elf64_Ehdr; const Shdrs: TArray<Elf64_Shdr>; SymIndex: Integer): Integer;
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    /// <summary> Load the symbol table. Returns False if the file is not a valid ELF64 file. </summary>
    function Load: Boolean;
    /// <summary> Find the symbol that contains the (link-time) address.
    /// If Strict is False, the nearest preceding function symbol is returned even if the address is
    /// beyond its declared size (Delphi sizes are not always reliable). </summary>
    function FindSymbol(Address: UInt64; out Symbol: TElfSymbol; Strict: Boolean = False): Boolean;
    function FindSymbolByName(const Name: string; out Symbol: TElfSymbol): Boolean;
    property FileName: string read FFileName;
    property Loaded: Boolean read FLoaded;
    property LoadError: string read FLoadError;
    property IsPIE: Boolean read FIsPIE;
    property HasSymtab: Boolean read FHasSymtab;
    property HasDynsym: Boolean read FHasDynsym;
    property HasDebugLine: Boolean read FHasDebugLine;
    property HasDebugInfo: Boolean read FHasDebugInfo;
    property Symbols: TList<TElfSymbol> read FSymbols;
    property SectionNames: TStringList read FSectionNames;
  end;

/// <summary> Demangle an Itanium C++ ABI name as emitted by the Delphi Linux compiler.
/// Nested names are joined with '.', parameters are dropped. Unknown formats are returned unchanged. </summary>
function DemangleName(const Mangled: string): string;

/// <summary> Return the unit (namespace) part of a demangled name: 'System.Sysutils.Format' => 'System.Sysutils'. </summary>
function UnitNameOfDemangled(const Demangled: string): string;

implementation

{$REGION 'Demangler'}

function DemangleName(const Mangled: string): string;
var
  P, L: Integer;
  Parts: TArray<string>;

  function ReadNumber(out N: Integer): Boolean;
  begin
    N := 0;
    Result := (P <= L) and CharInSet(Mangled[P], ['0' .. '9']);
    while (P <= L) and CharInSet(Mangled[P], ['0' .. '9']) do
    begin
      N := N * 10 + (Ord(Mangled[P]) - Ord('0'));
      Inc(P);
    end;
  end;

  function ReadSourceName(out S: string): Boolean;
  var
    N: Integer;
  begin
    Result := ReadNumber(N) and (N > 0) and (P + N - 1 <= L);
    if Result then
    begin
      S := Copy(Mangled, P, N);
      Inc(P, N);
    end;
  end;

  function ReadSpecialName(out S: string): Boolean;
  var
    Tag: string;
  begin
    { Constructors/destructors and a few operators. }
    Result := False;
    if P + 1 > L then
      Exit;
    Tag := Copy(Mangled, P, 2);
    if (Tag = 'C1') or (Tag = 'C2') or (Tag = 'C3') then
      S := 'Create'
    else if (Tag = 'D0') or (Tag = 'D1') or (Tag = 'D2') then
      S := 'Destroy'
    else
      Exit;
    Inc(P, 2);
    Result := True;
  end;

  function ReadName: Boolean;
  var
    S: string;
    Nested: Boolean;
  begin
    Result := False;
    Nested := (P <= L) and (Mangled[P] = 'N');
    if Nested then
      Inc(P);
    { Skip CV qualifiers of nested names (r, V, K). }
    while Nested and (P <= L) and CharInSet(Mangled[P], ['r', 'V', 'K']) do
      Inc(P);
    repeat
      if ReadSourceName(S) or ReadSpecialName(S) then
      begin
        Parts := Parts + [S];
        Result := True;
      end
      else if (P <= L) and (Mangled[P] = 'L') then
        Inc(P) // Local (internal linkage) marker.
      else if (P <= L) and (Mangled[P] = 'S') then
      begin
        { Substitution: we cannot resolve it without a full table, keep a marker. }
        Inc(P);
        while (P <= L) and (Mangled[P] <> '_') do
          Inc(P);
        Inc(P);
        Parts := Parts + ['?'];
      end
      else
        Break;
    until (P > L) or (Mangled[P] = 'E') or not Nested;
    if Nested and (P <= L) and (Mangled[P] = 'E') then
      Inc(P);
  end;

begin
  Result := Mangled;
  L := Length(Mangled);
  if (L < 3) or (Mangled[1] <> '_') or (Mangled[2] <> 'Z') then
    Exit;
  P := 3;
  Parts := nil;
  if ReadName and (Length(Parts) > 0) then
    Result := string.Join('.', Parts);
end;

function UnitNameOfDemangled(const Demangled: string): string;
var
  I: Integer;
begin
  I := Demangled.LastIndexOf('.');
  if I > 0 then
    Result := Demangled.Substring(0, I)
  else
    Result := '';
end;

{$ENDREGION}

{ TElfSymbol }

function TElfSymbol.DemangledName: string;
begin
  Result := DemangleName(Name);
end;

{ TElfSymbolTable }

constructor TElfSymbolTable.Create(const AFileName: string);
begin
  inherited Create;
  FFileName := AFileName;
  FSectionNames := TStringList.Create;
  FSymbols := TList<TElfSymbol>.Create;
end;

destructor TElfSymbolTable.Destroy;
begin
  FSymbols.Free;
  FSectionNames.Free;
  inherited;
end;

function TElfSymbolTable.LoadSymbols(Stream: TStream; const Ehdr: Elf64_Ehdr; const Shdrs: TArray<Elf64_Shdr>; SymIndex: Integer): Integer;
var
  SymHdr, StrHdr: Elf64_Shdr;
  Syms: TArray<Elf64_Sym>;
  StrTab: TBytes;
  I, Count: Integer;
  Sym: TElfSymbol;
  T: Byte;
begin
  Result := 0;
  SymHdr := Shdrs[SymIndex];
  if (SymHdr.sh_link >= Cardinal(Length(Shdrs))) or (SymHdr.sh_entsize = 0) then
    Exit;
  StrHdr := Shdrs[SymHdr.sh_link];
  Count := SymHdr.sh_size div SymHdr.sh_entsize;
  if Count = 0 then
    Exit;
  SetLength(Syms, Count);
  Stream.Position := SymHdr.sh_offset;
  Stream.ReadBuffer(Syms[0], Count * SizeOf(Elf64_Sym));
  SetLength(StrTab, StrHdr.sh_size + 1);
  Stream.Position := StrHdr.sh_offset;
  Stream.ReadBuffer(StrTab[0], StrHdr.sh_size);
  StrTab[StrHdr.sh_size] := 0;
  for I := 0 to Count - 1 do
  begin
    T := Syms[I].st_info and $0F;
    if not(T in [STT_FUNC, STT_OBJECT, STT_NOTYPE]) then
      Continue;
    if (Syms[I].st_shndx = SHN_UNDEF) or (Syms[I].st_value = 0) or (Syms[I].st_name >= StrHdr.sh_size) then
      Continue;
    Sym.Address := Syms[I].st_value;
    Sym.Size := Syms[I].st_size;
    Sym.SymType := T;
    Sym.Binding := Syms[I].st_info shr 4;
    Sym.Name := string(UTF8String(MarshaledAString(@StrTab[Syms[I].st_name])));
    if Sym.Name = '' then
      Continue;
    FSymbols.Add(Sym);
    Inc(Result);
  end;
end;

function TElfSymbolTable.Load: Boolean;
var
  Stream: TFileStream;
  Ehdr: Elf64_Ehdr;
  Shdrs: TArray<Elf64_Shdr>;
  ShStr: TBytes;
  I, SymTab, DynSym: Integer;
  Name: string;
begin
  Result := False;
  if FLoaded then
    Exit(True);
  FLoadError := '';
  try
    Stream := TFileStream.Create(FFileName, fmOpenRead or fmShareDenyNone);
  except
    on E: Exception do
    begin
      FLoadError := E.Message;
      Exit;
    end;
  end;
  try
    if Stream.Read(Ehdr, SizeOf(Ehdr)) <> SizeOf(Ehdr) then
      Exit;
    if (Ehdr.e_ident[0] <> $7F) or (Ehdr.e_ident[1] <> Ord('E')) or (Ehdr.e_ident[2] <> Ord('L')) or (Ehdr.e_ident[3] <> Ord('F')) then
    begin
      FLoadError := 'Not an ELF file';
      Exit;
    end;
    if Ehdr.e_ident[4] <> 2 then
    begin
      FLoadError := 'Not an ELF64 file';
      Exit;
    end;
    FIsPIE := Ehdr.e_type = ET_DYN;
    if (Ehdr.e_shoff = 0) or (Ehdr.e_shnum = 0) or (Ehdr.e_shentsize <> SizeOf(Elf64_Shdr)) then
    begin
      FLoadError := 'No section headers (stripped file?)';
      Exit;
    end;
    SetLength(Shdrs, Ehdr.e_shnum);
    Stream.Position := Ehdr.e_shoff;
    Stream.ReadBuffer(Shdrs[0], Ehdr.e_shnum * SizeOf(Elf64_Shdr));
    { Section names }
    if Ehdr.e_shstrndx < Ehdr.e_shnum then
    begin
      SetLength(ShStr, Shdrs[Ehdr.e_shstrndx].sh_size + 1);
      Stream.Position := Shdrs[Ehdr.e_shstrndx].sh_offset;
      Stream.ReadBuffer(ShStr[0], Shdrs[Ehdr.e_shstrndx].sh_size);
      ShStr[High(ShStr)] := 0;
    end;
    SymTab := -1;
    DynSym := -1;
    for I := 0 to Ehdr.e_shnum - 1 do
    begin
      Name := '';
      if (Length(ShStr) > 0) and (Shdrs[I].sh_name < Cardinal(Length(ShStr))) then
        Name := string(UTF8String(MarshaledAString(@ShStr[Shdrs[I].sh_name])));
      FSectionNames.Add(Name);
      if Shdrs[I].sh_type = SHT_SYMTAB then
        SymTab := I
      else if Shdrs[I].sh_type = SHT_DYNSYM then
        DynSym := I;
      if Name = '.debug_line' then
        FHasDebugLine := True
      else if Name = '.debug_info' then
        FHasDebugInfo := True;
    end;
    FHasSymtab := SymTab >= 0;
    FHasDynsym := DynSym >= 0;
    if SymTab >= 0 then
      LoadSymbols(Stream, Ehdr, Shdrs, SymTab)
    else if DynSym >= 0 then
      LoadSymbols(Stream, Ehdr, Shdrs, DynSym);
    FSymbols.Sort(TComparer<TElfSymbol>.Construct(
      function(const A, B: TElfSymbol): Integer
      begin
        if A.Address < B.Address then
          Result := -1
        else if A.Address > B.Address then
          Result := 1
        else
          { Prefer FUNC over NOTYPE, GLOBAL over LOCAL for the same address. }
          Result := Integer(B.SymType = STT_FUNC) - Integer(A.SymType = STT_FUNC);
      end));
    FLoaded := True;
    Result := True;
  finally
    Stream.Free;
  end;
end;

function TElfSymbolTable.FindSymbol(Address: UInt64; out Symbol: TElfSymbol; Strict: Boolean): Boolean;
var
  Lo, Hi, Mid, Best: Integer;
begin
  Result := False;
  if not FLoaded and not Load then
    Exit;
  if FSymbols.Count = 0 then
    Exit;
  { Binary search: last symbol with Address <= target. }
  Lo := 0;
  Hi := FSymbols.Count - 1;
  Best := -1;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if FSymbols[Mid].Address <= Address then
    begin
      Best := Mid;
      Lo := Mid + 1;
    end
    else
      Hi := Mid - 1;
  end;
  if Best < 0 then
    Exit;
  { Several symbols may share the address: walk back to the first one, then pick the best typed. }
  while (Best > 0) and (FSymbols[Best - 1].Address = FSymbols[Best].Address) do
    Dec(Best);
  Symbol := FSymbols[Best];
  if Strict and (Symbol.Size > 0) and (Address >= Symbol.Address + Symbol.Size) then
    Exit;
  Result := True;
end;

function TElfSymbolTable.FindSymbolByName(const Name: string; out Symbol: TElfSymbol): Boolean;
var
  I: Integer;
begin
  Result := False;
  if not FLoaded and not Load then
    Exit;
  for I := 0 to FSymbols.Count - 1 do
    if SameText(FSymbols[I].Name, Name) or SameText(FSymbols[I].DemangledName, Name) then
    begin
      Symbol := FSymbols[I];
      Exit(True);
    end;
end;

end.
