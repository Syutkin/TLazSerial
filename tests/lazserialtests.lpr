program LazSerialTests;

{$mode ObjFPC}{$H+}

uses
  HeapTrc,
  {$IFDEF UNIX}
  CThreads,
  cwstring,
  {$ENDIF}
  SysUtils,
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
  SerialRingBufferTests,
  LazSerialTransportTests,
  LazSerialAsyncWriteTests,
  LazSerialAsyncWindowsIoTests,
  LazSerialConfigurationTests,
  LazSerialIoLifecycleTests,
  LazSerialLineTests,
  LazSynaUtilTimeTests,
  LazSerialWindowsIoTests,
  SerialPlatformChangeSourceSmokeTests,
  SerialCommandRunnerTests,
  SerialDeviceFormatTests,
  SerialDeviceParserTests,
  SerialDeviceCollectorTests,
  SerialPlatformCollectorSmokeTests,
  SerialWindowsDeviceTests;

function RunCommandRunnerHelper: Integer;
var
  I: Integer;
  MarkerFile: TextFile;
  Mode: string;
begin
  if ParamCount < 2 then
    Exit(64);

  Mode := ParamStr(2);
  if Mode = 'echo' then
  begin
    for I := 3 to ParamCount do
    begin
      if I > 3 then
        Write('|');
      Write(ParamStr(I));
    end;
    Exit(0);
  end;

  if Mode = 'empty' then
    Exit(0);

  if Mode = 'fail' then
  begin
    Write('failed');
    Exit(7);
  end;

  if (Mode = 'partial-timeout') and (ParamCount >= 3) then
  begin
    Write('partial');
    Flush(Output);
    Sleep(StrToIntDef(ParamStr(4), 1000));
    AssignFile(MarkerFile, ParamStr(3));
    Rewrite(MarkerFile);
    WriteLn(MarkerFile, 'child survived');
    CloseFile(MarkerFile);
    Exit(0);
  end;

  Exit(64);
end;

var
  Runner: TTestRunner;
begin
  GlobalSkipIfNoLeaks := True;
  if (ParamCount > 0) and
    (ParamStr(1) = '--command-runner-helper') then
  begin
    ExitCode := RunCommandRunnerHelper;
    Exit;
  end;
  Application.Initialize;
  if (ParamCount = 2) and
    (ParamStr(1) = '--queued-serial-delivery-helper') then
  begin
    RunQueuedSerialDeliveryHelper(ParamStr(2));
    Exit;
  end;
  {$IF DEFINED(UNIX) AND DEFINED(LAZSERIAL_TESTING)}
  if (ParamCount = 1) and (ParamStr(1) = '--bandwidth-clock-helper') then
  begin
    RunBandwidthClockHelper;
    Exit;
  end;
  {$ENDIF}
  if (ParamCount = 2) and (ParamStr(1) = '--watcher-lifetime-helper') then
  begin
    KeepReleased := True;
    RunWatcherLifetimeHelper(ParamStr(2));
    Exit;
  end;
  if (ParamCount = 2) and (ParamStr(1) = '--selector-lifetime-helper') then
  begin
    KeepReleased := True;
    RunSelectorLifetimeHelper(ParamStr(2) = 'owner');
    Exit;
  end;
  if (ParamCount = 2) and (ParamStr(1) = '--synchronization-helper') then
  begin
    KeepReleased := True;
    RunSerialSynchronizationHelper(ParamStr(2));
    Exit;
  end;
  Runner := TTestRunner.Create(nil);
  Runner.Initialize;
  Runner.Run;
  Runner.Free;
end.
