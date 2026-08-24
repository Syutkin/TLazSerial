unit LazSerialIoLifecycleTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, FpcUnit, TestRegistry, LazSerial, LazSerialDevices, LazSynaSer,
  LazSerialTransportTests;

type
  TSerialIoProbe = class
  private
    FActiveDuringReceive: Boolean;
    FActiveDuringRemoved: Boolean;
    FActiveDuringStatus: Boolean;
    FCloseOnReceive: Boolean;
    FDestroyOnReceive: Boolean;
    FOrder: string;
    FRaiseOnFirstReceive: Boolean;
    FReceiveCount: Integer;
    FReceiveThreadId: TThreadID;
    FReceivedData: AnsiString;
    FRemovedCount: Integer;
    FSerial: TTestableLazSerial;
    FStatusCount: Integer;
    FStatusThreadId: TThreadID;
  public
    procedure DataReceived(Sender: TObject);
    procedure DeviceRemoved(Sender: TObject);
    procedure StatusChanged(Sender: TObject; Reason: THookSerialReason;
      const Value: string);
    property ActiveDuringReceive: Boolean read FActiveDuringReceive;
    property ActiveDuringRemoved: Boolean read FActiveDuringRemoved;
    property ActiveDuringStatus: Boolean read FActiveDuringStatus;
    property CloseOnReceive: Boolean read FCloseOnReceive
      write FCloseOnReceive;
    property DestroyOnReceive: Boolean read FDestroyOnReceive
      write FDestroyOnReceive;
    property Order: string read FOrder;
    property RaiseOnFirstReceive: Boolean read FRaiseOnFirstReceive
      write FRaiseOnFirstReceive;
    property ReceiveCount: Integer read FReceiveCount;
    property ReceiveThreadId: TThreadID read FReceiveThreadId;
    property ReceivedData: AnsiString read FReceivedData;
    property RemovedCount: Integer read FRemovedCount;
    property Serial: TTestableLazSerial read FSerial write FSerial;
    property StatusCount: Integer read FStatusCount;
    property StatusThreadId: TThreadID read FStatusThreadId;
  end;

  TLazSerialIoLifecycleTests = class(TTestCase)
  private
    function CreateDevice(const ADevice: string): TSerialDeviceInfo;
    function CreateSerial(out ATransport: TFakeSerialTransport;
      out AProbe: TSerialIoProbe): TTestableLazSerial;
    procedure PumpFor(const ADurationMs: Cardinal);
    procedure WaitForReceive(AProbe: TSerialIoProbe;
      const AExpectedCount: Integer; const ACatchExpectedException: Boolean);
  published
    procedure ReadWriteModesBinaryPayloadAndClosedErrors;
    procedure ReaderDeliversStatusAndDataOnceOnMainThread;
    procedure ReceiveExceptionDoesNotStopReader;
    procedure CloseFromReceiveStopsLateCallbacks;
    procedure DestroyFromReceiveStopsLateCallbacks;
    procedure RemovedEventFollowsCloseAndIgnoresOtherChanges;
  end;

implementation

uses
  SysUtils;

const
  ExpectedCallbackException = 'expected receive callback exception';

procedure TSerialIoProbe.DataReceived(Sender: TObject);
var
  SerialToDestroy: TTestableLazSerial;
begin
  Inc(FReceiveCount);
  FReceiveThreadId := GetCurrentThreadID;
  FOrder := FOrder + 'R';
  FActiveDuringReceive := (FSerial <> nil) and FSerial.Active;
  if FSerial <> nil then
    FReceivedData := FReceivedData + FSerial.ReadData;

  if FRaiseOnFirstReceive and (FReceiveCount = 1) then
    raise Exception.Create(ExpectedCallbackException);
  if FCloseOnReceive and (FSerial <> nil) then
    FSerial.Close;
  if FDestroyOnReceive and (FSerial <> nil) then
  begin
    SerialToDestroy := FSerial;
    FSerial := nil;
    SerialToDestroy.Free;
  end;
end;

procedure TSerialIoProbe.DeviceRemoved(Sender: TObject);
begin
  Inc(FRemovedCount);
  FOrder := FOrder + 'M';
  FActiveDuringRemoved := (FSerial <> nil) and FSerial.Active;
end;

