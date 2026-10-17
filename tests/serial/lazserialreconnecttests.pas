unit LazSerialReconnectTests;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, TypInfo, FpcUnit, TestRegistry, LazSerial, LazSerialCommon,
  LazSerialDevices, LazSerialReconnect, LazSerialStatistics, LazSerialTransportTests,
  SerialWatcher, SerialWatcherSupport, SerialWatcherComponentTests,
  LazSerialRead, LazSerialWrite, LazSynaSer;

type
  TLazSerialReconnectTests = class(TTestCase)
  private
    FOwner: TComponent;
    FSerial: TTestableLazSerial;
    FTransport: TFakeSerialTransport;
    FWatcher: TSerialWatcher;
    FScheduler: TFakeSerialRefreshScheduler;
    FDevice: TSerialDeviceInfo;
    FReconnected, FFailed, FErrorCount, FRemoved: Integer;
    FFailureCode: Integer;
    FFailureMessage: string;
    FAction: string;
    procedure Reconnected(Sender: TObject);
    procedure ReconnectFailed(Sender: TObject; ACode: Integer; const AMessage: string);
    procedure ReaderError(Sender: TObject; ACode: Integer; const AMessage: string);
    procedure Removed(Sender: TObject);
    procedure Status(Sender: TObject; Reason: THookSerialReason; const Value: string);
    procedure Act;
    procedure OpenSerial(ABuffered: Boolean = False);
    procedure Publish(const ADevices: array of TSerialDeviceInfo);
    procedure Unplug;
    procedure ReturnDevice;
    procedure Fire;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure DefaultsArePublishedAndOptional;
    procedure RemovalReconnectsRenamedPortWithSameSettings;
    procedure DisabledModePreservesExistingBehavior;
    procedure ManualCloseWhileInactiveCancelsWaiting;
    procedure ActiveFalseAndDisablingCancelWaiting;
    procedure ChangingDeviceCancelsWaiting;
    procedure RemovedHandlerCanCancelReconnect;
    procedure RetryBudgetReportsLastErrorOnce;
    procedure RetryCanSucceedAndResetStatistics;
    procedure InitialManualOpenFailureDoesNotArmReconnect;
    procedure ReconnectedHandlerCanClose;
    procedure ReconnectedHandlerCanDestroyOwner;
    procedure FailedHandlerCanDestroyOwner;
    procedure EventExceptionsPropagateWithoutRetry;
    procedure OpenStatusCanCancelSuccessfulReconnect;
    procedure OpenStatusCanDestroyOwner;
    procedure OpenStatusExceptionsAreNotOpeningFailures;
    procedure ReaderFailureBeforeWatcherStillReconnects;
    procedure ReaderErrorHandlerCanCancelWaiting;
    procedure BufferedFailureWaitsForCleanup;
    procedure BufferedOverflowDoesNotReconnect;
    procedure PendingWriteMustFinishBeforeReopening;
    procedure FailedEventExceptionPropagatesAfterBudgetExhaustion;
    procedure ReconnectApiRejectsWorkerAccess;
    procedure OpenStatusReopeningSuppressesOldReconnectNotification;
    procedure ReconnectedHandlerCanDestroyComponent;
  end;

implementation

