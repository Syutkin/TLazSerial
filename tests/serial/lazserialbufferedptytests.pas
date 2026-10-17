unit LazSerialBufferedPtyTests;
{$mode ObjFPC}{$H+}
interface
{$IFDEF UNIX}
uses Classes, SysUtils, FpcUnit, TestRegistry, LazSerial;
type
  TLazSerialBufferedPtyTests = class(TTestCase)
  private
    FSerial: TLazSerial;
    FMaster, FSlave, FAction, FCalls, FParseErrors, FTerminalError: Integer;
    FValues: TStringList;
    procedure Received(Sender: TObject);
    procedure Failed(Sender: TObject; Code: Integer; const Message: string);
    procedure Send(const Data: AnsiString);
    procedure Pump(AMs: Cardinal);
    procedure AwaitValues(ACount: Integer);
    procedure AwaitCleanup;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure SplitEmptyLinesAndModeSwitch;
    procedure NoReadDoesNotRepeatCallbacks;
    procedure LongLineErrorKeepsPortOpen;
    procedure OverflowClosesAndCanReopenInLegacyMode;
    procedure ReceiveContinuesDuringBlockedWrite;
    procedure ReceiveHandlerCanDestroyComponent;
    procedure SynchronousWriteRemainsUsable;
  end;
{$ENDIF}
implementation
{$IFDEF UNIX}
uses BaseUnix, ctypes, LazSynaSer;
function OpenBufferedPty(AMaster, ASlave: pcint; AName: PChar;
  ATermios, AWindowSize: Pointer): cint; cdecl; external 'util' name 'openpty';
procedure TLazSerialBufferedPtyTests.SetUp;
var Name: array[0..255] of Char;
begin
  FMaster := -1; FSlave := -1;
  AssertEquals(0, OpenBufferedPty(@FMaster, @FSlave, @Name[0], nil, nil));
  FValues := TStringList.Create;
  FSerial := TLazSerial.Create(nil);
  FSerial.Device := StrPas(Name);
  FSerial.BufferedRead := True;
  FSerial.OnRxData := @Received;
  FSerial.OnError := @Failed;
  FAction := 0; FCalls := 0; FParseErrors := 0; FTerminalError := 0;
end;
procedure TLazSerialBufferedPtyTests.TearDown;
begin
  if FSerial <> nil then begin FSerial.Close; AwaitCleanup; end;
  FreeAndNil(FSerial);
  Pump(20);
  FValues.Free;
  if FMaster >= 0 then fpClose(FMaster);
  if FSlave >= 0 then fpClose(FSlave);
end;
procedure TLazSerialBufferedPtyTests.Received(Sender: TObject);
var Data: string;
begin
  AssertEquals(Int64(MainThreadID), Int64(GetCurrentThreadID));
  Inc(FCalls);
  if FAction = 1 then Exit;
  if FAction = 2 then begin FreeAndNil(FSerial); Exit; end;
  try
    if FSerial.TryReadData(Data) then FValues.Add(Data);
  except
    on E: ESynaSerError do
    begin
      AssertEquals(ErrMaxBuffer, E.ErrorCode);
      Inc(FParseErrors);
    end;
  end;
end;
procedure TLazSerialBufferedPtyTests.Failed(Sender: TObject; Code: Integer;
  const Message: string);
begin
  AssertFalse(FSerial.Active);
  FTerminalError := Code;
end;
procedure TLazSerialBufferedPtyTests.Send(const Data: AnsiString);
begin AssertEquals(Length(Data), fpWrite(FMaster, Data[1], Length(Data))); end;
procedure TLazSerialBufferedPtyTests.Pump(AMs: Cardinal);
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + AMs;
  repeat CheckSynchronize(1); until GetTickCount64 >= Deadline;
end;
procedure TLazSerialBufferedPtyTests.AwaitValues(ACount: Integer);
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 2000;
  while (FValues.Count < ACount) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
  AssertEquals(ACount, FValues.Count);
end;
procedure TLazSerialBufferedPtyTests.AwaitCleanup;
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 2000;
  while (FSerial.ClosePending or FSerial.WritePending) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
  AssertFalse(FSerial.ClosePending);
  AssertFalse(FSerial.WritePending);
