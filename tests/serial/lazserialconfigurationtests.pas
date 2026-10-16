unit LazSerialConfigurationTests;

{$mode ObjFPC}{$H+}

interface

uses
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  Classes, SysUtils, SyncObjs, TypInfo, FpcUnit, TestRegistry, LazSerial, LazSerialCommon,
  LazSerialTransport, LazSynaSer, LazSerialTransportTests;

type
  TLazSerialConfigurationTests = class(TTestCase)
  private
    procedure CheckRejectedProperty(const AName: string; const AValue: Int64);
  published
    procedure SuccessfulConfigurationPreservesExceptionPreference;
    procedure ApplyFailureRaisesWithNativeExceptionsDisabled;
    procedure ApplyFailurePreservesNativeExceptions;
    procedure ReadStateFailureDoesNotApplyConfiguration;
    procedure OpenFailureClosesPortAndCanRetry;
    procedure OpenFailurePreservesErrorWhenCleanupAlsoFails;
    procedure LiveParameterFailuresAreReported;
    procedure ReaderCannotEraseConfigurationError;
    procedure FailedBaudRateKeepsPreviousValue;
    procedure FailedCustomBaudRateKeepsPreviousValue;
    procedure FailedDataBitsKeepsPreviousValue;
    procedure FailedParityKeepsPreviousValue;
    procedure FailedStopBitsKeepsPreviousValue;
    procedure FailedFlowControlKeepsPreviousValue;
    procedure FailedCustomBaudRateCanRetrySameValue;
    procedure FailedFlowControlCanRetrySameValue;
    procedure PartialConfigurationFailureRestoresDriverState;
    procedure FailedCustomOverrideSwitchCanRetry;
    procedure FailedRollbackClosesConnectionAndPreservesError;
    procedure ConfigurationStatusesObserveCommittedValues;
    procedure ConfigurationCallbackCanDestroyAfterRollbackFailure;
    procedure ConfigurationCallbackCanReopenAfterRollbackFailure;
  end;

implementation

type
  { Config itself is real; only the driver operations are simulated. }
  TConfigurationTestSerial = class(TBlockSerial)
  public
    ReadError: Integer;
    ApplyError: Integer;
    ReadCount: Integer;
    ApplyCount: Integer;
    ReadGate: TEvent;
    ReadDone: TEvent;
    procedure GetCommState; override;
    procedure SetCommState; override;
  end;

  TConfigurationTestTransport = class(TLazSynapseSerialTransport)
  private
    FOpen: Boolean;
  protected
    function CreateSerial: TBlockSerial; override;
  public
    CloseCount: Integer;
    procedure Connect(const ADevice: string); override;
    procedure Close; override;
    function IsOpen: Boolean; override;
    function CanRead(const ATimeout: Integer): Boolean; override;
    function TestSerial: TConfigurationTestSerial;
  end;

  TFailingCleanupTransport = class(TConfigurationTestTransport)
  public
    procedure Close; override;
  end;

procedure TFailingCleanupTransport.Close;
begin
  inherited Close;
  NativeSerial.RaiseSynaError(ErrNoDeviceAnswer);
end;

procedure TLazSerialConfigurationTests.OpenFailurePreservesErrorWhenCleanupAlsoFails;
var
  Serial: TTestableLazSerial;
  Transport: TFailingCleanupTransport;
  ErrorCode: Integer;
begin
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TFailingCleanupTransport.Create;
    Serial.InstallTransport(Transport);
    Transport.TestSerial.ApplyError := ErrWrongParameter;
    Transport.NativeSerial.RaiseExcept := True;
    ErrorCode := 0;
    try
      Serial.Open;
    except
      on E: ESynaSerError do
        ErrorCode := E.ErrorCode;
    end;
    AssertEquals('Cleanup must preserve the original configuration error',
      ErrWrongParameter, ErrorCode);
    AssertFalse(Serial.Active);
    AssertFalse(Transport.IsOpen);
    AssertEquals(1, Transport.CloseCount);
    AssertTrue(Transport.NativeSerial.RaiseExcept);
  finally
    Serial.Free;
  end;
end;

procedure TConfigurationTestSerial.GetCommState;
begin
  Inc(ReadCount);
  RaiseSynaError(ReadError);
end;

