program DebugEngineDemo;

uses
  Vcl.Forms,
  uMain in 'uMain.pas' {Main},
  DebugEngine.AsmRegUtils in '..\Source\DebugEngine.AsmRegUtils.pas',
  DebugEngine.Core in '..\Source\DebugEngine.Core.pas',
  DebugEngine.DebugInfo in '..\Source\DebugEngine.DebugInfo.pas',
  DebugEngine.DebugUtils in '..\Source\DebugEngine.DebugUtils.pas',
  DebugEngine.Disasm in '..\Source\DebugEngine.Disasm.pas',
  DebugEngine.HookException in '..\Source\DebugEngine.HookException.pas',
  DebugEngine.Trace in '..\Source\DebugEngine.Trace.pas',
  DebugEngine.MapParser in '..\Source\DebugEngine.MapParser.pas',
  DebugEngine.CrashLog in '..\Source\DebugEngine.CrashLog.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TMain, Main);
  Application.Run;
end.
