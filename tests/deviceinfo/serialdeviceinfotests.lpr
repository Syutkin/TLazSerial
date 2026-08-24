program SerialDeviceInfoTests;

{$mode ObjFPC}{$H+}

uses
  {$IFDEF UNIX}
  CThreads,
  cwstring,
  {$ENDIF}
  SysUtils,
  ConsoleTestRunner,
  SerialCommandRunnerTests,
  SerialDeviceFormatTests,
  SerialDeviceParserTests,
  SerialDeviceCollectorTests,
  SerialPlatformCollectorSmokeTests,
  SerialWindowsDeviceTests;

procedure RunCommandRunnerHelper;
var
  I: Integer;
  MarkerFile: TextFile;
  Mode: string;
begin
  if ParamCount < 2 then
    Halt(64);

  Mode := ParamStr(2);
  if Mode = 'echo' then
  begin
    for I := 3 to ParamCount do
    begin
      if I > 3 then
        Write('|');
      Write(ParamStr(I));
    end;
    Halt(0);
  end;

  if Mode = 'empty' then
    Halt(0);

  if Mode = 'fail' then
  begin
    Write('failed');
    Halt(7);
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
    Halt(0);
  end;

  Halt(64);
end;

var
  Runner: TTestRunner;
begin
  if (ParamCount > 0) and
    (ParamStr(1) = '--command-runner-helper') then
    RunCommandRunnerHelper;

  Runner := TTestRunner.Create(nil);
  Runner.Initialize;
  Runner.Run;
  Runner.Free;
end.
