unit SerialWatcherDeviceEventTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, TypInfo, FpcUnit, TestRegistry, LazSerialDevices,
  SerialWatcher, SerialWatcherSupport, SerialWatcherComponentTests;

type
  TDeviceTestHandler = procedure(Sender: TObject;
    const ADevice: TSerialDeviceInfo) of object;
  TDeviceChangedTestHandler = procedure(Sender: TObject;
    const APrevious, ACurrent: TSerialDeviceInfo) of object;

  TDeviceEventWatcher = class(TTestSerialWatcher)
  protected
    function LoadDevices: TSerialDeviceInfoArray; override;
  public
    FailLoad: Boolean;
    constructor Create(AOwner: TComponent); override;
    procedure RefreshAndWait;
  end;

  TSerialWatcherDeviceEventTests = class(TTestCase)
  private
    FOwner: TComponent;
    FWatcher: TDeviceEventWatcher;
    FEvents: TStringList;
    FAdded, FRemoved, FPrevious, FCurrent: TSerialDeviceInfoArray;
    FSnapshotCount, FConnectedCount, FDisconnectedCount: Integer;
    FDestroyAt: Integer;
    FDestroyOwner, FMutateSnapshot, FUnsubscribe, FRaiseAdded: Boolean;
    function Device(const AName, AModel: string): TSerialDeviceInfo;
    procedure ResetWatcher;
    procedure BindDeviceEvent(const AName: string; AHandler: TDeviceTestHandler);
    procedure CheckMainThread;
    procedure AfterDeviceEvent(AKind: Integer);
    procedure Refreshed(Sender: TObject; const ADevices: TSerialDeviceInfoArray);
    procedure Added(Sender: TObject; const ADevice: TSerialDeviceInfo);
    procedure Removed(Sender: TObject; const ADevice: TSerialDeviceInfo);
    procedure Changed(Sender: TObject; const APrevious, ACurrent: TSerialDeviceInfo);
    procedure Connected(Sender: TObject);
    procedure Disconnected(Sender: TObject);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure BaselineAndUnchangedSnapshotsDoNotEmitDeviceEvents;
    procedure MultipleChangesDeliverSpecificRecordsAndOneAggregateEvent;
    procedure EveryMetadataFieldTriggersChangedOnly;
    procedure ReorderingDoesNotEmitDeviceEvents;
    procedure AdoptedSnapshotIsAQuietBaselineForMetadataChanges;
    procedure DeviceMatchingFollowsPlatformRules;
    procedure RenamedPortIsRemovedAndAddedEvenWithSamePersistentId;
    procedure FailedRefreshRetainsPreviousDeviceDetails;
    procedure FailedFirstRefreshDoesNotCreateBaseline;
    procedure SnapshotSubscriberCannotMutateDeviceEvents;
    procedure DestroyingWatcherOrOwnerStopsEveryNewEventBatch;
    procedure HandlerCanUnsubscribeDuringBatch;
    procedure HandlerExceptionPropagatesAfterSnapshotCommit;
  end;

implementation

procedure AppendDevice(var ADevices: TSerialDeviceInfoArray;
  const ADevice: TSerialDeviceInfo);
var Count: Integer;
begin
  Count := Length(ADevices);
  SetLength(ADevices, Count + 1);
  ADevices[Count] := ADevice;
end;

constructor TDeviceEventWatcher.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  SetInfrastructure(TFakeSerialChangeSource.Create,
    TFakeSerialRefreshScheduler.Create, True);
end;

function TDeviceEventWatcher.LoadDevices: TSerialDeviceInfoArray;
begin
  if FailLoad then raise Exception.Create('Enumeration failed');
  Result := inherited LoadDevices;
end;

procedure TDeviceEventWatcher.RefreshAndWait;
var Deadline: QWord;
begin
  Refresh;
  Deadline := GetTickCount64 + 2000;
  while not BackgroundRefreshFinished and (GetTickCount64 < Deadline) do Sleep(1);
  TAssert.AssertTrue('Enumeration worker must finish', BackgroundRefreshFinished);
  CheckSynchronize(0);
