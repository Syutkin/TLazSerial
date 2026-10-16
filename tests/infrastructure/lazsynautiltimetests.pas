unit LazSynaUtilTimeTests;

{$mode ObjFPC}{$H+}

interface

uses
  FpcUnit, TestRegistry, LazSynaUtil;

type
  TLazSynaUtilTimeTests = class(TTestCase)
  {$IFDEF LAZSERIAL_TESTING}
  private
    procedure CheckBandwidthWait(ACurrent, ADeadline, AExpectedWait: LongWord);
  {$ENDIF}
  published
    procedure EqualTicksHaveZeroDelta;
    procedure IncreasingTicksHaveElapsedDelta;
    procedure TickDeltaHandlesUnsignedWrap;
    procedure TickDeltaHandlesSignedBoundary;
    {$IFDEF LAZSERIAL_TESTING}
    procedure MonotonicTicksWrapToLowWord;
    procedure BandwidthWaitsForFutureDeadline;
    procedure BandwidthWaitsAcrossUnsignedWrap;
    procedure BandwidthIgnoresExpiredDeadlineAcrossWrap;
    procedure BandwidthStartsWithoutWaiting;
    procedure BandwidthDeadlineWrapsWithoutOverflow;
    procedure BandwidthLongIntervalStaysWithinSignedRange;
    procedure DisabledBandwidthLeavesDeadlineUntouched;
    {$ENDIF}
    {$IF DEFINED(UNIX) AND DEFINED(LAZSERIAL_TESTING)}
    procedure MidnightDoesNotChangeElapsedTime;
    procedure WallClockChangesDoNotChangeElapsedTime;
    procedure WallClockRewindDoesNotChangeElapsedTime;
    procedure BandwidthWaitIsBoundedAcrossMidnight;
    {$ENDIF}
  end;

{$IF DEFINED(UNIX) AND DEFINED(LAZSERIAL_TESTING)}
procedure RunBandwidthClockHelper;
{$ENDIF}

implementation

uses
  SysUtils, LazSynaSer, SerialCommandRunner;

{$IFDEF LAZSERIAL_TESTING}
type
  EBandwidthWait = class(Exception);

  TBandwidthDeadlineProbe = class(TBlockSerial)
  protected
    procedure DoStatus(Reason: THookSerialReason; const Value: string); override;
  public
    WaitMs: LongWord;
    procedure Throttle(ALength, AMaxB: Integer; var ANext: LongWord);
  end;

var
  FakeTickCount: UInt64;

function ReadFakeTickCount: UInt64;
begin
  Result := FakeTickCount;
end;

procedure TBandwidthDeadlineProbe.DoStatus(Reason: THookSerialReason;
  const Value: string);
begin
  if Reason = HR_Wait then
  begin
    WaitMs := StrToInt64(Value);
    // Inspect the requested delay without actually sleeping, even on broken code.
    raise EBandwidthWait.Create('bandwidth wait intercepted');
  end;
end;

procedure TBandwidthDeadlineProbe.Throttle(ALength, AMaxB: Integer;
  var ANext: LongWord);
begin
  LimitBandwidth(ALength, AMaxB, ANext);
end;

procedure TLazSynaUtilTimeTests.CheckBandwidthWait(ACurrent, ADeadline,
  AExpectedWait: LongWord);
var
  Probe: TBandwidthDeadlineProbe;
begin
  Probe := TBandwidthDeadlineProbe.Create;
  SerialTestTickCount := @ReadFakeTickCount;
  try
    FakeTickCount := ACurrent;
    try
      Probe.Throttle(2, 1000, ADeadline);
    except
      on E: EBandwidthWait do ;
    end;
    AssertEquals('Requested bandwidth delay', Int64(AExpectedWait),
      Int64(Probe.WaitMs));
  finally
    SerialTestTickCount := nil;
    Probe.Free;
  end;
end;