procedure TConfigurationTestSerial.SetCommState;
begin
  Inc(ApplyCount);
  RaiseSynaError(ApplyError);
  if (ApplyError <> 0) and (ReadGate <> nil) then
  begin
    ReadGate.SetEvent;
    // A synchronized transport may block the reader until Config returns.
    // The bounded wait lets that implementation complete without deadlocking.
    ReadDone.WaitFor(200);
  end;
end;

function TConfigurationTestTransport.CreateSerial: TBlockSerial;
begin
  Result := TConfigurationTestSerial.Create;
end;

function TConfigurationTestTransport.TestSerial: TConfigurationTestSerial;
begin
  Result := TConfigurationTestSerial(NativeSerial);
end;

procedure TConfigurationTestTransport.Connect(const ADevice: string);
begin
  FOpen := True;
end;

procedure TConfigurationTestTransport.Close;
begin
  Inc(CloseCount);
  FOpen := False;
  // Like CloseSocket, cleanup clears LastError. The exception must retain it.
  NativeSerial.SetSynaError(0);
end;

function TConfigurationTestTransport.IsOpen: Boolean;
begin
  Result := FOpen;
end;

function TConfigurationTestTransport.CanRead(
  const ATimeout: Integer): Boolean;
begin
  if TestSerial.ReadGate <> nil then
  begin
    if TestSerial.ReadGate.WaitFor(ATimeout) = wrSignaled then
    begin
      NativeSerial.SetSynaError(0);
      TestSerial.ReadDone.SetEvent;
    end;
    Exit(False);
  end;
  if ATimeout > 0 then
    Sleep(ATimeout);
  Result := False;
end;

procedure TLazSerialConfigurationTests.
  SuccessfulConfigurationPreservesExceptionPreference;
var
  RaiseNative: Boolean;
  Transport: TConfigurationTestTransport;
begin
  Transport := TConfigurationTestTransport.Create;
  try
    for RaiseNative := False to True do
    begin
      Transport.NativeSerial.RaiseExcept := RaiseNative;
      Transport.Configure(57600, 7, 'E', SB2, fcRTS_CTS);
      AssertEquals(0, Transport.NativeSerial.LastError);
      AssertEquals(RaiseNative, Transport.NativeSerial.RaiseExcept);
      AssertEquals(57600, Transport.NativeSerial.dcb.BaudRate);
      AssertEquals(7, Transport.NativeSerial.dcb.ByteSize);
    end;
    AssertEquals(2, Transport.TestSerial.ReadCount);
    AssertEquals(2, Transport.TestSerial.ApplyCount);
  finally
    Transport.Free;
  end;
end;

procedure TLazSerialConfigurationTests.
  ApplyFailureRaisesWithNativeExceptionsDisabled;
var
  Raised: Boolean;
  Transport: TConfigurationTestTransport;
begin
  Transport := TConfigurationTestTransport.Create;
  try
    AssertFalse(Transport.NativeSerial.RaiseExcept);
    Transport.TestSerial.ApplyError := ErrWrongParameter;
    Raised := False;
    try
      Transport.Configure(115200, 8, 'N', SB1, fcNone);
    except
      on E: ESynaSerError do
      begin
        Raised := True;
        AssertEquals(ErrWrongParameter, E.ErrorCode);
        AssertEquals(TBlockSerial.GetErrorDesc(ErrWrongParameter),
          E.ErrorMessage);
      end;
    end;
    AssertTrue('Configuration errors must raise even with RaiseExcept=False',
      Raised);
    AssertFalse(Transport.NativeSerial.RaiseExcept);
    AssertEquals(ErrWrongParameter, Transport.NativeSerial.LastError);
  finally
    Transport.Free;
  end;
end;

procedure TLazSerialConfigurationTests.ApplyFailurePreservesNativeExceptions;
var
  Raised: Boolean;
  Transport: TConfigurationTestTransport;
begin
  Transport := TConfigurationTestTransport.Create;
  try
    Transport.NativeSerial.RaiseExcept := True;
    Transport.TestSerial.ApplyError := ErrWrongParameter;
    Raised := False;
    try
      Transport.Configure(115200, 8, 'N', SB1, fcNone);
    except
      on E: ESynaSerError do
      begin
        Raised := True;
        AssertEquals(ErrWrongParameter, E.ErrorCode);
      end;
    end;
    AssertTrue(Raised);
    AssertTrue(Transport.NativeSerial.RaiseExcept);
  finally
    Transport.Free;
  end;