end;

function TSerialWatcherDeviceEventTests.Device(const AName,
  AModel: string): TSerialDeviceInfo;
begin
  Result := Default(TSerialDeviceInfo);
  Result.Device := AName;
  Result.Model := AModel;
  Result.Vendor := 'vendor';
  Result.SerialShort := 'serial';
  Result.VendorId := '1234';
  Result.ProductId := '5678';
  Result.PersistentId := 'persistent-' + AName;
end;

procedure TSerialWatcherDeviceEventTests.BindDeviceEvent(const AName: string;
  AHandler: TDeviceTestHandler);
var Info: PPropInfo;
begin
  Info := GetPropInfo(FWatcher, AName);
  AssertNotNull('Missing published watcher event ' + AName, Info);
  SetMethodProp(FWatcher, Info, TMethod(AHandler));
end;

procedure TSerialWatcherDeviceEventTests.ResetWatcher;
var Info: PPropInfo; Handler: TDeviceChangedTestHandler;
begin
  FreeAndNil(FOwner);
  FOwner := TComponent.Create(nil);
  FWatcher := TDeviceEventWatcher.Create(FOwner);
  FEvents.Clear;
  FAdded := nil; FRemoved := nil; FPrevious := nil; FCurrent := nil;
  FSnapshotCount := 0; FConnectedCount := 0; FDisconnectedCount := 0;
  FDestroyAt := 0;
  FDestroyOwner := False; FMutateSnapshot := False;
  FUnsubscribe := False; FRaiseAdded := False;
  FWatcher.OnDevicesRefreshed := @Refreshed;
  FWatcher.OnComConnected := @Connected;
  FWatcher.OnComDisconnected := @Disconnected;
  BindDeviceEvent('OnDeviceAdded', @Added);
  BindDeviceEvent('OnDeviceRemoved', @Removed);
  Info := GetPropInfo(FWatcher, 'OnDeviceChanged');
  AssertNotNull('Missing published watcher event OnDeviceChanged', Info);
  Handler := @Changed;
  SetMethodProp(FWatcher, Info, TMethod(Handler));
end;

procedure TSerialWatcherDeviceEventTests.SetUp;
begin
  inherited SetUp;
  FEvents := TStringList.Create;
  ResetWatcher;
end;

procedure TSerialWatcherDeviceEventTests.TearDown;
begin
  FreeAndNil(FOwner);
  FWatcher := nil;
  FEvents.Free;
  inherited TearDown;
end;

procedure TSerialWatcherDeviceEventTests.CheckMainThread;
begin
  AssertEquals(Int64(MainThreadID), Int64(GetCurrentThreadID));
end;

procedure TSerialWatcherDeviceEventTests.AfterDeviceEvent(AKind: Integer);
begin
  if FDestroyAt <> AKind then Exit;
  if FDestroyOwner then
  begin
    FWatcher := nil;
    FreeAndNil(FOwner);
  end
  else FreeAndNil(FWatcher);
end;

procedure TSerialWatcherDeviceEventTests.Refreshed(Sender: TObject;
  const ADevices: TSerialDeviceInfoArray);
var Shared: TSerialDeviceInfoArray; I: Integer;
begin
  CheckMainThread;
  Inc(FSnapshotCount);
  FEvents.Add('snapshot');
  for I := 0 to High(ADevices) do
    AssertTrue('Commit the snapshot before callbacks', FWatcher.ContainsDevice(ADevices[I].Device));
  if FMutateSnapshot then
  begin
    Shared := ADevices;
    for I := 0 to High(Shared) do Shared[I].Model := 'subscriber mutation';
  end;
end;

procedure TSerialWatcherDeviceEventTests.Added(Sender: TObject;
  const ADevice: TSerialDeviceInfo);
