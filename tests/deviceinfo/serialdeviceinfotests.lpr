program SerialDeviceInfoTests;

{$mode ObjFPC}{$H+}

uses
  {$IFDEF UNIX}
  CThreads,
  {$ENDIF}
  ConsoleTestRunner,
  SerialDeviceFormatTests,
  SerialDeviceParserTests;

var
  Runner: TTestRunner;
begin
  Runner := TTestRunner.Create(nil);
  Runner.Initialize;
  Runner.Run;
  Runner.Free;
end.
