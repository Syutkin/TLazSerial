unit SerialMacChangeSourceTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, FpcUnit, TestRegistry, SerialMacChangeSource,
  SerialWatcherSupport;

type
  TFakeSerialIOKitApi = class(TSerialIOKitApi)
  private
    FAddedSourceCount: Integer;
    FCallbacks: array[TSerialIOKitNotificationKind] of
      TSerialIOKitServiceCallback;
    FCallbackContexts: array[TSerialIOKitNotificationKind] of Pointer;
    FDestroyedPortCount: Integer;
    FFailNotification: TSerialIOKitNotificationKind;
    FFailNotificationEnabled: Boolean;
    FInitialObjects: array[TSerialIOKitNotificationKind] of TSerialIOKitObject;
    FIterators: array[TSerialIOKitNotificationKind] of TSerialIOKitObject;
    FNextObjects: array[TSerialIOKitNotificationKind] of TSerialIOKitObject;
    FReleasedObjects: array of TSerialIOKitObject;
    FRemovedSourceCount: Integer;
    FSourceValid: Boolean;
    function KindForIterator(
      const AIterator: TSerialIOKitObject
    ): TSerialIOKitNotificationKind;
  public
    constructor Create;
    function AddSerialNotification(
      APort: TSerialIOKitNotificationPort;
      const AKind: TSerialIOKitNotificationKind;
      const ACallback: TSerialIOKitServiceCallback;
      AContext: Pointer;
      out AIterator: TSerialIOKitObject
    ): Boolean; override;
    procedure AddRunLoopSource(
      ARunLoop: TSerialIOKitRunLoop;
      ASource: TSerialIOKitRunLoopSource
    ); override;
    function CreateNotificationPort: TSerialIOKitNotificationPort; override;
    procedure DestroyNotificationPort(
      APort: TSerialIOKitNotificationPort
    ); override;
    function GetMainRunLoop: TSerialIOKitRunLoop; override;
    function GetRunLoopSource(
      APort: TSerialIOKitNotificationPort
    ): TSerialIOKitRunLoopSource; override;
    function IsRunLoopSourceValid(
      ASource: TSerialIOKitRunLoopSource
    ): Boolean; override;
    function NextObject(
      const AIterator: TSerialIOKitObject
    ): TSerialIOKitObject; override;
    procedure ReleaseObject(const AObject: TSerialIOKitObject); override;
    procedure RemoveRunLoopSource(
      ARunLoop: TSerialIOKitRunLoop;
      ASource: TSerialIOKitRunLoopSource
    ); override;
    procedure FailWhenAdding(
      const AKind: TSerialIOKitNotificationKind
    );
    procedure SetInitialObject(
      const AKind: TSerialIOKitNotificationKind;
      const AObject: TSerialIOKitObject
    );
    procedure Signal(
      const AKind: TSerialIOKitNotificationKind;
      const AObject: TSerialIOKitObject
    );
    function WasReleased(const AObject: TSerialIOKitObject): Boolean;
    property AddedSourceCount: Integer read FAddedSourceCount;
    property DestroyedPortCount: Integer read FDestroyedPortCount;
    property RemovedSourceCount: Integer read FRemovedSourceCount;
    property SourceValid: Boolean read FSourceValid write FSourceValid;
  end;

  TFakeMacBackupSource = class(TSerialChangeSource)
  private
    FStartCount: Integer;
  protected
    procedure DoStart; override;
    procedure DoStop; override;
  public
    property StartCount: Integer read FStartCount;
  end;

  TMacChangeObserver = class
  private
    FChangedCount: Integer;
  public
    procedure Changed(Sender: TObject);
    property ChangedCount: Integer read FChangedCount;
  end;

  TSerialMacChangeSourceTests = class(TTestCase)
  published
    procedure InitialIteratorsAreDrainedAndHandlesAreReleased;
    procedure PartialStartFailureFallsBackAndReleasesCreatedHandles;
    procedure InvalidRunLoopSourceAtStartReleasesCreatedHandles;
    procedure InvalidRunLoopSourceFallsBackAndRequestsRefresh;
  end;

implementation

const
  FakeNotificationPort = TSerialIOKitNotificationPort(PtrUInt(1));
  FakeRunLoopSource = TSerialIOKitRunLoopSource(PtrUInt(2));
  FakeRunLoop = TSerialIOKitRunLoop(PtrUInt(3));

constructor TFakeSerialIOKitApi.Create;
begin
  inherited Create;
  FIterators[siikMatched] := 101;
  FIterators[siikTerminated] := 102;
  FSourceValid := True;
end;

