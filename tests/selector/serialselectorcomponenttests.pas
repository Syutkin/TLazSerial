unit SerialSelectorComponentTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, TypInfo, FpcUnit, TestRegistry, StdCtrls,
  LazSerialCommon, LazSerialDevices, LazSerialSetup, SerialSelector,
  SerialWatcherSupport;

type
  TTestSerialSelector = class(TSerialSelector)
  private
    FSnapshot: TSerialDeviceInfoArray;
  protected
    function LoadDevices: TSerialDeviceInfoArray; override;
    function UseBackgroundRefresh: Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetSnapshot(const ADevices: array of TSerialDeviceInfo);
    function DisplayItem(const AIndex: Integer): string;
    function HintFirstLine: string;
    function IsSorted: Boolean;
  end;

  TBackgroundTestSerialSelector = class(TSerialSelector)
  private
    FApplyCount: PInteger;
    FLoadCount: Integer;
    FLoadStarted: TEvent;
    FRaiseOnLoad: Boolean;
    FRefreshDuringApply: Boolean;
    FSnapshot: TSerialDeviceInfoArray;
    FSnapshotAssigned: Boolean;
    FReleaseLoad: TEvent;
    FChangeSource: TSerialChangeSource;
    FRefreshScheduler: TSerialRefreshScheduler;
  protected
    procedure ApplyDevices(const ADevices: TSerialDeviceInfoArray); override;
    function LoadDevices: TSerialDeviceInfoArray; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure ApplySnapshot(const ADevices: array of TSerialDeviceInfo);
    function RefreshFinished: Boolean;
    procedure SetSnapshot(const ADevices: array of TSerialDeviceInfo);
    procedure SignalChange;
    procedure FireScheduledRefresh;
    function RefreshScheduled: Boolean;
    function HintCaption: string;
    procedure WaitForRefresh;
    property ApplyCount: PInteger read FApplyCount write FApplyCount;
    property LoadCount: Integer read FLoadCount;
    property LoadStarted: TEvent read FLoadStarted write FLoadStarted;
    property RaiseOnLoad: Boolean read FRaiseOnLoad write FRaiseOnLoad;
    property RefreshDuringApply: Boolean
      read FRefreshDuringApply write FRefreshDuringApply;
    property ReleaseLoad: TEvent read FReleaseLoad write FReleaseLoad;
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
    procedure InvalidIndexAndNoSelectionAreSafe;
    procedure BackgroundRefreshFailurePreservesKnownAndCustomSelection;
    procedure SuccessfulEmptyBackgroundRefreshClearsKnownSelection;
    procedure RepeatedBackgroundRefreshDoesNotOverlapOrReenter;
    procedure DestroyFromBackgroundApplyPreservesHeap;
    procedure DestroyOwnerFromBackgroundApplyPreservesHeap;
    procedure HotplugUsesOneEnumerationAndUpdatesMetadata;
    procedure HotplugDuringRefreshPublishesLatestSnapshot;
    procedure UnchangedPollingSnapshotPreservesTypedTextAndHint;
  end;

procedure RunSelectorLifetimeHelper(const AFreeOwner: Boolean);

implementation

uses
  SerialCommandRunner, SerialWatcher,
  SerialWatcherComponentTests;

type
  TSelectorWatcherAccess = class(TSerialWatcher)
  public
    procedure Configure(ASource: TSerialChangeSource;
      AScheduler: TSerialRefreshScheduler);
  end;

  TDestroyingSerialSelector = class(TBackgroundTestSerialSelector)
  protected
    procedure ApplyDevices(const ADevices: TSerialDeviceInfoArray); override;
  public
    FreeOwner: Boolean;
    Applied: PBoolean;
  end;

procedure TSelectorWatcherAccess.Configure(ASource: TSerialChangeSource;
  AScheduler: TSerialRefreshScheduler);
begin
  SetInfrastructure(ASource, AScheduler, True);
end;

constructor TBackgroundTestSerialSelector.Create(AOwner: TComponent);
var
  I: Integer;
