unit LazSerialStatisticsTests;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, FpcUnit, TestRegistry, LazSerial, LazSerialCommon,
  LazSerialTransportTests, LazSerialStatistics, LazSerialTransport, LazSynaSer,
  LazSerialDevices, SerialWatcher, SerialWatcherSupport, SerialWatcherComponentTests
  {$IFDEF LINUX}, BaseUnix, ctypes{$ENDIF};

type
  TLazSerialStatisticsTests = class(TTestCase)
  published
    procedure NewComponentHasEmptyStatistics;
    procedure ClosePreservesStatisticsAndReopenResetsThem;
    procedure FailedOpenPreservesPreviousSessionAndOldUpdatesStayIsolated;
    procedure ConfigurationErrorSurvivesRecoveryAndSuccessfulIO;
    procedure FailedConfigurationRecoveryRecordsCloseReason;
    procedure TerminalReaderFailureIsCountedOnceBeforeCloseNotification;
    procedure DeviceRemovalRecordsItsOwnReason;
    procedure StatisticsRejectWorkerThreadAccess;
    {$IFDEF LINUX}
    procedure NativePtyStatisticsCoverLegacyBufferedSyncAndAsync;
    procedure BufferedOverflowPreservesPeakAndDiagnosisAfterCleanup;
    {$ENDIF}
  end;

implementation

type
  TStatisticsTransport = class(TFakeSerialTransport)
  public
    CloseOnConfigureFailure: Boolean;
    ReaderFault: LongInt;
    function State: ISerialStatisticsState;
    procedure Configure(ABaudRate, ADataBits: Integer; AParity: Char;
      AStopBits: Integer; AFlowControl: TFlowControl); override;
    function CanRead(const ATimeout: Integer): Boolean; override;
  end;

  TStatisticsThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Serial: TLazSerial;
    Rejected: Boolean;
  end;

  TStatisticsWatcher = class(TSerialWatcher)
  public
    procedure Isolate;
  end;

{$IFDEF LINUX}
function OpenStatisticsPty(AMaster, ASlave: pcint; AName: PChar;
  ATermios, AWindowSize: Pointer): cint; cdecl; external 'util' name 'openpty';
{$ENDIF}

procedure TStatisticsWatcher.Isolate;
begin
  SetInfrastructure(TSerialManualChangeSource.Create,
    TFakeSerialRefreshScheduler.Create, True);
end;

function TStatisticsTransport.State: ISerialStatisticsState;
begin
  Result := FStatisticsState;
end;

procedure TStatisticsTransport.Configure(ABaudRate, ADataBits: Integer;
  AParity: Char; AStopBits: Integer; AFlowControl: TFlowControl);
var E: ESynaSerError;
begin
  if CloseOnConfigureFailure then
  begin
    inherited Close;
    E := ESynaSerError.Create('Configuration recovery failed');
    E.ErrorCode := ErrWrongParameter;
    E.ErrorMessage := E.Message;
    raise E;
  end;
  inherited Configure(ABaudRate, ADataBits, AParity, AStopBits, AFlowControl);
end;

function TStatisticsTransport.CanRead(const ATimeout: Integer): Boolean;
var E: ESynaSerError;
begin
  if InterlockedCompareExchange(ReaderFault, 0, 0) <> 0 then
  begin
    E := ESynaSerError.Create('Reader failed');
    E.ErrorCode := ErrNoDeviceAnswer;
    E.ErrorMessage := E.Message;
    raise E;
  end;
  Result := inherited CanRead(ATimeout);
end;

procedure TStatisticsThread.Execute;
var Stats: TSerialStatistics;
begin
  try Stats := Serial.Statistics;
  except on E: ELazSerialThreadError do Rejected := True; end;
end;


