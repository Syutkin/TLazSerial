unit LazSerialSetupTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, FpcUnit, TestRegistry;

type
  TLazSerialSetupTests = class(TTestCase)
  private
    procedure AssertItemOccursOnce(AItems: TStrings; const AValue: string);
  published
    procedure BaudRatesRoundTripAndMatchPlatformValues;
    procedure DataBitsRoundTrip;
    procedure StopBitsRoundTrip;
    procedure ParityRoundTripsCaseInsensitively;
    procedure FlowControlRoundTripsCaseInsensitively;
    procedure UnknownValuesUseDocumentedFallbacks;
    procedure SetupFormPopulatesEveryOptionExactlyOnce;
    procedure CancelledSetupLeavesActiveSerialUnchanged;
    procedure AcceptedSetupClosesAndAppliesEveryField;
  end;

implementation

uses
  SysUtils, Forms, Controls, LazSerial, LazSerialCommon, LazSerialSetup,
  LazSerialTransportTests;

procedure TLazSerialSetupTests.AssertItemOccursOnce(AItems: TStrings;
  const AValue: string);
var
  Count: Integer;
  I: Integer;
begin
  Count := 0;
  for I := 0 to AItems.Count - 1 do
    if AItems[I] = AValue then
      Inc(Count);
  AssertEquals(AValue, 1, Count);
end;

procedure TLazSerialSetupTests.BaudRatesRoundTripAndMatchPlatformValues;
var
  Index: Integer;
  Rate: TBaudRate;
begin
  for Index := Ord(Low(TBaudRate)) to Ord(High(TBaudRate)) do
  begin
    Rate := TBaudRate(Index);
    AssertEquals(IntToStr(ConstsBaud[Rate]), BaudRateToStr(Rate));
    AssertEquals(Index, Ord(StrToBaudRate(BaudRateToStr(Rate))));
  end;

  {$IFDEF Windows}
  AssertEquals(19, Ord(High(TBaudRate)) - Ord(Low(TBaudRate)) + 1);
  AssertEquals('110', BaudRateToStr(Low(TBaudRate)));
  AssertEquals('921600', BaudRateToStr(High(TBaudRate)));
  {$ELSE}
  {$IFDEF Darwin}
  AssertEquals(19, Ord(High(TBaudRate)) - Ord(Low(TBaudRate)) + 1);
  AssertEquals('0', BaudRateToStr(Low(TBaudRate)));
  AssertEquals('230400', BaudRateToStr(High(TBaudRate)));
  {$ELSE}
  AssertEquals(31, Ord(High(TBaudRate)) - Ord(Low(TBaudRate)) + 1);
  AssertEquals('0', BaudRateToStr(Low(TBaudRate)));
  AssertEquals('4000000', BaudRateToStr(High(TBaudRate)));
  {$ENDIF}
  {$ENDIF}
end;

procedure TLazSerialSetupTests.DataBitsRoundTrip;
var
  Index: Integer;
  Value: TDataBits;
begin
  for Index := Ord(Low(TDataBits)) to Ord(High(TDataBits)) do
  begin
    Value := TDataBits(Index);
    AssertEquals(Index, Ord(StrToDataBits(DataBitsToStr(Value))));
  end;
end;

procedure TLazSerialSetupTests.StopBitsRoundTrip;
var
  Index: Integer;
  Value: TStopBits;
begin
  for Index := Ord(Low(TStopBits)) to Ord(High(TStopBits)) do
  begin
    Value := TStopBits(Index);
    AssertEquals(Index, Ord(StrToStopBits(StopBitsToStr(Value))));
  end;
end;

procedure TLazSerialSetupTests.ParityRoundTripsCaseInsensitively;
var
  Index: Integer;
  Value: TParity;
begin
  for Index := Ord(Low(TParity)) to Ord(High(TParity)) do
  begin
    Value := TParity(Index);
    AssertEquals(Index, Ord(StrToParity(LowerCase(ParityToStr(Value)))));
  end;
end;

procedure TLazSerialSetupTests.FlowControlRoundTripsCaseInsensitively;
var
  Index: Integer;
  Value: TFlowControl;
begin
  for Index := Ord(Low(TFlowControl)) to Ord(High(TFlowControl)) do
  begin
    Value := TFlowControl(Index);
    AssertEquals(Index,
      Ord(StrToFlowControl(LowerCase(FlowControlToStr(Value)))));
  end;
end;

procedure TLazSerialSetupTests.UnknownValuesUseDocumentedFallbacks;
const
  UnknownValue = '__unknown_serial_setting__';
begin
  AssertEquals(Ord(br__9600), Ord(StrToBaudRate(UnknownValue)));
  AssertEquals(Ord(db8bits), Ord(StrToDataBits(UnknownValue)));
  AssertEquals(Ord(sbOne), Ord(StrToStopBits(UnknownValue)));
  AssertEquals(Ord(pNone), Ord(StrToParity(UnknownValue)));
  AssertEquals(Ord(fcNone), Ord(StrToFlowControl(UnknownValue)));
end;

procedure TLazSerialSetupTests.SetupFormPopulatesEveryOptionExactlyOnce;
var
  Form: TComSetupFrm;
  I: Integer;