procedure TLazSynaUtilTimeTests.MonotonicTicksWrapToLowWord;
begin
  SerialTestTickCount := @ReadFakeTickCount;
  try
    FakeTickCount := UInt64($FFFFFFFE);
    AssertEquals(Int64($FFFFFFFE), Int64(GetTick));
    FakeTickCount := UInt64($100000001);
    AssertEquals(Int64(1), Int64(GetTick));
  finally
    SerialTestTickCount := nil;
  end;
end;

procedure TLazSynaUtilTimeTests.BandwidthWaitsForFutureDeadline;
begin
  CheckBandwidthWait(100, 102, 2);
  CheckBandwidthWait($7FFFFFFE, $80000001, 3);
end;

procedure TLazSynaUtilTimeTests.BandwidthWaitsAcrossUnsignedWrap;
begin
  CheckBandwidthWait($FFFFFFFE, 2, 4);
end;

procedure TLazSynaUtilTimeTests.BandwidthIgnoresExpiredDeadlineAcrossWrap;
begin
  CheckBandwidthWait(2, $FFFFFFFE, 0);
  CheckBandwidthWait(100, 100, 0);
end;

procedure TLazSynaUtilTimeTests.BandwidthStartsWithoutWaiting;
begin
  CheckBandwidthWait($80000001, 0, 0);
  CheckBandwidthWait($FFFFFFFE, 0, 0);
end;

procedure TLazSynaUtilTimeTests.BandwidthDeadlineWrapsWithoutOverflow;
var
  Probe: TBandwidthDeadlineProbe;
  Next: LongWord;
begin
  Probe := TBandwidthDeadlineProbe.Create;
  SerialTestTickCount := @ReadFakeTickCount;
  try
    FakeTickCount := $FFFFFFFE;
    Next := 0;
    Probe.Throttle(4, 1000, Next);
    AssertEquals(Int64(2), Int64(Next));
    // Zero denotes an unset deadline; round this exceptional deadline down 1 ms.
    Next := 0;
    Probe.Throttle(2, 1000, Next);
    AssertEquals(Int64($FFFFFFFF), Int64(Next));
    CheckBandwidthWait($FFFFFFFE, Next, 1);
  finally
    SerialTestTickCount := nil;
    Probe.Free;
  end;
end;

procedure TLazSynaUtilTimeTests.BandwidthLongIntervalStaysWithinSignedRange;
var
  Probe: TBandwidthDeadlineProbe;
  Next: LongWord;
begin
  Probe := TBandwidthDeadlineProbe.Create;
  SerialTestTickCount := @ReadFakeTickCount;
  try
    FakeTickCount := 10;
    Next := 0;
    Probe.Throttle(High(Integer), 1, Next);
    AssertEquals(Int64(High(LongInt)), Int64(TickDelta(10, Next)));
  finally
    SerialTestTickCount := nil;
    Probe.Free;
  end;
end;

procedure TLazSynaUtilTimeTests.DisabledBandwidthLeavesDeadlineUntouched;
var
  Probe: TBandwidthDeadlineProbe;
  Next: LongWord;
begin
  Probe := TBandwidthDeadlineProbe.Create;
  SerialTestTickCount := @ReadFakeTickCount;
  try
    FakeTickCount := 100;
    Next := 200;
    Probe.Throttle(2, 0, Next);
    AssertEquals(Int64(200), Int64(Next));
    AssertEquals(Int64(0), Int64(Probe.WaitMs));
  finally
    SerialTestTickCount := nil;
    Probe.Free;
  end;
end;
{$ENDIF}

{$IF DEFINED(UNIX) AND DEFINED(LAZSERIAL_TESTING)}
var
  FakeWallTime: TDateTime;

function ReadFakeWallTime: TDateTime;
begin
  Result := FakeWallTime;
end;

type
  TBandwidthProbe = class(TBlockSerial)
  public
    procedure Throttle(var ANext: LongWord);
  end;

procedure TBandwidthProbe.Throttle(var ANext: LongWord);
begin
  LimitBandwidth(2, 1000, ANext);
end;

procedure RunBandwidthClockHelper;
var
  Probe: TBandwidthProbe;
  Next: LongWord;