procedure TLazSerialStatisticsTests.NewComponentHasEmptyStatistics;
var Serial: TLazSerial; Stats: TSerialStatistics;
begin
  Serial := TLazSerial.Create(nil);
  try
    Stats := Serial.Statistics;
    AssertEquals(QWord(0), Stats.BytesReceived);
    AssertEquals(QWord(0), Stats.BytesSent);
    AssertEquals(0, Stats.ReadBufferUsed);
    AssertEquals(0, Stats.ReadBufferPeak);
    AssertEquals(QWord(0), Stats.ErrorCount);
    AssertEquals(0, Stats.LastErrorCode);
    AssertEquals('', Stats.LastErrorMessage);
    AssertEquals(Ord(scrNone), Ord(Stats.CloseReason));
  finally Serial.Free; end;
end;

procedure TLazSerialStatisticsTests.ClosePreservesStatisticsAndReopenResetsThem;
var Serial: TTestableLazSerial; Transport: TFakeSerialTransport;
begin
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TFakeSerialTransport.Create;
    Serial.InstallTransport(Transport);
    Serial.Open;
    Serial.Close;
    AssertEquals(Ord(scrUserRequest), Ord(Serial.Statistics.CloseReason));
    Serial.Open;
    AssertEquals(Ord(scrNone), Ord(Serial.Statistics.CloseReason));
    Serial.Close;
  finally Serial.Free; end;
end;

procedure TLazSerialStatisticsTests.FailedOpenPreservesPreviousSessionAndOldUpdatesStayIsolated;
var Serial: TTestableLazSerial; Transport: TStatisticsTransport;
  Previous: ISerialStatisticsState; Raised: Boolean;
begin
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TStatisticsTransport.Create;
    Serial.InstallTransport(Transport);
    Serial.Open;
    Previous := Transport.State;
    Previous.AddSent(7);
    Serial.Close;
    Transport.FailConnect := True;
    Raised := False;
    try Serial.Open;
    except on E: Exception do Raised := True; end;
    AssertTrue(Raised);
    Transport.State.AddSent(100);
    AssertEquals(QWord(7), Serial.Statistics.BytesSent);
    AssertEquals(Ord(scrUserRequest), Ord(Serial.Statistics.CloseReason));
    Transport.FailConnect := False;
    Serial.Open;
    Previous.AddSent(5);
    AssertEquals(QWord(0), Serial.Statistics.BytesSent);
    AssertEquals(QWord(0), Serial.Statistics.ErrorCount);
    AssertEquals(Ord(scrNone), Ord(Serial.Statistics.CloseReason));
    Serial.Close;
  finally Serial.Free; end;
end;

procedure TLazSerialStatisticsTests.ConfigurationErrorSurvivesRecoveryAndSuccessfulIO;
var Serial: TTestableLazSerial; Transport: TStatisticsTransport; Raised: Boolean;
begin
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TStatisticsTransport.Create;
    Serial.InstallTransport(Transport);
    Serial.Open;
    Transport.FailConfigure := True;
    Raised := False;
    try Serial.CustomBaudRate := 57600;
    except on E: Exception do Raised := True; end;
    AssertTrue(Raised);
    AssertTrue(Serial.Active);
    AssertEquals(QWord(1), Serial.Statistics.ErrorCount);
    AssertTrue(Serial.Statistics.LastErrorMessage <> '');
    Transport.FailConfigure := False;
    Serial.CustomBaudRate := 57600;
    Serial.WriteData('ok');
    AssertEquals(QWord(1), Serial.Statistics.ErrorCount);
    AssertEquals(Ord(scrNone), Ord(Serial.Statistics.CloseReason));
    Serial.Close;
    AssertEquals(QWord(1), Serial.Statistics.ErrorCount);
  finally Serial.Free; end;
end;

procedure TLazSerialStatisticsTests.FailedConfigurationRecoveryRecordsCloseReason;
var Serial: TTestableLazSerial; Transport: TStatisticsTransport; Raised: Boolean;
begin
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TStatisticsTransport.Create;
    Serial.InstallTransport(Transport);
    Serial.Open;
    Transport.CloseOnConfigureFailure := True;
    Raised := False;
    try Serial.CustomBaudRate := 57600;
    except on E: ESynaSerError do Raised := True; end;
    AssertTrue(Raised);
    AssertFalse(Serial.Active);
    AssertEquals(QWord(1), Serial.Statistics.ErrorCount);
    AssertEquals(ErrWrongParameter, Serial.Statistics.LastErrorCode);
    AssertEquals(Ord(scrConfigurationError), Ord(Serial.Statistics.CloseReason));
  finally Serial.Free; end;