end;
procedure TLazSerialBufferedPtyTests.SplitEmptyLinesAndModeSwitch;
begin
  FSerial.RcvLineCRLF := True;
  FSerial.Open;
  Send('first' + #13);
  Pump(50);
  AssertEquals(0, FCalls);
  Send(#10 + #13#10 + 'second' + #13#10 + 'tail');
  AwaitValues(3);
  AssertEquals('first', FValues[0]); AssertEquals('', FValues[1]); AssertEquals('second', FValues[2]);
  Pump(30); AssertEquals(3, FCalls);
  AssertFalse(FSerial.DataAvailable);
  FSerial.RcvLineCRLF := False;
  AwaitValues(4);
  AssertEquals('tail', FValues[3]);
end;
procedure TLazSerialBufferedPtyTests.NoReadDoesNotRepeatCallbacks;
var Deadline: QWord;
begin
  FAction := 1;
  FSerial.Open;
  Send('ready');
  Deadline := GetTickCount64 + 2000;
  while (FCalls = 0) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
  AssertEquals(1, FCalls);
  Pump(50);
  AssertEquals(1, FCalls);
  AssertTrue(FSerial.DataAvailable);
end;
procedure TLazSerialBufferedPtyTests.LongLineErrorKeepsPortOpen;
begin
  FSerial.SynSer.MaxLineLength := 5;
  FSerial.RcvLineCRLF := True;
  FSerial.Open;
  Send('123456' + #13#10 + 'ok' + #13#10);
  AwaitValues(1);
  AssertEquals('ok', FValues[0]);
  AssertEquals(1, FParseErrors);
  AssertEquals(0, FTerminalError);
  AssertTrue(FSerial.Active);
end;
procedure TLazSerialBufferedPtyTests.OverflowClosesAndCanReopenInLegacyMode;
var Deadline: QWord;
begin
  FSerial.ReadBufferLimit := 4;
  FSerial.RcvLineCRLF := True;
  FSerial.Open;
  Send('full');
  Deadline := GetTickCount64 + 2000;
  while (FTerminalError = 0) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
  AssertEquals(LazSerial.ErrReadBufferOverflow, FTerminalError);
  AssertFalse(FSerial.Active);
  AssertFalse(FSerial.DataAvailable);
  AwaitCleanup;
  FSerial.BufferedRead := False;
  FSerial.OnRxData := nil;
  FSerial.RcvLineCRLF := False;
  FSerial.Open;
  Send('fresh');
  Deadline := GetTickCount64 + 2000;
  while not FSerial.DataAvailable and (GetTickCount64 < Deadline) do CheckSynchronize(1);
  AssertEquals('fresh', FSerial.ReadData);
end;
procedure TLazSerialBufferedPtyTests.ReceiveContinuesDuringBlockedWrite;
var Deadline: QWord; Rejected: Boolean;
begin
  FSerial.Open;
  FSerial.WriteDataAsync(StringOfChar('x', 512 * 1024), 5000);
  Send('received' + #0 + #255);
  AwaitValues(1);
  AssertEquals('received' + #0 + #255, FValues[0]);
  AssertTrue(FSerial.WritePending);
  Rejected := False;
  try FSerial.SynSer.MaxLineLength := 12; except on E: EInvalidOperation do Rejected := True; end;
  AssertTrue(Rejected);
  FSerial.CancelWrite;
  Deadline := GetTickCount64 + 2000;
  while FSerial.WritePending and (GetTickCount64 < Deadline) do CheckSynchronize(1);
  AssertFalse(FSerial.WritePending);
  AssertTrue(FSerial.Active);
  Send('after');
  AwaitValues(2); AssertEquals('after', FValues[1]);
end;
procedure TLazSerialBufferedPtyTests.ReceiveHandlerCanDestroyComponent;
var Deadline: QWord;
begin
  FAction := 2;
  FSerial.Open;
  Send('destroy');
  Deadline := GetTickCount64 + 2000;
  while (FSerial <> nil) and (GetTickCount64 < Deadline) do CheckSynchronize(1);
  AssertTrue(FSerial = nil);
end;
procedure TLazSerialBufferedPtyTests.SynchronousWriteRemainsUsable;
const Payload: AnsiString = 'sync' + #0 + #255;
var Descriptor: TPollFD; Bytes: array[0..63] of Byte; Count: Integer;
  Value: AnsiString;
begin
  FSerial.Open;
  AssertEquals(Length(Payload), FSerial.WriteData(Payload));
  FillChar(Descriptor, SizeOf(Descriptor), 0);
  Descriptor.fd := FMaster;
  Descriptor.events := POLLIN;
  AssertEquals(1, fpPoll(@Descriptor, 1, 2000));
  Count := fpRead(FMaster, Bytes[0], SizeOf(Bytes));
  AssertEquals(Length(Payload), Count);
  SetLength(Value, Count);
  Move(Bytes[0], Value[1], Count);
  AssertEquals(Payload, Value);
end;
initialization RegisterTest(TLazSerialBufferedPtyTests);
{$ENDIF}
end.
