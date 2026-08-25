program DebugEngineLinuxSimple;

{ DebugEngine for Linux - minimal example.

  One exception is raised a few calls deep, caught, and logged with:
    - the symbolized stack trace (E.StackTrace, provided by the hook),
    - System / Process / Threads / Modules information.

  The report is printed to the console and appended to DebugEngineLinuxSimple.log (next to the executable).

  Build with:  Linking > Map file = Detailed (-GD) and Debug information (-V), so that addr2line can
  resolve "file:line" (without it symbols still come from the ELF symbol table). }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  DebugEngine.Linux.HookException in '..\..\..\Source\Linux\DebugEngine.Linux.HookException.pas';

{ Some call depth so that the stack trace has something to show. }

procedure LoadCustomer(Id: Integer);
begin
  if Id <= 0 then
    raise EArgumentException.CreateFmt('Invalid customer id: %d', [Id]);
end;

procedure ProcessOrder(CustomerId: Integer);
begin
  LoadCustomer(CustomerId);
end;

procedure RunBatch;
begin
  ProcessOrder(0);
end;

{ Logging: uses the ready made report builder with only the requested sections. }

procedure LogException(E: Exception);
const
  Sections = [crsException, crsStackTrace, crsSystem, crsProcess, crsThreads, crsModules];
var
  LogFile, Report: string;
begin
  LogFile := ChangeFileExt(ParamStr(0), '.log');
  Report := WriteCrashLog(E, LogFile, Sections); // appends to the file and returns the text
  Writeln(Report);
  Writeln('Report appended to: ', LogFile);
end;

begin
  Writeln('DebugEngine Linux simple demo');
  try
    RunBatch;
  except
    on E: Exception do
      LogException(E);
  end;
end.
