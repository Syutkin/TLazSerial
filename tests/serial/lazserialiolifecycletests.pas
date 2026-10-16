unit LazSerialIoLifecycleTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SyncObjs, FpcUnit, TestRegistry, LazSerial, LazSerialDevices, LazSynaSer,
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
    procedure CheckReaderFailure(const ARaiseNative: Boolean);
  published
    procedure ReadWriteModesBinaryPayloadAndClosedErrors;
    procedure ReaderDeliversStatusAndDataOnceOnMainThread;
    procedure ReceiveExceptionDoesNotStopReader;
    procedure CloseFromReceiveStopsLateCallbacks;
    procedure DestroyFromReceiveStopsLateCallbacks;
    procedure RemovedEventFollowsCloseAndIgnoresOtherChanges;
    procedure ReaderExceptionClosesConnectionAndAllowsReopen;
    procedure ReaderErrorWithoutExceptionClosesConnection;
    procedure OrdinaryReadTimeoutKeepsConnectionOpen;
    procedure DestroyBeforeReaderErrorDeliveryCancelsCallbacks;
    procedure StaleReaderFailureDoesNotCloseReopenedConnection;
    procedure NativeTimeoutKeepsConnectionOpen;
    procedure ReaderErrorNotifiesAfterClose;
    procedure ReaderErrorHandlerCanDestroyComponent;
    procedure ReaderErrorHandlerCanReopenConnection;
    procedure DestroyCancelsReaderErrorNotification;
    procedure CloseStatusCanDestroyBeforeErrorNotification;
    procedure ReaderErrorSurvivesCloseError;
    procedure ReopenCancelsReaderErrorNotification;
    procedure ReaderExceptionWithoutNativeCodeIsReported;
  end;

implementation

uses
  SysUtils;

const
  ExpectedCallbackException = 'expected receive callback exception';

type
  TFailingReadinessTransport = class(TFakeSerialTransport)
  private
    FSerial: TBlockSerial;
  public
    FailureReported: TEvent;
    FailRead: Boolean;
    Attempts: LongInt;
    CloseThread: TThreadID;
    constructor Create;
    destructor Destroy; override;
    function NativeSerial: TBlockSerial; override;
    function CanRead(const ATimeout: Integer): Boolean; override;
    procedure Close; override;
  end;

type
  TTimeoutReadinessTransport = class(TFailingReadinessTransport)
  public
    function CanRead(const ATimeout: Integer): Boolean; override;
  end;

function TTimeoutReadinessTransport.CanRead(const ATimeout: Integer): Boolean;
begin
  InterlockedIncrement(Attempts);
  if ATimeout > 0 then
    Sleep(ATimeout);
  NativeSerial.SetSynaError(ErrTimeout);
  FailureReported.SetEvent;
  NativeSerial.ExceptCheck;
  Result := False;
end;

procedure TLazSerialIoLifecycleTests.NativeTimeoutKeepsConnectionOpen;
var
  Serial: TTestableLazSerial;
  Transport: TTimeoutReadinessTransport;
  RaiseNative: Boolean;
begin
  for RaiseNative := False to True do
  begin
    Serial := TTestableLazSerial.Create(nil);
    try
      Transport := TTimeoutReadinessTransport.Create;
      Transport.NativeSerial.RaiseExcept := RaiseNative;
      Serial.InstallTransport(Transport);
      Serial.Open;
      AssertEquals(Ord(wrSignaled), Ord(Transport.FailureReported.WaitFor(1000)));
      PumpFor(50);
      AssertTrue('A timeout must leave the connection active', Serial.Active);
      AssertTrue(Transport.IsOpen);
      AssertEquals(0, Transport.CloseCount);
      AssertTrue('The reader must continue after a timeout', Transport.Attempts > 1);
    finally
      Serial.Free;
    end;
  end;
end;