end;

procedure TLazSerialStatisticsTests.TerminalReaderFailureIsCountedOnceBeforeCloseNotification;
var Serial: TTestableLazSerial; Transport: TStatisticsTransport; Deadline: QWord;
begin
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TStatisticsTransport.Create;
    Serial.InstallTransport(Transport);
    Serial.Open;
    InterlockedExchange(Transport.ReaderFault, 1);
    Deadline := GetTickCount64 + 2000;
    while Serial.Active and (GetTickCount64 < Deadline) do CheckSynchronize(1);
    AssertFalse(Serial.Active);
    AssertEquals(QWord(1), Serial.Statistics.ErrorCount);
    AssertEquals(ErrNoDeviceAnswer, Serial.Statistics.LastErrorCode);
    AssertEquals(Ord(scrReadError), Ord(Serial.Statistics.CloseReason));
    Serial.Close;
    AssertEquals(QWord(1), Serial.Statistics.ErrorCount);
  finally Serial.Free; end;
end;

procedure TLazSerialStatisticsTests.DeviceRemovalRecordsItsOwnReason;
var Serial: TTestableLazSerial; Transport: TStatisticsTransport;
  Device: TSerialDeviceInfo; I: Integer;
begin
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TStatisticsTransport.Create;
    Serial.InstallTransport(Transport);
    for I := 0 to Serial.ComponentCount - 1 do
      if Serial.Components[I] is TSerialWatcher then
        TStatisticsWatcher(Serial.Components[I]).Isolate;
    Serial.Device := 'COM1';
    Serial.Open;
    Device := Default(TSerialDeviceInfo);
    Device.Device := 'COM1';
    Serial.AdoptWatcherSnapshot([Device]);
    Serial.CheckForDisconnectedDevice;
    Serial.AdoptWatcherSnapshot([]);
    Serial.CheckForDisconnectedDevice;
    AssertFalse(Serial.Active);
    AssertEquals(Ord(scrDeviceRemoved), Ord(Serial.Statistics.CloseReason));
    AssertEquals(QWord(0), Serial.Statistics.ErrorCount);
  finally Serial.Free; end;
end;

procedure TLazSerialStatisticsTests.StatisticsRejectWorkerThreadAccess;
var Serial: TLazSerial; Worker: TStatisticsThread;
begin
  Serial := TLazSerial.Create(nil);
  Worker := TStatisticsThread.Create(True);
  try
    Worker.Serial := Serial;
    Worker.Start;
    Worker.WaitFor;
    AssertTrue(Worker.Rejected);
  finally Worker.Free; Serial.Free; end;
end;

{$IFDEF LINUX}
procedure TLazSerialStatisticsTests.NativePtyStatisticsCoverLegacyBufferedSyncAndAsync;
var
  Serial: TLazSerial;
  Master, Slave: cint;
  Name: array[0..255] of Char;
  Buffered, Async: Boolean;
  Data: AnsiString;
  Deadline: QWord;
