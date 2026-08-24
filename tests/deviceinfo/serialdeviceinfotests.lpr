program SerialDeviceInfoTests;

{$mode ObjFPC}{$H+}

uses
  {$IFDEF UNIX}
  CThreads,
  cwstring,
  {$ENDIF}
  ConsoleTestRunner,
  SerialCommandRunnerTests,
  SerialDeviceFormatTests,
  SerialDeviceParserTests,
  SerialDeviceCollectorTests,
  SerialWindowsDeviceTests;

var
  Runner: TTestRunner;
begin
  Runner := TTestRunner.Create(nil);
  Runner.Initialize;
  Runner.Run;
  Runner.Free;
end.
