unit LazSerialLifecycleTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, FpcUnit, TestRegistry, LazSerial, LazSerialCommon,
  LazSynaSer;

type
  TLazSerialLifecycleTests = class(TTestCase)
  private
    FCallbackCount: Integer;
    FCallbackSerial: TLazSerial;
    FCanReadStatusCount: Integer;
    FClosing: Boolean;
    FDataCallbackCount: Integer;
    FLateCallbackCount: Integer;
    FSerialCloseCount: Integer;
    FStatusThreadId: TThreadID;
    FReceivedData: AnsiString;
    procedure AccumulateData(Sender: TObject);
    procedure CloseFromData(Sender: TObject);
    procedure ConsumeData(Sender: TObject);
    procedure DataReceived(Sender: TObject);
    procedure DestroyFromReadStatus(Sender: TObject;
      Reason: THookSerialReason; const Value: string);
    procedure RaiseOnceFromData(Sender: TObject);
    procedure RaiseOnceFromReadStatus(Sender: TObject;
      Reason: THookSerialReason; const Value: string);
    procedure StatusChanged(Sender: TObject; Reason: THookSerialReason;
      const Value: string);
  published
    procedure CloseFromReceiveCallbackDoesNotDeadlock;
    procedure CloseActiveSerialDeliversCloseStatus;
    procedure DestroyActiveSerialDoesNotDeliverCallbackWhileClosing;
    procedure DestroyFromReadStatusDoesNotDeadlock;
    procedure ReceiveCallbackExceptionDoesNotStopReader;
    procedure ReceiveStatusRunsOnMainThread;
    procedure StatusCallbackExceptionDoesNotStopReader;
    procedure PtyTransfersBurstLargePayloadAndReopens;
    {$IFDEF LINUX}
    procedure UnsupportedCustomSpeedIsRejectedOnOpen;
    procedure UnsupportedLiveSpeedPreservesActualSpeed;
    procedure DisconnectedPtyCloseReleasesHandleWithExceptions;
    procedure DisconnectedPtyCloseReleasesHandleWithoutExceptions;
    procedure ReportedZeroSpeedMatchesPtySettings;
    procedure Reported9600SpeedMatchesPtySettings;
    procedure Reported38400SpeedMatchesPtySettings;
    procedure Reported115200SpeedMatchesPtySettings;
    procedure OutputFlagsDoNotChangeReportedSpeed;
    {$ENDIF}
  end;

implementation

{$IFDEF UNIX}
uses
  BaseUnix, ctypes, Termio, LazSerialTransport;

function OpenPty(AMaster, ASlave: pcint; AName: PChar;
  ATermios, AWindowSize: Pointer): cint; cdecl;
  external 'util' name 'openpty';

type
  TPtyWriterThread = class(TThread)
  private
    FData: AnsiString;
    FHandle: cint;
  protected
    procedure Execute; override;
  public
    constructor Create(const AHandle: cint; const AData: AnsiString);
  end;

constructor TPtyWriterThread.Create(const AHandle: cint;
  const AData: AnsiString);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FHandle := AHandle;
  FData := AData;
end;

procedure TPtyWriterThread.Execute;
const
  ChunkSize = 512;
var
  BytesToWrite: SizeInt;
  Offset: SizeInt;
  Written: Int64;
begin
  Offset := 1;
  while not Terminated and (Offset <= Length(FData)) do
  begin
    BytesToWrite := Length(FData) - Offset + 1;
    if BytesToWrite > ChunkSize then
      BytesToWrite := ChunkSize;
    Written := fpWrite(FHandle, FData[Offset], BytesToWrite);
    if Written > 0 then
      Inc(Offset, Written)
    else
      Sleep(1);
  end;
end;
{$ENDIF}

{$IFDEF LINUX}
type
  TTermiosProbe = class(TBlockSerial)
  public
    function DecodeSpeed(const ASettings: Termios): Integer;
  end;

function TTermiosProbe.DecodeSpeed(const ASettings: Termios): Integer;
var
  State: TDCB;
begin
  State := Default(TDCB);
  TermiosToDcb(ASettings, State);
  Result := State.BaudRate;
end;