begin
  for Buffered := False to True do
    for Async := False to True do
    begin
      Master := -1; Slave := -1;
      FillChar(Name, SizeOf(Name), 0);
      AssertEquals(0, OpenStatisticsPty(@Master, @Slave, @Name[0], nil, nil));
      Serial := TLazSerial.Create(nil);
      try
        Serial.Device := StrPas(@Name[0]);
        Serial.BaudRate := br115200;
        Serial.BufferedRead := Buffered;
        Serial.ReadBufferLimit := 32;
        Serial.RcvLineCRLF := True;
        Serial.Open;
        Data := 'abc' + #13#10;
        AssertEquals(5, fpWrite(Master, Data[1], Length(Data)));
        Deadline := GetTickCount64 + 2000;
        while not Serial.DataAvailable and (GetTickCount64 < Deadline) do CheckSynchronize(1);
        AssertEquals('abc', Serial.ReadData);
        AssertEquals(QWord(5), Serial.Statistics.BytesReceived);
        AssertEquals(0, Serial.Statistics.ReadBufferUsed);
        if Buffered then AssertTrue(Serial.Statistics.ReadBufferPeak >= 5)
        else AssertEquals(0, Serial.Statistics.ReadBufferPeak);
        if Async then Serial.WriteDataAsync('out', 2000)
        else AssertEquals(3, Serial.WriteData('out'));
        Deadline := GetTickCount64 + 2000;
        while Serial.WritePending and (GetTickCount64 < Deadline) do CheckSynchronize(1);
        AssertFalse(Serial.WritePending);
        AssertEquals(QWord(3), Serial.Statistics.BytesSent);
        AssertEquals(QWord(0), Serial.Statistics.ErrorCount);
        Serial.Close;
        Deadline := GetTickCount64 + 2000;
        while Serial.ClosePending and (GetTickCount64 < Deadline) do CheckSynchronize(1);
        AssertFalse(Serial.ClosePending);
        AssertEquals(QWord(5), Serial.Statistics.BytesReceived);
        AssertEquals(QWord(3), Serial.Statistics.BytesSent);
        AssertEquals(Ord(scrUserRequest), Ord(Serial.Statistics.CloseReason));
      finally
        Serial.Free;
        if Master >= 0 then fpClose(Master);
        if Slave >= 0 then fpClose(Slave);
      end;
    end;
end;
{$ENDIF}

{$IFDEF LINUX}
procedure TLazSerialStatisticsTests.BufferedOverflowPreservesPeakAndDiagnosisAfterCleanup;
var Serial: TLazSerial; Master, Slave: cint;
  Name: array[0..255] of Char; Data: AnsiString; Deadline: QWord;
begin
  Master := -1; Slave := -1;
  FillChar(Name, SizeOf(Name), 0);
  AssertEquals(0, OpenStatisticsPty(@Master, @Slave, @Name[0], nil, nil));
  Serial := TLazSerial.Create(nil);
  try
    Serial.Device := StrPas(@Name[0]);
    Serial.BaudRate := br115200;
    Serial.BufferedRead := True;
    Serial.ReadBufferLimit := 32;
    Serial.Open;
    Data := StringOfChar('x', 32);
    AssertEquals(32, fpWrite(Master, Data[1], Length(Data)));
    Deadline := GetTickCount64 + 2000;
    while (Serial.Statistics.ErrorCount = 0) and (GetTickCount64 < Deadline) do Sleep(1);
    AssertEquals(QWord(32), Serial.Statistics.BytesReceived);
    AssertEquals(32, Serial.Statistics.ReadBufferUsed);
    AssertEquals(32, Serial.Statistics.ReadBufferPeak);
    AssertEquals(QWord(1), Serial.Statistics.ErrorCount);
    Deadline := GetTickCount64 + 2000;
    while (Serial.Active or Serial.ClosePending) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
    AssertFalse(Serial.Active);
    AssertFalse(Serial.ClosePending);
    AssertEquals(0, Serial.Statistics.ReadBufferUsed);
    AssertEquals(32, Serial.Statistics.ReadBufferPeak);
    AssertEquals(QWord(1), Serial.Statistics.ErrorCount);
    AssertEquals(ErrReadBufferOverflow, Serial.Statistics.LastErrorCode);
    AssertEquals(Ord(scrReadError), Ord(Serial.Statistics.CloseReason));
  finally
    Serial.Free;
    if Master >= 0 then fpClose(Master);
    if Slave >= 0 then fpClose(Slave);
  end;
end;
{$ENDIF}

initialization
  RegisterTest(TLazSerialStatisticsTests);
end.
