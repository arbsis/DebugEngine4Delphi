program DebugEngineSimple;

{ DebugEngine for Windows - minimal example.

  One exception is raised a few calls deep, caught, and logged with a madExcept-like header,
  the symbolized stack captured at raise, and the Threads / Modules sections.

  Symbols come from the detailed .map next to the executable (Project Options > Linking > Map file =
  Detailed / -GD). The map is converted in memory: no temporary file is written. To ship without the
  .map, embed it with the DD tool (DD -c -p App.map ; DD -i -s App.exe App.smap).

  The report is printed to the console and appended to DebugEngineSimple.log (next to the executable). }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  DebugEngine.HookException in '..\..\src\DebugEngine.HookException.pas',
  DebugEngine.CrashLog in '..\..\src\DebugEngine.CrashLog.pas';

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

procedure LogException(E: Exception);
var
  LogFile, Report: string;
begin
  LogFile := ChangeFileExt(ParamStr(0), '.log');
  Report := WriteCrashLog(E, LogFile, [crsHeader, crsException, crsThreads, crsModules]);
  Writeln(Report);
  Writeln('Report appended to: ', LogFile);
end;

begin
  Writeln('DebugEngine Windows simple demo');
  try
    RunBatch;
  except
    on E: Exception do
      LogException(E);
  end;
end.