procedure TLazSerialLifecycleTests.UnsupportedCustomSpeedIsRejectedOnOpen;
var
  Master, Slave: cint;
  Name: array[0..255] of Char;
  Raised: Boolean;
  Serial: TLazSerial;
begin
  AssertEquals(0, OpenPty(@Master, @Slave, @Name[0], nil, nil));
  Serial := TLazSerial.Create(nil);
  try
    Serial.Device := StrPas(Name);
    Serial.CustomBaudRate := 250123;
    Raised := False;
    try
      Serial.Open;
    except
      on E: ESynaSerError do
      begin
        Raised := True;
        AssertEquals(ErrWrongParameter, E.ErrorCode);
      end;
    end;
    AssertTrue('An unsupported positive speed must not silently apply B0', Raised);
    AssertFalse(Serial.Active);
    AssertTrue(Serial.SynSer.Handle = INVALID_HANDLE_VALUE);
  finally
    Serial.Free;
    fpClose(Slave);
    fpClose(Master);
  end;
end;

procedure TLazSerialLifecycleTests.UnsupportedLiveSpeedPreservesActualSpeed;
var
  Master, Slave: cint;
  Name: array[0..255] of Char;
  BeforeSettings, AfterSettings: Termios;
  Raised: Boolean;
  Serial: TLazSerial;
begin
  AssertEquals(0, OpenPty(@Master, @Slave, @Name[0], nil, nil));
  Serial := TLazSerial.Create(nil);
  try
    Serial.Device := StrPas(Name);
    Serial.BaudRate := br115200;
    Serial.Open;
    AssertEquals(0, TCGetAttr(Slave, BeforeSettings));
    Raised := False;
    try
      Serial.CustomBaudRate := 250123;
    except
      on E: ESynaSerError do
      begin
        Raised := True;
        AssertEquals(ErrWrongParameter, E.ErrorCode);
      end;
    end;
    AssertEquals(0, TCGetAttr(Slave, AfterSettings));
    AssertTrue('Driver speed must survive rejected reconfiguration',
      (BeforeSettings.c_cflag and CBAUD) = (AfterSettings.c_cflag and CBAUD));
    AssertTrue('Unsupported live speed must raise', Raised);
  finally
    Serial.Free;
    fpClose(Slave);
    fpClose(Master);
  end;
end;

procedure CheckDisconnectedPtyClose(const ARaiseNative: Boolean);
var
  Master, Slave, SerialHandle: cint;
  Name: array[0..255] of Char;
  Serial: TLazSerial;
  ActualActive, HandleReleased: Boolean;
  ErrorCode: Integer;
begin
  TAssert.AssertEquals(0, OpenPty(@Master, @Slave, @Name[0], nil, nil));
  Serial := TLazSerial.Create(nil);
  try
    Serial.Device := StrPas(Name);
    Serial.Open;
    SerialHandle := Serial.SynSer.Handle;
    Serial.SynSer.RaiseExcept := ARaiseNative;
    fpClose(Master);
    Master := -1;
    ErrorCode := 0;
    try
      Serial.Close;
    except
      on E: ESynaSerError do
        ErrorCode := E.ErrorCode;
    end;
    ActualActive := Serial.Active;
    HandleReleased := Serial.SynSer.Handle = INVALID_HANDLE_VALUE;
    // Let cleanup complete even when the assertions expose the current defect.
    Serial.SynSer.RaiseExcept := False;
    TAssert.AssertTrue('Close must release the disconnected descriptor', HandleReleased);
    TAssert.AssertEquals('OS descriptor must actually be closed',
      -1, fpFcntl(SerialHandle, F_GETFD));
    TAssert.AssertEquals(ESysEBADF, fpGetErrno);
    TAssert.AssertFalse('Close must reset Active even when flush fails', ActualActive);
    if ARaiseNative then
      TAssert.AssertEquals('Preserve the first I/O error', ESysEIO, ErrorCode);
    Serial.Close;
    TAssert.AssertFalse(Serial.Active);
  finally
    Serial.SynSer.RaiseExcept := False;
    Serial.Free;
    fpClose(Slave);
    if Master >= 0 then
      fpClose(Master);
  end;
end;