var EmptyHandler: TDeviceTestHandler;
begin
  CheckMainThread;
  FEvents.Add('added:' + ADevice.Device);
  AppendDevice(FAdded, ADevice);
  if FUnsubscribe then
  begin
    EmptyHandler := nil;
    BindDeviceEvent('OnDeviceAdded', EmptyHandler);
  end;
  if FRaiseAdded then raise EInvalidOperation.Create('Subscriber failed');
  AfterDeviceEvent(1);
end;

procedure TSerialWatcherDeviceEventTests.Removed(Sender: TObject;
  const ADevice: TSerialDeviceInfo);
begin
  CheckMainThread;
  FEvents.Add('removed:' + ADevice.Device);
  AppendDevice(FRemoved, ADevice);
  AfterDeviceEvent(2);
end;

procedure TSerialWatcherDeviceEventTests.Changed(Sender: TObject;
  const APrevious, ACurrent: TSerialDeviceInfo);
begin
  CheckMainThread;
  FEvents.Add('changed:' + ACurrent.Device);
  AppendDevice(FPrevious, APrevious);
  AppendDevice(FCurrent, ACurrent);
  AfterDeviceEvent(3);
end;

procedure TSerialWatcherDeviceEventTests.Connected(Sender: TObject);
begin
  CheckMainThread;
  Inc(FConnectedCount);
  FEvents.Add('connected');
end;

procedure TSerialWatcherDeviceEventTests.Disconnected(Sender: TObject);
begin
  CheckMainThread;
  Inc(FDisconnectedCount);
  FEvents.Add('disconnected');
end;

procedure TSerialWatcherDeviceEventTests.BaselineAndUnchangedSnapshotsDoNotEmitDeviceEvents;
begin
  FWatcher.SetSnapshot([Device('COM1', 'first')]);
  FWatcher.PollNow;
  FWatcher.PollNow;
  AssertEquals(2, FSnapshotCount);
  AssertEquals(0, Length(FAdded));
  AssertEquals(0, Length(FRemoved));
  AssertEquals(0, Length(FCurrent));
  AssertEquals(0, FConnectedCount);
  AssertEquals(0, FDisconnectedCount);
end;

procedure TSerialWatcherDeviceEventTests.MultipleChangesDeliverSpecificRecordsAndOneAggregateEvent;
var Old, Current: TSerialDeviceInfo;
begin
  Old := Device('COM1', 'before');
  FWatcher.SetSnapshot([Old, Device('COM2', 'removed')]);
  FWatcher.PollNow;
  FEvents.Clear;
  Current := Old;
  Current.Model := 'after';
  FWatcher.SetSnapshot([Current, Device('COM3', 'third'), Device('COM4', 'fourth')]);
  FWatcher.PollNow;
  AssertEquals(2, Length(FAdded));
  AssertEquals('third', FAdded[0].Model);
  AssertEquals('fourth', FAdded[1].Model);
  AssertEquals(1, Length(FRemoved));
  AssertEquals('COM2', FRemoved[0].Device);
  AssertEquals('removed', FRemoved[0].Model);
  AssertEquals(1, Length(FCurrent));
  AssertEquals('before', FPrevious[0].Model);
  AssertEquals('after', FCurrent[0].Model);
  AssertEquals(1, FConnectedCount);
  AssertEquals(1, FDisconnectedCount);
  AssertEquals('snapshot' + LineEnding + 'added:COM3' + LineEnding +
    'added:COM4' + LineEnding + 'removed:COM2' + LineEnding +
    'changed:COM1' + LineEnding + 'connected' + LineEnding +
    'disconnected' + LineEnding, FEvents.Text);
end;

