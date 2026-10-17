unit LazSerialReadRequirementTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, FpcUnit, TestRegistry, LazSynaSer,
  LazSerialTransportTests, LazSerialLineTests;

type
  { Characterizes the legacy path. These checks do not enable or prescribe
    a new public API; buffered receive will get its own contract tests. }
  TLazSerialReadRequirementTests = class(TTestCase)
  private
    procedure CheckMainThreadRead(ALineMode: Boolean);
  published
    procedure ZeroTimeoutPacketReadStillWaitsOnMainThread;
    procedure ZeroTimeoutLineReadStillWaitsOnMainThread;
    procedure PartialLineReadinessFallsBackToNativeProbe;
    procedure PartialLineReadFallsBackToNativeProbe;
    procedure CompleteBufferedPacketAvoidsNativeIO;
    procedure CompleteBufferedLineAvoidsNativeIO;
  end;

implementation

type
  TObservedReadSerial = class(TLineTestSerial)
  public
    Entered, Released: TEvent;
    Gated, GateTimedOut: Boolean;
    ReadCalls, ProbeCalls, WaitingCalls: Integer;
    ReadThreadId: TThreadID;
    constructor Create;
    destructor Destroy; override;
    function RecvBuffer(Buffer: Pointer; ALength: Integer): Integer; override;
    function CanRead(Timeout: Integer): Boolean; override;
    function WaitingData: Integer; override;
  end;

  TObservedReadTransport = class(TFakeSerialTransport)
  public
    Serial: TObservedReadSerial;
    LastTimeout: Integer;
    constructor Create;
    destructor Destroy; override;
    function NativeSerial: TBlockSerial; override;
    function ReadPacket(const ATimeout: Integer): AnsiString; override;
    function ReadString(const ATimeout: Integer): AnsiString; override;
  end;

  TReadGateRelease = class(TThread)
  private
    FSerial: TObservedReadSerial;
    procedure Delivered;
  protected
    procedure Execute; override;
  public
    EnteredTimedOut: Boolean;
    Deliveries: Integer;
    constructor Create(ASerial: TObservedReadSerial);
    destructor Destroy; override;
  end;

constructor TObservedReadSerial.Create;
begin
  inherited Create;
  Entered := TEvent.Create(nil, True, False, '');
  Released := TEvent.Create(nil, True, False, '');
end;

destructor TObservedReadSerial.Destroy;
begin
  Entered.Free;
  Released.Free;
  inherited Destroy;
end;

function TObservedReadSerial.RecvBuffer(Buffer: Pointer;
  ALength: Integer): Integer;
begin
  Inc(ReadCalls);
  ReadThreadId := GetCurrentThreadID;
  if Gated then
  begin
    Entered.SetEvent;
    GateTimedOut := Released.WaitFor(2000) <> wrSignaled;
  end;
  Result := inherited RecvBuffer(Buffer, ALength);
end;

function TObservedReadSerial.CanRead(Timeout: Integer): Boolean;
begin
  Inc(ProbeCalls);
  Result := inherited CanRead(Timeout);
end;

function TObservedReadSerial.WaitingData: Integer;
begin
  Inc(WaitingCalls);
  Result := inherited WaitingData;
end;

constructor TObservedReadTransport.Create;
begin
  inherited Create;
  Serial := TObservedReadSerial.Create;
  LastTimeout := -1;
end;

destructor TObservedReadTransport.Destroy;
begin
  Serial.Free;
  inherited Destroy;
end;

function TObservedReadTransport.NativeSerial: TBlockSerial;
begin
  Result := Serial;
end;

function TObservedReadTransport.ReadPacket(const ATimeout: Integer): AnsiString;
begin
  LastTimeout := ATimeout;
  Result := Serial.RecvPacket(ATimeout);
end;

function TObservedReadTransport.ReadString(const ATimeout: Integer): AnsiString;
begin
  LastTimeout := ATimeout;
  Result := Serial.RecvString(ATimeout);
end;

constructor TReadGateRelease.Create(ASerial: TObservedReadSerial);
begin
  inherited Create(True);
  FSerial := ASerial;
end;

destructor TReadGateRelease.Destroy;
begin
  // Own the queue entry until the test pumps or removes it. Do not rely on
  // FreeOnTerminate, which can remove a worker's queued callbacks in FPC.
  WaitFor;
  TThread.RemoveQueuedEvents(nil, @Delivered);
  inherited Destroy;
end;

procedure TReadGateRelease.Delivered;
begin
  Inc(Deliveries);
end;

procedure TReadGateRelease.Execute;
begin
  try
    EnteredTimedOut := FSerial.Entered.WaitFor(2000) <> wrSignaled;
    if not EnteredTimedOut then
      TThread.ForceQueue(nil, @Delivered);
  finally
    FSerial.Released.SetEvent;
  end;
