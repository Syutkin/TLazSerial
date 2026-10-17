unit LazSerialBufferedReadTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, FpcUnit, TestRegistry, LazSerial,
  LazSerialTransportTests;

type
  TLazSerialBufferedReadTests = class(TTestCase)
  published
    procedure DefaultsPreserveLegacyReceive;
    procedure InvalidLimitPreservesPreviousValue;
    procedure TryReadRequiresOptIn;
    procedure UnsupportedModeRollsBackOpen;
  end;

implementation

procedure TLazSerialBufferedReadTests.DefaultsPreserveLegacyReceive;
var
  Serial: TLazSerial;
begin
  Serial := TLazSerial.Create(nil);
  try
    AssertFalse(Serial.BufferedRead);
    AssertEquals(65536, Serial.ReadBufferLimit);
    AssertFalse(Serial.ClosePending);
    Serial.BufferedRead := True;
    Serial.ReadBufferLimit := 128;
    AssertTrue(Serial.BufferedRead);
    AssertEquals(128, Serial.ReadBufferLimit);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialBufferedReadTests.InvalidLimitPreservesPreviousValue;
var
  Serial: TLazSerial;
  Limit: Integer;
  Raised: Boolean;
begin
  Serial := TLazSerial.Create(nil);
  try
    for Limit := -1 to 0 do
    begin
      Raised := False;
      try
        Serial.ReadBufferLimit := Limit;
      except
        on E: EArgumentException do Raised := True;
      end;
      AssertTrue(Raised);
      AssertEquals(65536, Serial.ReadBufferLimit);
    end;
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialBufferedReadTests.TryReadRequiresOptIn;
var
  Serial: TLazSerial;
  Value: string;
  Raised: Boolean;
begin
  Serial := TLazSerial.Create(nil);
  try
    Raised := False;
    try
      Serial.TryReadData(Value);
    except
      on E: EInvalidOperation do Raised := True;
    end;
    AssertTrue(Raised);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialBufferedReadTests.UnsupportedModeRollsBackOpen;
var
  Serial: TTestableLazSerial;
  Transport: TFakeSerialTransport;
  Raised: Boolean;
begin
  Serial := TTestableLazSerial.Create(nil);
  try
    Transport := TFakeSerialTransport.Create;
    Serial.InstallTransport(Transport);
    Serial.BufferedRead := True;
    Raised := False;
    try
      Serial.Open;
    except
      on E: EInvalidOperation do Raised := True;
    end;
    AssertTrue(Raised);
    AssertFalse(Serial.Active);
    AssertFalse(Transport.IsOpen);
    AssertFalse(Serial.ClosePending);
  finally
    Serial.Free;
  end;
end;

initialization
  RegisterTest(TLazSerialBufferedReadTests);

end.
