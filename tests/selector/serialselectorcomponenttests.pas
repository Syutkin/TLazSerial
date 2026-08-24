unit SerialSelectorComponentTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, TypInfo, FpcUnit, TestRegistry, StdCtrls,
  LazSerialCommon, LazSerialDevices, LazSerialSetup, SerialSelector;

type
  TTestSerialSelector = class(TSerialSelector)
  private
    FSnapshot: TSerialDeviceInfoArray;
  protected
    function LoadDevices: TSerialDeviceInfoArray; override;
    function UseBackgroundRefresh: Boolean; override;
  public
    procedure SetSnapshot(const ADevices: array of TSerialDeviceInfo);
    function DisplayItem(const AIndex: Integer): string;
    function HintFirstLine: string;
    function IsSorted: Boolean;
  end;

  TBackgroundTestSerialSelector = class(TSerialSelector)
  private
    FApplyCount: PInteger;
    FLoadStarted: TEvent;
  protected
    procedure ApplyDevices(const ADevices: TSerialDeviceInfoArray); override;
    function LoadDevices: TSerialDeviceInfoArray; override;
  public
    function RefreshFinished: Boolean;
    property ApplyCount: PInteger read FApplyCount write FApplyCount;
    property LoadStarted: TEvent read FLoadStarted write FLoadStarted;
  end;

  TSerialSelectorComponentTests = class(TTestCase)
  private
    FSelector: TTestSerialSelector;
    function CreateDevice(
      const ADevice, AVendor, AModel, ASerialShort: string
    ): TSerialDeviceInfo;
    procedure AssertNotPublished(const APropertyName: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure RefreshBuildsItemsFromDeviceRecords;
    procedure EmptySnapshotHasNoSelection;
    procedure DeviceAndDevicesExposeSelectedRecord;
    procedure PublicItemIndexSelectsMatchingRecord;
    procedure DeviceSetBeforeFirstRefreshIsRestored;
    procedure RefreshPreservesDeviceAfterReorder;
    procedure RefreshSelectsFirstDeviceWhenSelectionDisappears;
    procedure ShowFriendlyNamePreservesOptionsAndSelection;
    procedure DisplayOptionsPreserveSelection;
    procedure SelectorKeepsItemsUnsorted;
    procedure ObjectInspectorContractContainsDisplayProperties;
    procedure CustomDeviceDefaultsToDisabledAndReadOnly;
    procedure EnablingCustomDeviceMakesSelectorEditable;
    procedure DisabledCustomDeviceKeepsExistingSelectionRules;
    procedure CustomDeviceSetBeforeAndAfterRefreshIsPreserved;
    procedure CustomDeviceSurvivesRebuildAndEmptySnapshot;
    procedure CustomDeviceHasNoSelectedMetadata;
    procedure CustomDevicePromotesWhenEnumerated;
    procedure DisablingCustomDeviceRestoresReadOnlySelection;
    procedure SetupDialogAllowsCustomDevice;
    procedure SelectedDeviceHintStartsWithDeviceMetadata;
    procedure CustomDeviceHintStartsWithManualDevice;
    procedure EmptySelectorHintReportsNoDevices;
    procedure InternalListPropertiesAreNotPublished;
    procedure BackgroundRefreshAppliesSnapshotOnMainThread;
    procedure QueuedBackgroundRefreshDoesNotDeliverAfterDestroy;
    procedure BackgroundRefreshDoesNotDeliverAfterDestroy;
  end;

implementation

procedure TBackgroundTestSerialSelector.ApplyDevices(
  const ADevices: TSerialDeviceInfoArray
);
begin
  if FApplyCount <> nil then
    Inc(FApplyCount^);
  inherited ApplyDevices(ADevices);
end;

function TBackgroundTestSerialSelector.LoadDevices: TSerialDeviceInfoArray;
begin
  if FLoadStarted <> nil then
    FLoadStarted.SetEvent;
  Sleep(50);
  Result := nil;
  SetLength(Result, 1);
  Result[0].Device := 'COM1';
end;

function TBackgroundTestSerialSelector.RefreshFinished: Boolean;
begin
  Result := BackgroundRefreshFinished;
end;

function TTestSerialSelector.LoadDevices: TSerialDeviceInfoArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(FSnapshot));
  for I := Low(FSnapshot) to High(FSnapshot) do
    Result[I] := FSnapshot[I];
