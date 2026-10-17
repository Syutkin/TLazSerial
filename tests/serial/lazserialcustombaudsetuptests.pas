unit LazSerialCustomBaudSetupTests;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, Forms, Controls, ExtCtrls, FpcUnit, TestRegistry, LazSerial,
  LazSerialSetup, LazSerialTransportTests;
type
  TLazSerialCustomBaudSetupTests = class(TTestCase)
  private
    Serial: TTestableLazSerial;
    Transport: TFakeSerialTransport;
    Timer: TTimer;
    Found: Boolean;
    ShownRate, ChooseRate: string;
    DialogResult: Integer;
    procedure HandleDialog(Sender: TObject);
    procedure RunDialog;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure DialogShowsEffectiveCustomRate;
    procedure AcceptWithoutChangesPreservesBothRates;
    procedure ChoosingPresetDisablesOverride;
    procedure ChoosingOriginalPresetAlsoDisablesOverride;
    procedure CancellationPreservesBothRates;
    procedure CustomEqualToPresetIsStillPreserved;
    procedure ZeroCustomRateIsDisplayedAndPreserved;
  end;
implementation
procedure TLazSerialCustomBaudSetupTests.SetUp;
begin
  inherited SetUp;
  Serial := TTestableLazSerial.Create(nil);
  Transport := TFakeSerialTransport.Create;
  Serial.InstallTransport(Transport);
  Serial.BaudRate := br__9600;
  Serial.CustomBaudRate := 123456;
  DialogResult := mrOK;
  ChooseRate := '';
  Found := False;
  Timer := TTimer.Create(nil);
  Timer.Enabled := False;
  Timer.Interval := 1;
  Timer.OnTimer := @HandleDialog;
end;
procedure TLazSerialCustomBaudSetupTests.TearDown;
begin
  Timer.Free;
  Serial.Free;
  inherited TearDown;
end;
procedure TLazSerialCustomBaudSetupTests.HandleDialog(Sender: TObject);
var I: Integer; Form: TComSetupFrm;
begin
  for I := 0 to Screen.FormCount - 1 do
    if Screen.Forms[I] is TComSetupFrm then
    begin
      Timer.Enabled := False;
      Form := TComSetupFrm(Screen.Forms[I]);
      ShownRate := Form.ComComboBox2.Text;
      if ChooseRate <> '' then
        Form.ComComboBox2.ItemIndex := Form.ComComboBox2.Items.IndexOf(ChooseRate);
      Found := True;
      Form.ModalResult := DialogResult;
      Exit;
    end;
end;
procedure TLazSerialCustomBaudSetupTests.RunDialog;
begin
  Timer.Enabled := True;
  Serial.ShowSetupDialog;
  AssertTrue('The real modal setup dialog was inspected', Found);
end;
procedure TLazSerialCustomBaudSetupTests.DialogShowsEffectiveCustomRate;
begin
  DialogResult := mrCancel;
  RunDialog;
  AssertTrue('The displayed rate must include the effective 123456 baud value',
    Pos('123456', ShownRate) > 0);
end;
procedure TLazSerialCustomBaudSetupTests.AcceptWithoutChangesPreservesBothRates;
begin
  RunDialog;
  AssertEquals(123456, Serial.CustomBaudRate);
  AssertEquals(Ord(br__9600), Ord(Serial.BaudRate));
end;
procedure TLazSerialCustomBaudSetupTests.ChoosingPresetDisablesOverride;
begin
  ChooseRate := '115200';
  RunDialog;
  AssertEquals(-1, Serial.CustomBaudRate);
  AssertEquals(Ord(br115200), Ord(Serial.BaudRate));
  Serial.Open;
  AssertEquals(115200, Transport.LastConfig.BaudRate);
end;
procedure TLazSerialCustomBaudSetupTests.ChoosingOriginalPresetAlsoDisablesOverride;
begin
  ChooseRate := '9600';
  RunDialog;
  AssertEquals(-1, Serial.CustomBaudRate);
  AssertEquals(Ord(br__9600), Ord(Serial.BaudRate));
end;
procedure TLazSerialCustomBaudSetupTests.CancellationPreservesBothRates;
begin
  ChooseRate := '115200';
  DialogResult := mrCancel;
  RunDialog;
  AssertEquals(123456, Serial.CustomBaudRate);
  AssertEquals(Ord(br__9600), Ord(Serial.BaudRate));
end;
procedure TLazSerialCustomBaudSetupTests.CustomEqualToPresetIsStillPreserved;
begin
  Serial.CustomBaudRate := 115200;
  RunDialog;
  AssertEquals(115200, Serial.CustomBaudRate);
  AssertEquals(Ord(br__9600), Ord(Serial.BaudRate));
end;
procedure TLazSerialCustomBaudSetupTests.ZeroCustomRateIsDisplayedAndPreserved;
begin
  Serial.CustomBaudRate := 0;
  RunDialog;
  AssertEquals('0', Copy(ShownRate, 1, 1));
  AssertEquals(0, Serial.CustomBaudRate);
  AssertEquals(Ord(br__9600), Ord(Serial.BaudRate));
end;
initialization RegisterTest(TLazSerialCustomBaudSetupTests);
end.
