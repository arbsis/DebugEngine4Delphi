// **************************************************************************************************
// Delphi DebugEngine.
// Unit DebugEngine.Linux.Registers
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
/// CPU register snapshot without inline assembly: getcontext() for the current thread, or the
/// ucontext_t delivered to a signal handler for the faulting context. x86_64 only.
/// </summary>
unit DebugEngine.Linux.Registers;

{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Math,
  DebugEngine.Linux.Posix;

type
  TXmmRegister = record
    case Integer of
      0: (AsUInt64: array [0 .. 1] of UInt64);
      1: (AsUInt32: array [0 .. 3] of Cardinal);
      2: (AsSingle: array [0 .. 3] of Single);
      3: (AsDouble: array [0 .. 1] of Double);
  end;

  TLinuxRegisters = record
    Valid: Boolean;
    { General purpose }
    RAX, RBX, RCX, RDX, RSI, RDI, RBP, RSP: UInt64;
    R8, R9, R10, R11, R12, R13, R14, R15: UInt64;
    RIP: UInt64;
    EFLAGS: UInt64;
    CS, GS, FS, SS: Word;
    { Fault info (signal context only) }
    TrapNo: UInt64;
    ErrorCode: UInt64;
    CR2: UInt64; // Faulting address for page faults.
    { FPU / SSE }
    HasFpu: Boolean;
    FpuControl: Word; // cwd
    FpuStatus: Word; // swd
    FpuTagWord: Word; // ftw (abridged)
    FpuOpcode: Word;
    FpuLastIP: UInt64;
    FpuLastDP: UInt64;
    MXCSR: Cardinal;
    MXCSRMask: Cardinal;
    ST: array [0 .. 7] of Extended;
    XMM: array [0 .. 15] of TXmmRegister;
  end;

/// <summary> Snapshot of the current thread registers (values as of the getcontext call). </summary>
function SnapshotOfRegisters(out Regs: TLinuxRegisters): Boolean;

/// <summary> Extract registers from a signal handler ucontext (3rd parameter of a SA_SIGINFO handler). </summary>
function RegistersFromContext(Context: Pucontext_t; out Regs: TLinuxRegisters): Boolean;

/// <summary> Append a human readable dump (general, flags, FPU/SSE) to SL. </summary>
procedure RegistersToStrings(const Regs: TLinuxRegisters; SL: TStrings; IncludeVector: Boolean = True);

/// <summary> Decode EFLAGS bits: 'CF PF ZF IF ...'. </summary>
function EFlagsToStr(Flags: UInt64): string;

/// <summary> Decode MXCSR bits. </summary>
function MxcsrToStr(Mxcsr: Cardinal): string;

implementation

function RegistersFromContext(Context: Pucontext_t; out Regs: TLinuxRegisters): Boolean;
var
  G: ^gregset_t;
  F: P_libc_fpstate;
  I: Integer;
  CsGsFs: UInt64;
begin
  Regs := Default (TLinuxRegisters);
  Result := Assigned(Context);
  if not Result then
    Exit;
  G := @Context^.uc_mcontext.gregs;
  Regs.RAX := UInt64(G^[REG_RAX]);
  Regs.RBX := UInt64(G^[REG_RBX]);
  Regs.RCX := UInt64(G^[REG_RCX]);
  Regs.RDX := UInt64(G^[REG_RDX]);
  Regs.RSI := UInt64(G^[REG_RSI]);
  Regs.RDI := UInt64(G^[REG_RDI]);
  Regs.RBP := UInt64(G^[REG_RBP]);
  Regs.RSP := UInt64(G^[REG_RSP]);
  Regs.R8 := UInt64(G^[REG_R8]);
  Regs.R9 := UInt64(G^[REG_R9]);
  Regs.R10 := UInt64(G^[REG_R10]);
  Regs.R11 := UInt64(G^[REG_R11]);
  Regs.R12 := UInt64(G^[REG_R12]);
  Regs.R13 := UInt64(G^[REG_R13]);
  Regs.R14 := UInt64(G^[REG_R14]);
  Regs.R15 := UInt64(G^[REG_R15]);
  Regs.RIP := UInt64(G^[REG_RIP]);
  Regs.EFLAGS := UInt64(G^[REG_EFL]);
  CsGsFs := UInt64(G^[REG_CSGSFS]);
  Regs.CS := Word(CsGsFs);
  Regs.GS := Word(CsGsFs shr 16);
  Regs.FS := Word(CsGsFs shr 32);
  Regs.SS := Word(CsGsFs shr 48);
  Regs.TrapNo := UInt64(G^[REG_TRAPNO]);
  Regs.ErrorCode := UInt64(G^[REG_ERR]);
  Regs.CR2 := UInt64(G^[REG_CR2]);
  F := Context^.uc_mcontext.fpregs;
  if Assigned(F) then
  begin
    Regs.HasFpu := True;
    Regs.FpuControl := F^.cwd;
    Regs.FpuStatus := F^.swd;
    Regs.FpuTagWord := F^.ftw;
    Regs.FpuOpcode := F^.fop;
    Regs.FpuLastIP := F^.rip;
    Regs.FpuLastDP := F^.rdp;
    Regs.MXCSR := F^.mxcsr;
    Regs.MXCSRMask := F^.mxcr_mask;
    for I := 0 to 7 do
      Move(F^._st[I], Regs.ST[I], Min(10, SizeOf(Extended)));
    for I := 0 to 15 do
      Move(F^._xmm[I], Regs.XMM[I], 16);
  end;
  Regs.Valid := True;
end;

function SnapshotOfRegisters(out Regs: TLinuxRegisters): Boolean;
var
  Ctx: ucontext_t;
begin
  FillChar(Ctx, SizeOf(Ctx), 0);
  Result := getcontext(Ctx) = 0;
  if Result then
    Result := RegistersFromContext(@Ctx, Regs)
  else
    Regs := Default (TLinuxRegisters);
end;

function EFlagsToStr(Flags: UInt64): string;
const
  Names: array [0 .. 21] of string = ('CF', '', 'PF', '', 'AF', '', 'ZF', 'SF', 'TF', 'IF', 'DF', 'OF', 'IOPL0', 'IOPL1', 'NT', '', 'RF', 'VM', 'AC', 'VIF',
    'VIP', 'ID');
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Names) do
    if (Names[I] <> '') and (Flags and (UInt64(1) shl I) <> 0) then
      Result := Result + Names[I] + ' ';
  Result := Result.Trim;