begin
  inherited Create(AOwner);
  // Exercise the real selector/watcher connection with deterministic hotplug
  // signals and scheduling, without polling the host's serial devices.
  for I := 0 to ComponentCount - 1 do
    if Components[I] is TSerialWatcher then
    begin
      FChangeSource := TFakeSerialChangeSource.Create;
      FRefreshScheduler := TFakeSerialRefreshScheduler.Create;
      TSelectorWatcherAccess(Components[I]).Configure(
        TFakeSerialChangeSource(FChangeSource),
        TFakeSerialRefreshScheduler(FRefreshScheduler));
      Exit;
    end;
  raise Exception.Create('Selector watcher not found');
end;

constructor TTestSerialSelector.Create(AOwner: TComponent);
var
  I: Integer;
begin
  inherited Create(AOwner);
  for I := 0 to ComponentCount - 1 do
    if Components[I] is TSerialWatcher then
    begin
      TSelectorWatcherAccess(Components[I]).Configure(
        TSerialManualChangeSource.Create, TFakeSerialRefreshScheduler.Create);
      Exit;
    end;
  raise Exception.Create('Selector watcher not found');
end;

procedure TBackgroundTestSerialSelector.SignalChange;
begin
  TFakeSerialChangeSource(FChangeSource).Signal;
end;

procedure TBackgroundTestSerialSelector.FireScheduledRefresh;
begin
  TFakeSerialRefreshScheduler(FRefreshScheduler).Fire;
end;

function TBackgroundTestSerialSelector.RefreshScheduled: Boolean;
begin
  Result := TFakeSerialRefreshScheduler(FRefreshScheduler).Scheduled;
end;

procedure TBackgroundTestSerialSelector.WaitForRefresh;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + 1000;
  while not RefreshFinished and (GetTickCount64 < Deadline) do
    Sleep(1);
  TAssert.AssertTrue('Selector worker must finish', RefreshFinished);
  CheckSynchronize(0);
end;

function TBackgroundTestSerialSelector.HintCaption: string;
begin
  Result := BuildHintCaption;
end;

procedure TDestroyingSerialSelector.ApplyDevices(
  const ADevices: TSerialDeviceInfoArray);
begin
  Applied^ := True;
  if FreeOwner then
    Owner.Free
  else
    Free;
end;

procedure RunSelectorLifetimeHelper(const AFreeOwner: Boolean);
var
  Owner: TComponent;
  Selector: TDestroyingSerialSelector;
  Applied: Boolean;
  Deadline: QWord;
begin
  Owner := TComponent.Create(nil);
  Applied := False;
  try
    Selector := TDestroyingSerialSelector.Create(Owner);
    Selector.FreeOwner := AFreeOwner;
    Selector.Applied := @Applied;
    Selector.Refresh;
    Deadline := GetTickCount64 + 1000;
    while not Selector.RefreshFinished and (GetTickCount64 < Deadline) do
      Sleep(1);
    if not Selector.RefreshFinished then
      raise Exception.Create('Selector refresh did not finish');
    CheckSynchronize(0);
    if not Applied then
      raise Exception.Create('Selector callback did not execute');
    if AFreeOwner then
      Owner := nil;
    WriteLn('selector lifetime helper completed');
  finally
    Owner.Free;
  end;
end;

procedure CheckSelectorLifetime(const AMode: string);
var
  Output: string;
  Success: Boolean;
begin
  Success := RunSerialCommand(ExpandFileName(ParamStr(0)),
    ['--selector-lifetime-helper', AMode], 5000, Output);
  TAssert.AssertTrue('Selector lifetime helper failed: ' + Output, Success);
  TAssert.AssertTrue('Selector callback must execute: ' + Output,
    Pos('selector lifetime helper completed', Output) > 0);
  TAssert.AssertEquals('HeapTrc detected use after free: ' + Output, 0,
    Pos('marked memory', LowerCase(Output)));
end;

procedure TSerialSelectorComponentTests.DestroyFromBackgroundApplyPreservesHeap;
begin
  CheckSelectorLifetime('self');
end;

procedure TSerialSelectorComponentTests.DestroyOwnerFromBackgroundApplyPreservesHeap;
begin
  CheckSelectorLifetime('owner');
