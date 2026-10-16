unit LazSerialConfigurationTests;

{$mode ObjFPC}{$H+}

interface

uses
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

initialization
  RegisterTest(TLazSerialConfigurationTests);

end.