procedure TSerialWatcherDeviceEventTests.EveryMetadataFieldTriggersChangedOnly;
var Info: TSerialDeviceInfo; I: Integer;
begin
  Info := Device('COM1', 'first');
  FWatcher.SetSnapshot([Info]);
  FWatcher.PollNow;
  for I := 1 to 7 do
  begin
    case I of
      1: Info.Vendor := 'changed vendor';
      2: Info.Model := 'changed model';
      3: Info.SerialShort := 'changed serial';
      4: Info.VendorId := '4321';
      5: Info.ProductId := '8765';
      6: Info.PersistentId := 'changed persistent path';
      7: Info.ErrorCode := 'access denied';
    end;
    FWatcher.SetSnapshot([Info]);
    FWatcher.PollNow;
    AssertEquals(I, Length(FCurrent));
  end;
  AssertEquals(0, Length(FAdded));
  AssertEquals(0, Length(FRemoved));
  AssertEquals(0, FConnectedCount);
  AssertEquals(0, FDisconnectedCount);
end;

procedure TSerialWatcherDeviceEventTests.ReorderingDoesNotEmitDeviceEvents;
var A, B: TSerialDeviceInfo;
begin
  A := Device('COM1', 'first'); B := Device('COM2', 'second');
  FWatcher.SetSnapshot([A, B]); FWatcher.PollNow;
  FWatcher.SetSnapshot([B, A]); FWatcher.PollNow;
  AssertEquals(0, Length(FAdded));
  AssertEquals(0, Length(FRemoved));
  AssertEquals(0, Length(FCurrent));
end;

procedure TSerialWatcherDeviceEventTests.DeviceMatchingFollowsPlatformRules;
var Info: TSerialDeviceInfo;
begin
  Info := Device('COM1', 'first');
  FWatcher.SetSnapshot([Info]); FWatcher.PollNow;
  Info.Device := 'com1';
  FWatcher.SetSnapshot([Info]); FWatcher.PollNow;
  {$IFDEF MSWINDOWS}
  AssertEquals(0, Length(FAdded)); AssertEquals(0, Length(FRemoved));
  {$ELSE}
  AssertEquals(1, Length(FAdded)); AssertEquals(1, Length(FRemoved));
  {$ENDIF}
  AssertEquals(0, Length(FCurrent));
end;

procedure TSerialWatcherDeviceEventTests.RenamedPortIsRemovedAndAddedEvenWithSamePersistentId;
var Info: TSerialDeviceInfo;
begin
  Info := Device('COM1', 'first');
  FWatcher.SetSnapshot([Info]); FWatcher.PollNow;
  Info.Device := 'COM2';
  FWatcher.SetSnapshot([Info]); FWatcher.PollNow;
  AssertEquals(1, Length(FAdded)); AssertEquals(1, Length(FRemoved));
  AssertEquals('COM1', FRemoved[0].Device);
  AssertEquals('COM2', FAdded[0].Device);
  AssertEquals(0, Length(FCurrent));
end;

procedure TSerialWatcherDeviceEventTests.FailedRefreshRetainsPreviousDeviceDetails;
begin
  FWatcher.SetSnapshot([Device('COM1', 'last known')]);
  FWatcher.RefreshAndWait;
  FWatcher.FailLoad := True;
  FWatcher.SetSnapshot([]);
  FWatcher.RefreshAndWait;
  AssertEquals(1, FSnapshotCount);
  AssertEquals(0, Length(FRemoved));
  AssertTrue(FWatcher.ContainsDevice('COM1'));
  FWatcher.FailLoad := False;
  FWatcher.RefreshAndWait;
  AssertEquals(2, FSnapshotCount);
  AssertEquals(1, Length(FRemoved));
  AssertEquals('last known', FRemoved[0].Model);
  AssertEquals(1, FDisconnectedCount);
end;

procedure TSerialWatcherDeviceEventTests.FailedFirstRefreshDoesNotCreateBaseline;
begin
  FWatcher.FailLoad := True;
  FWatcher.RefreshAndWait;
  AssertEquals(0, FSnapshotCount);
  FWatcher.FailLoad := False;
  FWatcher.SetSnapshot([Device('COM1', 'first')]);
  FWatcher.RefreshAndWait;
  AssertEquals(1, FSnapshotCount);
  AssertEquals(0, Length(FAdded));