end;

function MxcsrToStr(Mxcsr: Cardinal): string;
const
  Names: array [0 .. 15] of string = ('IE', 'DE', 'ZE', 'OE', 'UE', 'PE', 'DAZ', 'IM', 'DM', 'ZM', 'OM', 'UM', 'PM', 'RC0', 'RC1', 'FZ');
  RoundNames: array [0 .. 3] of string = ('nearest', 'down', 'up', 'toward zero');
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Names) do
    if (I <> 13) and (I <> 14) and (Mxcsr and (1 shl I) <> 0) then
      Result := Result + Names[I] + ' ';
  Result := Result + 'RC=' + RoundNames[(Mxcsr shr 13) and 3];
end;

procedure RegistersToStrings(const Regs: TLinuxRegisters; SL: TStrings; IncludeVector: Boolean);
var
  I: Integer;
begin
  if not Regs.Valid then
  begin
    SL.Add('  (registers not available)');
    Exit;
  end;
  SL.Add(Format('  RAX=%.16x  RBX=%.16x  RCX=%.16x  RDX=%.16x', [Regs.RAX, Regs.RBX, Regs.RCX, Regs.RDX]));
  SL.Add(Format('  RSI=%.16x  RDI=%.16x  RBP=%.16x  RSP=%.16x', [Regs.RSI, Regs.RDI, Regs.RBP, Regs.RSP]));
  SL.Add(Format('  R8 =%.16x  R9 =%.16x  R10=%.16x  R11=%.16x', [Regs.R8, Regs.R9, Regs.R10, Regs.R11]));
  SL.Add(Format('  R12=%.16x  R13=%.16x  R14=%.16x  R15=%.16x', [Regs.R12, Regs.R13, Regs.R14, Regs.R15]));
  SL.Add(Format('  RIP=%.16x  EFLAGS=%.8x [%s]', [Regs.RIP, Regs.EFLAGS, EFlagsToStr(Regs.EFLAGS)]));
  SL.Add(Format('  CS=%.4x  SS=%.4x  FS=%.4x  GS=%.4x', [Regs.CS, Regs.SS, Regs.FS, Regs.GS]));
  if (Regs.TrapNo <> 0) or (Regs.ErrorCode <> 0) or (Regs.CR2 <> 0) then
    SL.Add(Format('  TRAPNO=%d  ERR=%.x  CR2(fault address)=%.16x', [Regs.TrapNo, Regs.ErrorCode, Regs.CR2]));
  if Regs.HasFpu then
  begin
    SL.Add(Format('  FPU: CW=%.4x SW=%.4x TW=%.4x OP=%.4x LastIP=%.16x LastDP=%.16x', [Regs.FpuControl, Regs.FpuStatus, Regs.FpuTagWord, Regs.FpuOpcode,
      Regs.FpuLastIP, Regs.FpuLastDP]));
    SL.Add(Format('  MXCSR=%.8x [%s]', [Regs.MXCSR, MxcsrToStr(Regs.MXCSR)]));
    if IncludeVector then
    begin
      for I := 0 to 7 do
        SL.Add(Format('  ST%d=%s', [I, FloatToStr(Regs.ST[I])]));
      for I := 0 to 15 do
        SL.Add(Format('  XMM%-2d=%.16x%.16x  (d: %g, %g)', [I, Regs.XMM[I].AsUInt64[1], Regs.XMM[I].AsUInt64[0], Regs.XMM[I].AsDouble[0],
          Regs.XMM[I].AsDouble[1]]));
    end;
  end;
end;

end.