procedure TLazSerialLifecycleTests.DisconnectedPtyCloseReleasesHandleWithExceptions;
begin
  CheckDisconnectedPtyClose(True);
end;

procedure TLazSerialLifecycleTests.DisconnectedPtyCloseReleasesHandleWithoutExceptions;
begin
  CheckDisconnectedPtyClose(False);
end;

procedure CheckReportedPtySpeed(const ABaudRate: Integer;
  const ANativeSpeed: Cardinal);
var
  Master, Slave: cint;
  Name: array[0..255] of Char;
  Settings: Termios;
  Transport: TLazSynapseSerialTransport;
begin
  TAssert.AssertEquals(0, OpenPty(@Master, @Slave, @Name[0], nil, nil));
  Transport := TLazSynapseSerialTransport.Create;
  try
    Transport.Connect(StrPas(Name));
    Transport.Configure(ABaudRate, 8, 'N', SB1, fcNone);
    TAssert.AssertEquals(0, TCGetAttr(Slave, Settings));
    TAssert.AssertEquals('Independent PTY speed', Int64(ANativeSpeed),
      Int64(Settings.c_cflag and CBAUD));
    Transport.NativeSerial.GetCommState;
    TAssert.AssertEquals('Reported speed for ' + IntToStr(ABaudRate),
      ABaudRate, Transport.NativeSerial.DCB.BaudRate);
    TAssert.AssertEquals(0, Transport.NativeSerial.LastError);
  finally
    Transport.Free;
    fpClose(Slave);
    fpClose(Master);
  end;
end;

procedure TLazSerialLifecycleTests.ReportedZeroSpeedMatchesPtySettings;
begin
  CheckReportedPtySpeed(0, B0);
end;

procedure TLazSerialLifecycleTests.Reported9600SpeedMatchesPtySettings;
begin
  CheckReportedPtySpeed(9600, B9600);
end;

procedure TLazSerialLifecycleTests.Reported38400SpeedMatchesPtySettings;
begin
  CheckReportedPtySpeed(38400, B38400);
end;

procedure TLazSerialLifecycleTests.Reported115200SpeedMatchesPtySettings;
begin
  CheckReportedPtySpeed(115200, B115200);
end;

procedure TLazSerialLifecycleTests.OutputFlagsDoNotChangeReportedSpeed;
var
  Probe: TTermiosProbe;
  Settings: Termios;
begin
  Probe := TTermiosProbe.Create;
  try
    Settings := Default(Termios);
    Settings.c_cflag := B115200 or CS8;
    Settings.c_oflag := 0;
    AssertEquals(115200, Probe.DecodeSpeed(Settings));
    Settings.c_oflag := OPOST or ONLCR;
    AssertEquals(115200, Probe.DecodeSpeed(Settings));
  finally
    Probe.Free;
  end;
end;
{$ENDIF}

const
  CallbackExceptionMessage = 'intentional serial callback exception';

procedure TLazSerialLifecycleTests.AccumulateData(Sender: TObject);
begin
  FReceivedData := FReceivedData + TLazSerial(Sender).ReadData;
end;

procedure TLazSerialLifecycleTests.CloseFromData(Sender: TObject);
begin
  Inc(FCallbackCount);
  TLazSerial(Sender).ReadData;
  TLazSerial(Sender).Close;
end;

procedure TLazSerialLifecycleTests.ConsumeData(Sender: TObject);
begin
  Inc(FDataCallbackCount);
  TLazSerial(Sender).ReadData;
end;

procedure TLazSerialLifecycleTests.DataReceived(Sender: TObject);
begin
  if FClosing then
    Inc(FLateCallbackCount);
end;