end;

procedure TSerialWatcherDeviceEventTests.SnapshotSubscriberCannotMutateDeviceEvents;
begin
  FWatcher.SetSnapshot([Device('COM1', 'before')]); FWatcher.PollNow;
  FMutateSnapshot := True;
  FWatcher.SetSnapshot([Device('COM1', 'after'), Device('COM2', 'new')]);
  FWatcher.PollNow;
  AssertEquals('new', FAdded[0].Model);
  AssertEquals('before', FPrevious[0].Model);
  AssertEquals('after', FCurrent[0].Model);
  FWatcher.PollNow;
  AssertEquals(1, Length(FCurrent));
end;

procedure TSerialWatcherDeviceEventTests.DestroyingWatcherOrOwnerStopsEveryNewEventBatch;
var Kind: Integer; FreeOwner: Boolean;
begin
  for FreeOwner := False to True do
    for Kind := 1 to 3 do
    begin
      ResetWatcher;
      FWatcher.SetSnapshot([Device('COM1', 'before'), Device('COM2', 'before')]);
      FWatcher.PollNow;
      FEvents.Clear;
      FDestroyAt := Kind;
      FDestroyOwner := FreeOwner;
      case Kind of
        1: FWatcher.SetSnapshot([Device('COM3', 'new'), Device('COM4', 'new')]);
        2: FWatcher.SetSnapshot([]);
        3: FWatcher.SetSnapshot([Device('COM1', 'after'), Device('COM2', 'after')]);
      end;
      FWatcher.PollNow;
      AssertNull(FWatcher);
      AssertEquals('No event may follow destruction', 2, FEvents.Count);
      AssertEquals(0, FConnectedCount);
      AssertEquals(0, FDisconnectedCount);
    end;
end;

procedure TSerialWatcherDeviceEventTests.HandlerCanUnsubscribeDuringBatch;
begin
  FWatcher.SetSnapshot([]); FWatcher.PollNow;
  FUnsubscribe := True;
  FWatcher.SetSnapshot([Device('COM1', 'first'), Device('COM2', 'second')]);
  FWatcher.PollNow;
  AssertEquals(1, Length(FAdded));
  AssertEquals(1, FConnectedCount);
end;

procedure TSerialWatcherDeviceEventTests.HandlerExceptionPropagatesAfterSnapshotCommit;
var Raised: Boolean;
begin
  FWatcher.SetSnapshot([]); FWatcher.PollNow;
  FRaiseAdded := True;
  FWatcher.SetSnapshot([Device('COM1', 'first'), Device('COM2', 'second')]);
  Raised := False;
  try FWatcher.PollNow;
  except on E: EInvalidOperation do Raised := True; end;
  AssertTrue(Raised);
  AssertTrue(FWatcher.ContainsDevice('COM1'));
  AssertTrue(FWatcher.ContainsDevice('COM2'));
  FRaiseAdded := False;
  FWatcher.PollNow;
  AssertEquals(1, Length(FAdded));
end;

procedure TSerialWatcherDeviceEventTests.AdoptedSnapshotIsAQuietBaselineForMetadataChanges;
var Info: TSerialDeviceInfo;
begin
  Info := Device('COM1', 'adopted');
  FWatcher.AdoptSnapshot([Info]);
  AssertEquals(0, FEvents.Count);
  Info.Model := 'updated';
  FWatcher.SetSnapshot([Info]);
  FWatcher.PollNow;
  AssertEquals(1, FSnapshotCount);
  AssertEquals(0, Length(FAdded));
  AssertEquals(1, Length(FCurrent));
  AssertEquals('adopted', FPrevious[0].Model);
  AssertEquals('updated', FCurrent[0].Model);
end;

initialization
  RegisterTest(TSerialWatcherDeviceEventTests);
end.
