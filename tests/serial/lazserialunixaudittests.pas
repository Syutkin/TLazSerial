unit LazSerialUnixAuditTests;
{$mode objfpc}{$H+}
interface
{$IFDEF LINUX}
uses Classes, SysUtils, SyncObjs, BaseUnix, Termio, FpcUnit, TestRegistry,
  LazSynaSer, LazSerialCommon, LazSerialRead, LazSerialWrite, LazSerialNativeRead;
type
  TLazSerialUnixAuditTests = class(TTestCase)
  published
    procedure InterruptedReadThenTimeoutIsNotAnError;
    procedure InterruptedReadPreservesReceivedData;
    procedure PurgeResetsBothLineSeparators;
    procedure ReconnectResetsBothLineSeparators;
    procedure SoftwareFlowRoundTripsIndependentlyOfSpeed;
    procedure AllParityModesRoundTripAndClearPreviousMode;
  end;
{$ENDIF}
implementation
{$IFDEF LINUX}
type
  TTermiosAuditSerial = class(TBlockSerial)
  public
    procedure Encode(const State: TDCB; var Settings: Termios);
    procedure Decode(const Settings: Termios; var State: TDCB);
  end;
  TReadAuditProbe = class(TNativeSerialReadOperation)
  public
    function ReadOnce(out Data: AnsiString): Integer;
  end;
  TInterruptedReader = class(TThread)
  public
    Ready: TEvent;
    Reader: TReadAuditProbe;
    Error: Integer;
    ExpectData: Boolean;
    Data: AnsiString;
    constructor Create(AReader: TReadAuditProbe);
    destructor Destroy; override;
    procedure Execute; override;
  end;
var
  SignalOutput: cint = -1;
  SignalCount: LongInt;
function KillThread(Thread: PtrUInt; Signal: cint): cint; cdecl;
  external 'c' name 'pthread_kill';
function OpenAuditPty(AMaster, ASlave: pcint; AName: PChar;
  ATermios, AWindowSize: Pointer): cint; cdecl; external 'util' name 'openpty';
procedure InterruptReader(Signal: cint; Info: PSigInfo; Context: PSigContext); cdecl;
var Value: Byte;
begin
  InterlockedIncrement(SignalCount);
  if SignalOutput >= 0 then
  begin
    Value := Ord('x');
    fpWrite(SignalOutput, Value, 1);
  end;
end;
procedure TTermiosAuditSerial.Encode(const State: TDCB; var Settings: Termios);
begin DcbToTermios(State, Settings); end;
procedure TTermiosAuditSerial.Decode(const Settings: Termios; var State: TDCB);
begin TermiosToDcb(Settings, State); end;
function TReadAuditProbe.ReadOnce(out Data: AnsiString): Integer;
var Buffer: array[0..31] of Byte; Received: Integer;
begin
  Result := ReadChunk(@Buffer[0], Length(Buffer), Received);
  SetString(Data, PAnsiChar(@Buffer[0]), Received);
end;
constructor TInterruptedReader.Create(AReader: TReadAuditProbe);
begin
  inherited Create(True);
  Ready := TEvent.Create(nil, True, False, '');
  Reader := AReader;
end;
destructor TInterruptedReader.Destroy;
begin Ready.Free; inherited Destroy; end;
procedure TInterruptedReader.Execute;
begin
  Ready.SetEvent;
  repeat
    Error := Reader.ReadOnce(Data);
  until Terminated or (Error <> 0) or
    ((SignalCount > 0) and (not ExpectData or (Data <> '')));
end;
procedure CheckInterruptedRead(WithData: Boolean);
var
  PipeFD: TFilDes;
  Serial: TBlockSerial;
  Port: ISerialWritePort;
  Reader: TReadAuditProbe;
  Worker: TInterruptedReader;
  Action, Previous: SigActionRec;
begin
  TAssert.AssertEquals(0, fpPipe(PipeFD));
  Action := Default(SigActionRec);
  Action.sa_handler := @InterruptReader;
  fpSigEmptySet(Action.sa_mask);
  TAssert.AssertEquals(0, fpSigAction(SIGUSR1, @Action, @Previous));
  Serial := TBlockSerial.Create;
  Serial.Handle := PipeFD[0];
  Port := TSerialWritePort.Create(Serial);
  Reader := TReadAuditProbe.Create(Port, 32, nil);
  Worker := TInterruptedReader.Create(Reader);
  try
    SignalCount := 0;
    Worker.ExpectData := WithData;
    if WithData then SignalOutput := PipeFD[1] else SignalOutput := -1;
    Worker.Start;
    TAssert.AssertEquals(Ord(wrSignaled), Ord(Worker.Ready.WaitFor(2000)));
    Sleep(2);
    TAssert.AssertEquals(0, KillThread(Worker.ThreadID, SIGUSR1));
    Worker.WaitFor;
    TAssert.AssertTrue('The reader thread received the signal', SignalCount > 0);
    TAssert.AssertEquals('EINTR is a retry, not a terminal read result', 0, Worker.Error);
    if WithData then TAssert.AssertEquals('x', Worker.Data)
    else TAssert.AssertEquals('', Worker.Data);
  finally
    Worker.Terminate;
    Worker.WaitFor;
    Worker.Free;
    Reader.Free;
    SignalOutput := -1;
    fpSigAction(SIGUSR1, @Previous, nil);
    Serial.Handle := INVALID_HANDLE_VALUE;
    Port := nil;
    fpClose(PipeFD[0]);
    fpClose(PipeFD[1]);
  end;
