unit SerialSelectorMouseEventTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, Forms, Controls, FpcUnit, TestRegistry, SerialSelector,
  LazSerialDevices;

type
  THintTestSerialSelector = class(TSerialSelector)
  public
    procedure SetSnapshot(const ADevices: TSerialDeviceInfoArray);
    procedure EnterAndLeave;
    property OnShowHint;
  end;

  TSerialSelectorMouseEventTests = class(TTestCase)
  private
    FForm: TForm;
    FSelector: THintTestSerialSelector;
    FEnterCount: Integer;
    FLeaveCount: Integer;
    procedure Entered(Sender: TObject);
    procedure Left(Sender: TObject);
    procedure CustomizeHint(Sender: TObject; HintInfo: PHintInfo);
    function RequestedHint: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure CustomHintIsAvailableToLCL;
    procedure AutomaticHintUsesCurrentSelection;
    procedure ClearingCustomHintRestoresAutomaticText;
    procedure ManualDeviceHintUsesCurrentText;
    procedure ShowHintUsesLCLProperty;
    procedure UserMouseEventsPreserveHint;
    procedure UserShowHintCanCustomizeText;
  end;

implementation

uses
  LMessages, LazSerialCommon;

procedure THintTestSerialSelector.SetSnapshot(
  const ADevices: TSerialDeviceInfoArray);
begin
  ApplyDevices(ADevices);
end;

procedure THintTestSerialSelector.EnterAndLeave;
begin
  MouseEnter;
  MouseLeave;
end;

procedure TSerialSelectorMouseEventTests.SetUp;
begin
  inherited SetUp;
  FEnterCount := 0;
  FLeaveCount := 0;
  FForm := TForm.CreateNew(nil);
  FSelector := THintTestSerialSelector.Create(FForm);
  FSelector.Parent := FForm;
end;

procedure TSerialSelectorMouseEventTests.TearDown;
begin
  FForm.Free;
  inherited TearDown;
end;

procedure TSerialSelectorMouseEventTests.Entered(Sender: TObject);
begin
  AssertSame(FSelector, Sender);
  Inc(FEnterCount);
end;

procedure TSerialSelectorMouseEventTests.Left(Sender: TObject);
begin
  AssertSame(FSelector, Sender);
  Inc(FLeaveCount);
end;

procedure TSerialSelectorMouseEventTests.CustomizeHint(Sender: TObject;
  HintInfo: PHintInfo);
begin
  AssertSame(FSelector, Sender);
  HintInfo^.HintStr := HintInfo^.HintStr + ' (customized)';
end;

function TSerialSelectorMouseEventTests.RequestedHint: string;
var
  Info: THintInfo;
begin
  Info := Default(THintInfo);
  Info.HintControl := FSelector;
  Info.HintStr := TControl(FSelector).Hint;
  AssertEquals(0, FSelector.Perform(CM_HINTSHOW, 0, PtrInt(@Info)));
  Result := Info.HintStr;
end;

procedure TSerialSelectorMouseEventTests.CustomHintIsAvailableToLCL;
begin
  FSelector.Hint := 'Port details';
  AssertEquals('Port details', TControl(FSelector).Hint);
  AssertEquals('Port details', RequestedHint);
end;

procedure TSerialSelectorMouseEventTests.AutomaticHintUsesCurrentSelection;
var
  FirstDevice, SecondDevice: TSerialDeviceInfo;
begin
  FirstDevice := Default(TSerialDeviceInfo);
  FirstDevice.Device := 'COM1';
  SecondDevice := Default(TSerialDeviceInfo);
  SecondDevice.Device := 'COM2';
  SecondDevice.Vendor := 'Vendor';
  FSelector.SetSnapshot([FirstDevice, SecondDevice]);
  AssertTrue('LCL needs a nonempty hint to schedule its display',
    TControl(FSelector).Hint <> '');
  FSelector.ItemIndex := 1;
  AssertTrue(Pos(FormatSerialDeviceDisplayName(SecondDevice), RequestedHint) = 1);
end;

procedure TSerialSelectorMouseEventTests.ClearingCustomHintRestoresAutomaticText;
begin
  FSelector.Hint := 'Port details';
  FSelector.Hint := '';
  AssertEquals('', FSelector.Hint);
  AssertEquals(lngNoDevicesAvailable, TControl(FSelector).Hint);
  AssertEquals(lngNoDevicesAvailable, RequestedHint);
end;

procedure TSerialSelectorMouseEventTests.ManualDeviceHintUsesCurrentText;
begin
  FSelector.AllowCustomDevice := True;
  FSelector.Text := '/dev/custom-port';
  AssertTrue(Pos('/dev/custom-port', RequestedHint) > 0);
  FSelector.Text := '/dev/another-port';
  AssertTrue(Pos('/dev/another-port', RequestedHint) > 0);
end;

procedure TSerialSelectorMouseEventTests.ShowHintUsesLCLProperty;
begin
  AssertTrue(TControl(FSelector).ShowHint);
  FSelector.ShowHint := False;
  AssertFalse(TControl(FSelector).ShowHint);
  FSelector.ShowHint := True;
  AssertTrue(TControl(FSelector).ShowHint);
end;

procedure TSerialSelectorMouseEventTests.UserMouseEventsPreserveHint;
begin
  FSelector.Hint := 'Port details';
  FSelector.OnMouseEnter := @Entered;
  FSelector.OnMouseLeave := @Left;
  FSelector.EnterAndLeave;
  AssertEquals(1, FEnterCount);
  AssertEquals(1, FLeaveCount);
  AssertEquals('Port details', RequestedHint);
  FSelector.OnMouseEnter := nil;
  FSelector.OnMouseLeave := nil;
  FSelector.EnterAndLeave;
  AssertEquals(1, FEnterCount);
  AssertEquals(1, FLeaveCount);
  AssertEquals('Port details', RequestedHint);
end;

procedure TSerialSelectorMouseEventTests.UserShowHintCanCustomizeText;
begin
  FSelector.Hint := 'Port details';
  FSelector.OnShowHint := @CustomizeHint;
  AssertEquals('Port details (customized)', RequestedHint);
end;

initialization
  RegisterTest(TSerialSelectorMouseEventTests);

end.
