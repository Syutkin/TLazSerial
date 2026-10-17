unit SerialCommandAuditTests;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, FpcUnit, TestRegistry, SerialCommandRunner;
function RunAuditOutputHelper: Integer;
type
  TSerialCommandAuditTests = class(TTestCase)
  published
    procedure SuccessfulCommandPreservesLargeFinalOutput;
    procedure FailedCommandPreservesLargeFinalOutput;
  end;
implementation
{$IFDEF LINUX}
uses BaseUnix;
{$ENDIF}
const PayloadSize = 500000;
function RunAuditOutputHelper: Integer;
var Data: AnsiString;
begin
  {$IFDEF LINUX}
  if fpFcntl(1, 1031 {F_SETPIPE_SZ}, 1048576) < 0 then
  begin Write('pipe-resize-unavailable'); Exit(77); end;
  {$ENDIF}
  Data := StringOfChar('z', PayloadSize);
  Write(Data);
  Flush(Output);
  Result := StrToIntDef(ParamStr(2), 0);
end;
procedure CheckFinalOutput(ExitStatus: Integer);
var Output: string; Success: Boolean;
begin
  Success := RunSerialCommand(ParamStr(0),
    ['--audit-output-helper', IntToStr(ExitStatus)], 5000, Output);
  if Output = 'pipe-resize-unavailable' then
    raise EIgnoredTest.Create('Pipe capacity cannot be increased in this environment');
  TAssert.AssertEquals(ExitStatus = 0, Success);
  TAssert.AssertEquals(PayloadSize, Length(Output));
  TAssert.AssertTrue('All output bytes must be retained',
    Output = StringOfChar('z', PayloadSize));
end;
procedure TSerialCommandAuditTests.SuccessfulCommandPreservesLargeFinalOutput;
begin CheckFinalOutput(0); end;
procedure TSerialCommandAuditTests.FailedCommandPreservesLargeFinalOutput;
begin CheckFinalOutput(7); end;
initialization RegisterTest(TSerialCommandAuditTests);
end.