end;

procedure TBackgroundTestSerialSelector.ApplyDevices(
  const ADevices: TSerialDeviceInfoArray
);
begin
  TAssert.AssertEquals('Snapshots must be applied on the main thread',
    Int64(MainThreadID), Int64(GetCurrentThreadID));
  if FApplyCount <> nil then
    Inc(FApplyCount^);
  if FRefreshDuringApply then
    Refresh;
  inherited ApplyDevices(ADevices);
end;

function TBackgroundTestSerialSelector.LoadDevices: TSerialDeviceInfoArray;
var
  I: Integer;
begin
  Inc(FLoadCount);
  if not FSnapshotAssigned then
  begin
    Result := nil;
    SetLength(Result, 1);
    Result[0].Device := 'COM1';
  end
  else
  begin
    SetLength(Result, Length(FSnapshot));
    for I := Low(FSnapshot) to High(FSnapshot) do
      Result[I] := FSnapshot[I];
  end;
  // Capture the snapshot before signalling: tests can then change the next
  // snapshot while this worker is still returning the previous one.
  if FLoadStarted <> nil then
    FLoadStarted.SetEvent;
  if FReleaseLoad <> nil then
    FReleaseLoad.WaitFor(1000)
  else
    Sleep(50);
  if FRaiseOnLoad then
    raise EInvalidOperation.Create('Simulated selector load failure');
end;

procedure TBackgroundTestSerialSelector.ApplySnapshot(
  const ADevices: array of TSerialDeviceInfo);
var
  SnapshotDevices: TSerialDeviceInfoArray;
  I: Integer;
begin
  SetLength(SnapshotDevices, Length(ADevices));
  for I := Low(ADevices) to High(ADevices) do
    SnapshotDevices[I] := ADevices[I];
  ApplyDevices(SnapshotDevices);
end;

procedure TBackgroundTestSerialSelector.SetSnapshot(
  const ADevices: array of TSerialDeviceInfo);
var
  I: Integer;
