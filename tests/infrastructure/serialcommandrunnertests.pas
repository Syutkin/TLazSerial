unit SerialCommandRunnerTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, FpcUnit, TestRegistry, SerialCommandRunner;

type
  TSerialCommandRunnerTests = class(TTestCase)
  private
    function CurrentExecutable: string;
    function NewMarkerPath: string;
  published
    procedure SuccessfulCommandCapturesOutputAndArguments;
    procedure EmptyOutputSucceeds;
    procedure NonZeroExitFails;
    procedure MissingExecutableFails;
    procedure ZeroTimeoutDoesNotStartCommand;
    procedure TimeoutKeepsPartialOutputAndStopsProcess;
  end;

implementation

function TSerialCommandRunnerTests.CurrentExecutable: string;
begin
  Result := ExpandFileName(ParamStr(0));
end;

function TSerialCommandRunnerTests.NewMarkerPath: string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'tlazserial-command-runner-' + IntToStr(GetProcessID) + '-' +
    IntToStr(Int64(GetTickCount64)) + '.marker';
end;

procedure TSerialCommandRunnerTests.
  SuccessfulCommandCapturesOutputAndArguments;
var
  Output: string;
begin
  AssertTrue(RunSerialCommand(
    CurrentExecutable,
    ['--command-runner-helper', 'echo', 'value with spaces', 'Привет'],
    5000,
    Output
  ));
  AssertEquals('value with spaces|Привет', Output);
end;

procedure TSerialCommandRunnerTests.EmptyOutputSucceeds;
var
  Output: string;
begin
  Output := 'stale';
  AssertTrue(RunSerialCommand(
    CurrentExecutable,
    ['--command-runner-helper', 'empty'],
    5000,
    Output
  ));
  AssertEquals('', Output);
end;

procedure TSerialCommandRunnerTests.NonZeroExitFails;
var
  Output: string;
begin
  AssertFalse(RunSerialCommand(
    CurrentExecutable,
    ['--command-runner-helper', 'fail'],
    5000,
    Output
  ));
  AssertEquals('failed', Output);
end;

procedure TSerialCommandRunnerTests.MissingExecutableFails;
var
  Output: string;
begin
  Output := 'stale';
  AssertFalse(RunSerialCommand(
    IncludeTrailingPathDelimiter(GetTempDir(False)) +
      'tlazserial-command-that-does-not-exist',
    [],
    5000,
    Output
  ));
  AssertEquals('', Output);
end;

procedure TSerialCommandRunnerTests.ZeroTimeoutDoesNotStartCommand;
var
  MarkerPath: string;
  Output: string;
begin
  MarkerPath := NewMarkerPath;
  DeleteFile(MarkerPath);
  AssertFalse(RunSerialCommand(
    CurrentExecutable,
    ['--command-runner-helper', 'partial-timeout', MarkerPath],
    0,
    Output
  ));
  Sleep(1100);
  AssertFalse(FileExists(MarkerPath));
end;

procedure TSerialCommandRunnerTests.TimeoutKeepsPartialOutputAndStopsProcess;
var
  Elapsed: QWord;
  MarkerPath: string;
  Output: string;
  StartedAt: QWord;
begin
  MarkerPath := NewMarkerPath;
  DeleteFile(MarkerPath);
  StartedAt := GetTickCount64;
  AssertFalse(RunSerialCommand(
    CurrentExecutable,
    ['--command-runner-helper', 'partial-timeout', MarkerPath, '2000'],
    1000,
    Output
  ));
  Elapsed := GetTickCount64 - StartedAt;

  AssertEquals('partial', Output);
  AssertTrue(
    'Timed-out command must be terminated without waiting for normal exit',
    Elapsed < 2000
  );
  Sleep(1500);
  AssertFalse(
    'Timed-out child process must not continue after RunSerialCommand returns',
    FileExists(MarkerPath)
  );
end;

initialization
  RegisterTest(TSerialCommandRunnerTests);

end.
