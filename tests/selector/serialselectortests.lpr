program SerialSelectorTests;

{$mode ObjFPC}{$H+}

uses
  {$IFDEF UNIX}
  CThreads,
  cwstring,
  {$ENDIF}
  Interfaces,
  Forms,
  ConsoleTestRunner,
  LazSerialLifecycleTests,
  LazSerialThreadContractTests,
  SerialLinuxChangeSourceTests,
  SerialMacChangeSourceTests,
  SerialWindowsChangeSourceTests,
  SerialSelectorComponentTests,
  SerialWatcherComponentTests,
  LazSerialSetupTests,
  SerialInfrastructureTests;

var
  Runner: TTestRunner;
begin
  Application.Initialize;
  Runner := TTestRunner.Create(nil);
  Runner.Initialize;
  Runner.Run;
  Runner.Free;
end.