begin
  FSnapshotAssigned := True;
  SetLength(FSnapshot, Length(ADevices));
  for I := Low(ADevices) to High(ADevices) do
    FSnapshot[I] := ADevices[I];
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
  FSelector.DisplayOptions := [sddoVendor, sddoModel, sddoErrorCode];
  FSelector.SetSnapshot([DeviceA]);
  FSelector.Refresh;

  AssertEquals(
    FormatSerialDeviceDisplayName(
      DeviceA,
      FSelector.DisplayOptions
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

procedure TSerialSelectorComponentTests.InvalidIndexAndNoSelectionAreSafe;
var
  DeviceInfo: TSerialDeviceInfo;
  Raised: Boolean;
begin
  FSelector.SetSnapshot([]);
  FSelector.Refresh;
  FSelector.ItemIndex := 42;

  AssertEquals('', FSelector.Device);
  AssertFalse(FSelector.TryGetSelectedDevice(DeviceInfo));
  AssertEquals('', DeviceInfo.Device);

  Raised := False;
  try
    DeviceInfo := FSelector.Devices[-1];
  except
    on E: EListError do
      Raised := True;
  end;
  AssertTrue(Raised);
  Raised := False;
  try
    DeviceInfo := FSelector.Devices[0];
  except
    on E: EListError do
      Raised := True;
  end;
  AssertTrue(Raised);
end;

procedure TSerialSelectorComponentTests.
  BackgroundRefreshFailurePreservesKnownAndCustomSelection;
var
  ApplyCount: Integer;
  DeviceA: TSerialDeviceInfo;
  DeviceB: TSerialDeviceInfo;
  SelectedDevice: TSerialDeviceInfo;
  Selector: TBackgroundTestSerialSelector;
begin
  ApplyCount := 0;
  DeviceA := CreateDevice('COM1', 'Vendor A', 'Model A', 'A');
  DeviceB := CreateDevice('COM2', 'Vendor B', 'Model B', 'B');
  Selector := TBackgroundTestSerialSelector.Create(nil);
  try
    Selector.ApplyCount := @ApplyCount;
    Selector.ApplySnapshot([DeviceA, DeviceB]);
    Selector.Device := DeviceB.Device;
    Selector.RaiseOnLoad := True;
    Selector.Refresh;
    Selector.WaitForRefresh;

    AssertEquals('Failed loads must not publish an empty snapshot', 1, ApplyCount);
    AssertEquals(DeviceB.Device, Selector.Device);
    AssertEquals(1, Selector.ItemIndex);
    AssertTrue(Selector.TryGetSelectedDevice(SelectedDevice));
    AssertEquals('Model B', SelectedDevice.Model);

    Selector.AllowCustomDevice := True;
    Selector.Device := 'custom-device';
    Selector.Refresh;
    Selector.WaitForRefresh;

    AssertEquals(1, ApplyCount);
    AssertEquals('custom-device', Selector.Device);
    AssertEquals('custom-device', Selector.Text);
    AssertEquals(-1, Selector.ItemIndex);
    AssertFalse(Selector.TryGetSelectedDevice(SelectedDevice));
  finally
    Selector.Free;
  end;
end;

procedure TSerialSelectorComponentTests.
  SuccessfulEmptyBackgroundRefreshClearsKnownSelection;
var
  ApplyCount: Integer;
  Deadline: QWord;
  DeviceA: TSerialDeviceInfo;
  Selector: TBackgroundTestSerialSelector;
begin
  ApplyCount := 0;
  DeviceA := CreateDevice('COM1', '', '', '');
  Selector := TBackgroundTestSerialSelector.Create(nil);
  try
    Selector.ApplyCount := @ApplyCount;
    Selector.ApplySnapshot([DeviceA]);
    Selector.SetSnapshot([]);
    Selector.Refresh;
    Deadline := GetTickCount64 + 1000;
    repeat
      CheckSynchronize(10);
    until (ApplyCount >= 2) or (GetTickCount64 >= Deadline);

    AssertEquals(0, Selector.DeviceCount);
    AssertEquals('', Selector.Device);
    AssertEquals(-1, Selector.ItemIndex);
  finally
    Selector.Free;
  end;
end;

procedure TSerialSelectorComponentTests.
  RepeatedBackgroundRefreshDoesNotOverlapOrReenter;
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
    Selector.RefreshDuringApply := True;
    Selector.Refresh;
    AssertEquals(Ord(wrSignaled), Ord(LoadStarted.WaitFor(1000)));
    Selector.Refresh;
    Selector.Refresh;

    Deadline := GetTickCount64 + 1000;
    repeat
      CheckSynchronize(10);
    until (ApplyCount > 0) or (GetTickCount64 >= Deadline);
    AssertEquals(1, ApplyCount);
    AssertEquals(1, Selector.LoadCount);
    AssertEquals(1, Selector.DeviceCount);
  finally
    Selector.Free;
    LoadStarted.Free;
  end;
end;

procedure TSerialSelectorComponentTests.HotplugUsesOneEnumerationAndUpdatesMetadata;
var
  Selector: TBackgroundTestSerialSelector;
  DeviceA, DeviceB: TSerialDeviceInfo;
  ApplyCount: Integer;
begin
  ApplyCount := 0;
  DeviceA := CreateDevice('COM1', 'A', 'First', '1');
  DeviceB := CreateDevice('COM2', 'B', 'Second', '2');
  Selector := TBackgroundTestSerialSelector.Create(nil);
  try
    Selector.ApplyCount := @ApplyCount;
    Selector.SetSnapshot([DeviceA]);
    Selector.Refresh;
    Selector.WaitForRefresh;
    AssertEquals(1, Selector.LoadCount);
    AssertEquals(1, ApplyCount);
    AssertEquals('COM1', Selector.Device);

    // Replacing a port produces both add/remove notifications. The selector
    // must consume their shared snapshot rather than load the devices again.
    Selector.SetSnapshot([DeviceB]);
    Selector.SignalChange;
    Selector.FireScheduledRefresh;
    Selector.WaitForRefresh;
    AssertEquals(2, Selector.LoadCount);
    AssertEquals(2, ApplyCount);
    AssertEquals(1, Selector.DeviceCount);
    AssertEquals('COM2', Selector.Device);
    AssertTrue(Pos(lngAddedPorts, Selector.HintCaption) > 0);
    AssertTrue(Pos(lngRemovedPorts, Selector.HintCaption) > 0);
    AssertFalse(Selector.RefreshScheduled);

    DeviceB.Model := 'Updated metadata';
    Selector.SetSnapshot([DeviceB]);
    Selector.SignalChange;
    Selector.FireScheduledRefresh;
    Selector.WaitForRefresh;
    AssertEquals(3, Selector.LoadCount);
    AssertEquals(3, ApplyCount);
    AssertEquals('Updated metadata', Selector.Devices[0].Model);
  finally
    Selector.Free;
  end;
end;

procedure TSerialSelectorComponentTests.HotplugDuringRefreshPublishesLatestSnapshot;
var
  Selector: TBackgroundTestSerialSelector;
  DeviceA, DeviceB: TSerialDeviceInfo;
  LoadStarted, ReleaseLoad: TEvent;
begin
  DeviceA := CreateDevice('COM1', '', '', '');
  DeviceB := CreateDevice('COM2', '', '', '');
  LoadStarted := TEvent.Create(nil, True, False, '');
  ReleaseLoad := TEvent.Create(nil, True, False, '');
  Selector := TBackgroundTestSerialSelector.Create(nil);
  try
    Selector.LoadStarted := LoadStarted;
    Selector.ReleaseLoad := ReleaseLoad;
    Selector.SetSnapshot([DeviceA]);
    Selector.Refresh;
    AssertEquals(Ord(wrSignaled), Ord(LoadStarted.WaitFor(1000)));
    Selector.SetSnapshot([DeviceB]);
    Selector.SignalChange;
    Selector.SignalChange;
    AssertEquals('A running enumeration must not overlap another one',
      1, Selector.LoadCount);
    ReleaseLoad.SetEvent;
    Selector.WaitForRefresh;
    AssertEquals('COM1', Selector.Device);
    AssertTrue('The watcher must retain the hotplug request',
      Selector.RefreshScheduled);

    Selector.FireScheduledRefresh;
    Selector.WaitForRefresh;
    AssertEquals(2, Selector.LoadCount);
    AssertEquals('COM2', Selector.Device);
    AssertFalse(Selector.RefreshScheduled);
  finally
    ReleaseLoad.SetEvent;
    Selector.Free;
    ReleaseLoad.Free;
    LoadStarted.Free;
  end;
end;

procedure TSerialSelectorComponentTests.UnchangedPollingSnapshotPreservesTypedTextAndHint;
var
  Selector: TBackgroundTestSerialSelector;
  DeviceA, DeviceB: TSerialDeviceInfo;
  PreviousHint: string;
begin
  DeviceA := CreateDevice('COM1', '', '', '');
  DeviceB := CreateDevice('COM2', '', '', '');
  Selector := TBackgroundTestSerialSelector.Create(nil);
  try
    Selector.SetSnapshot([DeviceA]);
    Selector.Refresh;
    Selector.WaitForRefresh;
    Selector.SetSnapshot([DeviceA, DeviceB]);
    Selector.SignalChange;
    Selector.FireScheduledRefresh;
    Selector.WaitForRefresh;

    Selector.AllowCustomDevice := True;
    Selector.Device := '/dev/custom-device';
    Selector.SelStart := 4;
    Selector.SelLength := 3;
    PreviousHint := Selector.HintCaption;
    AssertTrue(Pos(lngAddedPorts, PreviousHint) > 0);
    Selector.SignalChange;
    Selector.FireScheduledRefresh;
    Selector.WaitForRefresh;

    AssertEquals(3, Selector.LoadCount);
    AssertEquals('/dev/custom-device', Selector.Device);
    AssertEquals(4, Selector.SelStart);
    AssertEquals(3, Selector.SelLength);
    AssertEquals(PreviousHint, Selector.HintCaption);
  finally
    Selector.Free;
  end;
end;

initialization
  RegisterTest(TSerialSelectorComponentTests);

end.
