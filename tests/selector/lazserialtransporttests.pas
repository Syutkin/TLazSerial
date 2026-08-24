unit LazSerialTransportTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SyncObjs, FpcUnit, TestRegistry, LazSerial, LazSerialCommon,
  LazSerialDevices, LazSerialTransport, LazSynaSer;

type
  TSerialConfigCall = record
    BaudRate: Integer;
    DataBits: Integer;
    Parity: Char;
    StopBits: Integer;
    FlowControl: TFlowControl;
  end;

  TFakeSerialTransport = class(TLazSerialTransport)
  private
    FCanRead: Boolean;
    FCarrier: Boolean;
    FCloseCount: Integer;
    FConfigCount: Integer;
    FConnectCount: Integer;
    FCTS: Boolean;
    FDeviceName: string;
    FDSR: Boolean;
    FDTR: Boolean;
    FFailConfigure: Boolean;
    FFailConnect: Boolean;
    FLastConfig: TSerialConfigCall;
    FLastConnectedDevice: string;
    FLeaveClosedOnConnect: Boolean;
    FLock: TCriticalSection;
    FOpen: Boolean;
    FReadEvent: TEvent;
    FReadPacketCount: Integer;
    FReadQueue: array of AnsiString;
    FReadStringCount: Integer;
    FRing: Boolean;
    FRTS: Boolean;
    FStatusHandler: THookSerialStatus;
    FWrittenData: AnsiString;
    function PopReadData: AnsiString;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Close; override;
    procedure Configure(ABaudRate, ADataBits: Integer; AParity: Char;
      AStopBits: Integer; AFlowControl: TFlowControl); override;
    procedure Connect(const ADevice: string); override;
    function CanRead(const ATimeout: Integer): Boolean; override;
    function DeviceName: string; override;
    function IsOpen: Boolean; override;
    function NativeSerial: TBlockSerial; override;
    function ReadPacket(const ATimeout: Integer): AnsiString; override;
    function ReadString(const ATimeout: Integer): AnsiString; override;
    function SendBuffer(ABuffer: Pointer; ASize: Integer): Integer; override;
    function SendString(const AData: AnsiString): Integer; override;
    procedure SetDTR(const AEnabled: Boolean); override;
    procedure SetRTS(const AEnabled: Boolean); override;
    procedure SetStatusHandler(const AHandler: THookSerialStatus); override;
    function GetCarrier: Boolean; override;
    function GetCTS: Boolean; override;
    function GetDSR: Boolean; override;
    function GetRing: Boolean; override;
    procedure QueueIncoming(const AData: AnsiString);
    property CanReadValue: Boolean read FCanRead write FCanRead;
    property CarrierValue: Boolean read FCarrier write FCarrier;
    property CloseCount: Integer read FCloseCount;
    property ConfigCount: Integer read FConfigCount;
    property ConnectCount: Integer read FConnectCount;
    property CTSValue: Boolean read FCTS write FCTS;
    property DSRValue: Boolean read FDSR write FDSR;
    property DTRValue: Boolean read FDTR;
    property FailConfigure: Boolean read FFailConfigure write FFailConfigure;
    property FailConnect: Boolean read FFailConnect write FFailConnect;
    property LastConfig: TSerialConfigCall read FLastConfig;
    property LastConnectedDevice: string read FLastConnectedDevice;
    property LeaveClosedOnConnect: Boolean
      read FLeaveClosedOnConnect write FLeaveClosedOnConnect;
    property OpenValue: Boolean read FOpen write FOpen;
    property ReadPacketCount: Integer read FReadPacketCount;
    property ReadStringCount: Integer read FReadStringCount;
    property RingValue: Boolean read FRing write FRing;
    property RTSValue: Boolean read FRTS;
    property WrittenData: AnsiString read FWrittenData;
  end;

  TTestableLazSerial = class(TLazSerial)
  public
    procedure AdoptWatcherSnapshot(
      const ADevices: TSerialDeviceInfoArray);
    procedure CheckForDisconnectedDevice;
    procedure InstallTransport(ATransport: TLazSerialTransport);
  end;

  TLazSerialTransportTests = class(TTestCase)
  private
    procedure AssertLastConfig(ATransport: TFakeSerialTransport;
      ABaudRate, ADataBits: Integer; AParity: Char; AStopBits: Integer;
      AFlowControl: TFlowControl);
    function CreateSerial(out ATransport: TFakeSerialTransport):
      TTestableLazSerial;
  published
    procedure NewComponentHasStableDefaults;
    procedure OpenCloseAndActiveFollowTransport;
    procedure ConnectFailureIsAtomicAndRetryable;
    procedure ClosedConnectResultIsAtomicAndRetryable;
    procedure ConfigureFailureIsAtomicAndRetryable;
    procedure ConfigurationUsesExactAndCurrentPropertyValues;
    procedure ModemLinesDelegateAndSignalsCombine;
  end;