end;

procedure TLazSerialConfigurationTests.ReadStateFailureDoesNotApplyConfiguration;
var
  Raised: Boolean;
  Transport: TConfigurationTestTransport;
begin
  Transport := TConfigurationTestTransport.Create;
  try
    Transport.TestSerial.ReadError := ErrNoDeviceAnswer;
    Raised := False;
    try
      Transport.Configure(115200, 8, 'N', SB1, fcNone);
    except
      on E: ESynaSerError do
      begin
        Raised := True;
        AssertEquals(ErrNoDeviceAnswer, E.ErrorCode);
      end;
    end;
    AssertTrue('A failed GetCommState must not be masked by SetCommState', Raised);
    AssertEquals(ErrNoDeviceAnswer, Transport.NativeSerial.LastError);
    AssertEquals(0, Transport.TestSerial.ApplyCount);
  finally
    Transport.Free;
  end;
end;

procedure TLazSerialConfigurationTests.OpenFailureClosesPortAndCanRetry;
var
  Raised: Boolean;
  Serial: TTestableLazSerial;
  Transport: TConfigurationTestTransport;
begin
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TConfigurationTestTransport.Create;
    Serial.InstallTransport(Transport);
    Transport.TestSerial.ApplyError := ErrWrongParameter;
    Raised := False;
    try
      Serial.Open;
    except
      on E: ESynaSerError do
      begin
        Raised := True;
        AssertEquals('Cleanup must not erase the reported error',
          ErrWrongParameter, E.ErrorCode);
      end;
    end;
    AssertTrue(Raised);
    AssertFalse(Serial.Active);
    AssertFalse(Transport.IsOpen);
    AssertEquals(1, Transport.CloseCount);
    AssertFalse(Serial.SynSer.RaiseExcept);

    Transport.TestSerial.ApplyError := 0;
    Serial.Open;
    AssertTrue(Serial.Active);
    AssertTrue(Transport.IsOpen);
    AssertEquals(2, Transport.TestSerial.ApplyCount);
    AssertEquals(0, Serial.SynSer.LastError);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialConfigurationTests.LiveParameterFailuresAreReported;
var
  Operation: Integer;
  Raised: Boolean;
  Serial: TTestableLazSerial;
  Transport: TConfigurationTestTransport;
begin
  for Operation := 0 to 5 do
  begin
    Serial := TTestableLazSerial.Create(nil);
    try
      Transport := TConfigurationTestTransport.Create;
      Serial.InstallTransport(Transport);
      Serial.Open;
      Transport.TestSerial.ApplyError := ErrWrongParameter;
      Raised := False;
      try
        case Operation of
          0: Serial.BaudRate := br_57600;
          1: Serial.CustomBaudRate := 57600;
          2: Serial.DataBits := db7bits;
          3: Serial.Parity := pEven;
          4: Serial.StopBits := sbTwo;
          5: Serial.FlowControl := fcRTS_CTS;
        end;
      except
        on E: ESynaSerError do
        begin
          Raised := True;
          AssertEquals(ErrWrongParameter, E.ErrorCode);
        end;
      end;
      AssertTrue('Live configuration operation ' + IntToStr(Operation), Raised);
      AssertFalse(Serial.SynSer.RaiseExcept);
    finally
      Serial.Free;
    end;
  end;
end;

procedure TLazSerialConfigurationTests.ReaderCannotEraseConfigurationError;
var
  Gate, Done: TEvent;
  Raised: Boolean;
  Serial: TTestableLazSerial;
  Transport: TConfigurationTestTransport;
begin
  Gate := TEvent.Create(nil, False, False, '');
  Done := TEvent.Create(nil, False, False, '');
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TConfigurationTestTransport.Create;
    Transport.TestSerial.ReadGate := Gate;
    Transport.TestSerial.ReadDone := Done;
    Serial.InstallTransport(Transport);
    Serial.Open;
    Transport.TestSerial.ApplyError := ErrWrongParameter;
    Raised := False;
    try
      Serial.BaudRate := br_57600;
    except
      on E: ESynaSerError do
      begin
        Raised := True;
        AssertEquals(ErrWrongParameter, E.ErrorCode);
      end;
    end;
    AssertTrue('Internal reader must not turn a rejected configuration into success',
      Raised);
  finally
    Serial.Free;
    Done.Free;
    Gate.Free;
  end;
