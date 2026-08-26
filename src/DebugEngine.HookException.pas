// **************************************************************************************************
// Delphi DebugEngine.
// Unit DebugEngine.HookException
// https://github.com/MahdiSafsafi/DebugEngine

// The contents of this file are subject to the Mozilla Public License Version 1.1 (the "License");
// you may not use this file except in compliance with the License. You may obtain a copy of the
// License at http://www.mozilla.org/MPL/
//
// Software distributed under the License is distributed on an "AS IS" basis, WITHOUT WARRANTY OF
// ANY KIND, either express or implied. See the License for the specific language governing rights
// and limitations under the License.
//
// The Original Code is DebugEngine.HookException.pas.
//
//
// The Initial Developer of the Original Code is Mahdi Safsafi.
// Portions created by Mahdi Safsafi . are Copyright (C) 2016-2019 Mahdi Safsafi.
// All Rights Reserved.
//
// **************************************************************************************************

unit DebugEngine.HookException;

{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  System.Classes,
  System.SysUtils;

type
  /// <summary> Stack captured by the hook: exception address followed by the call stack. </summary>
  TExceptionStackAddresses = TArray<Pointer>;

procedure InstallExceptionHook;
procedure RemoveExceptionHook;

/// <summary> Addresses of the stack attached to an exception (E.StackInfo). First entry = exception address.
/// Returns nil when the exception carries no stack info. </summary>
function GetExceptionStackAddresses(E: Exception): TExceptionStackAddresses;

/// <summary> Format a list of addresses the same way E.StackTrace does (one line per frame). </summary>
function FormatStackAddresses(const Addresses: TExceptionStackAddresses): string;

implementation

uses
  Winapi.Windows,
  DebugEngine.Core,
  DebugEngine.DebugInfo,
  DebugEngine.Trace;

type
  PExcStackInfo = ^TExcStackInfo;

  TExcStackInfo = record
    Addresses: TExceptionStackAddresses; // [0] = exception address
    Trimmed: Boolean; // Raise machinery frames already removed.
    Text: string; // Lazily formatted.
  end;

{ Frames that belong to the exception raising machinery (RTL, kernel and this library). They sit
  between the exception address and the first user frame and are removed lazily. }
function IsRaiseMachineryFrame(Address: Pointer): Boolean;
const
  Units: array [0 .. 2] of string = ('DebugEngine.Trace', 'DebugEngine.HookException', 'DebugEngine.Core');
  Symbols: array [0 .. 12] of string = ('RaisingException', 'RaiseExceptObject', '@RaiseExcept', '@RaiseAtExcept', '@InternalRaiseAtExcept', 'GetExceptionObject',
    '@HandleAnyException', '@HandleOnException', '@HandleAutoException', 'KiUserExceptionDispatcher', 'RaiseException', 'RtlRaiseException',
    '@DelphiExceptionHandler');
var
  Info: TAddressInfo;
  S: string;
  H: THandle;
begin
  Result := False;
  { Kernel exception dispatch frames (x64 hardware exceptions) live in ntdll. }
  H := GetModuleHandleFromAddress(Address);
  if (H <> 0) and SameText(GetModuleBaseName(H), 'ntdll.dll') then
    Exit(True);
  if not GetAddressInfo(Address, Info, aimSymbolName) then
    Exit;
  for S in Units do
    if SameText(Info.UnitName, S) then
      Exit(True);
  for S in Symbols do
    if Info.SymbolName.EndsWith(S, True) then
      Exit(True);
end;

procedure TrimRaiseFrames(var Info: TExcStackInfo);
var
  I, First: Integer;
  ExcInfo, FrameInfo: TAddressInfo;
  HaveExc: Boolean;
begin
  if Info.Trimmed or (Length(Info.Addresses) < 2) then
  begin
    Info.Trimmed := True;
    Exit;
  end;
  Info.Trimmed := True;
  First := 1;
  while (First < High(Info.Addresses)) and IsRaiseMachineryFrame(Info.Addresses[First]) do
    Inc(First);
  { The frame right after the machinery is usually the return address of the call to the raise
    helper, i.e. the same function as the exception address: drop it to avoid a duplicate line. }
  HaveExc := GetAddressInfo(Info.Addresses[0], ExcInfo, aimAddress);
  if HaveExc and (First < High(Info.Addresses)) and GetAddressInfo(Info.Addresses[First], FrameInfo, aimAddress) and
    (FrameInfo.SymbolAddress = ExcInfo.SymbolAddress) then
    Inc(First);
  if First > 1 then
  begin
    for I := First to High(Info.Addresses) do
      Info.Addresses[I - First + 1] := Info.Addresses[I];
    SetLength(Info.Addresses, Length(Info.Addresses) - First + 1);
  end;
end;

function FormatStackAddresses(const Addresses: TExceptionStackAddresses): string;
var
  SL: TStringList;
  Item: TStackItem;
  I: Integer;
begin
  SL := TStringList.Create;
  try
    for I := 0 to High(Addresses) do
    begin
      FillChar(Item, SizeOf(Item), #00);
      Item.CallAddress := Addresses[I];
      Item.Info.Address := Addresses[I];
      SL.Add(LogCall(@Item));
    end;
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

{$IFDEF CPUX64}
function RtlCaptureStackBackTrace(FramesToSkip, FramesToCapture: ULONG; BackTrace: PPointer; BackTraceHash: PULONG): USHORT; stdcall;
  external kernel32 name 'RtlCaptureStackBackTrace';
{$ENDIF}

function GetExceptionStackInfo(P: System.SysUtils.PExceptionRecord): Pointer;
var
  Info: PExcStackInfo;
{$IFDEF CPUX64}
  Buf: array [0 .. 127] of Pointer;
  N: Integer;
{$ELSE}
  StackTrace: TCallTrace;
  StackInfo: TStackInfo;
{$ENDIF}
  I: Integer;
begin
  { Only capture addresses here (cheap): symbols are resolved lazily when E.StackTrace is read. }
  New(Info);
  Info^.Text := '';
  Info^.Addresses := nil;
  Info^.Trimmed := False; // New() does not zero the record.
  try
    { First caller is exception address. }
    Info^.Addresses := [P^.ExceptionAddress];
{$IFDEF CPUX64}
    { x64: use the OS unwinder (table based, exact). It also walks through the kernel exception
      dispatcher frame, so the callers of the faulting function are recovered for hardware
      exceptions (access violations...) raised from inside KiUserExceptionDispatcher. }
    N := RtlCaptureStackBackTrace(0, Length(Buf), @Buf[0], nil);
    SetLength(Info^.Addresses, N + 1);
    for I := 0 to N - 1 do
      Info^.Addresses[I + 1] := Buf[I];
{$ELSE}
    { x86: DebugEngine EBP chain walker (with broken chain detection). }
    GetStackInfo(StackInfo);
    if GetStackTraceError = 0 then
    begin
      StackTrace := TCallTrace.Create;
      try
        StackTrace.Options := [soUseFirstCallOnEbp { ,soRebuildBrokenEbpChain,soDropCurrentEbpChain } ];
        StackTrace.StackInfo := StackInfo;
        StackTrace.Trace;
        SetLength(Info^.Addresses, StackTrace.Count + 1);
        for I := 0 to StackTrace.Count - 1 do
          Info^.Addresses[I + 1] := StackTrace.Items[I]^.CallAddress;
      finally
        StackTrace.Free;
      end;
    end;
{$ENDIF}
  except
    // Never let the hook raise inside a raise.
  end;
  Result := Info;
end;

function GetStackInfoString(Info: Pointer): string;
var
  SI: PExcStackInfo;
begin
  SI := Info;
  if not Assigned(SI) then
    Exit('');
  if (SI^.Text = '') and (Length(SI^.Addresses) > 0) then
  begin
    TrimRaiseFrames(SI^);
    SI^.Text := FormatStackAddresses(SI^.Addresses);
  end;
  Result := SI^.Text;
end;

procedure CleanUpStackInfo(Info: Pointer);
begin
  if Assigned(Info) then
    Dispose(PExcStackInfo(Info));
end;

function GetExceptionStackAddresses(E: Exception): TExceptionStackAddresses;
begin
  Result := nil;
  if Assigned(E) and Assigned(E.StackInfo) then
  begin
    TrimRaiseFrames(PExcStackInfo(E.StackInfo)^);
    Result := PExcStackInfo(E.StackInfo)^.Addresses;
  end;
end;

procedure InstallExceptionHook;
begin
  Exception.GetExceptionStackInfoProc := GetExceptionStackInfo;
  Exception.GetStackInfoStringProc := GetStackInfoString;
  Exception.CleanUpStackInfoProc := CleanUpStackInfo;
end;

procedure RemoveExceptionHook;
begin
  Exception.GetExceptionStackInfoProc := nil;
  Exception.GetStackInfoStringProc := nil;
  Exception.CleanUpStackInfoProc := nil;
end;

initialization

InstallExceptionHook;

finalization

RemoveExceptionHook;

end.