implementation

uses
  SysUtils;

constructor TFakeSerialTransport.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FReadEvent := TEvent.Create(nil, True, False, '');
end;

destructor TFakeSerialTransport.Destroy;
begin
  FReadEvent.SetEvent;
  FReadEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TFakeSerialTransport.Close;
begin
  Inc(FCloseCount);
  FLock.Acquire;
  try
    FOpen := False;
    FReadEvent.SetEvent;
  finally
    FLock.Release;
  end;
end;

procedure TFakeSerialTransport.Configure(ABaudRate, ADataBits: Integer;
  AParity: Char; AStopBits: Integer; AFlowControl: TFlowControl);
begin
  Inc(FConfigCount);
  FLastConfig.BaudRate := ABaudRate;
  FLastConfig.DataBits := ADataBits;
  FLastConfig.Parity := AParity;
  FLastConfig.StopBits := AStopBits;
  FLastConfig.FlowControl := AFlowControl;
  if FFailConfigure then
    raise EInvalidOperation.Create('Simulated Config failure');
end;

procedure TFakeSerialTransport.Connect(const ADevice: string);
begin
  Inc(FConnectCount);
  FLastConnectedDevice := ADevice;
  FDeviceName := ADevice;
  if FFailConnect then
    raise EInvalidOperation.Create('Simulated Connect failure');
  FLock.Acquire;
  try
    FOpen := not FLeaveClosedOnConnect;
    if FOpen and (Length(FReadQueue) > 0) then
      FReadEvent.SetEvent;
  finally
    FLock.Release;
  end;
end;

function TFakeSerialTransport.CanRead(const ATimeout: Integer): Boolean;
var
  Handler: THookSerialStatus;
begin
  Result := FReadEvent.WaitFor(ATimeout) = wrSignaled;
  if not Result then
    Exit;
  FLock.Acquire;
  try
    Result := FOpen and (FCanRead or (Length(FReadQueue) > 0));
    if not Result then
      FReadEvent.ResetEvent;
    Handler := FStatusHandler;
  finally
    FLock.Release;
  end;
  if Result and Assigned(Handler) then
    Handler(Self, HR_CanRead, '');
end;

function TFakeSerialTransport.DeviceName: string;
begin
  Result := FDeviceName;
end;

function TFakeSerialTransport.IsOpen: Boolean;
begin
  Result := FOpen;
end;

function TFakeSerialTransport.NativeSerial: TBlockSerial;
begin
  Result := nil;
end;

function TFakeSerialTransport.ReadPacket(
  const ATimeout: Integer): AnsiString;
begin
  Inc(FReadPacketCount);
  Result := PopReadData;
end;

function TFakeSerialTransport.ReadString(
  const ATimeout: Integer): AnsiString;
begin
  Inc(FReadStringCount);
  Result := PopReadData;
end;

function TFakeSerialTransport.SendBuffer(ABuffer: Pointer;
  ASize: Integer): Integer;
begin
  if ASize > 0 then
  begin
    SetLength(FWrittenData, Length(FWrittenData) + ASize);
    Move(ABuffer^, FWrittenData[Length(FWrittenData) - ASize + 1], ASize);
  end;
  Result := ASize;
end;

function TFakeSerialTransport.SendString(
  const AData: AnsiString): Integer;
begin
  FWrittenData := FWrittenData + AData;
  Result := Length(AData);
end;

function TFakeSerialTransport.PopReadData: AnsiString;
var
  I: Integer;
begin
  Result := '';
  FLock.Acquire;
  try
    if Length(FReadQueue) = 0 then
      Exit;
    Result := FReadQueue[0];
    for I := 1 to High(FReadQueue) do
      FReadQueue[I - 1] := FReadQueue[I];
    SetLength(FReadQueue, Length(FReadQueue) - 1);
    if not FCanRead and (Length(FReadQueue) = 0) then
      FReadEvent.ResetEvent;
  finally
    FLock.Release;
  end;
end;

procedure TFakeSerialTransport.QueueIncoming(const AData: AnsiString);
var
  Index: Integer;
begin
  FLock.Acquire;
  try
    Index := Length(FReadQueue);
    SetLength(FReadQueue, Index + 1);
    FReadQueue[Index] := AData;
    FReadEvent.SetEvent;
  finally
    FLock.Release;
  end;