procedure TLazSerialIoLifecycleTests.StaleReaderFailureDoesNotCloseReopenedConnection;
var
  Serial: TTestableLazSerial;
  Transport: TFailingReadinessTransport;
begin
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TFailingReadinessTransport.Create;
    Serial.InstallTransport(Transport);
    Serial.Open;
    AssertEquals(Ord(wrSignaled), Ord(Transport.FailureReported.WaitFor(1000)));
    // Close joins the old reader without pumping its queued error delivery.
    Serial.Close;
    Transport.FailRead := False;
    Serial.Open;
    PumpFor(50);
    AssertTrue('An old reader error must not close the new connection', Serial.Active);
    AssertTrue(Transport.IsOpen);
    AssertEquals(1, Transport.CloseCount);
    AssertEquals(2, Transport.ConnectCount);
  finally
    Serial.Free;
  end;
end;

type
  TReaderErrorProbe = class
  public
    Serial: TTestableLazSerial;
    Transport: TFailingReadinessTransport;
    Count, Code: Integer;
    ErrorMessage: string;
    ErrorThread: TThreadID;
    ActiveOnError, OpenOnError: Boolean;
    DestroyOnError, ReopenOnError: Boolean;
    procedure ReaderFailed(Sender: TObject; ErrorCode: Integer;
      const AErrorMessage: string);
    procedure DestroyOnClose(Sender: TObject; Reason: THookSerialReason;
      const Value: string);
  end;

  TExceptionReadinessTransport = class(TFailingReadinessTransport)
  public
    function CanRead(const ATimeout: Integer): Boolean; override;
  end;

  TErrorClosingTransport = class(TFailingReadinessTransport)
  private
    FHandler: THookSerialStatus;
  public
    FailClose: Boolean;
    procedure SetStatusHandler(const AHandler: THookSerialStatus); override;
    procedure Close; override;
  end;

function TExceptionReadinessTransport.CanRead(const ATimeout: Integer): Boolean;
begin
  if ATimeout > 0 then
    Sleep(ATimeout);
  FailureReported.SetEvent;
  raise Exception.Create('readiness failed');
end;

procedure TReaderErrorProbe.ReaderFailed(Sender: TObject; ErrorCode: Integer;
  const AErrorMessage: string);
begin
  Inc(Count);
  Code := ErrorCode;
  ErrorMessage := AErrorMessage;
  ErrorThread := GetCurrentThreadID;
  ActiveOnError := Serial.Active;
  OpenOnError := Transport.IsOpen;
  if DestroyOnError then
    FreeAndNil(Serial)
  else if ReopenOnError then
  begin
    Transport.FailRead := False;
    Serial.Open;
  end;
end;

