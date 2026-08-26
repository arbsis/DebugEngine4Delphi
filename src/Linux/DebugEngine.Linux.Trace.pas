// **************************************************************************************************
// Delphi DebugEngine.
// Unit DebugEngine.Linux.Trace
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
/// Stack capture (glibc backtrace, DWARF based unwinding) and formatting for Linux.
/// </summary>
unit DebugEngine.Linux.Trace;

{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  System.SysUtils,
  System.Classes,
  DebugEngine.Linux.Posix,
  DebugEngine.Linux.Modules,
  DebugEngine.Linux.DebugInfo;

const
  MaxStackDepth = 128;

type
  TStackFrameInfo = record
    Index: Integer;
    Info: TLinuxAddressInfo;
  end;

/// <summary> Capture the current call stack. Skip = number of innermost frames to drop (0 = include the caller). </summary>
function CaptureStackTrace(Skip: Integer = 0; MaxDepth: Integer = MaxStackDepth): TArray<Pointer>;

/// <summary> Resolve a captured stack. </summary>
function ResolveStackTrace(const Addresses: TArray<Pointer>; FirstIsExact: Boolean = False): TArray<TStackFrameInfo>;

/// <summary> Format one frame the same way DebugEngine does on Windows:
/// $address  module  unit  source:line  symbol+offset </summary>
function FormatStackFrame(const Frame: TStackFrameInfo; IncludeInlined: Boolean = True): string;

/// <summary> Capture + resolve + format the current call stack into SL. </summary>
procedure StackTrace(SL: TStrings; Skip: Integer = 0);

/// <summary> Resolve + format the given addresses into SL. FirstAddress (optional) is prepended
/// (used for the exception address). When TrimRaiseFrames is True the leading RTL frames that belong
/// to the raise machinery (RaisingException, _RaiseExcept, SignalConverter...) are dropped. </summary>
procedure StackTraceFromAddresses(const Addresses: TArray<Pointer>; SL: TStrings; FirstAddress: Pointer = nil; TrimRaiseFrames: Boolean = False);

/// <summary> True when the frame belongs to the Delphi RTL exception raising machinery. </summary>
function IsRtlRaiseFrame(const Info: TLinuxAddressInfo): Boolean;

/// <summary> True when Address lies in an executable segment of a loaded module. </summary>
function IsCodeAddress(Address: Pointer): Boolean;

/// <summary> Raw backtrace_symbols() output (last resort / cross check). </summary>
function RawBacktraceSymbols(const Addresses: TArray<Pointer>): TArray<string>;

implementation

function CaptureStackTrace(Skip: Integer; MaxDepth: Integer): TArray<Pointer>;
var
  Buf: array [0 .. MaxStackDepth - 1] of Pointer;
  N, I: Integer;
begin
  if MaxDepth > MaxStackDepth then
    MaxDepth := MaxStackDepth;
  N := backtrace(@Buf[0], MaxDepth);
  Inc(Skip); // Drop CaptureStackTrace itself.
  if N <= Skip then
    Exit(nil);
  SetLength(Result, N - Skip);
  for I := Skip to N - 1 do
    Result[I - Skip] := Buf[I];
end;

function ResolveStackTrace(const Addresses: TArray<Pointer>; FirstIsExact: Boolean): TArray<TStackFrameInfo>;
var
  Infos: TArray<TLinuxAddressInfo>;
  Lookup: TArray<Pointer>;
  I: Integer;
begin
  { Return addresses point after the call instruction: resolve Address-1 so that the symbol and
    the line number are the ones of the call and not of the next statement. When FirstIsExact is
    True the first address is an exact PC (exception address) and is resolved as is. }
  SetLength(Lookup, Length(Addresses));
  for I := 0 to High(Addresses) do
    if (I = 0) and FirstIsExact then
      Lookup[I] := Addresses[I]
    else
      Lookup[I] := Pointer(UIntPtr(Addresses[I]) - 1);
  Infos := GetAddressInfoList(Lookup);
  SetLength(Result, Length(Infos));
  for I := 0 to High(Infos) do
  begin
    Result[I].Index := I;
    Result[I].Info := Infos[I];
    Result[I].Info.Address := Addresses[I];
  end;
end;

function FormatStackFrame(const Frame: TStackFrameInfo; IncludeInlined: Boolean): string;
var
  Loc, Sym, S: string;
begin
  with Frame.Info do
  begin
    if HasLine then
      Loc := Format('%s:%d', [ExtractFileName(SourceFile), LineNumber])
    else
      Loc := '';
    if HasSymbol then
      Sym := Format('%s+0x%x', [SymbolName, SymbolOffset])
    else
      Sym := '??';
    Result := Format('$%.16x  %-24s  %-28s  %-28s  %s', [UIntPtr(Address), ModuleBaseName, UnitName, Loc, Sym]);
    if IncludeInlined then
      for S in Inlined do
        Result := Result + sLineBreak + StringOfChar(' ', 20) + '(inlined by) ' + S;
  end;
end;

function IsRtlRaiseFrame(const Info: TLinuxAddressInfo): Boolean;
const
  Names: array [0 .. 11] of string = ('SignalConverter', 'SignalConverterUnAligned', 'System.Sysutils.Exception.RaisingException', 'System.Sysutils.RaiseExceptObject', 'System._InternalRaiseAtExcept',
    'System._RaiseAtExcept', 'System._RaiseExcept', 'System.Internal.Excutils.SignalConverter', 'System.Internal.Excutils.SignalConverterUnAligned',
    'System.Sysutils.GetExceptionObject', 'Debugengine.Linux.Hookexception.GetExceptionStackInfo', 'Debugengine.Linux.Trace.CaptureStackTrace');
var
  N: string;
begin
  Result := False;
  if not Info.HasSymbol then
    Exit;
  for N in Names do
    if SameText(Info.SymbolName, N) then
      Exit(True);
end;

function IsCodeAddress(Address: Pointer): Boolean;
var
  M: TLinuxModule;
  Seg: TLinuxSegment;
begin
  Result := False;
  if not Assigned(Address) then
    Exit;
  M := GlobalModules.ModuleFromAddress(Address);
  if not Assigned(M) then
    Exit;
  for Seg in M.Segments do
    if Seg.Contains(UIntPtr(Address)) then
      Exit(Seg.IsExecutable);
end;

procedure StackTraceFromAddresses(const Addresses: TArray<Pointer>; SL: TStrings; FirstAddress: Pointer; TrimRaiseFrames: Boolean);
var
  All: TArray<Pointer>;
  Frames: TArray<TStackFrameInfo>;
  I, Start: Integer;
begin
  if Assigned(FirstAddress) then
    All := [FirstAddress] + Addresses
  else
    All := Addresses;
  Frames := ResolveStackTrace(All, Assigned(FirstAddress));
  Start := 0;
  if TrimRaiseFrames then
  begin
    { Skip leading RTL frames, but never the exact exception address and never everything. }
    I := 0;
    if Assigned(FirstAddress) then
      I := 1;
    while (I < High(Frames)) and IsRtlRaiseFrame(Frames[I].Info) do
      Inc(I);
    { Signal converted exceptions: the frame right after the converter is the faulting PC again. }
    if Assigned(FirstAddress) then
      while (I < High(Frames)) and (Frames[I].Info.Address = FirstAddress) do
        Inc(I);
    if Assigned(FirstAddress) then
    begin
      { Keep the exact address, then continue after the RTL frames. }
      SL.BeginUpdate;
      try
        SL.Add(FormatStackFrame(Frames[0]));
        for Start := I to High(Frames) do
          SL.Add(FormatStackFrame(Frames[Start]));
      finally
        SL.EndUpdate;
      end;
      Exit;
    end;
    Start := I;
  end;
  SL.BeginUpdate;
  try
    for I := Start to High(Frames) do
      SL.Add(FormatStackFrame(Frames[I]));
  finally
    SL.EndUpdate;
  end;
end;

procedure StackTrace(SL: TStrings; Skip: Integer);
begin
  StackTraceFromAddresses(CaptureStackTrace(Skip + 1), SL);
end;

function RawBacktraceSymbols(const Addresses: TArray<Pointer>): TArray<string>;
var
  P: PPAnsiChar;
  I: Integer;
begin
  Result := nil;
  if Length(Addresses) = 0 then
    Exit;
  P := backtrace_symbols(@Addresses[0], Length(Addresses));
  if P = nil then
    Exit;
  try
    SetLength(Result, Length(Addresses));
    for I := 0 to High(Addresses) do
      Result[I] := string(UTF8String(MarshaledAString(PPAnsiChar(PByte(P) + I * SizeOf(Pointer))^)));
  finally
    free(P);
  end;
end;

end.