begin
  SerialTestWallClock := @ReadFakeWallTime;
  Probe := TBandwidthProbe.Create;
  try
    Next := 0;
    FakeWallTime := EncodeDate(2026, 10, 16) + EncodeTime(23, 59, 59, 999);
    Probe.Throttle(Next);
    FakeWallTime := EncodeDate(2026, 10, 17) + EncodeTime(0, 0, 0, 1);
    Probe.Throttle(Next);
    WriteLn('bandwidth helper completed');
  finally
    Probe.Free;
    SerialTestWallClock := nil;
  end;
end;

procedure TLazSynaUtilTimeTests.MidnightDoesNotChangeElapsedTime;
var
  BeforeTick, AfterTick: LongWord;
begin
  SerialTestWallClock := @ReadFakeWallTime;
  try
    FakeWallTime := EncodeDate(2026, 10, 16) + EncodeTime(23, 59, 59, 999);
    BeforeTick := GetTick;
    FakeWallTime := EncodeDate(2026, 10, 17) + EncodeTime(0, 0, 0, 1);
    AfterTick := GetTick;
    AssertTrue('Midnight must not add a day to elapsed time',
      TickDelta(BeforeTick, AfterTick) < 1000);
  finally
    SerialTestWallClock := nil;
  end;
end;

procedure TLazSynaUtilTimeTests.WallClockChangesDoNotChangeElapsedTime;
var
  BeforeTick: LongWord;
begin
  SerialTestWallClock := @ReadFakeWallTime;
  try
    FakeWallTime := EncodeDate(2026, 10, 16) + EncodeTime(12, 0, 0, 0);
    BeforeTick := GetTick;
    FakeWallTime := FakeWallTime + 6 / 24;
    AssertTrue('Advancing the wall clock must not advance a timeout',
      TickDelta(BeforeTick, GetTick) < 1000);
  finally
    SerialTestWallClock := nil;
  end;
end;

procedure TLazSynaUtilTimeTests.WallClockRewindDoesNotChangeElapsedTime;
var
  BeforeTick: LongWord;
begin
  SerialTestWallClock := @ReadFakeWallTime;
  try
    FakeWallTime := EncodeDate(2026, 10, 16) + EncodeTime(12, 0, 0, 0);
    BeforeTick := GetTick;
    FakeWallTime := FakeWallTime - 6 / 24;
    AssertTrue('Rewinding the wall clock must not advance a timeout',
      TickDelta(BeforeTick, GetTick) < 1000);
  finally
    SerialTestWallClock := nil;
  end;
end;

procedure TLazSynaUtilTimeTests.BandwidthWaitIsBoundedAcrossMidnight;
var
  Output: string;
  Success: Boolean;
begin
  Success := RunSerialCommand(ExpandFileName(ParamStr(0)),
    ['--bandwidth-clock-helper'], 1500, Output);
  AssertTrue('Bandwidth wait must finish without a multi-hour sleep: ' + Output,
    Success);
  AssertTrue(Pos('bandwidth helper completed', Output) > 0);
end;
{$ENDIF}

procedure TLazSynaUtilTimeTests.EqualTicksHaveZeroDelta;
begin
  AssertEquals(Int64(0), Int64(TickDelta(42, 42)));
end;

procedure TLazSynaUtilTimeTests.IncreasingTicksHaveElapsedDelta;
begin
  AssertEquals(Int64(17), Int64(TickDelta(100, 117)));
end;

procedure TLazSynaUtilTimeTests.TickDeltaHandlesUnsignedWrap;
begin
  AssertEquals(Int64(3), Int64(TickDelta($FFFFFFFE, 1)));
  AssertEquals(Int64(1), Int64(TickDelta($FFFFFFFF, 0)));
end;

procedure TLazSynaUtilTimeTests.TickDeltaHandlesSignedBoundary;
begin
  AssertEquals(Int64(3), Int64(TickDelta($7FFFFFFE, $80000001)));
end;

initialization
  RegisterTest(TLazSynaUtilTimeTests);

end.