end;

procedure TLazSerialConfigurationTests.CheckRejectedProperty(
  const AName: string; const AValue: Int64);
var
  OldValue: Int64;
  Raised: Boolean;
  Serial: TTestableLazSerial;
  Transport: TConfigurationTestTransport;
begin
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TConfigurationTestTransport.Create;
    Serial.InstallTransport(Transport);
    Serial.Open;
    OldValue := GetOrdProp(Serial, AName);
    Transport.TestSerial.ApplyError := ErrWrongParameter;
    Raised := False;
    try
      SetOrdProp(Serial, AName, AValue);
    except
      on E: ESynaSerError do
      begin
        Raised := True;
        AssertEquals(ErrWrongParameter, E.ErrorCode);
      end;
    end;
    AssertTrue('Driver must reject ' + AName, Raised);
    AssertEquals('Rejected setting must preserve ' + AName,
      OldValue, GetOrdProp(Serial, AName));
    Transport.TestSerial.ApplyError := 0;
    SetOrdProp(Serial, AName, AValue);
    AssertEquals(AValue, GetOrdProp(Serial, AName));
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialConfigurationTests.FailedBaudRateKeepsPreviousValue;
begin
  CheckRejectedProperty('BaudRate', Ord(br_57600));
end;

procedure TLazSerialConfigurationTests.FailedCustomBaudRateKeepsPreviousValue;
begin
  CheckRejectedProperty('CustomBaudRate', 57600);
end;

procedure TLazSerialConfigurationTests.FailedDataBitsKeepsPreviousValue;
begin
  CheckRejectedProperty('DataBits', Ord(db7bits));
end;

procedure TLazSerialConfigurationTests.FailedParityKeepsPreviousValue;
begin
  CheckRejectedProperty('Parity', Ord(pEven));
end;

procedure TLazSerialConfigurationTests.FailedStopBitsKeepsPreviousValue;
begin
  CheckRejectedProperty('StopBits', Ord(sbTwo));
end;

procedure TLazSerialConfigurationTests.FailedFlowControlKeepsPreviousValue;
begin
  CheckRejectedProperty('FlowControl', Ord(fcRTS_CTS));
end;

procedure TLazSerialConfigurationTests.FailedCustomBaudRateCanRetrySameValue;
var
  Count: Integer;
  Serial: TTestableLazSerial;
  Transport: TFakeSerialTransport;
begin
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TFakeSerialTransport.Create;
    Serial.InstallTransport(Transport);
    Serial.Open;
    Transport.FailConfigure := True;
    try
      Serial.CustomBaudRate := 57600;
      Fail('Expected configuration failure');
    except
      on E: EInvalidOperation do ;
    end;
    Count := Transport.ConfigCount;
    Transport.FailConfigure := False;
    Serial.CustomBaudRate := 57600;
    AssertEquals('Retry must reach the driver', Count + 1, Transport.ConfigCount);
    AssertEquals(57600, Transport.LastConfig.BaudRate);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialConfigurationTests.FailedFlowControlCanRetrySameValue;
var
  Count: Integer;
  Serial: TTestableLazSerial;
  Transport: TFakeSerialTransport;
begin
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TFakeSerialTransport.Create;
    Serial.InstallTransport(Transport);
    Serial.Open;
    Transport.FailConfigure := True;
    try
      Serial.FlowControl := fcRTS_CTS;
      Fail('Expected configuration failure');
    except
      on E: EInvalidOperation do ;
    end;
    Count := Transport.ConfigCount;
    Transport.FailConfigure := False;
    Serial.FlowControl := fcRTS_CTS;
    AssertEquals('Retry must reach the driver', Count + 1, Transport.ConfigCount);
    AssertEquals(Ord(fcRTS_CTS), Ord(Transport.LastConfig.FlowControl));
  finally
    Serial.Free;
  end;
end;