end;

procedure TFakeSerialTransport.SetDTR(const AEnabled: Boolean);
begin
  FDTR := AEnabled;
end;

procedure TFakeSerialTransport.SetRTS(const AEnabled: Boolean);
begin
  FRTS := AEnabled;
end;

procedure TFakeSerialTransport.SetStatusHandler(
  const AHandler: THookSerialStatus);
begin
  FStatusHandler := AHandler;
end;

function TFakeSerialTransport.GetCarrier: Boolean;
begin
  Result := FCarrier;
end;

function TFakeSerialTransport.GetCTS: Boolean;
begin
  Result := FCTS;
end;

function TFakeSerialTransport.GetDSR: Boolean;
begin
  Result := FDSR;
end;

function TFakeSerialTransport.GetRing: Boolean;
begin
  Result := FRing;
end;

procedure TTestableLazSerial.InstallTransport(
  ATransport: TLazSerialTransport);
begin
  ReplaceTransportForTesting(ATransport);
end;

procedure TTestableLazSerial.AdoptWatcherSnapshot(
  const ADevices: TSerialDeviceInfoArray);
begin
  AdoptWatcherSnapshotForTesting(ADevices);
end;

procedure TTestableLazSerial.CheckForDisconnectedDevice;
begin
  TriggerDisconnected;
end;

procedure TLazSerialTransportTests.AssertLastConfig(
  ATransport: TFakeSerialTransport; ABaudRate, ADataBits: Integer;
  AParity: Char; AStopBits: Integer; AFlowControl: TFlowControl);
begin
  AssertEquals(ABaudRate, ATransport.LastConfig.BaudRate);
  AssertEquals(ADataBits, ATransport.LastConfig.DataBits);
  AssertEquals(AParity, ATransport.LastConfig.Parity);
  AssertEquals(AStopBits, ATransport.LastConfig.StopBits);
  AssertEquals(Ord(AFlowControl), Ord(ATransport.LastConfig.FlowControl));
end;

function TLazSerialTransportTests.CreateSerial(
  out ATransport: TFakeSerialTransport): TTestableLazSerial;
begin
  Result := TTestableLazSerial.Create(nil);
  ATransport := TFakeSerialTransport.Create;
  Result.InstallTransport(ATransport);
end;

procedure TLazSerialTransportTests.NewComponentHasStableDefaults;
var
  Serial: TLazSerial;
begin
  Serial := TLazSerial.Create(nil);
  try
    AssertFalse(Serial.Active);
    AssertEquals(Ord(Low(TBaudRate)), Ord(Serial.BaudRate));
    AssertEquals(-1, Serial.CustomBaudRate);
    AssertEquals(Ord(db8bits), Ord(Serial.DataBits));
    AssertEquals(Ord(pNone), Ord(Serial.Parity));
    AssertEquals(Ord(fcNone), Ord(Serial.FlowControl));
    AssertEquals(Ord(sbOne), Ord(Serial.StopBits));
    AssertFalse(Serial.RcvLineCRLF);
    {$IFDEF LINUX}
    AssertEquals('/dev/ttyS0', Serial.Device);
    {$ELSE}
    AssertEquals('COM1', Serial.Device);
    {$ENDIF}
    AssertNotNull(Serial.SynSer);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialTransportTests.OpenCloseAndActiveFollowTransport;
var
  Serial: TTestableLazSerial;
  Transport: TFakeSerialTransport;
begin
  Serial := CreateSerial(Transport);
  try
    Serial.Device := 'test-device';
    Serial.Open;
    Serial.Open;

    AssertTrue(Serial.Active);
    AssertTrue(Transport.IsOpen);
    AssertEquals(1, Transport.ConnectCount);
    AssertEquals(1, Transport.ConfigCount);
    AssertEquals('test-device', Transport.LastConnectedDevice);

    Serial.Close;
    Serial.Close;
    AssertFalse(Serial.Active);
    AssertFalse(Transport.IsOpen);
    AssertEquals(1, Transport.CloseCount);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialTransportTests.ConnectFailureIsAtomicAndRetryable;
var
  Raised: Boolean;
  Serial: TTestableLazSerial;
  Transport: TFakeSerialTransport;
begin
  Serial := CreateSerial(Transport);
  try
    Transport.FailConnect := True;
    Raised := False;
    try
      Serial.Open;
    except
      on E: EInvalidOperation do
        Raised := True;
    end;
    AssertTrue(Raised);
    AssertFalse(Serial.Active);
    AssertFalse(Transport.IsOpen);
    AssertEquals(1, Transport.CloseCount);

    Transport.FailConnect := False;
    Serial.Open;
    AssertTrue(Serial.Active);
    AssertEquals(2, Transport.ConnectCount);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialTransportTests.ClosedConnectResultIsAtomicAndRetryable;
