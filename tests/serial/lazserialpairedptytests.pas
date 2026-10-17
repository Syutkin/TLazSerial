unit LazSerialPairedPtyTests;

{$mode ObjFPC}{$H+}

interface

{$IFDEF LINUX}
uses
  Classes, SysUtils, FpcUnit, TestRegistry, LazSerial;

type
  { Two slave devices are exposed to TLazSerial. Only the master ends use
    native I/O; the relay never calls a component from its worker thread. }
  TPtyRelay = class(TThread)
  private
    FMasters: array[0..1] of Integer;
    FForwarded: array[0..1] of LongInt;
    FError: LongInt;
  protected
    procedure Execute; override;
  public
    constructor Create(AMaster0, AMaster1: Integer);
    function Forwarded(AFrom: Integer): Integer;
    function ErrorCode: Integer;
  end;

  TLazSerialPairedPtyTests = class(TTestCase)
  private
    FPorts: array[0..1] of TLazSerial;
    FMasters, FSlaves: array[0..1] of Integer;
    FRelay: TPtyRelay;
    FBytes: array[0..1] of AnsiString;
    FLines: array[0..1] of TStringList;
    FCompletions: array[0..1] of Integer;
    FExpectedId: array[0..1] of QWord;
    FExpectedWriteSize: array[0..1] of Integer;
    FErrors: array[0..1] of Integer;
    function PortIndex(Sender: TObject): Integer;
    procedure Received(Sender: TObject);
    procedure Completed(Sender: TObject; const AResult: TSerialWriteResult);
    procedure Failed(Sender: TObject; Code: Integer; const Message: string);
    procedure CheckHealthy;
    procedure OpenPorts(ABuffered0, ABuffered1, ALines: Boolean);
    procedure ClosePorts;
    procedure Send(AFrom: Integer; const AData: AnsiString; AAsync: Boolean);
    procedure AwaitForwarded(AFrom, ACount: Integer);
    procedure AwaitReceived(AAt, ACount: Integer);
    procedure CheckTransfer(ABuffered, ALines, AAsync: Boolean);
    procedure CheckDuplex(ABuffered0, ABuffered1: Boolean);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure LegacyBytesSync;
    procedure LegacyBytesAsync;
    procedure LegacyLinesSync;
    procedure LegacyLinesAsync;
    procedure BufferedBytesSync;
    procedure BufferedBytesAsync;
    procedure BufferedLinesSync;
    procedure BufferedLinesAsync;
    procedure LegacyDuplex;
    procedure BufferedDuplex;
    procedure MixedReadModesDuplex;
    procedure ReopenAndChangeModes;
  end;
{$ENDIF}

implementation

{$IFDEF LINUX}
uses
  BaseUnix, ctypes, LazSynaSer;

const
  TestTimeoutMs = 5000;
  RelayQueueLimit = 64 * 1024;

function OpenPairedPty(AMaster, ASlave: pcint; AName: PChar;
  ATermios, AWindowSize: Pointer): cint; cdecl;
  external 'util' name 'openpty';