procedure TReaderErrorProbe.DestroyOnClose(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
begin
  if Reason = HR_SerialClose then
    FreeAndNil(Serial);
end;

procedure TErrorClosingTransport.SetStatusHandler(const AHandler: THookSerialStatus);
begin
  inherited SetStatusHandler(AHandler);
  FHandler := AHandler;
end;

procedure TErrorClosingTransport.Close;
var
  Error: ESynaSerError;
begin
  inherited Close;
  NativeSerial.SetSynaError(0);
  if Assigned(FHandler) then
    FHandler(Self, HR_SerialClose, DeviceName);
  if FailClose then
  begin
    Error := ESynaSerError.Create('secondary close error');
    Error.ErrorCode := 6;
    Error.ErrorMessage := 'secondary close error';
    raise Error;
  end;
end;

procedure TLazSerialIoLifecycleTests.ReaderErrorNotifiesAfterClose;
var
  Probe: TReaderErrorProbe;
  RaiseNative: Boolean;
begin
  for RaiseNative := False to True do
  begin
    Probe := TReaderErrorProbe.Create;
    try
      Probe.Serial := TTestableLazSerial.Create(nil);
      Probe.Transport := TErrorClosingTransport.Create;
      Probe.Transport.NativeSerial.RaiseExcept := RaiseNative;
      Probe.Serial.InstallTransport(Probe.Transport);
      Probe.Serial.OnError := @Probe.ReaderFailed;
      Probe.Serial.Open;
      AssertEquals(Ord(wrSignaled), Ord(Probe.Transport.FailureReported.WaitFor(1000)));
      AssertEquals('Delivery must wait for the main thread', 0, Probe.Count);
      PumpFor(50);
      AssertEquals(1, Probe.Count);
      AssertEquals(5, Probe.Code);
      AssertEquals(TBlockSerial.GetErrorDesc(5), Probe.ErrorMessage);
      AssertTrue(Probe.ErrorThread = MainThreadID);
      AssertFalse(Probe.ActiveOnError);
      AssertFalse(Probe.OpenOnError);
      AssertEquals(1, Probe.Transport.Attempts);
    finally
      Probe.Serial.Free;
      Probe.Free;
    end;
  end;
end;

procedure TLazSerialIoLifecycleTests.ReaderErrorHandlerCanDestroyComponent;
var
  Probe: TReaderErrorProbe;
begin
  Probe := TReaderErrorProbe.Create;
  try
    Probe.Serial := TTestableLazSerial.Create(nil);
    Probe.Transport := TFailingReadinessTransport.Create;
    Probe.Serial.InstallTransport(Probe.Transport);
    Probe.Serial.OnError := @Probe.ReaderFailed;
    Probe.DestroyOnError := True;
    Probe.Serial.Open;
    AssertEquals(Ord(wrSignaled), Ord(Probe.Transport.FailureReported.WaitFor(1000)));
    PumpFor(50);
    AssertEquals(1, Probe.Count);
    AssertNull(Probe.Serial);
  finally
    Probe.Serial.Free;
    Probe.Free;
  end;
end;

procedure TLazSerialIoLifecycleTests.ReaderErrorHandlerCanReopenConnection;
var
  Probe: TReaderErrorProbe;
begin
  Probe := TReaderErrorProbe.Create;
  try
    Probe.Serial := TTestableLazSerial.Create(nil);
    Probe.Transport := TFailingReadinessTransport.Create;
    Probe.Serial.InstallTransport(Probe.Transport);
    Probe.Serial.OnError := @Probe.ReaderFailed;
    Probe.ReopenOnError := True;
    Probe.Serial.Open;
    AssertEquals(Ord(wrSignaled), Ord(Probe.Transport.FailureReported.WaitFor(1000)));
    PumpFor(50);
    AssertEquals(1, Probe.Count);
    AssertTrue(Probe.Serial.Active);
    AssertTrue(Probe.Transport.IsOpen);
    AssertEquals(2, Probe.Transport.ConnectCount);
  finally
    Probe.Serial.Free;
    Probe.Free;
  end;
end;

procedure TLazSerialIoLifecycleTests.DestroyCancelsReaderErrorNotification;
var
  Probe: TReaderErrorProbe;
begin
  Probe := TReaderErrorProbe.Create;
  try
    Probe.Serial := TTestableLazSerial.Create(nil);
    Probe.Transport := TFailingReadinessTransport.Create;
    Probe.Serial.InstallTransport(Probe.Transport);
    Probe.Serial.OnError := @Probe.ReaderFailed;
    Probe.Serial.Open;
    AssertEquals(Ord(wrSignaled), Ord(Probe.Transport.FailureReported.WaitFor(1000)));
    FreeAndNil(Probe.Serial);
    PumpFor(50);
    AssertEquals(0, Probe.Count);
  finally
    Probe.Serial.Free;
    Probe.Free;
  end;
end;

procedure TLazSerialIoLifecycleTests.CloseStatusCanDestroyBeforeErrorNotification;
var
  Probe: TReaderErrorProbe;
begin
  Probe := TReaderErrorProbe.Create;
  try
    Probe.Serial := TTestableLazSerial.Create(nil);
    Probe.Transport := TErrorClosingTransport.Create;
    Probe.Serial.InstallTransport(Probe.Transport);
    Probe.Serial.OnError := @Probe.ReaderFailed;
    Probe.Serial.OnStatus := @Probe.DestroyOnClose;
    Probe.Serial.Open;
    AssertEquals(Ord(wrSignaled), Ord(Probe.Transport.FailureReported.WaitFor(1000)));
    PumpFor(50);
    AssertNull(Probe.Serial);
    AssertEquals(0, Probe.Count);
  finally
    Probe.Serial.Free;
    Probe.Free;
  end;
end;

procedure TLazSerialIoLifecycleTests.ReaderErrorSurvivesCloseError;
var
  Probe: TReaderErrorProbe;
begin
  Probe := TReaderErrorProbe.Create;
  try
    Probe.Serial := TTestableLazSerial.Create(nil);
    Probe.Transport := TErrorClosingTransport.Create;
    TErrorClosingTransport(Probe.Transport).FailClose := True;
    Probe.Serial.InstallTransport(Probe.Transport);
    Probe.Serial.OnError := @Probe.ReaderFailed;
    Probe.Serial.Open;
    AssertEquals(Ord(wrSignaled), Ord(Probe.Transport.FailureReported.WaitFor(1000)));
    PumpFor(50);
    AssertEquals(1, Probe.Count);
    AssertEquals(5, Probe.Code);
    AssertEquals(TBlockSerial.GetErrorDesc(5), Probe.ErrorMessage);
    AssertFalse(Probe.Serial.Active);
  finally
    Probe.Serial.Free;
    Probe.Free;
  end;
end;

procedure TLazSerialIoLifecycleTests.ReopenCancelsReaderErrorNotification;
var
  Probe: TReaderErrorProbe;
begin
  Probe := TReaderErrorProbe.Create;
  try
    Probe.Serial := TTestableLazSerial.Create(nil);
    Probe.Transport := TFailingReadinessTransport.Create;
    Probe.Serial.InstallTransport(Probe.Transport);
    Probe.Serial.OnError := @Probe.ReaderFailed;
    Probe.Serial.Open;
    AssertEquals(Ord(wrSignaled), Ord(Probe.Transport.FailureReported.WaitFor(1000)));
    Probe.Serial.Close;
    Probe.Transport.FailRead := False;
    Probe.Serial.Open;
    PumpFor(50);
    AssertEquals(0, Probe.Count);
    AssertTrue(Probe.Serial.Active);
  finally
    Probe.Serial.Free;
    Probe.Free;
  end;
end;

procedure TLazSerialIoLifecycleTests.ReaderExceptionWithoutNativeCodeIsReported;
var
  Probe: TReaderErrorProbe;
begin
  Probe := TReaderErrorProbe.Create;
  try
    Probe.Serial := TTestableLazSerial.Create(nil);
    Probe.Transport := TExceptionReadinessTransport.Create;
    Probe.Serial.InstallTransport(Probe.Transport);
    Probe.Serial.OnError := @Probe.ReaderFailed;
    Probe.Serial.Open;
    AssertEquals(Ord(wrSignaled), Ord(Probe.Transport.FailureReported.WaitFor(1000)));
    PumpFor(50);
    AssertEquals(1, Probe.Count);
    AssertEquals(0, Probe.Code);
    AssertEquals('readiness failed', Probe.ErrorMessage);
    AssertFalse(Probe.Serial.Active);
  finally
    Probe.Serial.Free;
    Probe.Free;
  end;
end;

constructor TFailingReadinessTransport.Create;
begin
  inherited Create;
  FSerial := TBlockSerial.Create;
  FailureReported := TEvent.Create(nil, True, False, '');
  FailRead := True;
end;

destructor TFailingReadinessTransport.Destroy;
begin
  FailureReported.Free;
  FSerial.Free;
  inherited Destroy;
end;

function TFailingReadinessTransport.NativeSerial: TBlockSerial;
begin
  Result := FSerial;
end;

function TFailingReadinessTransport.CanRead(const ATimeout: Integer): Boolean;
begin
  InterlockedIncrement(Attempts);
  if ATimeout > 0 then
    Sleep(ATimeout);
  if FailRead then
  begin
    FSerial.SetSynaError(5);
    FailureReported.SetEvent;
    FSerial.ExceptCheck;
  end
  else
  begin
    FSerial.SetSynaError(0);
    FailureReported.SetEvent;
  end;
  Result := False;
end;

procedure TFailingReadinessTransport.Close;
begin
  CloseThread := GetCurrentThreadID;
  inherited Close;
end;

procedure TLazSerialIoLifecycleTests.CheckReaderFailure(const ARaiseNative: Boolean);
var
  Deadline: QWord;
  Serial: TTestableLazSerial;
  Transport: TFailingReadinessTransport;
begin
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TFailingReadinessTransport.Create;
    Transport.NativeSerial.RaiseExcept := ARaiseNative;
    Serial.InstallTransport(Transport);
    Serial.Open;
    AssertEquals(Ord(wrSignaled), Ord(Transport.FailureReported.WaitFor(1000)));
    Deadline := GetTickCount64 + 500;
    repeat
      CheckSynchronize(1);
    until not Serial.Active or (GetTickCount64 >= Deadline);
    AssertFalse('A terminal reader error must deactivate the component', Serial.Active);
    AssertFalse(Transport.IsOpen);
    AssertEquals(1, Transport.CloseCount);
    AssertTrue('Reader cleanup must run on the main thread',
      Transport.CloseThread = MainThreadID);
    AssertEquals('Broken connection must not be retried by the reader',
      1, Transport.Attempts);
    Transport.FailRead := False;
    Serial.Open;
    AssertTrue(Serial.Active);
    AssertEquals(2, Transport.ConnectCount);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialIoLifecycleTests.ReaderExceptionClosesConnectionAndAllowsReopen;
begin
  CheckReaderFailure(True);
end;

procedure TLazSerialIoLifecycleTests.ReaderErrorWithoutExceptionClosesConnection;
begin
  CheckReaderFailure(False);
end;

procedure TLazSerialIoLifecycleTests.OrdinaryReadTimeoutKeepsConnectionOpen;
var
  Serial: TTestableLazSerial;
  Transport: TFailingReadinessTransport;
begin
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TFailingReadinessTransport.Create;
    Transport.FailRead := False;
    Serial.InstallTransport(Transport);
    Serial.Open;
    AssertEquals(Ord(wrSignaled), Ord(Transport.FailureReported.WaitFor(1000)));
    CheckSynchronize(0);
    AssertTrue(Serial.Active);
    AssertTrue(Transport.IsOpen);
    AssertEquals(0, Transport.CloseCount);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialIoLifecycleTests.DestroyBeforeReaderErrorDeliveryCancelsCallbacks;
var
  Probe: TSerialIoProbe;
  Serial: TTestableLazSerial;
  Transport: TFailingReadinessTransport;
begin
  Serial := TTestableLazSerial.Create(nil);
  Probe := TSerialIoProbe.Create;
  try
    Transport := TFailingReadinessTransport.Create;
    Transport.NativeSerial.RaiseExcept := True;
    Serial.InstallTransport(Transport);
    Serial.OnRxData := @Probe.DataReceived;
    Serial.OnStatus := @Probe.StatusChanged;
    Serial.Open;
    AssertEquals(Ord(wrSignaled), Ord(Transport.FailureReported.WaitFor(1000)));
    FreeAndNil(Serial);
    CheckSynchronize(0);
    AssertEquals(0, Probe.ReceiveCount);
    AssertEquals(0, Probe.StatusCount);
  finally
    Serial.Free;
    Probe.Free;
  end;
end;

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
