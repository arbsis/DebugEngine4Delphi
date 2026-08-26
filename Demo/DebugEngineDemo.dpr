program DebugEngineDemo;

uses
  Vcl.Forms,
  uMain in 'uMain.pas' {Main},
  DebugEngine.AsmRegUtils in '..\src\DebugEngine.AsmRegUtils.pas',
  DebugEngine.Core in '..\src\DebugEngine.Core.pas',
  DebugEngine.DebugInfo in '..\src\DebugEngine.DebugInfo.pas',
  DebugEngine.DebugUtils in '..\src\DebugEngine.DebugUtils.pas',
  DebugEngine.Disasm in '..\src\DebugEngine.Disasm.pas',
  DebugEngine.HookException in '..\src\DebugEngine.HookException.pas',
  DebugEngine.Trace in '..\src\DebugEngine.Trace.pas',
  DebugEngine.MapParser in '..\src\DebugEngine.MapParser.pas',
  DebugEngine.CrashLog in '..\src\DebugEngine.CrashLog.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TMain, Main);
  Application.Run;
end.