procedure TLazSerialLifecycleTests.DestroyFromReadStatus(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
var
  Serial: TLazSerial;
begin
  if Reason <> HR_CanRead then
    Exit;

  Inc(FCallbackCount);
  Serial := FCallbackSerial;
  FCallbackSerial := nil;
  Serial.Free;
end;

procedure TLazSerialLifecycleTests.RaiseOnceFromData(Sender: TObject);
begin
  Inc(FCallbackCount);
  TLazSerial(Sender).ReadData;
  if FCallbackCount = 1 then
    raise Exception.Create(CallbackExceptionMessage);
end;

procedure TLazSerialLifecycleTests.RaiseOnceFromReadStatus(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
begin
  if Reason <> HR_CanRead then
    Exit;

  Inc(FCallbackCount);
  if FCallbackCount = 1 then
    raise Exception.Create(CallbackExceptionMessage);
end;

procedure TLazSerialLifecycleTests.StatusChanged(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
begin
  if Reason = HR_SerialClose then
    Inc(FSerialCloseCount)
  else if Reason = HR_CanRead then
  begin
    Inc(FCanReadStatusCount);
    FStatusThreadId := GetCurrentThreadID;
  end;
end;

procedure TLazSerialLifecycleTests.CloseFromReceiveCallbackDoesNotDeadlock;
{$IFDEF UNIX}
const
  TestData: AnsiString = 'x';
var
  Deadline: QWord;
  MasterHandle: cint;
  NameBuffer: array[0..255] of Char;
  Serial: TLazSerial;
  SlaveHandle: cint;
{$ENDIF}
begin
  {$IFDEF UNIX}
  MasterHandle := -1;
  SlaveHandle := -1;
  FillChar(NameBuffer, SizeOf(NameBuffer), 0);
  AssertEquals(0, OpenPty(@MasterHandle, @SlaveHandle, @NameBuffer[0], nil,
    nil));
  try
    fpClose(SlaveHandle);
    SlaveHandle := -1;

    FCallbackCount := 0;
    Serial := TLazSerial.Create(nil);
    try
      Serial.Device := StrPas(@NameBuffer[0]);
      Serial.OnRxData := @CloseFromData;
      Serial.Active := True;
      AssertEquals(Length(TestData),
        fpWrite(MasterHandle, TestData[1], Length(TestData)));

      Deadline := GetTickCount64 + 1000;
      repeat
        CheckSynchronize(10);
      until (FCallbackCount > 0) or (GetTickCount64 >= Deadline);

      AssertEquals(1, FCallbackCount);
      AssertFalse(Serial.Active);
    finally
      Serial.Free;
    end;
  finally
    if SlaveHandle >= 0 then
      fpClose(SlaveHandle);
    if MasterHandle >= 0 then
      fpClose(MasterHandle);
  end;
  {$ENDIF}
end;

procedure TLazSerialLifecycleTests.CloseActiveSerialDeliversCloseStatus;
{$IFDEF UNIX}
var
  MasterHandle: cint;
  NameBuffer: array[0..255] of Char;
  Serial: TLazSerial;
  SlaveHandle: cint;
{$ENDIF}
begin
  {$IFDEF UNIX}
  MasterHandle := -1;
  SlaveHandle := -1;
  FillChar(NameBuffer, SizeOf(NameBuffer), 0);
  AssertEquals(
    0,
    OpenPty(@MasterHandle, @SlaveHandle, @NameBuffer[0], nil, nil)
  );
  try
    fpClose(SlaveHandle);
    SlaveHandle := -1;

    FSerialCloseCount := 0;
    Serial := TLazSerial.Create(nil);
    try
      Serial.Device := StrPas(@NameBuffer[0]);
      Serial.OnStatus := @StatusChanged;
      Serial.Active := True;

      Serial.Close;

      AssertFalse(Serial.Active);
      AssertEquals(1, FSerialCloseCount);
    finally
      Serial.Free;
    end;
  finally
    if SlaveHandle >= 0 then
      fpClose(SlaveHandle);
    if MasterHandle >= 0 then
      fpClose(MasterHandle);
  end;
  {$ENDIF}
end;

procedure TLazSerialLifecycleTests.
  DestroyActiveSerialDoesNotDeliverCallbackWhileClosing;
{$IFDEF UNIX}
const
  TestData: AnsiString = 'x';
var
  MasterHandle: cint;
  NameBuffer: array[0..255] of Char;
  Serial: TLazSerial;
  SlaveHandle: cint;
{$ENDIF}
begin
  {$IFDEF UNIX}
  MasterHandle := -1;
  SlaveHandle := -1;
  FillChar(NameBuffer, SizeOf(NameBuffer), 0);
  AssertEquals(
    0,
    OpenPty(@MasterHandle, @SlaveHandle, @NameBuffer[0], nil, nil)
  );
  try
    fpClose(SlaveHandle);
    SlaveHandle := -1;

    FClosing := False;
    FLateCallbackCount := 0;
    Serial := TLazSerial.Create(nil);
    try
      Serial.Device := StrPas(@NameBuffer[0]);
      Serial.OnRxData := @DataReceived;
      Serial.Active := True;
      AssertEquals(
        Length(TestData),
        fpWrite(MasterHandle, TestData[1], Length(TestData))
      );
      Sleep(50);

      FClosing := True;
      Serial.Free;
      Serial := nil;
      FClosing := False;

      CheckSynchronize(100);
      AssertEquals(0, FLateCallbackCount);
    finally
      Serial.Free;
    end;
  finally
    if SlaveHandle >= 0 then
      fpClose(SlaveHandle);
    if MasterHandle >= 0 then
      fpClose(MasterHandle);
  end;
  {$ENDIF}
end;

procedure TLazSerialLifecycleTests.DestroyFromReadStatusDoesNotDeadlock;
{$IFDEF UNIX}
const
  TestData: AnsiString = 'x';
var
  Deadline: QWord;
  MasterHandle: cint;
  NameBuffer: array[0..255] of Char;
  SlaveHandle: cint;
{$ENDIF}
begin
  {$IFDEF UNIX}
  MasterHandle := -1;
  SlaveHandle := -1;
  FillChar(NameBuffer, SizeOf(NameBuffer), 0);
  AssertEquals(0, OpenPty(@MasterHandle, @SlaveHandle, @NameBuffer[0], nil,
    nil));
  try
    fpClose(SlaveHandle);
    SlaveHandle := -1;

    FCallbackCount := 0;
    FCallbackSerial := TLazSerial.Create(nil);
    try
      FCallbackSerial.Device := StrPas(@NameBuffer[0]);
      FCallbackSerial.OnStatus := @DestroyFromReadStatus;
      FCallbackSerial.Active := True;
      AssertEquals(Length(TestData),
        fpWrite(MasterHandle, TestData[1], Length(TestData)));

      Deadline := GetTickCount64 + 1000;
      repeat
        CheckSynchronize(10);
      until (FCallbackSerial = nil) or (GetTickCount64 >= Deadline);

      AssertEquals(1, FCallbackCount);
      AssertNull(FCallbackSerial);
    finally
      FreeAndNil(FCallbackSerial);
    end;
  finally
    if SlaveHandle >= 0 then
      fpClose(SlaveHandle);
    if MasterHandle >= 0 then
      fpClose(MasterHandle);
  end;
  {$ENDIF}
end;

procedure TLazSerialLifecycleTests.ReceiveCallbackExceptionDoesNotStopReader;
{$IFDEF UNIX}
const
  FirstData: AnsiString = 'x';
  SecondData: AnsiString = 'y';
var
  CallbackExceptionSeen: Boolean;
  Deadline: QWord;
  MasterHandle: cint;
  NameBuffer: array[0..255] of Char;
  Serial: TLazSerial;
  SlaveHandle: cint;
{$ENDIF}
begin
  {$IFDEF UNIX}
  MasterHandle := -1;
  SlaveHandle := -1;
  FillChar(NameBuffer, SizeOf(NameBuffer), 0);
  AssertEquals(0, OpenPty(@MasterHandle, @SlaveHandle, @NameBuffer[0], nil,
    nil));
  try
    fpClose(SlaveHandle);
    SlaveHandle := -1;

    CallbackExceptionSeen := False;
    FCallbackCount := 0;
    Serial := TLazSerial.Create(nil);
    try
      Serial.Device := StrPas(@NameBuffer[0]);
      Serial.OnRxData := @RaiseOnceFromData;
      Serial.Active := True;
      AssertEquals(Length(FirstData),
        fpWrite(MasterHandle, FirstData[1], Length(FirstData)));

      Deadline := GetTickCount64 + 1000;
      repeat
        try
          CheckSynchronize(10);
        except
          on E: Exception do
            if E.Message = CallbackExceptionMessage then
              CallbackExceptionSeen := True
            else
              raise;
        end;
      until (FCallbackCount > 0) or (GetTickCount64 >= Deadline);

      AssertTrue('Expected callback exception on the main thread',
        CallbackExceptionSeen);
      AssertEquals(Length(SecondData),
        fpWrite(MasterHandle, SecondData[1], Length(SecondData)));

      Deadline := GetTickCount64 + 1000;
      repeat
        CheckSynchronize(10);
      until (FCallbackCount > 1) or (GetTickCount64 >= Deadline);
      AssertEquals(2, FCallbackCount);
    finally
      Serial.Free;
    end;
  finally
    if SlaveHandle >= 0 then
      fpClose(SlaveHandle);
    if MasterHandle >= 0 then
      fpClose(MasterHandle);
  end;
  {$ENDIF}
end;

procedure TLazSerialLifecycleTests.ReceiveStatusRunsOnMainThread;
{$IFDEF UNIX}
const
  TestData: AnsiString = 'x';
var
  Deadline: QWord;
  MainThreadId: TThreadID;
  MasterHandle: cint;
  NameBuffer: array[0..255] of Char;
  Serial: TLazSerial;
  SlaveHandle: cint;
{$ENDIF}
begin
  {$IFDEF UNIX}
  MasterHandle := -1;
  SlaveHandle := -1;
  FillChar(NameBuffer, SizeOf(NameBuffer), 0);
  AssertEquals(
    0,
    OpenPty(@MasterHandle, @SlaveHandle, @NameBuffer[0], nil, nil)
  );
  try
    fpClose(SlaveHandle);
    SlaveHandle := -1;

    FCanReadStatusCount := 0;
    FStatusThreadId := Default(TThreadID);
    MainThreadId := GetCurrentThreadID;
    Serial := TLazSerial.Create(nil);
    try
      Serial.Device := StrPas(@NameBuffer[0]);
      Serial.OnStatus := @StatusChanged;
      Serial.Active := True;
      AssertEquals(
        Length(TestData),
        fpWrite(MasterHandle, TestData[1], Length(TestData))
      );

      Deadline := GetTickCount64 + 1000;
      repeat
        CheckSynchronize(10);
      until (FCanReadStatusCount > 0) or (GetTickCount64 >= Deadline);

      AssertTrue('Expected HR_CanRead status', FCanReadStatusCount > 0);
      AssertEquals('Serial status must be delivered on the main thread',
        QWord(MainThreadId), QWord(FStatusThreadId));
    finally
      Serial.Free;
    end;
  finally
    if SlaveHandle >= 0 then
      fpClose(SlaveHandle);
    if MasterHandle >= 0 then
      fpClose(MasterHandle);
  end;
  {$ENDIF}
end;

procedure TLazSerialLifecycleTests.StatusCallbackExceptionDoesNotStopReader;
{$IFDEF UNIX}
const
  FirstData: AnsiString = 'x';
  SecondData: AnsiString = 'y';
var
  CallbackExceptionSeen: Boolean;
  Deadline: QWord;
  MasterHandle: cint;
  NameBuffer: array[0..255] of Char;
  Serial: TLazSerial;
  SlaveHandle: cint;
{$ENDIF}
begin
  {$IFDEF UNIX}
  MasterHandle := -1;
  SlaveHandle := -1;
  FillChar(NameBuffer, SizeOf(NameBuffer), 0);
  AssertEquals(0, OpenPty(@MasterHandle, @SlaveHandle, @NameBuffer[0], nil,
    nil));
  try
    fpClose(SlaveHandle);
    SlaveHandle := -1;

    CallbackExceptionSeen := False;
    FCallbackCount := 0;
    FDataCallbackCount := 0;
    Serial := TLazSerial.Create(nil);
    try
      Serial.Device := StrPas(@NameBuffer[0]);
      Serial.OnRxData := @ConsumeData;
      Serial.OnStatus := @RaiseOnceFromReadStatus;
      Serial.Active := True;
      AssertEquals(Length(FirstData),
        fpWrite(MasterHandle, FirstData[1], Length(FirstData)));

      Deadline := GetTickCount64 + 1000;
      repeat
        try
          CheckSynchronize(10);
        except
          on E: Exception do
            if E.Message = CallbackExceptionMessage then
              CallbackExceptionSeen := True
            else
              raise;
        end;
      until (FDataCallbackCount > 0) or (GetTickCount64 >= Deadline);

      AssertTrue('Expected status exception on the main thread',
        CallbackExceptionSeen);
      AssertEquals(1, FCallbackCount);
      AssertEquals(Length(SecondData),
        fpWrite(MasterHandle, SecondData[1], Length(SecondData)));

      Deadline := GetTickCount64 + 1000;
      repeat
        CheckSynchronize(10);
      until (FCallbackCount > 1) or (GetTickCount64 >= Deadline);
      AssertEquals(2, FCallbackCount);
    finally
      Serial.Free;
    end;
  finally
    if SlaveHandle >= 0 then
      fpClose(SlaveHandle);
    if MasterHandle >= 0 then
      fpClose(MasterHandle);
  end;
  {$ENDIF}
end;

procedure TLazSerialLifecycleTests.PtyTransfersBurstLargePayloadAndReopens;
{$IFDEF UNIX}
const
  OutboundData: AnsiString = 'serial-out';
  ReopenedData: AnsiString = 'reopened';
var
  Deadline: QWord;
  I: Integer;
  MasterHandle: cint;
  NameBuffer: array[0..255] of Char;
  OutboundBuffer: array[0..31] of Char;
  Payload: AnsiString;
  ReadCount: Int64;
  ReceivedOutbound: AnsiString;
  Serial: TLazSerial;
  SlaveHandle: cint;
  Writer: TPtyWriterThread;
{$ENDIF}
begin
  {$IFDEF UNIX}
  MasterHandle := -1;
  SlaveHandle := -1;
  FillChar(NameBuffer, SizeOf(NameBuffer), 0);
  AssertEquals(0, OpenPty(@MasterHandle, @SlaveHandle, @NameBuffer[0], nil,
    nil));
  try
    fpClose(SlaveHandle);
    SlaveHandle := -1;
    SetLength(Payload, cSerialChunk + 1024);
    for I := 1 to Length(Payload) do
      Payload[I] := AnsiChar(Ord('A') + ((I - 1) mod 26));

    Serial := TLazSerial.Create(nil);
    try
      Serial.Device := StrPas(@NameBuffer[0]);
      Serial.OnRxData := @AccumulateData;
      Serial.Open;

      FillChar(OutboundBuffer, SizeOf(OutboundBuffer), 0);
      AssertEquals(Length(OutboundData), Serial.WriteData(OutboundData));
      ReadCount := fpRead(MasterHandle, OutboundBuffer[0],
        Length(OutboundData));
      AssertEquals(Length(OutboundData), ReadCount);
      SetString(ReceivedOutbound, PChar(@OutboundBuffer[0]), ReadCount);
      AssertEquals(OutboundData, ReceivedOutbound);

      FReceivedData := '';
      Writer := TPtyWriterThread.Create(MasterHandle, Payload);
      try
        Writer.Start;
        Deadline := GetTickCount64 + 3000;
        repeat
          CheckSynchronize(10);
        until (Length(FReceivedData) >= Length(Payload)) or
          (GetTickCount64 >= Deadline);
        Writer.Terminate;
        Writer.WaitFor;
      finally
        Writer.Free;
      end;
      AssertEquals(Payload, FReceivedData);

      Serial.Close;
      AssertFalse(Serial.Active);
      Serial.Open;
      AssertTrue(Serial.Active);
      FReceivedData := '';
      AssertEquals(Length(ReopenedData), fpWrite(MasterHandle,
        ReopenedData[1], Length(ReopenedData)));
      Deadline := GetTickCount64 + 1000;
      repeat
        CheckSynchronize(10);
      until (FReceivedData = ReopenedData) or
        (GetTickCount64 >= Deadline);
      AssertEquals(ReopenedData, FReceivedData);
    finally
      Serial.Free;
    end;
  finally
    if SlaveHandle >= 0 then
      fpClose(SlaveHandle);
    if MasterHandle >= 0 then
      fpClose(MasterHandle);
  end;
  {$ENDIF}
end;

initialization
  RegisterTest(TLazSerialLifecycleTests);

end.
