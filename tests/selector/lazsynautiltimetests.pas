unit LazSynaUtilTimeTests;

{$mode ObjFPC}{$H+}

interface

uses
  FpcUnit, TestRegistry, LazSynaUtil;

type
  TLazSynaUtilTimeTests = class(TTestCase)
  published
    procedure EqualTicksHaveZeroDelta;
    procedure IncreasingTicksHaveElapsedDelta;
    procedure TickDeltaHandlesUnsignedWrap;
    procedure TickDeltaHandlesSignedBoundary;
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