type
  TRollbackTestSerial = class(TConfigurationTestSerial)
  private
    FRestoring: Boolean;
  public
    DriverState: TDCB;
    FailNextApply, FailRestore, EmitStatus: Boolean;
    Component: TLazSerial;
    ObservedProperty: Int64;
    PropertyName: string;
    procedure GetCommState; override;
    procedure SetCommState; override;
  end;

  TRollbackTestTransport = class(TConfigurationTestTransport)
  protected
    function CreateSerial: TBlockSerial; override;
  public
    FailClose: Boolean;
    function Driver: TRollbackTestSerial;
    function CanRead(const ATimeout: Integer): Boolean; override;
    procedure Close; override;
  end;

  TConfigurationStatusProbe = class
  public
    Serial: TTestableLazSerial;
    Count: Integer;
    ExpectedValue: Int64;
    Mismatch, DestroyOnStatus, ReopenOnStatus, ActiveOnFirstStatus: Boolean;
    Transport: TRollbackTestTransport;
    procedure StatusChanged(Sender: TObject; Reason: THookSerialReason;
      const Value: string);
  end;

procedure TRollbackTestSerial.GetCommState;
begin
  Inc(ReadCount);
  DCB := DriverState;
  RaiseSynaError(0);
end;

procedure TRollbackTestSerial.SetCommState;
begin
  Inc(ApplyCount);
  if PropertyName <> '' then
    ObservedProperty := GetOrdProp(Component, PropertyName);
  if EmitStatus then
    DoStatus(HR_Connect, 'configuration');
  if FailNextApply then
  begin
    DriverState := DCB;
    FailNextApply := False;
    FRestoring := True;
    RaiseSynaError(ErrWrongParameter);
    Exit;
  end;
  if FRestoring and FailRestore then
  begin
    RaiseSynaError(ErrNoDeviceAnswer);
    Exit;
  end;
  DriverState := DCB;
  FRestoring := False;
  RaiseSynaError(0);
end;

function TRollbackTestTransport.CreateSerial: TBlockSerial;
begin
  Result := TRollbackTestSerial.Create;
end;

function TRollbackTestTransport.Driver: TRollbackTestSerial;
begin
  Result := TRollbackTestSerial(NativeSerial);
end;

function TRollbackTestTransport.CanRead(const ATimeout: Integer): Boolean;
begin
  Result := inherited CanRead(ATimeout);
  // Real readiness calls refresh LastError on every attempt.
  NativeSerial.SetSynaError(0);
end;

procedure TRollbackTestTransport.Close;
begin
  if not IsOpen then
    Exit;
  inherited Close;
  if FailClose then
    NativeSerial.RaiseSynaError(ErrNoDeviceAnswer);
end;