end;

procedure TLazSerialReadRequirementTests.CheckMainThreadRead(ALineMode: Boolean);
const
  Payload: AnsiString = 'received' + #0 + #255;
var
  Component: TTestableLazSerial;
  Transport: TObservedReadTransport;
  Releaser: TReadGateRelease;
  Value: AnsiString;
begin
  Component := TTestableLazSerial.Create(nil);
  Releaser := nil;
  try
    Transport := TObservedReadTransport.Create;
    Component.InstallTransport(Transport);
    Component.RcvLineCRLF := ALineMode;
    // Isolate public ReadData delegation; no readiness worker is needed to
    // demonstrate that the caller performs the actual native read.
    Transport.OpenValue := True;
    Transport.Serial.Gated := True;
    if ALineMode then
      Transport.Serial.QueueIncoming(Payload + #13#10)
    else
      Transport.Serial.QueueIncoming(Payload);
    Releaser := TReadGateRelease.Create(Transport.Serial);
    Releaser.Start;
    Value := Component.ReadData;
    AssertEquals(Payload, Value);
    AssertEquals('The component passes a zero timeout', 0, Transport.LastTimeout);
    AssertFalse('Native read must reach the controlled release',
      Transport.Serial.GateTimedOut);
    AssertFalse('Controller must observe entry into native read',
      Releaser.EnteredTimedOut);
    AssertEquals('Native read still executes on the caller thread',
      Int64(MainThreadID), Int64(Transport.Serial.ReadThreadId));
    AssertEquals('No queued main-thread work is dispatched while read waits',
      0, Releaser.Deliveries);
    Releaser.WaitFor;
    CheckSynchronize(0);
    AssertEquals('Queued work can run after ReadData returns', 1, Releaser.Deliveries);
  finally
    Releaser.Free;
    Component.Free;
  end;
end;

procedure TLazSerialReadRequirementTests.ZeroTimeoutPacketReadStillWaitsOnMainThread;
begin
  CheckMainThreadRead(False);
end;

procedure TLazSerialReadRequirementTests.ZeroTimeoutLineReadStillWaitsOnMainThread;
begin
  CheckMainThreadRead(True);
end;

procedure TLazSerialReadRequirementTests.PartialLineReadinessFallsBackToNativeProbe;
var
  Serial: TObservedReadSerial;
begin
  Serial := TObservedReadSerial.Create;
  try
    Serial.LineBuffer := 'partial' + #13;
    AssertFalse(Serial.CanReadLine(0));
    AssertTrue('Incomplete line readiness consults native readiness',
      Serial.ProbeCalls > 0);
    AssertEquals('partial' + #13, Serial.LineBuffer);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialReadRequirementTests.PartialLineReadFallsBackToNativeProbe;
var
  Serial: TObservedReadSerial;
begin
  Serial := TObservedReadSerial.Create;
  try
    Serial.LineBuffer := 'partial' + #13;
    AssertEquals('', Serial.RecvString(0));
    AssertEquals(ErrTimeout, Serial.LastError);
    AssertTrue('Extraction of an incomplete line probes native input',
      Serial.WaitingCalls + Serial.ProbeCalls > 0);
    AssertEquals('partial' + #13, Serial.LineBuffer);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialReadRequirementTests.CompleteBufferedPacketAvoidsNativeIO;
var
  Serial: TObservedReadSerial;
begin
  Serial := TObservedReadSerial.Create;
  try
    Serial.LineBuffer := #0 + #255 + 'packet';
    AssertTrue(Serial.CanReadEx(0));
    AssertEquals(#0 + #255 + 'packet', Serial.RecvPacket(0));
    AssertEquals(0, Serial.ReadCalls + Serial.WaitingCalls + Serial.ProbeCalls);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialReadRequirementTests.CompleteBufferedLineAvoidsNativeIO;
var
  Serial: TObservedReadSerial;
begin
  Serial := TObservedReadSerial.Create;
  try
    Serial.LineBuffer := #13#10 + 'next' + #13#10 + 'tail';
    AssertTrue(Serial.CanReadLine(0));
    AssertEquals('', Serial.RecvString(0));
    AssertEquals(0, Serial.LastError);
    AssertEquals('next', Serial.RecvString(0));
    AssertEquals('tail', Serial.LineBuffer);
    AssertEquals(0, Serial.ReadCalls + Serial.WaitingCalls + Serial.ProbeCalls);
  finally
    Serial.Free;
  end;
end;

initialization
  RegisterTest(TLazSerialReadRequirementTests);

end.