type
  TReconnectWatcher = class(TSerialWatcher)
  public
    procedure Isolate;
    procedure Stop;
    procedure Publish(const ADevices: TSerialDeviceInfoArray);
  end;
  TReconnectPolicyAccess = class(TSerialReconnect);
  TReconnectTransport = class;
  TReconnectRead = class(TInterfacedObject, ISerialReadOperation)
  public
    Transport: TReconnectTransport;
    Changed: TSerialReadChanged;
    ErrorCode: Integer;
    HoldCleanup, Closing: Boolean;
    procedure Start;
    procedure Cancel;
    procedure ClosePort;
    procedure Detach;
    function DataAvailable(ALineMode: Boolean): Boolean;
    function TryReadData(ALineMode: Boolean; out AData: AnsiString): Boolean;
    function GetFailure(out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    function GetClosePending: Boolean;
    procedure Fail(ACode: Integer);
  end;
  TReconnectWrite = class(TInterfacedObject, ISerialWriteOperation)
  public
    Finished: TSerialWriteFinished;
    Id: QWord;
    procedure Start;
    procedure Cancel;
    procedure ClosePort;
    procedure Detach;
    procedure DeferDelivery;
    procedure Complete;
  end;
  TReconnectTransport = class(TFakeSerialTransport)
  private
    FHandler: THookSerialStatus;
  public
    ReaderFault: LongInt;
    EmitOpenStatus, FailNative: Boolean;
    ReadOp: TReconnectRead;
    WriteOp: TReconnectWrite;
    ReadReference: ISerialReadOperation;
    WriteReference: ISerialWriteOperation;
    procedure Connect(const ADevice: string); override;
    function CanRead(const ATimeout: Integer): Boolean; override;
    procedure SetStatusHandler(const AHandler: THookSerialStatus); override;
    function CreateReadOperation(const ALimit: Integer;
      const AOnChanged: TSerialReadChanged): ISerialReadOperation; override;
    function CreateWriteOperation(const AData: AnsiString; const AId: QWord;
      const ATimeout: Cardinal; const AOnFinished: TSerialWriteFinished): ISerialWriteOperation; override;
  end;
  TReconnectApiThread = class(TThread)
  public
    Serial: TLazSerial;
    Rejected: Integer;
    procedure Execute; override;
  end;

procedure TReconnectApiThread.Execute;
var I: Integer; Flag: Boolean; Value: Cardinal;
begin
  for I := 0 to 6 do
    try
      case I of
        0: Flag := Serial.AutoReconnect;
        1: Serial.AutoReconnect := True;
        2: Value := Serial.ReconnectIntervalMs;
        3: Serial.ReconnectIntervalMs := 100;
        4: Value := Serial.ReconnectMaxAttempts;
        5: Serial.ReconnectMaxAttempts := 2;
        6: Flag := Serial.ReconnectPending;
      end;
    except on E: ELazSerialThreadError do Inc(Rejected); end;
end;

procedure TReconnectWatcher.Isolate;
begin
  SetInfrastructure(TSerialManualChangeSource.Create,
    TFakeSerialRefreshScheduler.Create, True);
end;
procedure TReconnectWatcher.Stop;
begin StopWatching; end;
procedure TReconnectWatcher.Publish(const ADevices: TSerialDeviceInfoArray);
begin ApplyDevices(ADevices); end;

procedure TReconnectRead.Start;
begin end;
procedure TReconnectRead.Cancel;
begin end;
procedure TReconnectRead.ClosePort;
begin Closing := True; Transport.OpenValue := False; end;
procedure TReconnectRead.Detach;
begin Changed := nil; end;
function TReconnectRead.DataAvailable(ALineMode: Boolean): Boolean;
begin Result := False; end;
function TReconnectRead.TryReadData(ALineMode: Boolean; out AData: AnsiString): Boolean;
begin AData := ''; Result := False; end;
function TReconnectRead.GetFailure(out AErrorCode: Integer; out AErrorMessage: string): Boolean;
begin AErrorCode := ErrorCode; AErrorMessage := 'Read failed'; Result := ErrorCode <> 0; end;
function TReconnectRead.GetClosePending: Boolean;
begin Result := Closing and HoldCleanup; end;
procedure TReconnectRead.Fail(ACode: Integer);
var Handler: TSerialReadChanged;
begin
  ErrorCode := ACode;
  Handler := Changed;
  if Assigned(Handler) then Handler;
end;
procedure TReconnectWrite.Start;
begin end;
procedure TReconnectWrite.Cancel;
begin end;
procedure TReconnectWrite.ClosePort;
begin end;
procedure TReconnectWrite.Detach;
begin Finished := nil; end;
procedure TReconnectWrite.DeferDelivery;
begin end;
procedure TReconnectWrite.Complete;
var Handler: TSerialWriteFinished; Value: TSerialWriteResult;
begin
  Handler := Finished;
  Value := Default(TSerialWriteResult);
  Value.OperationId := Id;
  if Assigned(Handler) then Handler(Value);
end;

procedure TReconnectTransport.Connect(const ADevice: string);
var Error: ESynaSerError;
begin
  inherited Connect(ADevice);
  if FailNative then
  begin
    Error := ESynaSerError.Create('Device is busy');
    Error.ErrorCode := ErrAlreadyInUse;
    Error.ErrorMessage := Error.Message;
    raise Error;
  end;
  InterlockedExchange(ReaderFault, 0);
  if EmitOpenStatus and Assigned(FHandler) then
    FHandler(Self, HR_Connect, ADevice);
end;
function TReconnectTransport.CanRead(const ATimeout: Integer): Boolean;
var Error: ESynaSerError;
begin
  if InterlockedCompareExchange(ReaderFault, 0, 0) <> 0 then
  begin
    Error := ESynaSerError.Create('Device disappeared');
    Error.ErrorCode := ErrNoDeviceAnswer;
    Error.ErrorMessage := Error.Message;
    raise Error;
  end;
  Result := inherited CanRead(ATimeout);
end;
procedure TReconnectTransport.SetStatusHandler(const AHandler: THookSerialStatus);
begin FHandler := AHandler; inherited SetStatusHandler(AHandler); end;
function TReconnectTransport.CreateReadOperation(const ALimit: Integer;
  const AOnChanged: TSerialReadChanged): ISerialReadOperation;
begin
  ReadOp := TReconnectRead.Create;
  ReadOp.Transport := Self;
  ReadOp.Changed := AOnChanged;
  ReadReference := ReadOp;
  Result := ReadReference;
end;
function TReconnectTransport.CreateWriteOperation(const AData: AnsiString;
  const AId: QWord; const ATimeout: Cardinal;
  const AOnFinished: TSerialWriteFinished): ISerialWriteOperation;
begin
  WriteOp := TReconnectWrite.Create;
  WriteOp.Id := AId;
  WriteOp.Finished := AOnFinished;
  WriteReference := WriteOp;
  Result := WriteReference;
end;

procedure TLazSerialReconnectTests.SetUp;
var I: Integer;
begin
  inherited SetUp;
  FOwner := TComponent.Create(nil);
  FSerial := TTestableLazSerial.Create(FOwner);
  FTransport := TReconnectTransport.Create;
  FSerial.InstallTransport(FTransport);
  FSerial.Device := 'port0';
  FSerial.OnReconnected := @Reconnected;
  FSerial.OnReconnectFailed := @ReconnectFailed;
  FSerial.OnError := @ReaderError;
  FSerial.OnRemoved := @Removed;
  FWatcher := nil;
  FScheduler := TFakeSerialRefreshScheduler.Create;
  for I := 0 to FSerial.ComponentCount - 1 do
    if FSerial.Components[I] is TSerialWatcher then
    begin
      FWatcher := TSerialWatcher(FSerial.Components[I]);
      TReconnectWatcher(FWatcher).Isolate;
    end
    else if FSerial.Components[I] is TSerialReconnect then
      TReconnectPolicyAccess(FSerial.Components[I]).ReplaceScheduler(FScheduler);
  AssertNotNull(FWatcher);
  FDevice := Default(TSerialDeviceInfo);
  FDevice.Device := 'port0';
  FDevice.PersistentId := 'persistent-A';
  FReconnected := 0; FFailed := 0; FErrorCount := 0; FRemoved := 0;
  FAction := '';
end;

procedure TLazSerialReconnectTests.TearDown;
begin
  if FSerial <> nil then FSerial.OnStatus := nil;
  FreeAndNil(FOwner);
  FSerial := nil;
  inherited TearDown;
end;

procedure TLazSerialReconnectTests.Act;
begin
  if FAction = 'close' then FSerial.Close
  else if FAction = 'reopen' then
  begin
    FSerial.OnStatus := nil;
    FSerial.Close;
    FSerial.Device := 'manual-port';
    FSerial.Open;
  end
  else if FAction = 'destroyserial' then FreeAndNil(FSerial)
  else if FAction = 'destroy' then
  begin FSerial := nil; FreeAndNil(FOwner); end
  else if FAction = 'raise' then raise EInvalidOperation.Create('event exception');
end;
procedure TLazSerialReconnectTests.Reconnected(Sender: TObject);
begin
  Inc(FReconnected);
  AssertTrue(FSerial.Active);
  AssertFalse(FSerial.ReconnectPending);
  Act;
end;
procedure TLazSerialReconnectTests.ReconnectFailed(Sender: TObject;
  ACode: Integer; const AMessage: string);
begin
  Inc(FFailed);
  AssertFalse(FSerial.Active);
  AssertFalse(FSerial.ReconnectPending);
  FFailureCode := ACode;
  FFailureMessage := AMessage;
  Act;
end;
procedure TLazSerialReconnectTests.ReaderError(Sender: TObject;
  ACode: Integer; const AMessage: string);
begin Inc(FErrorCount); Act; end;
procedure TLazSerialReconnectTests.Removed(Sender: TObject);
begin Inc(FRemoved); Act; end;
procedure TLazSerialReconnectTests.Status(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
begin
  if Reason = HR_Connect then Act;
end;
procedure TLazSerialReconnectTests.OpenSerial(ABuffered: Boolean);
begin
  FSerial.BufferedRead := ABuffered;
  FSerial.AutoReconnect := True;
  FSerial.Open;
  TReconnectWatcher(FWatcher).Stop;
  Publish([FDevice]);
end;
procedure TLazSerialReconnectTests.Publish(const ADevices: array of TSerialDeviceInfo);
var Devices: TSerialDeviceInfoArray; I: Integer;
begin
  SetLength(Devices, Length(ADevices));
  for I := 0 to High(ADevices) do Devices[I] := ADevices[I];
  TReconnectWatcher(FWatcher).Publish(Devices);
end;
procedure TLazSerialReconnectTests.Unplug;
begin
  Publish([]);
  AssertFalse(FSerial.Active);
  AssertTrue(FSerial.ReconnectPending);
end;
procedure TLazSerialReconnectTests.ReturnDevice;
begin
  FDevice.Device := 'port7';
  Publish([FDevice]);
end;
procedure TLazSerialReconnectTests.Fire;
begin
  FScheduler.Fire;
  if FSerial <> nil then TReconnectWatcher(FWatcher).Stop;
end;

procedure TLazSerialReconnectTests.DefaultsArePublishedAndOptional;
var Prop: PPropInfo;
begin
  AssertFalse(FSerial.AutoReconnect);
  AssertFalse(FSerial.ReconnectPending);
  AssertEquals(1000, FSerial.ReconnectIntervalMs);
  AssertEquals(5, FSerial.ReconnectMaxAttempts);
  Prop := GetPropInfo(FSerial, 'ReconnectIntervalMs');
  AssertNotNull(Prop);
  AssertEquals(1000, Prop^.Default);
  Prop := GetPropInfo(FSerial, 'ReconnectMaxAttempts');
  AssertNotNull(Prop);
  AssertEquals(5, Prop^.Default);
end;
procedure TLazSerialReconnectTests.RemovalReconnectsRenamedPortWithSameSettings;
begin
  FSerial.CustomBaudRate := 12345;
  FSerial.DataBits := db7bits;
  FSerial.Parity := pEven;
  OpenSerial;
  Unplug;
  AssertEquals(1, FRemoved);
  ReturnDevice;
  Fire;
  AssertTrue(FSerial.Active);
  AssertEquals('port7', FSerial.Device);
  AssertEquals('port7', FTransport.LastConnectedDevice);
  AssertEquals(12345, FTransport.LastConfig.BaudRate);
  AssertEquals(7, FTransport.LastConfig.DataBits);
  AssertEquals('E', string(FTransport.LastConfig.Parity));
  AssertEquals(1, FReconnected);
end;
procedure TLazSerialReconnectTests.DisabledModePreservesExistingBehavior;
begin
  OpenSerial;
  FSerial.AutoReconnect := False;
  Publish([]);
  ReturnDevice;
  Fire;
  AssertFalse(FSerial.Active);
  AssertFalse(FSerial.ReconnectPending);
  AssertEquals(1, FTransport.ConnectCount);
end;
procedure TLazSerialReconnectTests.ManualCloseWhileInactiveCancelsWaiting;
begin
  OpenSerial;
  Unplug;
  FSerial.Close;
  ReturnDevice;
  Fire;
  AssertFalse(FSerial.ReconnectPending);
  AssertEquals(1, FTransport.ConnectCount);
end;
procedure TLazSerialReconnectTests.ActiveFalseAndDisablingCancelWaiting;
begin
  OpenSerial;
  Unplug;
  ReturnDevice;
  FSerial.Active := False;
  Fire;
  AssertFalse(FSerial.ReconnectPending);
  AssertEquals(1, FTransport.ConnectCount);
  FSerial.Device := FDevice.Device;
  FSerial.Open;
  TReconnectWatcher(FWatcher).Stop;
  Publish([FDevice]);
  Unplug;
  FSerial.AutoReconnect := False;
  ReturnDevice;
  Fire;
  AssertFalse(FSerial.ReconnectPending);
end;
procedure TLazSerialReconnectTests.ChangingDeviceCancelsWaiting;
begin
  OpenSerial;
  Unplug;
  FSerial.Device := 'manual-port';
  ReturnDevice;
  Fire;
  AssertFalse(FSerial.ReconnectPending);
  AssertEquals('manual-port', FSerial.Device);
  AssertEquals(1, FTransport.ConnectCount);
end;
procedure TLazSerialReconnectTests.RemovedHandlerCanCancelReconnect;
begin
  OpenSerial;
  FAction := 'close';
  Publish([]);
  ReturnDevice;
  Fire;
  AssertFalse(FSerial.ReconnectPending);
  AssertEquals(1, FTransport.ConnectCount);
end;
procedure TLazSerialReconnectTests.RetryBudgetReportsLastErrorOnce;
var I: Integer;
begin
  OpenSerial;
  Unplug;
  ReturnDevice;
  TReconnectTransport(FTransport).FailNative := True;
  for I := 1 to 5 do Fire;
  AssertEquals(6, FTransport.ConnectCount);
  AssertEquals(1, FFailed);
  AssertEquals(ErrAlreadyInUse, FFailureCode);
  AssertEquals('Device is busy', FFailureMessage);
  AssertEquals(0, FErrorCount);
  AssertFalse(FScheduler.Scheduled);
  Publish([FDevice]);
  Fire;
  AssertEquals(1, FFailed);
  AssertEquals(6, FTransport.ConnectCount);
end;
procedure TLazSerialReconnectTests.RetryCanSucceedAndResetStatistics;
begin
  OpenSerial;
  Unplug;
  AssertEquals(Ord(scrDeviceRemoved), Ord(FSerial.Statistics.CloseReason));
  ReturnDevice;
  FTransport.FailConnect := True;
  Fire;
  AssertTrue(FSerial.ReconnectPending);
  AssertEquals(Ord(scrDeviceRemoved), Ord(FSerial.Statistics.CloseReason));
  FTransport.FailConnect := False;
  Fire;
  AssertEquals(1, FReconnected);
  AssertEquals(0, FFailed);
  AssertEquals(Ord(scrNone), Ord(FSerial.Statistics.CloseReason));
end;
procedure TLazSerialReconnectTests.InitialManualOpenFailureDoesNotArmReconnect;
begin
  FSerial.AutoReconnect := True;
  FTransport.FailConnect := True;
  try
    FSerial.Open;
    Fail('Manual opening must still raise');
  except on E: EInvalidOperation do ; end;
  TReconnectWatcher(FWatcher).Stop;
  Publish([FDevice]);
  AssertFalse(FSerial.ReconnectPending);
  AssertFalse(FScheduler.Scheduled);
end;
procedure TLazSerialReconnectTests.ReconnectedHandlerCanClose;
begin
  OpenSerial;
  Unplug;
  ReturnDevice;
  FAction := 'close';
  Fire;
  AssertFalse(FSerial.Active);
  AssertFalse(FSerial.ReconnectPending);
  AssertEquals(1, FReconnected);
end;
procedure TLazSerialReconnectTests.ReconnectedHandlerCanDestroyOwner;
begin
  OpenSerial;
  Unplug;
  ReturnDevice;
  FAction := 'destroy';
  Fire;
  AssertNull(FOwner);
  AssertEquals(1, FReconnected);
end;
procedure TLazSerialReconnectTests.FailedHandlerCanDestroyOwner;
begin
  FSerial.ReconnectMaxAttempts := 1;
  OpenSerial;
  Unplug;
  ReturnDevice;
  FTransport.FailConnect := True;
  FAction := 'destroy';
  Fire;
  AssertNull(FOwner);
  AssertEquals(1, FFailed);
end;
procedure TLazSerialReconnectTests.EventExceptionsPropagateWithoutRetry;
begin
  OpenSerial;
  Unplug;
  ReturnDevice;
  FAction := 'raise';
  try Fire; Fail('Event exception must propagate');
  except on E: EInvalidOperation do AssertEquals('event exception', E.Message); end;
  AssertEquals(1, FReconnected);
  AssertEquals(0, FFailed);
  AssertFalse(FSerial.ReconnectPending);
end;
procedure TLazSerialReconnectTests.OpenStatusCanCancelSuccessfulReconnect;
begin
  OpenSerial;
  Unplug;
  ReturnDevice;
  TReconnectTransport(FTransport).EmitOpenStatus := True;
  FSerial.OnStatus := @Status;
  FAction := 'close';
  Fire;
  AssertFalse(FSerial.Active);
  AssertFalse(FSerial.ReconnectPending);
  AssertEquals(0, FReconnected);
end;
procedure TLazSerialReconnectTests.OpenStatusCanDestroyOwner;
begin
  OpenSerial;
  Unplug;
  ReturnDevice;
  TReconnectTransport(FTransport).EmitOpenStatus := True;
  FSerial.OnStatus := @Status;
  FAction := 'destroy';
  Fire;
  AssertNull(FOwner);
  AssertEquals(0, FReconnected);
end;
procedure TLazSerialReconnectTests.OpenStatusExceptionsAreNotOpeningFailures;
begin
  OpenSerial;
  Unplug;
  ReturnDevice;
  TReconnectTransport(FTransport).EmitOpenStatus := True;
  FSerial.OnStatus := @Status;
  FAction := 'raise';
  try Fire; Fail('Status exception must propagate');
  except on E: EInvalidOperation do AssertEquals('event exception', E.Message); end;
  AssertTrue(FSerial.Active);
  AssertFalse(FSerial.ReconnectPending);
  AssertEquals(0, FFailed);
end;
procedure TLazSerialReconnectTests.ReaderFailureBeforeWatcherStillReconnects;
var Deadline: QWord;
begin
  OpenSerial;
  InterlockedExchange(TReconnectTransport(FTransport).ReaderFault, 1);
  Deadline := GetTickCount64 + 2000;
  while (FErrorCount = 0) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
  AssertEquals(1, FErrorCount);
  AssertFalse(FSerial.Active);
  AssertTrue(FSerial.ReconnectPending);
  AssertFalse(FScheduler.Scheduled);
  Publish([]);
  ReturnDevice;
  Fire;
  AssertTrue(FSerial.Active);
  AssertEquals(1, FReconnected);
end;
procedure TLazSerialReconnectTests.ReaderErrorHandlerCanCancelWaiting;
begin
  OpenSerial(True);
  FAction := 'close';
  TReconnectTransport(FTransport).ReadOp.Fail(ErrNoDeviceAnswer);
  Publish([]);
  ReturnDevice;
  Fire;
  AssertFalse(FSerial.ReconnectPending);
  AssertEquals(1, FTransport.ConnectCount);
end;
procedure TLazSerialReconnectTests.BufferedFailureWaitsForCleanup;
var ReadOp: TReconnectRead; Reference: ISerialReadOperation;
begin
  FSerial.ReconnectMaxAttempts := 1;
  OpenSerial(True);
  ReadOp := TReconnectTransport(FTransport).ReadOp;
  Reference := ReadOp;
  ReadOp.HoldCleanup := True;
  ReadOp.Fail(ErrNoDeviceAnswer);
  AssertTrue(FSerial.ClosePending);
  Publish([]);
  ReturnDevice;
  Fire;
  Fire;
  AssertEquals(1, FTransport.ConnectCount);
  AssertTrue(FSerial.ReconnectPending);
  ReadOp.HoldCleanup := False;
  Fire;
  AssertTrue(FSerial.Active);
  AssertEquals(1, FReconnected);
end;
procedure TLazSerialReconnectTests.BufferedOverflowDoesNotReconnect;
begin
  OpenSerial(True);
  TReconnectTransport(FTransport).ReadOp.Fail(ErrReadBufferOverflow);
  AssertFalse(FSerial.Active);
  Publish([]);
  ReturnDevice;
  Fire;
  AssertFalse(FSerial.ReconnectPending);
  AssertEquals(1, FTransport.ConnectCount);
end;
procedure TLazSerialReconnectTests.PendingWriteMustFinishBeforeReopening;
var WriteOp: TReconnectWrite; Reference: ISerialWriteOperation;
begin
  OpenSerial(True);
  FSerial.WriteDataAsync('never replay this', 1000);
  WriteOp := TReconnectTransport(FTransport).WriteOp;
  Reference := WriteOp;
  Unplug;
  ReturnDevice;
  Fire;
  AssertTrue(FSerial.WritePending);
  AssertEquals(1, FTransport.ConnectCount);
  WriteOp.Complete;
  AssertFalse(FSerial.WritePending);
  Fire;
  AssertTrue(FSerial.Active);
  AssertEquals(1, FReconnected);
  AssertEquals('', FTransport.WrittenData);
end;

procedure TLazSerialReconnectTests.FailedEventExceptionPropagatesAfterBudgetExhaustion;
begin
  FSerial.ReconnectMaxAttempts := 1;
  OpenSerial;
  Unplug;
  ReturnDevice;
  FTransport.FailConnect := True;
  FAction := 'raise';
  try Fire; Fail('Failure event exception must propagate');
  except on E: EInvalidOperation do AssertEquals('event exception', E.Message); end;
  AssertEquals(1, FFailed);
  AssertFalse(FSerial.ReconnectPending);
  AssertFalse(FScheduler.Scheduled);
end;

procedure TLazSerialReconnectTests.ReconnectApiRejectsWorkerAccess;
var Worker: TReconnectApiThread;
begin
  Worker := TReconnectApiThread.Create(True);
  try
    Worker.Serial := FSerial;
    Worker.Start;
    Worker.WaitFor;
    AssertEquals(7, Worker.Rejected);
    AssertFalse(FSerial.AutoReconnect);
    AssertEquals(1000, FSerial.ReconnectIntervalMs);
    AssertEquals(5, FSerial.ReconnectMaxAttempts);
  finally Worker.Free; end;
end;

procedure TLazSerialReconnectTests.OpenStatusReopeningSuppressesOldReconnectNotification;
begin
  OpenSerial;
  Unplug;
  ReturnDevice;
  TReconnectTransport(FTransport).EmitOpenStatus := True;
  FSerial.OnStatus := @Status;
  FAction := 'reopen';
  Fire;
  AssertTrue(FSerial.Active);
  AssertEquals('manual-port', FTransport.LastConnectedDevice);
  AssertEquals(0, FReconnected);
  AssertFalse(FSerial.ReconnectPending);
end;

procedure TLazSerialReconnectTests.ReconnectedHandlerCanDestroyComponent;
begin
  OpenSerial;
  Unplug;
  ReturnDevice;
  FAction := 'destroyserial';
  Fire;
  AssertNull(FSerial);
  AssertEquals(1, FReconnected);
end;

initialization
  RegisterTest(TLazSerialReconnectTests);

end.