procedure TConfigurationStatusProbe.StatusChanged(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
begin
  if Reason <> HR_Connect then
    Exit;
  Inc(Count);
  if Count = 1 then
    ActiveOnFirstStatus := Serial.Active;
  if ReopenOnStatus then
  begin
    ReopenOnStatus := False;
    Transport.Driver.FailRestore := False;
    Transport.Driver.EmitStatus := False;
    Serial.Open;
  end
  else if DestroyOnStatus then
    FreeAndNil(Serial)
  else
    Mismatch := Mismatch or
      (GetOrdProp(Serial, 'FlowControl') <> ExpectedValue);
end;

procedure TLazSerialConfigurationTests.PartialConfigurationFailureRestoresDriverState;
const
  Names: array[0..5] of string = ('BaudRate', 'CustomBaudRate', 'DataBits',
    'Parity', 'StopBits', 'FlowControl');
  Values: array[0..5] of Int64 = (Ord(br_57600), 57600, Ord(db7bits),
    Ord(pEven), Ord(sbTwo), Ord(fcRTS_CTS));
var
  Serial: TTestableLazSerial;
  Transport: TRollbackTestTransport;
  PreviousState: TDCB;
  PreviousValue: Int64;
  Operation, ErrorCode: Integer;
  RaiseNative: Boolean;
begin
  for RaiseNative := False to True do
    for Operation := Low(Names) to High(Names) do
    begin
      Serial := TTestableLazSerial.Create(nil);
      try
        Transport := TRollbackTestTransport.Create;
        Serial.InstallTransport(Transport);
        Transport.NativeSerial.RaiseExcept := RaiseNative;
        Serial.Open;
        PreviousValue := GetOrdProp(Serial, Names[Operation]);
        PreviousState := Transport.Driver.DriverState;
        Transport.Driver.Component := Serial;
        Transport.Driver.PropertyName := Names[Operation];
        Transport.Driver.FailNextApply := True;
        ErrorCode := 0;
        try
          SetOrdProp(Serial, Names[Operation], Values[Operation]);
        except
          on E: ESynaSerError do ErrorCode := E.ErrorCode;
        end;
        AssertEquals(ErrWrongParameter, ErrorCode);
        AssertEquals(PreviousValue, GetOrdProp(Serial, Names[Operation]));
        AssertTrue('Restore all previously applied driver settings',
          CompareMem(@PreviousState, @Transport.Driver.DriverState, SizeOf(TDCB)));
        AssertTrue(Serial.Active);
        AssertEquals(RaiseNative, Transport.NativeSerial.RaiseExcept);
        SetOrdProp(Serial, Names[Operation], Values[Operation]);
        AssertEquals('Commit properties only after applying the driver settings',
          PreviousValue, Transport.Driver.ObservedProperty);
        AssertEquals(Values[Operation], GetOrdProp(Serial, Names[Operation]));
      finally
        Serial.Free;
      end;
    end;
end;

procedure TLazSerialConfigurationTests.FailedCustomOverrideSwitchCanRetry;
var
  Serial: TTestableLazSerial;
  Transport: TRollbackTestTransport;
  RaiseNative: Boolean;
begin
  for RaiseNative := False to True do
  begin
    Serial := TTestableLazSerial.Create(nil);
    try
      Transport := TRollbackTestTransport.Create;
      Serial.InstallTransport(Transport);
      Transport.NativeSerial.RaiseExcept := RaiseNative;
      Serial.CustomBaudRate := 57600;
      Serial.Open;
      Serial.BaudRate := br115200;
      Transport.Driver.FailNextApply := True;
      try
        Serial.CustomBaudRate := -1;
        Fail('Expected a rejected switch to the standard baud rate');
      except
        on E: ESynaSerError do AssertEquals(ErrWrongParameter, E.ErrorCode);
      end;
      AssertEquals(57600, Serial.CustomBaudRate);
      AssertEquals(Ord(br115200), Ord(Serial.BaudRate));
      AssertEquals(57600, Transport.Driver.DriverState.BaudRate);
      Serial.CustomBaudRate := -1;
      AssertEquals(115200, Transport.Driver.DriverState.BaudRate);
      Transport.Driver.FailNextApply := True;
      try
        Serial.CustomBaudRate := 38400;
        Fail('Expected a rejected switch to the custom baud rate');
      except
        on E: ESynaSerError do AssertEquals(ErrWrongParameter, E.ErrorCode);
      end;
      AssertEquals(-1, Serial.CustomBaudRate);
      AssertEquals(115200, Transport.Driver.DriverState.BaudRate);
      Serial.CustomBaudRate := 38400;
      AssertEquals(38400, Transport.Driver.DriverState.BaudRate);
    finally
      Serial.Free;
    end;
  end;
end;

procedure TLazSerialConfigurationTests.FailedRollbackClosesConnectionAndPreservesError;
var
  Serial: TTestableLazSerial;
  Transport: TRollbackTestTransport;
  PreviousFlow: TFlowControl;
  ErrorCode: Integer;
  RaiseNative: Boolean;
begin
  for RaiseNative := False to True do
  begin
    Serial := TTestableLazSerial.Create(nil);
    try
      Transport := TRollbackTestTransport.Create;
      Serial.InstallTransport(Transport);
      Transport.NativeSerial.RaiseExcept := RaiseNative;
      Serial.Open;
      PreviousFlow := Serial.FlowControl;
      Transport.Driver.FailNextApply := True;
      Transport.Driver.FailRestore := True;
      Transport.FailClose := True;
      ErrorCode := 0;
      try
        Serial.FlowControl := fcRTS_CTS;
      except
        on E: ESynaSerError do ErrorCode := E.ErrorCode;
      end;
      AssertEquals('Recovery and cleanup must preserve the first error',
        ErrWrongParameter, ErrorCode);
      AssertEquals(Ord(PreviousFlow), Ord(Serial.FlowControl));
      AssertFalse(Serial.Active);
      AssertFalse(Transport.IsOpen);
      AssertEquals(1, Transport.CloseCount);
      AssertEquals(RaiseNative, Transport.NativeSerial.RaiseExcept);
      Transport.Driver.FailRestore := False;
      Transport.FailClose := False;
      Serial.Open;
      AssertTrue(Serial.Active);
      AssertEquals(Ord(PreviousFlow), Ord(Serial.FlowControl));
    finally
      Serial.Free;
    end;
  end;
end;

procedure TLazSerialConfigurationTests.ConfigurationStatusesObserveCommittedValues;
var
  Probe: TConfigurationStatusProbe;
  Transport: TRollbackTestTransport;
begin
  Probe := TConfigurationStatusProbe.Create;
  try
    Probe.Serial := TTestableLazSerial.Create(nil);
    Transport := TRollbackTestTransport.Create;
    Probe.Serial.InstallTransport(Transport);
    Probe.Serial.Open;
    Probe.Serial.OnStatus := @Probe.StatusChanged;
    Transport.Driver.EmitStatus := True;
    Probe.ExpectedValue := Ord(fcRTS_CTS);
    Probe.Serial.FlowControl := fcRTS_CTS;
    AssertTrue(Probe.Count > 0);
    AssertFalse(Probe.Mismatch);
    Probe.Count := 0;
    Transport.Driver.FailNextApply := True;
    try
      Probe.Serial.FlowControl := fcDTR;
      Fail('Expected configuration failure');
    except
      on E: ESynaSerError do AssertEquals(ErrWrongParameter, E.ErrorCode);
    end;
    AssertTrue(Probe.Count > 0);
    AssertFalse('Failed candidates must not be visible in status callbacks', Probe.Mismatch);
  finally
    Probe.Serial.Free;
    Probe.Free;
  end;
end;

procedure TLazSerialConfigurationTests.ConfigurationCallbackCanDestroyAfterRollbackFailure;
var
  Probe: TConfigurationStatusProbe;
  Transport: TRollbackTestTransport;
  ErrorCode: Integer;
begin
  Probe := TConfigurationStatusProbe.Create;
  try
    Probe.Serial := TTestableLazSerial.Create(nil);
    Transport := TRollbackTestTransport.Create;
    Probe.Serial.InstallTransport(Transport);
    Probe.Serial.Open;
    Probe.DestroyOnStatus := True;
    Probe.Serial.OnStatus := @Probe.StatusChanged;
    Transport.Driver.EmitStatus := True;
    Transport.Driver.FailNextApply := True;
    Transport.Driver.FailRestore := True;
    ErrorCode := 0;
    try
      Probe.Serial.FlowControl := fcRTS_CTS;
    except
      on E: ESynaSerError do ErrorCode := E.ErrorCode;
    end;
    AssertEquals(ErrWrongParameter, ErrorCode);
    AssertNull(Probe.Serial);
    AssertEquals(1, Probe.Count);
  finally
    Probe.Serial.Free;
    Probe.Free;
  end;
end;

procedure TLazSerialConfigurationTests.ConfigurationCallbackCanReopenAfterRollbackFailure;
var
  Probe: TConfigurationStatusProbe;
  ErrorCode: Integer;
begin
  Probe := TConfigurationStatusProbe.Create;
  try
    Probe.Serial := TTestableLazSerial.Create(nil);
    Probe.Transport := TRollbackTestTransport.Create;
    Probe.Serial.InstallTransport(Probe.Transport);
    Probe.Serial.Open;
    Probe.ReopenOnStatus := True;
    Probe.ExpectedValue := Ord(Probe.Serial.FlowControl);
    Probe.Serial.OnStatus := @Probe.StatusChanged;
    Probe.Transport.Driver.EmitStatus := True;
    Probe.Transport.Driver.FailNextApply := True;
    Probe.Transport.Driver.FailRestore := True;
    ErrorCode := 0;
    try
      Probe.Serial.FlowControl := fcRTS_CTS;
    except
      on E: ESynaSerError do ErrorCode := E.ErrorCode;
    end;
    AssertEquals(ErrWrongParameter, ErrorCode);
    AssertTrue(Probe.Count > 0);
    AssertFalse('Publish the closed state before status callbacks',
      Probe.ActiveOnFirstStatus);
    AssertTrue('The callback must be able to reopen immediately', Probe.Serial.Active);
    AssertTrue(Probe.Transport.IsOpen);
    AssertFalse(Probe.Mismatch);
  finally
    Probe.Serial.Free;
    Probe.Free;
  end;
end;

initialization
  RegisterTest(TLazSerialConfigurationTests);

end.