function TFakeSerialIOKitApi.KindForIterator(
  const AIterator: TSerialIOKitObject
): TSerialIOKitNotificationKind;
begin
  if AIterator = FIterators[siikMatched] then
    Exit(siikMatched);
  Result := siikTerminated;
end;

function TFakeSerialIOKitApi.AddSerialNotification(
  APort: TSerialIOKitNotificationPort;
  const AKind: TSerialIOKitNotificationKind;
  const ACallback: TSerialIOKitServiceCallback;
  AContext: Pointer;
  out AIterator: TSerialIOKitObject
): Boolean;
begin
  if FFailNotificationEnabled and (AKind = FFailNotification) then
    Exit(False);
  FCallbacks[AKind] := ACallback;
  FCallbackContexts[AKind] := AContext;
  AIterator := FIterators[AKind];
  FNextObjects[AKind] := FInitialObjects[AKind];
  Result := True;
end;

procedure TFakeSerialIOKitApi.AddRunLoopSource(
  ARunLoop: TSerialIOKitRunLoop;
  ASource: TSerialIOKitRunLoopSource
);
begin
  Inc(FAddedSourceCount);
end;

function TFakeSerialIOKitApi.CreateNotificationPort:
  TSerialIOKitNotificationPort;
begin
  Result := FakeNotificationPort;
end;

procedure TFakeSerialIOKitApi.DestroyNotificationPort(
  APort: TSerialIOKitNotificationPort
);
begin
  Inc(FDestroyedPortCount);
end;

function TFakeSerialIOKitApi.GetMainRunLoop: TSerialIOKitRunLoop;
begin
  Result := FakeRunLoop;
end;

function TFakeSerialIOKitApi.GetRunLoopSource(
  APort: TSerialIOKitNotificationPort
): TSerialIOKitRunLoopSource;
begin
  Result := FakeRunLoopSource;
end;

function TFakeSerialIOKitApi.IsRunLoopSourceValid(
  ASource: TSerialIOKitRunLoopSource
): Boolean;
begin
  Result := FSourceValid;
end;

function TFakeSerialIOKitApi.NextObject(
  const AIterator: TSerialIOKitObject
): TSerialIOKitObject;
var
  Kind: TSerialIOKitNotificationKind;
begin
  Kind := KindForIterator(AIterator);
  Result := FNextObjects[Kind];
  FNextObjects[Kind] := 0;
end;

procedure TFakeSerialIOKitApi.ReleaseObject(
  const AObject: TSerialIOKitObject
);
var
  Index: Integer;
begin
  Index := Length(FReleasedObjects);
  SetLength(FReleasedObjects, Index + 1);
  FReleasedObjects[Index] := AObject;
end;

procedure TFakeSerialIOKitApi.RemoveRunLoopSource(
  ARunLoop: TSerialIOKitRunLoop;
  ASource: TSerialIOKitRunLoopSource
);
begin
  Inc(FRemovedSourceCount);
end;

procedure TFakeSerialIOKitApi.FailWhenAdding(
  const AKind: TSerialIOKitNotificationKind
);
begin
  FFailNotification := AKind;
  FFailNotificationEnabled := True;
end;

procedure TFakeSerialIOKitApi.SetInitialObject(
  const AKind: TSerialIOKitNotificationKind;
  const AObject: TSerialIOKitObject
);
begin
  FInitialObjects[AKind] := AObject;
end;

procedure TFakeSerialIOKitApi.Signal(
  const AKind: TSerialIOKitNotificationKind;
  const AObject: TSerialIOKitObject
);
begin
  FNextObjects[AKind] := AObject;
  if Assigned(FCallbacks[AKind]) then
    FCallbacks[AKind](FCallbackContexts[AKind], FIterators[AKind]);
end;

function TFakeSerialIOKitApi.WasReleased(
  const AObject: TSerialIOKitObject
): Boolean;
var
  ReleasedObject: TSerialIOKitObject;
begin
  for ReleasedObject in FReleasedObjects do
    if ReleasedObject = AObject then
      Exit(True);
  Result := False;
end;

procedure TFakeMacBackupSource.DoStart;
begin
  Inc(FStartCount);
end;

procedure TFakeMacBackupSource.DoStop;
begin
end;

procedure TMacChangeObserver.Changed(Sender: TObject);
begin
  Inc(FChangedCount);
end;

procedure TSerialMacChangeSourceTests.
  InitialIteratorsAreDrainedAndHandlesAreReleased;
var
  Api: TFakeSerialIOKitApi;
  Driver: TSerialIOKitNotificationDriver;
  Observer: TMacChangeObserver;
  Source: TSerialMacNotificationChangeSource;