constructor TPtyRelay.Create(AMaster0, AMaster1: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FMasters[0] := AMaster0;
  FMasters[1] := AMaster1;
end;

function TPtyRelay.Forwarded(AFrom: Integer): Integer;
begin
  Result := InterlockedCompareExchange(FForwarded[AFrom], 0, 0);
end;

function TPtyRelay.ErrorCode: Integer;
begin
  Result := InterlockedCompareExchange(FError, 0, 0);
end;

procedure TPtyRelay.Execute;
var
  Descriptors: array[0..1] of TPollFD;
  Pending: array[0..1] of AnsiString;
  Buffer: array[0..4095] of Byte;
  I, Other, Count, Code, ReadSize: Integer;
begin
  Pending[0] := '';
  Pending[1] := '';
  { Keep independent bounded queues so backpressure in one direction does
    not prevent the opposite direction from making progress. }
  while not Terminated do
  begin
    FillChar(Descriptors, SizeOf(Descriptors), 0);
    for I := 0 to 1 do
    begin
      Descriptors[I].fd := FMasters[I];
      if Length(Pending[I]) < RelayQueueLimit then
        Descriptors[I].events := POLLIN;
      if Pending[1 - I] <> '' then
        Descriptors[I].events := Descriptors[I].events or POLLOUT;
    end;
    Count := fpPoll(@Descriptors[0], 2, 10);
    if Count < 0 then
    begin
      Code := fpGetErrno;
      if Code = ESysEINTR then Continue;
      InterlockedExchange(FError, Code);
      Exit;
    end;
    for I := 0 to 1 do
    begin
      if (Descriptors[I].revents and (POLLERR or POLLHUP or POLLNVAL)) <> 0 then
      begin
        InterlockedExchange(FError, ESysEIO);
        Exit;
      end;
      if (Descriptors[I].revents and POLLIN) <> 0 then
      begin
        ReadSize := RelayQueueLimit - Length(Pending[I]);
        if ReadSize > SizeOf(Buffer) then ReadSize := SizeOf(Buffer);
        Count := fpRead(FMasters[I], Buffer[0], ReadSize);
        if Count > 0 then
        begin
          Other := Length(Pending[I]);
          SetLength(Pending[I], Other + Count);
          Move(Buffer[0], Pending[I][Other + 1], Count);
        end
        else
        begin
          Code := fpGetErrno;
          if Count = 0 then Code := ESysEIO;
          if (Code <> ESysEINTR) and (Code <> ESysEAGAIN) then
          begin
            InterlockedExchange(FError, Code);
            Exit;
          end;
        end;
      end;
      Other := 1 - I;
      if ((Descriptors[I].revents and POLLOUT) <> 0) and
        (Pending[Other] <> '') then
      begin
        Count := fpWrite(FMasters[I], Pending[Other][1], Length(Pending[Other]));
        if Count > 0 then
        begin
          Delete(Pending[Other], 1, Count);
          InterlockedExchangeAdd(FForwarded[Other], Count);
        end
        else
        begin
          Code := fpGetErrno;
          if Count = 0 then Code := ESysEIO;
          if (Code <> ESysEINTR) and (Code <> ESysEAGAIN) then
          begin
            InterlockedExchange(FError, Code);
            Exit;
          end;
        end;
      end;
    end;
  end;
end;

procedure TLazSerialPairedPtyTests.SetUp;
var
  I, Flags: Integer;
  Name: array[0..255] of Char;
begin
  for I := 0 to 1 do
  begin
    FMasters[I] := -1;
    FSlaves[I] := -1;
  end;
  for I := 0 to 1 do
  begin
    AssertEquals('openpty', 0,
      OpenPairedPty(@FMasters[I], @FSlaves[I], @Name[0], nil, nil));
    Flags := fpFcntl(FMasters[I], F_GETFL, 0);
    AssertTrue('Read master flags', Flags >= 0);
    AssertEquals('Nonblocking relay', 0,
      fpFcntl(FMasters[I], F_SETFL, Flags or O_NONBLOCK));
    FLines[I] := TStringList.Create;
    FPorts[I] := TLazSerial.Create(nil);
    FPorts[I].Device := StrPas(Name);
    FPorts[I].ReadBufferLimit := 256 * 1024;
    FPorts[I].OnRxData := @Received;
    FPorts[I].OnWriteCompleted := @Completed;
    FPorts[I].OnError := @Failed;
  end;
end;

procedure TLazSerialPairedPtyTests.TearDown;
var
  I: Integer;
begin
  try
    ClosePorts;
  finally
    for I := 0 to 1 do FreeAndNil(FPorts[I]);
    if FRelay <> nil then
    begin
      FRelay.Terminate;
      FRelay.WaitFor;
      FreeAndNil(FRelay);
    end;
    for I := 0 to 1 do
    begin
      FLines[I].Free;
      if FMasters[I] >= 0 then fpClose(FMasters[I]);
      if FSlaves[I] >= 0 then fpClose(FSlaves[I]);
    end;
  end;
end;

function TLazSerialPairedPtyTests.PortIndex(Sender: TObject): Integer;
begin
  AssertEquals('Callbacks run on main thread', Int64(MainThreadID),
    Int64(GetCurrentThreadID));
  if Sender = FPorts[0] then Exit(0);
  AssertTrue('Known endpoint', Sender = FPorts[1]);
  Result := 1;
end;

procedure TLazSerialPairedPtyTests.Received(Sender: TObject);
var
  I: Integer;
  Data: string;
begin
  I := PortIndex(Sender);
  while FPorts[I].DataAvailable do
  begin
    if FPorts[I].BufferedRead then
    begin
      if not FPorts[I].TryReadData(Data) then Break;
    end
    else
    begin
      Data := FPorts[I].ReadData;
      { Legacy readiness can include an incomplete native line. Unlike
        TryReadData, ReadData distinguishes it from an empty line by LastError.
        These line scenarios send one way at a time, so SynSer is accessible. }
      if FPorts[I].RcvLineCRLF and (Data = '') and
        (FPorts[I].SynSer.LastError = ErrTimeout) then Continue;
    end;
    if FPorts[I].RcvLineCRLF then FLines[I].Add(Data)
    else FBytes[I] := FBytes[I] + Data;
  end;
end;

procedure TLazSerialPairedPtyTests.Completed(Sender: TObject;
  const AResult: TSerialWriteResult);
var
  I: Integer;
begin
  I := PortIndex(Sender);
  AssertFalse('Pending cleared before callback', FPorts[I].WritePending);
  AssertEquals('Operation id', FExpectedId[I], AResult.OperationId);
  AssertEquals('Completed write', Ord(swoCompleted), Ord(AResult.Outcome));
  AssertEquals('No write error', 0, AResult.ErrorCode);
  AssertEquals('Requested size', FExpectedWriteSize[I], AResult.BytesRequested);
  AssertEquals('Written size', FExpectedWriteSize[I], AResult.BytesWritten);
  Inc(FCompletions[I]);
end;

procedure TLazSerialPairedPtyTests.Failed(Sender: TObject; Code: Integer;
  const Message: string);
begin
  FErrors[PortIndex(Sender)] := Code;
  Fail('Unexpected port error: ' + IntToStr(Code) + ' ' + Message);
end;

procedure TLazSerialPairedPtyTests.CheckHealthy;
var
  I: Integer;
begin
  AssertEquals('Relay error', 0, FRelay.ErrorCode);
  AssertTrue('Relay thread exception', FRelay.FatalException = nil);
  for I := 0 to 1 do
  begin
    AssertEquals('Endpoint error', 0, FErrors[I]);
    AssertTrue('Endpoint remains active', FPorts[I].Active);
  end;
end;

procedure TLazSerialPairedPtyTests.OpenPorts(ABuffered0, ABuffered1,
  ALines: Boolean);
var
  I: Integer;
begin
  FPorts[0].BufferedRead := ABuffered0;
  FPorts[1].BufferedRead := ABuffered1;
  for I := 0 to 1 do
  begin
    FPorts[I].RcvLineCRLF := ALines;
    FPorts[I].Open;
    AssertTrue('Opened endpoint', FPorts[I].Active);
  end;
  if FRelay = nil then
  begin
    FRelay := TPtyRelay.Create(FMasters[0], FMasters[1]);
    FRelay.Start;
  end;
end;

procedure TLazSerialPairedPtyTests.ClosePorts;
var
  I: Integer;
  Deadline: QWord;
  Pending: Boolean;
begin
  for I := 0 to 1 do
    if FPorts[I] <> nil then FPorts[I].Close;
  Deadline := GetTickCount64 + TestTimeoutMs;
  repeat
    Pending := False;
    for I := 0 to 1 do
      if FPorts[I] <> nil then
        Pending := Pending or FPorts[I].ClosePending or FPorts[I].WritePending;
    if not Pending then Break;
    CheckSynchronize(1);
  until GetTickCount64 >= Deadline;
  AssertFalse('Both endpoints finished cleanup', Pending);
end;

procedure TLazSerialPairedPtyTests.Send(AFrom: Integer;
  const AData: AnsiString; AAsync: Boolean);
var
  Deadline: QWord;
  ExpectedCompletions: Integer;
begin
  if not AAsync then
  begin
    AssertEquals('Synchronous write size', Length(AData), FPorts[AFrom].WriteData(AData));
    Exit;
  end;
  ExpectedCompletions := FCompletions[AFrom] + 1;
  FExpectedWriteSize[AFrom] := Length(AData);
  FExpectedId[AFrom] := FPorts[AFrom].WriteDataAsync(AData, TestTimeoutMs);
  Deadline := GetTickCount64 + TestTimeoutMs;
  while (FCompletions[AFrom] < ExpectedCompletions) and
    (GetTickCount64 < Deadline) do
  begin
    CheckHealthy;
    CheckSynchronize(1);
  end;
  AssertEquals('Write completion callback', ExpectedCompletions, FCompletions[AFrom]);
end;

procedure TLazSerialPairedPtyTests.AwaitForwarded(AFrom, ACount: Integer);
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + TestTimeoutMs;
  while (FRelay.Forwarded(AFrom) < ACount) and (GetTickCount64 < Deadline) do
  begin
    CheckHealthy;
    CheckSynchronize(1);
  end;
  AssertEquals('Bytes relayed to peer', ACount, FRelay.Forwarded(AFrom));
end;

procedure TLazSerialPairedPtyTests.AwaitReceived(AAt, ACount: Integer);
var
  Deadline: QWord;
  Actual: Integer;
begin
  Deadline := GetTickCount64 + TestTimeoutMs;
  repeat
    CheckHealthy;
    if FPorts[AAt].RcvLineCRLF then Actual := FLines[AAt].Count
    else Actual := Length(FBytes[AAt]);
    if Actual >= ACount then Break;
    CheckSynchronize(1);
  until GetTickCount64 >= Deadline;
  AssertEquals('Received count', ACount, Actual);
end;

function BinaryPayload(ASize, ASeed: Integer): AnsiString;
var
  I: Integer;
begin
  SetLength(Result, ASize);
  for I := 1 to ASize do Result[I] := AnsiChar((I + ASeed) mod 256);
end;

procedure TLazSerialPairedPtyTests.CheckTransfer(ABuffered, ALines,
  AAsync: Boolean);
var
  From, At, ForwardedBefore: Integer;
  Payload, First, Last: AnsiString;
begin
  OpenPorts(ABuffered, ABuffered, ALines);
  for From := 0 to 1 do
  begin
    At := 1 - From;
    if ALines then
    begin
      First := 'first from ' + IntToStr(From);
      Last := 'last' + #0#255;
      ForwardedBefore := FRelay.Forwarded(From);
      Send(From, First + #13, AAsync);
      AwaitForwarded(From, ForwardedBefore + Length(First) + 1);
      AssertEquals('Incomplete line is retained', 0, FLines[At].Count);
      Send(From, #10#13#10 + Last + #13, AAsync);
      AwaitForwarded(From, ForwardedBefore + Length(First) + Length(Last) + 5);
      Send(From, #10, AAsync);
      AwaitReceived(At, 3);
      AssertEquals(First, FLines[At][0]);
      AssertEquals('Empty line', '', FLines[At][1]);
      AssertEquals(Last, FLines[At][2]);
    end
    else
    begin
      Payload := BinaryPayload(8192, From * 71);
      Send(From, Copy(Payload, 1, 17), AAsync);
      Send(From, Copy(Payload, 18, 4096), AAsync);
      Send(From, Copy(Payload, 4114, MaxInt), AAsync);
      AwaitReceived(At, Length(Payload));
      AssertEquals('Ordered binary stream', Payload, FBytes[At]);
    end;
  end;
end;

procedure TLazSerialPairedPtyTests.CheckDuplex(ABuffered0, ABuffered1: Boolean);
var
  Payload: array[0..1] of AnsiString;
  I: Integer;
  Deadline: QWord;
begin
  OpenPorts(ABuffered0, ABuffered1, False);
  for I := 0 to 1 do
  begin
    Payload[I] := BinaryPayload(128 * 1024, I * 91);
    FExpectedWriteSize[I] := Length(Payload[I]);
    FExpectedId[I] := FPorts[I].WriteDataAsync(Payload[I], TestTimeoutMs);
  end;
  { Start both writes before pumping the main queue. Receipt and completion
    are separate conditions: completion alone does not prove peer delivery. }
  for I := 0 to 1 do
  begin
    AwaitReceived(I, Length(Payload[1 - I]));
    AssertEquals('Duplex ordered stream', Payload[1 - I], FBytes[I]);
  end;
  Deadline := GetTickCount64 + TestTimeoutMs;
  while ((FCompletions[0] = 0) or (FCompletions[1] = 0)) and
    (GetTickCount64 < Deadline) do CheckSynchronize(1);
  for I := 0 to 1 do AssertEquals('Duplex completion', 1, FCompletions[I]);
  CheckHealthy;
end;

procedure TLazSerialPairedPtyTests.LegacyBytesSync;
begin CheckTransfer(False, False, False); end;
procedure TLazSerialPairedPtyTests.LegacyBytesAsync;
begin CheckTransfer(False, False, True); end;
procedure TLazSerialPairedPtyTests.LegacyLinesSync;
begin CheckTransfer(False, True, False); end;
procedure TLazSerialPairedPtyTests.LegacyLinesAsync;
begin CheckTransfer(False, True, True); end;
procedure TLazSerialPairedPtyTests.BufferedBytesSync;
begin CheckTransfer(True, False, False); end;
procedure TLazSerialPairedPtyTests.BufferedBytesAsync;
begin CheckTransfer(True, False, True); end;
procedure TLazSerialPairedPtyTests.BufferedLinesSync;
begin CheckTransfer(True, True, False); end;
procedure TLazSerialPairedPtyTests.BufferedLinesAsync;
begin CheckTransfer(True, True, True); end;
procedure TLazSerialPairedPtyTests.LegacyDuplex;
begin CheckDuplex(False, False); end;
procedure TLazSerialPairedPtyTests.BufferedDuplex;
begin CheckDuplex(True, True); end;
procedure TLazSerialPairedPtyTests.MixedReadModesDuplex;
begin CheckDuplex(False, True); end;

procedure TLazSerialPairedPtyTests.ReopenAndChangeModes;
var
  From, At: Integer;
  Payload: AnsiString;
begin
  OpenPorts(True, False, False);
  for From := 0 to 1 do
  begin
    Payload := 'old session ' + IntToStr(From);
    Send(From, Payload, True);
    AwaitReceived(1 - From, Length(Payload));
    AssertEquals(Payload, FBytes[1 - From]);
  end;
  ClosePorts;
  for At := 0 to 1 do
  begin
    AssertFalse('Endpoint closed', FPorts[At].Active);
    FBytes[At] := '';
  end;
  OpenPorts(False, True, True);
  for From := 0 to 1 do
  begin
    At := 1 - From;
    Payload := 'new session ' + IntToStr(From);
    Send(From, Payload + #13#10, True);
    AwaitReceived(At, 1);
    AssertEquals('New session only', Payload, FLines[At][0]);
  end;
end;

initialization
  RegisterTest(TLazSerialPairedPtyTests);
{$ENDIF}
end.
