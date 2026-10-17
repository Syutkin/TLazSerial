unit LazSerialStreamAuditTests;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, FpcUnit, TestRegistry, LazSynaSer;
type
  TLazSerialStreamAuditTests = class(TTestCase)
  published
    procedure RawStreamRetriesEveryPartialBlock;
    procedure StreamHeadersAreSentCompletely;
    procedure ZeroProgressFailsWithoutLooping;
    procedure ErrorStopsTheStreamAndPreservesCode;
    procedure HeaderErrorDoesNotSendPayload;
  end;
implementation
uses LazSerialCommon;
type
  TPartialStreamSerial = class(TBlockSerial)
  public
    Output: AnsiString;
    Calls, ErrorAt: Integer;
    NoProgress: Boolean;
    function SendBuffer(Buffer: Pointer; Length: Integer): Integer; override;
  end;
function TPartialStreamSerial.SendBuffer(Buffer: Pointer; Length: Integer): Integer;
var Part: AnsiString;
begin
  Inc(Calls);
  if (ErrorAt > 0) and (Calls >= ErrorAt) then
  begin SetSynaError(ErrNoDeviceAnswer); Exit(0); end;
  SetSynaError(0);
  if NoProgress then Exit(0);
  Result := Length div 2;
  if Result = 0 then Result := Length;
  SetString(Part, PAnsiChar(Buffer), Result);
  Output := Output + Part;
end;
procedure TLazSerialStreamAuditTests.RawStreamRetriesEveryPartialBlock;
var Serial: TPartialStreamSerial; Stream: TStringStream; Data: string;
begin
  Data := StringOfChar('x', cSerialChunk + 17);
  Serial := TPartialStreamSerial.Create;
  Stream := TStringStream.Create(Data);
  try
    Serial.SendStreamRaw(Stream);
    AssertEquals(0, Serial.LastError);
    AssertEquals(Data, Serial.Output);
  finally Stream.Free; Serial.Free; end;
end;
procedure TLazSerialStreamAuditTests.StreamHeadersAreSentCompletely;
var Serial: TPartialStreamSerial; Stream: TStringStream; Indy: Boolean;
    Header: Integer;
begin
  for Indy := False to True do
  begin
    Serial := TPartialStreamSerial.Create;
    Stream := TStringStream.Create('payload');
    try
      if Indy then Serial.SendStreamIndy(Stream) else Serial.SendStream(Stream);
      AssertEquals(4 + Length('payload'), Length(Serial.Output));
      Move(Serial.Output[1], Header, SizeOf(Header));
      if Indy then Header := SwapEndian(Header);
      AssertEquals(7, Header);
      AssertEquals('payload', Copy(Serial.Output, 5, MaxInt));
    finally Stream.Free; Serial.Free; end;
  end;
end;
procedure TLazSerialStreamAuditTests.ZeroProgressFailsWithoutLooping;
var Serial: TPartialStreamSerial; Stream: TStringStream; Raises: Boolean;
    Code: Integer;
begin
  for Raises := False to True do
  begin
    Serial := TPartialStreamSerial.Create;
    Stream := TStringStream.Create('payload');
    try
      Serial.NoProgress := True;
      Serial.RaiseExcept := Raises;
      Code := 0;
      try Serial.SendStreamRaw(Stream);
      except on E: ESynaSerError do Code := E.ErrorCode; end;
      AssertEquals(ErrTimeout, Serial.LastError);
      if Raises then AssertEquals(ErrTimeout, Code) else AssertEquals(0, Code);
      AssertEquals(1, Serial.Calls);
    finally Stream.Free; Serial.Free; end;
  end;
end;
procedure TLazSerialStreamAuditTests.ErrorStopsTheStreamAndPreservesCode;
var Serial: TPartialStreamSerial; Stream: TStringStream;
begin
  Serial := TPartialStreamSerial.Create;
  Stream := TStringStream.Create(StringOfChar('x', 3 * cSerialChunk));
  try
    Serial.ErrorAt := 2;
    Serial.SendStreamRaw(Stream);
    AssertEquals(2, Serial.Calls);
    AssertEquals(cSerialChunk div 2, Length(Serial.Output));
    AssertEquals(ErrNoDeviceAnswer, Serial.LastError);
    AssertEquals(Int64(cSerialChunk), Stream.Position);
  finally Stream.Free; Serial.Free; end;
end;
procedure TLazSerialStreamAuditTests.HeaderErrorDoesNotSendPayload;
var Serial: TPartialStreamSerial; Stream: TStringStream; Indy: Boolean;
begin
  for Indy := False to True do
  begin
    Serial := TPartialStreamSerial.Create;
    Stream := TStringStream.Create('payload');
    try
      Serial.ErrorAt := 1;
      if Indy then Serial.SendStreamIndy(Stream) else Serial.SendStream(Stream);
      AssertEquals(1, Serial.Calls);
      AssertEquals(Int64(0), Stream.Position);
      AssertEquals(ErrNoDeviceAnswer, Serial.LastError);
    finally Stream.Free; Serial.Free; end;
  end;
end;
initialization RegisterTest(TLazSerialStreamAuditTests);
end.