end;
procedure TLazSerialUnixAuditTests.InterruptedReadThenTimeoutIsNotAnError;
begin CheckInterruptedRead(False); end;
procedure TLazSerialUnixAuditTests.InterruptedReadPreservesReceivedData;
begin CheckInterruptedRead(True); end;
procedure CheckLineReset(Reconnect: Boolean);
var
  Master, Slave: cint;
  Name: array[0..255] of Char;
  Serial: TBlockSerial;
  Data: AnsiString;
  First, Second: AnsiChar;
  Invert: Boolean;
begin
  TAssert.AssertEquals(0, OpenAuditPty(@Master, @Slave, @Name[0], nil, nil));
  Serial := TBlockSerial.Create;
  try
    Serial.LinuxLock := False;
    for Invert := False to True do
    begin
      if Invert then begin First := #10; Second := #13; end
      else begin First := #13; Second := #10; end;
      Serial.Connect(StrPas(Name));
      Serial.Config(9600, 8, 'N', SB1, fcNone);
      Serial.ConvertLineEnd := True;
      Serial.LineBuffer := 'old' + First;
      TAssert.AssertTrue(Serial.TryReadBuffered(True, Data));
      TAssert.AssertEquals('old', Data);
      if Reconnect then
      begin
        Serial.CloseSocket;
        Serial.Connect(StrPas(Name));
        Serial.Config(9600, 8, 'N', SB1, fcNone);
      end
      else Serial.Purge;
      Serial.LineBuffer := Second;
      TAssert.AssertTrue('New session must contain its own empty line',
        Serial.TryReadBuffered(True, Data));
      TAssert.AssertEquals('', Data);
      Serial.CloseSocket;
    end;
  finally
    Serial.Free;
    fpClose(Slave);
    fpClose(Master);
  end;
end;
procedure TLazSerialUnixAuditTests.PurgeResetsBothLineSeparators;
begin CheckLineReset(False); end;
procedure TLazSerialUnixAuditTests.ReconnectResetsBothLineSeparators;
begin CheckLineReset(True); end;
procedure TLazSerialUnixAuditTests.SoftwareFlowRoundTripsIndependentlyOfSpeed;
const Speeds: array[0..1] of Integer = (9600, 115200);
var
  Serial: TTermiosAuditSerial;
  State, Decoded: TDCB;
  Settings: Termios;
  Speed, Flags: Integer;
begin
  Serial := TTermiosAuditSerial.Create;
  try
    for Speed in Speeds do
      for Flags := 0 to 3 do
      begin
        State := Default(TDCB);
        State.BaudRate := Speed;
        State.ByteSize := 8;
        if (Flags and 1) <> 0 then State.Flags := State.Flags or dcb_OutX;
        if (Flags and 2) <> 0 then State.Flags := State.Flags or dcb_InX;
        Settings := Default(Termios);
        Serial.Encode(State, Settings);
        AssertEquals('IXON follows OutX', (Flags and 1) <> 0,
          (Settings.c_iflag and IXON) <> 0);
        AssertEquals('IXOFF follows InX', (Flags and 2) <> 0,
          (Settings.c_iflag and IXOFF) <> 0);
        Decoded := Default(TDCB);
        Serial.Decode(Settings, Decoded);
        AssertEquals(State.Flags and (dcb_OutX or dcb_InX),
          Decoded.Flags and (dcb_OutX or dcb_InX));
      end;
  finally Serial.Free; end;
end;
procedure TLazSerialUnixAuditTests.AllParityModesRoundTripAndClearPreviousMode;
var
  Serial: TTermiosAuditSerial;
  State, Decoded: TDCB;
  Settings: Termios;
  Parity: Integer;
begin
  Serial := TTermiosAuditSerial.Create;
  try
    for Parity := 4 downto 0 do
    begin
      State := Default(TDCB);
      State.BaudRate := 9600;
      State.ByteSize := 8;
      State.Parity := Parity;
      if Parity <> 0 then State.Flags := dcb_ParityCheck;
      Settings := Default(Termios);
      Settings.c_cflag := CMSPAR or PARODD;
      Serial.Encode(State, Settings);
      AssertEquals(0, Serial.LastError);
      AssertEquals(Parity >= 3, (Settings.c_cflag and CMSPAR) <> 0);
      Decoded := Default(TDCB);
      Serial.Decode(Settings, Decoded);
      AssertEquals(Parity, Integer(Decoded.Parity));
    end;
  finally Serial.Free; end;
end;
initialization RegisterTest(TLazSerialUnixAuditTests);
{$ENDIF}
end.