end;

function TTestSerialSelector.UseBackgroundRefresh: Boolean;
begin
  Result := False;
end;

function TTestSerialSelector.HintFirstLine: string;
var
  HintText: string;
  LineBreakIndex: Integer;
begin
  HintText := BuildHintCaption;
  LineBreakIndex := Pos(LineEnding, HintText);
  if LineBreakIndex > 0 then
    Result := Copy(HintText, 1, LineBreakIndex - 1)
  else
    Result := HintText;
end;

procedure TTestSerialSelector.SetSnapshot(
  const ADevices: array of TSerialDeviceInfo
);
var
  I: Integer;
begin
  SetLength(FSnapshot, Length(ADevices));
  for I := Low(ADevices) to High(ADevices) do
    FSnapshot[I] := ADevices[I];
end;

function TTestSerialSelector.DisplayItem(const AIndex: Integer): string;
begin
  Result := TCustomComboBox(Self).Items[AIndex];
end;

function TTestSerialSelector.IsSorted: Boolean;
begin
  Result := Sorted;
end;

function TSerialSelectorComponentTests.CreateDevice(
  const ADevice, AVendor, AModel, ASerialShort: string
): TSerialDeviceInfo;
begin
  Result := Default(TSerialDeviceInfo);
  Result.Device := ADevice;
  Result.Vendor := AVendor;
  Result.Model := AModel;
  Result.SerialShort := ASerialShort;
end;

procedure TSerialSelectorComponentTests.AssertNotPublished(
  const APropertyName: string
);
begin
  AssertNull(
    APropertyName + ' must not be published',
    GetPropInfo(TSerialSelector.ClassInfo, APropertyName)
  );
end;

procedure TSerialSelectorComponentTests.SetUp;
begin
  FSelector := TTestSerialSelector.Create(nil);
end;

procedure TSerialSelectorComponentTests.TearDown;
begin
  FSelector.Free;
end;

procedure TSerialSelectorComponentTests.RefreshBuildsItemsFromDeviceRecords;
var
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0', 'Espressif', 'ESP32', 'ABC123');
  DeviceB := CreateDevice('/dev/ttyUSB0', '', '', '');
  FSelector.SetSnapshot([DeviceA, DeviceB]);

  FSelector.Refresh;

  AssertEquals(2, FSelector.DeviceCount);
  AssertEquals(
    '/dev/ttyACM0 <Espressif ESP32 ABC123>',
    FSelector.DisplayItem(0)
  );
  AssertEquals('/dev/ttyUSB0', FSelector.DisplayItem(1));
end;

procedure TSerialSelectorComponentTests.EmptySnapshotHasNoSelection;
var
  SelectedDevice: TSerialDeviceInfo;
begin
  FSelector.SetSnapshot([]);

  FSelector.Refresh;

  AssertEquals(0, FSelector.DeviceCount);
  AssertEquals(-1, FSelector.ItemIndex);
  AssertEquals('', FSelector.Device);
  AssertFalse(FSelector.TryGetSelectedDevice(SelectedDevice));
end;

procedure TSerialSelectorComponentTests.DeviceAndDevicesExposeSelectedRecord;
var
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
  SelectedDevice: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0', 'Espressif', 'ESP32', 'ABC123');
  DeviceB := CreateDevice('/dev/ttyUSB0', 'QinHeng', 'CH343', 'XYZ');
  FSelector.SetSnapshot([DeviceA, DeviceB]);
  FSelector.Refresh;

  FSelector.Device := '/dev/ttyUSB0';

  AssertEquals('/dev/ttyUSB0', FSelector.Device);
  AssertEquals('/dev/ttyACM0', FSelector.Devices[0].Device);
  AssertEquals('CH343', FSelector.Devices[1].Model);
  AssertTrue(FSelector.TryGetSelectedDevice(SelectedDevice));
  AssertEquals('/dev/ttyUSB0', SelectedDevice.Device);
  AssertEquals('XYZ', SelectedDevice.SerialShort);
