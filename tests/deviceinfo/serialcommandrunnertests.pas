unit SerialCommandRunnerTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, FpcUnit, TestRegistry, SerialCommandRunner;

type
  TSerialCommandRunnerTests = class(TTestCase)
  published
    procedure TimeoutStopsCommandWithinBoundedTime;
  end;

implementation

procedure TSerialCommandRunnerTests.TimeoutStopsCommandWithinBoundedTime;
{$IFDEF UNIX}
var
  Elapsed: QWord;
  Output: string;
  StartedAt: QWord;
{$ENDIF}
begin
  {$IFDEF UNIX}
  StartedAt := GetTickCount64;
  AssertFalse(RunSerialCommand('/bin/sleep', ['5'], 100, Output));
  Elapsed := GetTickCount64 - StartedAt;

  AssertTrue(
    'Timed-out command must be terminated without waiting for normal exit',
    Elapsed < 1000
  );
  {$ENDIF}
end;

initialization
  RegisterTest(TSerialCommandRunnerTests);

end.
