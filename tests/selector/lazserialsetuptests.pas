unit LazSerialSetupTests;

{$mode ObjFPC}{$H+}

interface

uses
  FpcUnit, TestRegistry;

type
  TLazSerialSetupTests = class(TTestCase)
  published
    procedure BaudRatesRoundTripAndMatchPlatformValues;
    procedure DataBitsRoundTrip;
    procedure StopBitsRoundTrip;
    procedure ParityRoundTripsCaseInsensitively;
    procedure FlowControlRoundTripsCaseInsensitively;
    procedure UnknownValuesUseDocumentedFallbacks;
  end;

implementation

uses
  SysUtils, LazSerial, LazSerialCommon, LazSerialSetup;

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

initialization
  RegisterTest(TLazSerialSetupTests);

end.