end;

procedure TSerialSelectorComponentTests.PublicItemIndexSelectsMatchingRecord;
var
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
  SelectedDevice: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0', '', '', '');
  DeviceB := CreateDevice('/dev/ttyUSB0', '', '', '');
  FSelector.SetSnapshot([DeviceA, DeviceB]);
  FSelector.Refresh;

  FSelector.ItemIndex := 1;

  AssertEquals('/dev/ttyUSB0', FSelector.Device);
  AssertTrue(FSelector.TryGetSelectedDevice(SelectedDevice));
  AssertEquals('/dev/ttyUSB0', SelectedDevice.Device);
end;

procedure TSerialSelectorComponentTests.DeviceSetBeforeFirstRefreshIsRestored;
var
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0', '', '', '');
  DeviceB := CreateDevice('/dev/ttyUSB0', '', '', '');
  FSelector.Device := DeviceB.Device;
  FSelector.SetSnapshot([DeviceA, DeviceB]);

  FSelector.Refresh;

  AssertEquals(DeviceB.Device, FSelector.Device);
  AssertEquals(1, FSelector.ItemIndex);
end;

procedure TSerialSelectorComponentTests.RefreshPreservesDeviceAfterReorder;
var
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0', '', '', '');
  DeviceB := CreateDevice('/dev/ttyUSB0', '', '', '');
  FSelector.SetSnapshot([DeviceA, DeviceB]);
  FSelector.Refresh;
  FSelector.Device := DeviceB.Device;

  FSelector.SetSnapshot([DeviceB, DeviceA]);
  FSelector.Refresh;

  AssertEquals(DeviceB.Device, FSelector.Device);
  AssertEquals(0, FSelector.ItemIndex);
end;

procedure TSerialSelectorComponentTests.RefreshSelectsFirstDeviceWhenSelectionDisappears;
var
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0', '', '', '');
  DeviceB := CreateDevice('/dev/ttyUSB0', '', '', '');
  FSelector.SetSnapshot([DeviceA, DeviceB]);
  FSelector.Refresh;
  FSelector.Device := DeviceB.Device;

  FSelector.SetSnapshot([DeviceA]);
  FSelector.Refresh;

  AssertEquals(DeviceA.Device, FSelector.Device);
  AssertEquals(0, FSelector.ItemIndex);
end;

procedure TSerialSelectorComponentTests.ShowFriendlyNamePreservesOptionsAndSelection;
var
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
  OriginalOptions: TSerialDeviceDisplayOptions;
begin
  DeviceA := CreateDevice('/dev/ttyACM0', 'Espressif', 'ESP32', 'ABC123');
  DeviceB := CreateDevice('/dev/ttyUSB0', 'QinHeng', 'CH343', 'XYZ');
  FSelector.SetSnapshot([DeviceA, DeviceB]);
  FSelector.Refresh;
  FSelector.Device := DeviceB.Device;
  FSelector.DisplayOptions := [sddoModel];
  OriginalOptions := FSelector.DisplayOptions;

  FSelector.ShowFriendlyName := False;

  AssertEquals('/dev/ttyUSB0', FSelector.Device);
  AssertEquals('/dev/ttyACM0', FSelector.DisplayItem(0));
  AssertTrue(OriginalOptions = FSelector.DisplayOptions);
end;

procedure TSerialSelectorComponentTests.DisplayOptionsPreserveSelection;
var
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0', 'Espressif', 'ESP32', 'ABC123');
  DeviceB := CreateDevice('/dev/ttyUSB0', 'QinHeng', 'CH343', 'XYZ');
  FSelector.SetSnapshot([DeviceA, DeviceB]);
  FSelector.Refresh;
  FSelector.Device := DeviceB.Device;

  FSelector.DisplayOptions := [sddoVendor];

  AssertEquals('/dev/ttyUSB0', FSelector.Device);
  AssertEquals('/dev/ttyUSB0 <QinHeng>', FSelector.DisplayItem(1));
end;

