program SerialSelectorTests;

{$mode ObjFPC}{$H+}

uses
  HeapTrc,
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
  SerialInfrastructureTests,
  LazSerialTransportTests,
  LazSerialConfigurationTests,
  LazSerialIoLifecycleTests,
  LazSerialLineTests,
  LazSynaUtilTimeTests,
  LazSerialWindowsIoTests,
  SerialPlatformChangeSourceSmokeTests;

var
  Runner: TTestRunner;
begin
  GlobalSkipIfNoLeaks := True;
  Application.Initialize;
  {$IF DEFINED(UNIX) AND DEFINED(LAZSERIAL_TESTING)}
  if (ParamCount = 1) and (ParamStr(1) = '--bandwidth-clock-helper') then
  begin
    RunBandwidthClockHelper;
    Halt(0);
  end;
  {$ENDIF}
  if (ParamCount = 2) and (ParamStr(1) = '--watcher-lifetime-helper') then
  begin
    KeepReleased := True;
    RunWatcherLifetimeHelper(ParamStr(2));
    Halt(0);
  end;
  if (ParamCount = 2) and (ParamStr(1) = '--selector-lifetime-helper') then
  begin
    KeepReleased := True;
    RunSelectorLifetimeHelper(ParamStr(2) = 'owner');
    Halt(0);
  end;
  Runner := TTestRunner.Create(nil);
  Runner.Initialize;
  Runner.Run;
  Runner.Free;
end.