begin
  Form := TComSetupFrm.Create(nil);
  try
    Form.FormCreate(nil);
    AssertTrue(Form.SerialSelector1.AllowCustomDevice);
    AssertEquals(Ord(High(TBaudRate)) - Ord(Low(TBaudRate)) + 1,
      Form.ComComboBox2.Items.Count);
    AssertEquals(Ord(High(TDataBits)) - Ord(Low(TDataBits)) + 1,
      Form.ComComboBox3.Items.Count);
    AssertEquals(Ord(High(TStopBits)) - Ord(Low(TStopBits)) + 1,
      Form.ComComboBox4.Items.Count);
    AssertEquals(Ord(High(TParity)) - Ord(Low(TParity)) + 1,
      Form.ComComboBox5.Items.Count);
    AssertEquals(Ord(High(TFlowControl)) - Ord(Low(TFlowControl)) + 1,
      Form.ComComboBox6.Items.Count);

    for I := Ord(Low(TBaudRate)) to Ord(High(TBaudRate)) do
      AssertItemOccursOnce(Form.ComComboBox2.Items,
        BaudRateToStr(TBaudRate(I)));
    for I := Ord(Low(TDataBits)) to Ord(High(TDataBits)) do
      AssertItemOccursOnce(Form.ComComboBox3.Items,
        DataBitsToStr(TDataBits(I)));
    for I := Ord(Low(TStopBits)) to Ord(High(TStopBits)) do
      AssertItemOccursOnce(Form.ComComboBox4.Items,
        StopBitsToStr(TStopBits(I)));
    for I := Ord(Low(TParity)) to Ord(High(TParity)) do
      AssertItemOccursOnce(Form.ComComboBox5.Items,
        ParityToStr(TParity(I)));
    for I := Ord(Low(TFlowControl)) to Ord(High(TFlowControl)) do
      AssertItemOccursOnce(Form.ComComboBox6.Items,
        FlowControlToStr(TFlowControl(I)));
  finally
    Form.Free;
  end;
end;

procedure TLazSerialSetupTests.CancelledSetupLeavesActiveSerialUnchanged;
var
  Form: TComSetupFrm;
  Serial: TTestableLazSerial;
  Transport: TFakeSerialTransport;
begin
  Serial := TTestableLazSerial.Create(nil);
  Transport := TFakeSerialTransport.Create;
  Serial.InstallTransport(Transport);
  Form := TComSetupFrm.Create(nil);
  try
    Serial.Device := 'original-device';
    Serial.BaudRate := br__9600;
    Serial.DataBits := db8bits;
    Serial.StopBits := sbOne;
    Serial.Parity := pNone;
    Serial.FlowControl := fcNone;
    Serial.Open;

    Form.SerialSelector1.Device := 'new-device';
    Form.ComComboBox2.Text := BaudRateToStr(br115200);
    Form.ComComboBox3.Text := DataBitsToStr(db7bits);
    Form.ComComboBox4.Text := StopBitsToStr(sbTwo);
    Form.ComComboBox5.Text := ParityToStr(pEven);
    Form.ComComboBox6.Text := FlowControlToStr(fcRTS_CTS);
    ApplyComPortSetupResult(Serial, Form, mrCancel);

    AssertTrue(Serial.Active);
    AssertEquals('original-device', Serial.Device);
    AssertEquals(Ord(br__9600), Ord(Serial.BaudRate));
    AssertEquals(Ord(db8bits), Ord(Serial.DataBits));
    AssertEquals(Ord(sbOne), Ord(Serial.StopBits));
    AssertEquals(Ord(pNone), Ord(Serial.Parity));
    AssertEquals(Ord(fcNone), Ord(Serial.FlowControl));
    AssertEquals(0, Transport.CloseCount);
  finally
    Form.Free;
    Serial.Free;
  end;
end;

procedure TLazSerialSetupTests.AcceptedSetupClosesAndAppliesEveryField;
var
  Form: TComSetupFrm;
  Serial: TTestableLazSerial;
  Transport: TFakeSerialTransport;
begin
  Serial := TTestableLazSerial.Create(nil);
  Transport := TFakeSerialTransport.Create;
  Serial.InstallTransport(Transport);
  Form := TComSetupFrm.Create(nil);
  try
    Serial.Device := 'original-device';
    Serial.Open;
    Form.SerialSelector1.Device := 'new-device';
    Form.ComComboBox2.Text := BaudRateToStr(br115200);
    Form.ComComboBox3.Text := DataBitsToStr(db7bits);
    Form.ComComboBox4.Text := StopBitsToStr(sbTwo);
    Form.ComComboBox5.Text := ParityToStr(pEven);
    Form.ComComboBox6.Text := FlowControlToStr(fcRTS_CTS);

    ApplyComPortSetupResult(Serial, Form, mrOK);

    AssertFalse(Serial.Active);
    AssertEquals(1, Transport.CloseCount);
    AssertEquals('new-device', Serial.Device);
    AssertEquals(Ord(br115200), Ord(Serial.BaudRate));
    AssertEquals(Ord(db7bits), Ord(Serial.DataBits));
    AssertEquals(Ord(sbTwo), Ord(Serial.StopBits));
    AssertEquals(Ord(pEven), Ord(Serial.Parity));
    AssertEquals(Ord(fcRTS_CTS), Ord(Serial.FlowControl));
  finally
    Form.Free;
    Serial.Free;
  end;
end;

initialization
  RegisterTest(TLazSerialSetupTests);

end.