procedure TSerialSelectorComponentTests.SelectorKeepsItemsUnsorted;
var
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
begin
  AssertFalse(FSelector.IsSorted);
  DeviceA := CreateDevice('/dev/ttyUSB9', '', '', '');
  DeviceB := CreateDevice('/dev/ttyUSB1', '', '', '');
  FSelector.SetSnapshot([DeviceA, DeviceB]);

  FSelector.Refresh;

  AssertFalse(FSelector.IsSorted);
  AssertEquals('/dev/ttyUSB9', FSelector.DisplayItem(0));
  AssertEquals('/dev/ttyUSB1', FSelector.DisplayItem(1));
end;

procedure TSerialSelectorComponentTests.ObjectInspectorContractContainsDisplayProperties;
begin
  AssertNotNull(
    GetPropInfo(TSerialSelector.ClassInfo, 'ShowFriendlyName')
  );
  AssertNotNull(
    GetPropInfo(TSerialSelector.ClassInfo, 'DisplayOptions')
  );
  AssertNotNull(
    GetPropInfo(TSerialSelector.ClassInfo, 'AllowCustomDevice')
  );
  AssertNotNull(GetPropInfo(TSerialSelector.ClassInfo, 'ShowHint'));
  AssertNotNull(GetPropInfo(TSerialSelector.ClassInfo, 'Hint'));
  AssertTrue(FSelector.ShowFriendlyName);
  AssertTrue(
    DefaultSerialDeviceDisplayOptions = FSelector.DisplayOptions
  );
  AssertTrue(FSelector.ShowHint);
  AssertEquals('', FSelector.Hint);
end;

procedure TSerialSelectorComponentTests.CustomDeviceDefaultsToDisabledAndReadOnly;
begin
  AssertFalse(FSelector.AllowCustomDevice);
  AssertTrue(FSelector.ReadOnly);
end;

procedure TSerialSelectorComponentTests.EnablingCustomDeviceMakesSelectorEditable;
begin
  FSelector.AllowCustomDevice := True;

  AssertEquals(Ord(csDropDown), Ord(FSelector.Style));
  AssertFalse(FSelector.ReadOnly);
end;

procedure TSerialSelectorComponentTests.
  DisabledCustomDeviceKeepsExistingSelectionRules;
var
  DeviceA: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0', '', '', '');
  FSelector.SetSnapshot([DeviceA]);
  FSelector.Refresh;

  FSelector.Device := '/tmp/manual-port';
  AssertEquals('', FSelector.Device);

  FSelector.Refresh;
  AssertEquals(DeviceA.Device, FSelector.Device);
  AssertEquals(0, FSelector.ItemIndex);
end;

procedure TSerialSelectorComponentTests.
  CustomDeviceSetBeforeAndAfterRefreshIsPreserved;
var
  DeviceA: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0', '', '', '');
  FSelector.AllowCustomDevice := True;
  FSelector.Device := '/tmp/manual-before-refresh';
  FSelector.SetSnapshot([DeviceA]);

  FSelector.Refresh;
  AssertEquals('/tmp/manual-before-refresh', FSelector.Device);
  AssertEquals('/tmp/manual-before-refresh', FSelector.Text);
  AssertEquals(-1, FSelector.ItemIndex);

  FSelector.Device := '/tmp/manual-after-refresh';
  FSelector.Refresh;
  AssertEquals('/tmp/manual-after-refresh', FSelector.Device);
  AssertEquals('/tmp/manual-after-refresh', FSelector.Text);
  AssertEquals(-1, FSelector.ItemIndex);
end;

procedure TSerialSelectorComponentTests.
  CustomDeviceSurvivesRebuildAndEmptySnapshot;