var
  Raised: Boolean;
  Serial: TTestableLazSerial;
  Transport: TFakeSerialTransport;
begin
  Serial := CreateSerial(Transport);
  try
    Transport.LeaveClosedOnConnect := True;
    Raised := False;
    try
      Serial.Open;
    except
      on E: Exception do
        Raised := True;
    end;
    AssertTrue(Raised);
    AssertFalse(Serial.Active);
    AssertFalse(Transport.IsOpen);

    Transport.LeaveClosedOnConnect := False;
    Serial.Open;
    AssertTrue(Serial.Active);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialTransportTests.ConfigureFailureIsAtomicAndRetryable;
var
  Raised: Boolean;
  Serial: TTestableLazSerial;
  Transport: TFakeSerialTransport;
begin
  Serial := CreateSerial(Transport);
  try
    Transport.FailConfigure := True;
    Raised := False;
    try
      Serial.Open;
    except
      on E: EInvalidOperation do
        Raised := True;
    end;
    AssertTrue(Raised);
    AssertFalse(Serial.Active);
    AssertFalse(Transport.IsOpen);
    AssertEquals(1, Transport.CloseCount);

    Transport.FailConfigure := False;
    Serial.Open;
    AssertTrue(Serial.Active);
    AssertEquals(2, Transport.ConnectCount);
    AssertEquals(2, Transport.ConfigCount);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialTransportTests.
  ConfigurationUsesExactAndCurrentPropertyValues;
var
  ConfigCount: Integer;
  Serial: TTestableLazSerial;
  Transport: TFakeSerialTransport;
begin
  Serial := CreateSerial(Transport);
  try
    Serial.BaudRate := br_57600;
    Serial.DataBits := db7bits;
    Serial.Parity := pEven;
    Serial.StopBits := sbTwo;
    Serial.FlowControl := fcRTS_CTS;
    AssertEquals(0, Transport.ConfigCount);

    Serial.Open;
    AssertLastConfig(Transport, 57600, 7, 'E', SB2, fcRTS_CTS);

    Serial.CustomBaudRate := 250123;
    AssertLastConfig(Transport, 250123, 7, 'E', SB2, fcRTS_CTS);
    ConfigCount := Transport.ConfigCount;
    Serial.BaudRate := br115200;
    AssertEquals(ConfigCount, Transport.ConfigCount);

    Serial.CustomBaudRate := -1;
    AssertLastConfig(Transport, 115200, 7, 'E', SB2, fcRTS_CTS);

    Serial.DataBits := db6bits;
    AssertLastConfig(Transport, 115200, 6, 'E', SB2, fcRTS_CTS);
    Serial.Parity := pOdd;
    AssertLastConfig(Transport, 115200, 6, 'O', SB2, fcRTS_CTS);
    Serial.StopBits := sbOneAndHalf;
    AssertLastConfig(Transport, 115200, 6, 'O', SB1AndHalf,
      fcRTS_CTS);
    Serial.FlowControl := fcDTR;
    AssertLastConfig(Transport, 115200, 6, 'O', SB1AndHalf, fcDTR);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialTransportTests.ModemLinesDelegateAndSignalsCombine;
var
  Serial: TTestableLazSerial;
  Signals: TModemSignals;
  Transport: TFakeSerialTransport;
begin
  Serial := CreateSerial(Transport);
  try
    Serial.SetDTR(True);
    Serial.SetRTS(True);
    AssertTrue(Transport.DTRValue);
    AssertTrue(Transport.RTSValue);

    Transport.CTSValue := True;
    Transport.CarrierValue := True;
    Transport.RingValue := False;
    Transport.DSRValue := True;
    Signals := Serial.ModemSignals;
    AssertTrue(msCTS in Signals);
    AssertTrue(msCD in Signals);
    AssertFalse(msRI in Signals);
    AssertTrue(msDSR in Signals);
    AssertTrue(Serial.GetCTS);
    AssertTrue(Serial.GetCarrier);
    AssertFalse(Serial.GetRing);
    AssertTrue(Serial.GetDSR);

    Serial.SetDTR(False);
    Serial.SetRTS(False);
    AssertFalse(Transport.DTRValue);
    AssertFalse(Transport.RTSValue);
  finally
    Serial.Free;
  end;
end;

initialization
  RegisterTest(TLazSerialTransportTests);

end.