procedure TSerialIoProbe.StatusChanged(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
begin
  if Reason <> HR_CanRead then
    Exit;
  Inc(FStatusCount);
  FStatusThreadId := GetCurrentThreadID;
  FOrder := FOrder + 'S';
  FActiveDuringStatus := (FSerial <> nil) and FSerial.Active;
end;

function TLazSerialIoLifecycleTests.CreateDevice(
  const ADevice: string): TSerialDeviceInfo;
begin
  Result := Default(TSerialDeviceInfo);
  Result.Device := ADevice;
end;

function TLazSerialIoLifecycleTests.CreateSerial(
  out ATransport: TFakeSerialTransport;
  out AProbe: TSerialIoProbe): TTestableLazSerial;
begin
  Result := TTestableLazSerial.Create(nil);
  ATransport := TFakeSerialTransport.Create;
  Result.InstallTransport(ATransport);
  AProbe := TSerialIoProbe.Create;
  AProbe.Serial := Result;
  Result.OnRxData := @AProbe.DataReceived;
  Result.OnStatus := @AProbe.StatusChanged;
  Result.OnRemoved := @AProbe.DeviceRemoved;
end;

procedure TLazSerialIoLifecycleTests.PumpFor(
  const ADurationMs: Cardinal);
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + ADurationMs;
  repeat
    CheckSynchronize(1);
  until GetTickCount64 >= Deadline;
end;

procedure TLazSerialIoLifecycleTests.WaitForReceive(
  AProbe: TSerialIoProbe; const AExpectedCount: Integer;
  const ACatchExpectedException: Boolean);
var
  Deadline: QWord;
  ExpectedExceptionSeen: Boolean;
begin
  Deadline := GetTickCount64 + 1000;
  ExpectedExceptionSeen := False;
  repeat
    try
      CheckSynchronize(10);
    except
      on E: Exception do
        if ACatchExpectedException and
          (E.Message = ExpectedCallbackException) then
          ExpectedExceptionSeen := True
        else
          raise;
    end;
  until (AProbe.ReceiveCount >= AExpectedCount) or
    (GetTickCount64 >= Deadline);
  AssertEquals(AExpectedCount, AProbe.ReceiveCount);
  if ACatchExpectedException then
    AssertTrue('Expected callback exception was not delivered',
      ExpectedExceptionSeen);
end;

procedure TLazSerialIoLifecycleTests.
  ReadWriteModesBinaryPayloadAndClosedErrors;
var
  Buffer: AnsiString;
  Probe: TSerialIoProbe;
  Raised: Boolean;
  Serial: TTestableLazSerial;
  Transport: TFakeSerialTransport;
begin
  Serial := CreateSerial(Transport, Probe);
  try
    AssertFalse(Serial.DataAvailable);

    Raised := False;
    try
      Serial.ReadData;
    except
      on E: Exception do
        Raised := True;
    end;
    AssertTrue(Raised);
    Raised := False;
    try
      Serial.WriteData('closed');
    except
      on E: Exception do
        Raised := True;
    end;
    AssertTrue(Raised);
    Buffer := 'x';
    Raised := False;
    try
      Serial.WriteBuffer(Buffer[1], Length(Buffer));
    except
      on E: Exception do
        Raised := True;
    end;
    AssertTrue(Raised);

    Serial.Open;
    AssertEquals(0, Serial.WriteData(''));
    AssertEquals(3, Serial.WriteData('A' + #0 + 'B'));
    Buffer := #1 + #0 + #2;
    AssertEquals(3, Serial.WriteBuffer(Buffer[1], Length(Buffer)));
    AssertEquals('A' + #0 + 'B' + Buffer, Transport.WrittenData);

    Serial.OnRxData := nil;
    Serial.OnStatus := nil;
    Transport.QueueIncoming('P' + #0 + 'Q');
    AssertTrue(Serial.DataAvailable);
    AssertEquals('P' + #0 + 'Q', Serial.ReadData);
    AssertEquals(1, Transport.ReadPacketCount);
    AssertEquals(0, Transport.ReadStringCount);

    Serial.RcvLineCRLF := True;
    Transport.QueueIncoming('line' + #13 + #10);
    AssertTrue(Serial.DataAvailable);
    AssertEquals('line' + #13 + #10, Serial.ReadData);
    AssertEquals(1, Transport.ReadPacketCount);
    AssertEquals(1, Transport.ReadStringCount);
  finally
    Serial.Free;
    Probe.Free;
  end;
end;

procedure TLazSerialIoLifecycleTests.
  ReaderDeliversStatusAndDataOnceOnMainThread;
var
  Probe: TSerialIoProbe;
  Serial: TTestableLazSerial;
  Transport: TFakeSerialTransport;
begin
  Serial := CreateSerial(Transport, Probe);
  try
    Serial.Open;
    Transport.QueueIncoming('payload');
    WaitForReceive(Probe, 1, False);
    PumpFor(50);

    AssertEquals(1, Probe.StatusCount);
    AssertEquals('SR', Probe.Order);
    AssertEquals('payload', Probe.ReceivedData);
    AssertTrue(Probe.ActiveDuringStatus);
    AssertTrue(Probe.ActiveDuringReceive);
    AssertTrue(Probe.StatusThreadId = MainThreadID);
    AssertTrue(Probe.ReceiveThreadId = MainThreadID);
  finally
    Serial.Free;
    Probe.Free;
  end;
end;

procedure TLazSerialIoLifecycleTests.ReceiveExceptionDoesNotStopReader;
var
  Probe: TSerialIoProbe;
  Serial: TTestableLazSerial;
  Transport: TFakeSerialTransport;
begin
  Serial := CreateSerial(Transport, Probe);
  try
    Serial.OnStatus := nil;
    Probe.RaiseOnFirstReceive := True;
    Serial.Open;
    Transport.QueueIncoming('first');
    WaitForReceive(Probe, 1, True);
    Transport.QueueIncoming('second');
    WaitForReceive(Probe, 2, False);

    AssertEquals('firstsecond', Probe.ReceivedData);
    AssertTrue(Serial.Active);
  finally
    Serial.Free;
    Probe.Free;
  end;
end;

procedure TLazSerialIoLifecycleTests.CloseFromReceiveStopsLateCallbacks;
var
  Probe: TSerialIoProbe;
  Serial: TTestableLazSerial;
  Transport: TFakeSerialTransport;
begin
  Serial := CreateSerial(Transport, Probe);
  try
    Serial.OnStatus := nil;
    Probe.CloseOnReceive := True;
    Serial.Open;
    Transport.QueueIncoming('first');
    Transport.QueueIncoming('late');
    WaitForReceive(Probe, 1, False);
    PumpFor(50);

    AssertEquals(1, Probe.ReceiveCount);
    AssertEquals('first', Probe.ReceivedData);
    AssertFalse(Serial.Active);
    AssertEquals(1, Transport.CloseCount);
  finally
    Serial.Free;
    Probe.Free;
  end;
end;

procedure TLazSerialIoLifecycleTests.DestroyFromReceiveStopsLateCallbacks;
var
  Probe: TSerialIoProbe;
  Serial: TTestableLazSerial;
  Transport: TFakeSerialTransport;
begin
  Serial := CreateSerial(Transport, Probe);
  Probe.DestroyOnReceive := True;
  Serial.OnStatus := nil;
  Serial.Open;
  Transport.QueueIncoming('first');
  Transport.QueueIncoming('late');
  WaitForReceive(Probe, 1, False);
  Serial := Probe.Serial;
  PumpFor(50);

  AssertNull(Serial);
  AssertEquals(1, Probe.ReceiveCount);
  AssertEquals('first', Probe.ReceivedData);
  Probe.Free;
end;

procedure TLazSerialIoLifecycleTests.
  RemovedEventFollowsCloseAndIgnoresOtherChanges;
var
  ActiveDevice: TSerialDeviceInfo;
  OtherDevice: TSerialDeviceInfo;
  Probe: TSerialIoProbe;
  Serial: TTestableLazSerial;
  Transport: TFakeSerialTransport;
begin
  ActiveDevice := CreateDevice('test-device');
  OtherDevice := CreateDevice('other-device');
  Serial := CreateSerial(Transport, Probe);
  try
    Serial.Device := ActiveDevice.Device;
    Serial.Open;
    Serial.AdoptWatcherSnapshot([ActiveDevice, OtherDevice]);
    Serial.CheckForDisconnectedDevice;
    AssertEquals(0, Probe.RemovedCount);
    AssertTrue(Serial.Active);

    Serial.AdoptWatcherSnapshot([OtherDevice]);
    Serial.CheckForDisconnectedDevice;
    AssertEquals(1, Probe.RemovedCount);
    AssertFalse(Probe.ActiveDuringRemoved);
    AssertFalse(Serial.Active);
    AssertEquals('M', Probe.Order);

    Serial.CheckForDisconnectedDevice;
    AssertEquals(1, Probe.RemovedCount);
  finally
    Serial.Free;
    Probe.Free;
  end;

  Serial := CreateSerial(Transport, Probe);
  try
    Serial.Device := ActiveDevice.Device;
    Serial.AdoptWatcherSnapshot([OtherDevice]);
    Serial.CheckForDisconnectedDevice;
    AssertEquals(0, Probe.RemovedCount);
  finally
    Serial.Free;
    Probe.Free;
  end;
end;

initialization
  RegisterTest(TLazSerialIoLifecycleTests);

end.