var
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0', 'Espressif', 'ESP32', 'ABC123');
  DeviceB := CreateDevice('/dev/ttyUSB0', 'QinHeng', 'CH343', 'XYZ');
  FSelector.AllowCustomDevice := True;
  FSelector.SetSnapshot([DeviceA, DeviceB]);
  FSelector.Refresh;
  FSelector.Text := '/tmp/typed-port';
  FSelector.ItemIndex := -1;

  FSelector.SetSnapshot([DeviceB, DeviceA]);
  FSelector.Refresh;
  AssertEquals('/tmp/typed-port', FSelector.Device);
  AssertEquals('/tmp/typed-port', FSelector.Text);

  FSelector.DisplayOptions := [sddoModel];
  FSelector.ShowFriendlyName := False;
  AssertEquals('/tmp/typed-port', FSelector.Device);
  AssertEquals('/tmp/typed-port', FSelector.Text);

  FSelector.SetSnapshot([]);
  FSelector.Refresh;
  AssertEquals('/tmp/typed-port', FSelector.Device);
  AssertEquals('/tmp/typed-port', FSelector.Text);
  AssertEquals(-1, FSelector.ItemIndex);
end;

procedure TSerialSelectorComponentTests.CustomDeviceHasNoSelectedMetadata;
var
  DeviceA: TSerialDeviceInfo;
  SelectedDevice: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0', 'Espressif', 'ESP32', 'ABC123');
  FSelector.AllowCustomDevice := True;
  FSelector.SetSnapshot([DeviceA]);
  FSelector.Refresh;

  FSelector.Device := '/tmp/manual-port';

  AssertEquals('/tmp/manual-port', FSelector.Device);
  AssertFalse(FSelector.TryGetSelectedDevice(SelectedDevice));
  AssertEquals('', SelectedDevice.Device);
end;

procedure TSerialSelectorComponentTests.CustomDevicePromotesWhenEnumerated;
var
  DeviceA: TSerialDeviceInfo;
  CustomDevice: TSerialDeviceInfo;
  SelectedDevice: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0', '', '', '');
  CustomDevice := CreateDevice('/tmp/manual-port', 'Virtual', 'PTY', '');
  FSelector.AllowCustomDevice := True;
  FSelector.SetSnapshot([DeviceA]);
  FSelector.Refresh;
  FSelector.Device := CustomDevice.Device;

  FSelector.SetSnapshot([DeviceA, CustomDevice]);
  FSelector.Refresh;

  AssertEquals(CustomDevice.Device, FSelector.Device);
  AssertEquals(1, FSelector.ItemIndex);
  AssertTrue(FSelector.TryGetSelectedDevice(SelectedDevice));
  AssertEquals('PTY', SelectedDevice.Model);
end;

procedure TSerialSelectorComponentTests.
  DisablingCustomDeviceRestoresReadOnlySelection;
var
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice('/dev/ttyACM0', '', '', '');
  DeviceB := CreateDevice('/dev/ttyUSB0', '', '', '');
  FSelector.AllowCustomDevice := True;
  FSelector.SetSnapshot([DeviceA, DeviceB]);
  FSelector.Refresh;
  FSelector.Device := '/tmp/manual-port';

  FSelector.AllowCustomDevice := False;

  AssertFalse(FSelector.AllowCustomDevice);
  AssertTrue(FSelector.ReadOnly);
  AssertEquals(DeviceA.Device, FSelector.Device);
  AssertEquals(0, FSelector.ItemIndex);
end;

procedure TSerialSelectorComponentTests.SetupDialogAllowsCustomDevice;
var
  SetupForm: TComSetupFrm;
begin
  SetupForm := TComSetupFrm.Create(nil);
  try
    AssertTrue(SetupForm.SerialSelector1.AllowCustomDevice);
  finally
    SetupForm.Free;
  end;
end;

procedure TSerialSelectorComponentTests.
  SelectedDeviceHintStartsWithDeviceMetadata;
var
  DeviceA: TSerialDeviceInfo;
begin
  DeviceA := CreateDevice(
    '/dev/ttyACM0',
    'Espressif',
    'ESP32',
    'ABC123'
  );
  FSelector.SetSnapshot([DeviceA]);
  FSelector.Refresh;

  AssertEquals(
    FormatSerialDeviceDisplayName(
      DeviceA,
      DefaultSerialDeviceDisplayOptions
    ),
    FSelector.HintFirstLine
  );
end;

procedure TSerialSelectorComponentTests.
  CustomDeviceHintStartsWithManualDevice;
const
  CUSTOM_DEVICE = '/tmp/gps-a';