begin
  Api := TFakeSerialIOKitApi.Create;
  Api.SetInitialObject(siikMatched, 201);
  Api.SetInitialObject(siikTerminated, 202);
  Driver := TSerialIOKitNotificationDriver.Create(Api, False);
  Observer := TMacChangeObserver.Create;
  Source := TSerialMacNotificationChangeSource.Create(Driver, False);
  try
    Source.Start(@Observer.Changed);

    AssertEquals(0, Observer.ChangedCount);
    AssertTrue(Api.WasReleased(201));
    AssertTrue(Api.WasReleased(202));
    AssertEquals(1, Api.AddedSourceCount);

    Api.Signal(siikMatched, 203);
    AssertEquals(1, Observer.ChangedCount);
    AssertTrue(Api.WasReleased(203));

    Source.Stop;
    Api.Signal(siikTerminated, 204);
    AssertEquals(1, Observer.ChangedCount);
    AssertTrue(Api.WasReleased(101));
    AssertTrue(Api.WasReleased(102));
    AssertEquals(1, Api.RemovedSourceCount);
    AssertEquals(1, Api.DestroyedPortCount);
  finally
    Source.Free;
    Observer.Free;
    Driver.Free;
    Api.Free;
  end;
end;

procedure TSerialMacChangeSourceTests.
  PartialStartFailureFallsBackAndReleasesCreatedHandles;
var
  Api: TFakeSerialIOKitApi;
  Backup: TFakeMacBackupSource;
  Driver: TSerialIOKitNotificationDriver;
  Monitor: TSerialMacNotificationChangeSource;
  Source: TSerialFallbackChangeSource;
begin
  Api := TFakeSerialIOKitApi.Create;
  Api.FailWhenAdding(siikTerminated);
  Driver := TSerialIOKitNotificationDriver.Create(Api, False);
  Monitor := TSerialMacNotificationChangeSource.Create(Driver, False);
  Backup := TFakeMacBackupSource.Create;
  Source := TSerialFallbackChangeSource.Create([Monitor, Backup]);
  try
    Source.Start(nil);

    AssertEquals(1, Source.CurrentIndex);
    AssertEquals(1, Backup.StartCount);
    AssertTrue(Api.WasReleased(101));
    AssertEquals(0, Api.AddedSourceCount);
    AssertEquals(0, Api.RemovedSourceCount);
    AssertEquals(1, Api.DestroyedPortCount);
  finally
    Source.Free;
    Driver.Free;
    Api.Free;
  end;
end;

procedure TSerialMacChangeSourceTests.
  InvalidRunLoopSourceAtStartReleasesCreatedHandles;
var
  Api: TFakeSerialIOKitApi;
  Driver: TSerialIOKitNotificationDriver;
begin
  Api := TFakeSerialIOKitApi.Create;
  Api.SourceValid := False;
  Driver := TSerialIOKitNotificationDriver.Create(Api, False);
  try
    AssertFalse(Driver.Start(nil, nil));

    AssertTrue(Api.WasReleased(101));
    AssertTrue(Api.WasReleased(102));
    AssertEquals(1, Api.AddedSourceCount);
    AssertEquals(1, Api.RemovedSourceCount);
    AssertEquals(1, Api.DestroyedPortCount);
  finally
    Driver.Free;
    Api.Free;
  end;
end;

procedure TSerialMacChangeSourceTests.
  InvalidRunLoopSourceFallsBackAndRequestsRefresh;
var
  Api: TFakeSerialIOKitApi;
  Backup: TFakeMacBackupSource;
  Driver: TSerialIOKitNotificationDriver;
  Monitor: TSerialMacNotificationChangeSource;
  Observer: TMacChangeObserver;
  Source: TSerialFallbackChangeSource;
begin
  Api := TFakeSerialIOKitApi.Create;
  Driver := TSerialIOKitNotificationDriver.Create(Api, False);
  Monitor := TSerialMacNotificationChangeSource.Create(Driver, False);
  Backup := TFakeMacBackupSource.Create;
  Observer := TMacChangeObserver.Create;
  Source := TSerialFallbackChangeSource.Create([Monitor, Backup]);
  try
    Source.Start(@Observer.Changed);
    Api.SourceValid := False;
    Driver.CheckHealth;

    AssertEquals(1, Source.CurrentIndex);
    AssertEquals(1, Backup.StartCount);
    AssertEquals(1, Observer.ChangedCount);
    AssertTrue(Api.WasReleased(101));
    AssertTrue(Api.WasReleased(102));
    AssertEquals(1, Api.DestroyedPortCount);
  finally
    Source.Free;
    Observer.Free;
    Driver.Free;
    Api.Free;
  end;
end;

initialization
  RegisterTest(TSerialMacChangeSourceTests);

end.