begin
  FSelector.AllowCustomDevice := True;
  FSelector.Device := CUSTOM_DEVICE;

  AssertEquals(
    Format(lngManualDevice, [CUSTOM_DEVICE]),
    FSelector.HintFirstLine
  );
end;

procedure TSerialSelectorComponentTests.EmptySelectorHintReportsNoDevices;
begin
  AssertEquals(lngNoDevicesAvailable, FSelector.HintFirstLine);
end;

procedure TSerialSelectorComponentTests.InternalListPropertiesAreNotPublished;
begin
  AssertNotPublished('Items');
  AssertNotPublished('ItemIndex');
  AssertNotPublished('Sorted');
  AssertNotPublished('OnGetItems');
  AssertNotPublished('Device');
  AssertNotPublished('DeviceCount');
  AssertNotPublished('Devices');
  AssertNotPublished('DeviceList');
  AssertNotPublished('DeviceListFriend');
  AssertNotPublished('Options');
end;

procedure TSerialSelectorComponentTests.
  BackgroundRefreshAppliesSnapshotOnMainThread;
var
  ApplyCount: Integer;
  Deadline: QWord;
  LoadStarted: TEvent;
  Selector: TBackgroundTestSerialSelector;
begin
  ApplyCount := 0;
  LoadStarted := TEvent.Create(nil, True, False, '');
  Selector := TBackgroundTestSerialSelector.Create(nil);
  try
    Selector.ApplyCount := @ApplyCount;
    Selector.LoadStarted := LoadStarted;
    Selector.Refresh;
    AssertEquals(
      Ord(wrSignaled),
      Ord(LoadStarted.WaitFor(1000))
    );

    Deadline := TThread.GetTickCount64 + 1000;
    repeat
      CheckSynchronize(10);
    until (ApplyCount > 0) or (TThread.GetTickCount64 >= Deadline);

    AssertEquals(1, ApplyCount);
    AssertEquals(1, Selector.DeviceCount);
    AssertEquals('COM1', Selector.Device);
  finally
    Selector.Free;
    LoadStarted.Free;
  end;
end;

procedure TSerialSelectorComponentTests.
  QueuedBackgroundRefreshDoesNotDeliverAfterDestroy;
var
  ApplyCount: Integer;
  Deadline: QWord;
  LoadStarted: TEvent;
  Selector: TBackgroundTestSerialSelector;
begin
  ApplyCount := 0;
  LoadStarted := TEvent.Create(nil, True, False, '');
  Selector := TBackgroundTestSerialSelector.Create(nil);
  try
    Selector.ApplyCount := @ApplyCount;
    Selector.LoadStarted := LoadStarted;
    Selector.Refresh;
    AssertEquals(
      Ord(wrSignaled),
      Ord(LoadStarted.WaitFor(1000))
    );

    Deadline := TThread.GetTickCount64 + 1000;
    while not Selector.RefreshFinished and
      (TThread.GetTickCount64 < Deadline) do
      Sleep(1);
    AssertTrue(Selector.RefreshFinished);
  finally
    Selector.Free;
    LoadStarted.Free;
  end;

  CheckSynchronize(100);
  AssertEquals(0, ApplyCount);
end;

procedure TSerialSelectorComponentTests.
  BackgroundRefreshDoesNotDeliverAfterDestroy;
var
  ApplyCount: Integer;
  LoadStarted: TEvent;
  Selector: TBackgroundTestSerialSelector;
begin
  ApplyCount := 0;
  LoadStarted := TEvent.Create(nil, True, False, '');
  Selector := TBackgroundTestSerialSelector.Create(nil);
  try
    Selector.ApplyCount := @ApplyCount;
    Selector.LoadStarted := LoadStarted;
    Selector.Refresh;
    AssertEquals(
      Ord(wrSignaled),
      Ord(LoadStarted.WaitFor(1000))
    );
  finally
    Selector.Free;
    LoadStarted.Free;
  end;

  CheckSynchronize(100);
  AssertEquals(0, ApplyCount);
end;

initialization
  RegisterTest(TSerialSelectorComponentTests);

end.
