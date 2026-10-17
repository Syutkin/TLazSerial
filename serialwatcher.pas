// Introduced in v0.7 by СМ630 2025÷2026
unit SerialWatcher;

{$mode ObjFPC}{$H+}

interface

uses
  {$IFDEF Windows}
  SerialWindowsChangeSource,
  {$ENDIF}
  {$IFDEF Linux}
  SerialLinuxChangeSource,
  {$ENDIF}
  {$IFDEF Darwin}
  SerialMacChangeSource,
  {$ENDIF}
  Classes, SysUtils, Controls, LResources, LazSerialDevices,
  SerialWatcherSupport, SerialDeviceRefresh;

type
  TSerialDevicesRefreshedEvent = procedure(Sender: TObject;
    const ADevices: TSerialDeviceInfoArray) of object;

  TSerialWatcher = class(TComponent)
  private
    FChangeDelayMs: Cardinal;
    FChangeSource: TSerialChangeSource;
    FComConnected: TNotifyEvent;
    FComDisconnected: TNotifyEvent;
    FDeviceRefreshThread: TSerialDeviceRefreshThread;
    FDevices: TSerialDeviceInfoArray;
    FOnDevicesRefreshed: TSerialDevicesRefreshedEvent;
    FInitialized: Boolean;
    FLastRefreshChanged: Boolean;
    FOwnInfrastructure: Boolean;
    FRefreshDirty: Boolean;
    FFailureRetryCount: Cardinal;
    FRefreshOnLoaded: Boolean;
    FRefreshPending: Boolean;
    FRefreshScheduler: TSerialRefreshScheduler;
    FSettleRetryCount: Cardinal;
    FSettleRetryDelayMs: Cardinal;
    FSettleRetriesRemaining: Cardinal;
    FSettlingActive: Boolean;
    FWatching: Boolean;
    procedure ChangeDetected(Sender: TObject);
    procedure InitializeInfrastructure(
      AChangeSource: TSerialChangeSource;
      ARefreshScheduler: TSerialRefreshScheduler;
      const AOwnInfrastructure: Boolean
    );
    procedure RefreshFinished;
    procedure ScheduledRefresh(Sender: TObject);
    function SettleRetryDelay: Cardinal;
    procedure StartBackgroundRefresh;
  protected
    procedure SetInfrastructure(
      AChangeSource: TSerialChangeSource;
      ARefreshScheduler: TSerialRefreshScheduler;
      const AOwnInfrastructure: Boolean
    );
    procedure ConfigureChangeTiming(
      const AChangeDelayMs: Cardinal;
      const ASettleRetryDelayMs: Cardinal;
      const ASettleRetryCount: Cardinal
    );
    procedure ApplyDevices(const ADevices: TSerialDeviceInfoArray); virtual;
    function BackgroundRefreshFinished: Boolean;
    function LoadDevices: TSerialDeviceInfoArray; virtual;
    procedure Loaded; override;
    procedure PollDevices;
    procedure StartWatching;
    procedure StopWatching;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure AdoptSnapshot(const ADevices: TSerialDeviceInfoArray);
    function ContainsDevice(const ADevice: string): Boolean;
    procedure Refresh;
    property RefreshOnLoaded: Boolean
      read FRefreshOnLoaded write FRefreshOnLoaded;
  published
    // Every successful refresh, including the baseline and metadata-only
    // changes. Delivered on the main thread before connection-change events.
    property OnDevicesRefreshed: TSerialDevicesRefreshedEvent
      read FOnDevicesRefreshed write FOnDevicesRefreshed;
    property OnComConnected: TNotifyEvent
      read FComConnected write FComConnected;
    property OnComDisconnected: TNotifyEvent
      read FComDisconnected write FComDisconnected;
  end;

procedure Register;

implementation

type
  TSerialWatcherEventGuard = class(TComponent)
  private
    FWatcher: TSerialWatcher;
  protected
    procedure Notification(AComponent: TComponent;
      Operation: TOperation); override;
  public
    constructor Create(AWatcher: TSerialWatcher); reintroduce;
    property Watcher: TSerialWatcher read FWatcher;
  end;

constructor TSerialWatcherEventGuard.Create(AWatcher: TSerialWatcher);
begin
  inherited Create(nil);
  FWatcher := AWatcher;
  AWatcher.FreeNotification(Self);
end;

procedure TSerialWatcherEventGuard.Notification(AComponent: TComponent;
  Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FWatcher) then
    FWatcher := nil;
end;

const
  SerialRefreshSettleRetryMs = 1;
  SerialRefreshFailureRetryCount = 3;
  SerialRefreshFailureRetryDelayMs = 250;
  {$IFDEF Windows}
  WindowsChangeDebounceMs = 150;
  WindowsSettleRetryDelayMs = 250;
  WindowsSettleRetryCount = 3;
  {$ENDIF}

function SnapshotHasAddedDevices(
  const APrevious, ACurrent: TSerialDeviceInfoArray
): Boolean;
var
  I: Integer;
begin
  for I := Low(ACurrent) to High(ACurrent) do
    if not ContainsSerialDevice(APrevious, ACurrent[I].Device) then
      Exit(True);
  Result := False;
end;

function SnapshotHasRemovedDevices(
  const APrevious, ACurrent: TSerialDeviceInfoArray
): Boolean;
var
  I: Integer;
begin
  for I := Low(APrevious) to High(APrevious) do
    if not ContainsSerialDevice(ACurrent, APrevious[I].Device) then
      Exit(True);
  Result := False;
end;

function TSerialWatcher.LoadDevices: TSerialDeviceInfoArray;
begin
  Result := GetSerialDevices;
end;

procedure TSerialWatcher.Refresh;
begin
  StartWatching;
  if FRefreshPending then
  begin
    // Refresh from a delivery callback must not create an endless reload loop.
    if (FDeviceRefreshThread <> nil) and not FDeviceRefreshThread.Delivering then
      FRefreshDirty := True;
    Exit;
  end;
  FRefreshScheduler.Cancel;
  FRefreshDirty := False;
  FFailureRetryCount := 0;
  FSettleRetriesRemaining := 0;
  FSettlingActive := False;
  StartBackgroundRefresh;
end;

procedure TSerialWatcher.ApplyDevices(
  const ADevices: TSerialDeviceInfoArray
);
var
  AddedDevices: Boolean;
  RemovedDevices: Boolean;
  Guard: TSerialWatcherEventGuard;
  Snapshot: TSerialDeviceInfoArray;
begin
  if (FDeviceRefreshThread <> nil) and
    FDeviceRefreshThread.Delivering and
    not FDeviceRefreshThread.LoadSucceeded then
    Exit;
  AddedDevices := False;
  RemovedDevices := False;
  if FInitialized then
  begin
    AddedDevices := SnapshotHasAddedDevices(FDevices, ADevices);
    RemovedDevices := SnapshotHasRemovedDevices(FDevices, ADevices);
  end;
  FLastRefreshChanged := AddedDevices or RemovedDevices;
  FDevices := Copy(ADevices, 0, Length(ADevices));
  FInitialized := True;

  Guard := TSerialWatcherEventGuard.Create(Self);
  try
    if Assigned(FOnDevicesRefreshed) then
    begin
      // Dynamic arrays are shared even through const parameters. Do not expose
      // the watcher's own storage to an event handler.
      Snapshot := Copy(FDevices, 0, Length(FDevices));
      FOnDevicesRefreshed(Self, Snapshot);
    end;
    // Any event may destroy this watcher or its owning component.
    if Guard.Watcher = nil then
      Exit;
    if AddedDevices and Assigned(FComConnected) then
      FComConnected(Self);
    if Guard.Watcher = nil then
      Exit;
    if RemovedDevices and Assigned(FComDisconnected) then
      FComDisconnected(Self);
  finally
    Guard.Free;
  end;
end;

function TSerialWatcher.BackgroundRefreshFinished: Boolean;
begin
  // Completion of the worker does not imply delivery of its queued snapshot.
  Result := (FDeviceRefreshThread = nil) or FDeviceRefreshThread.Finished;
end;

procedure TSerialWatcher.PollDevices;
begin
  ApplyDevices(LoadDevices);
end;

procedure TSerialWatcher.AdoptSnapshot(
  const ADevices: TSerialDeviceInfoArray
);
begin
  FDevices := Copy(ADevices, 0, Length(ADevices));
  FInitialized := True;
  StartWatching;
end;

procedure TSerialWatcher.StartBackgroundRefresh;
begin
  if not FWatching or FRefreshPending then
    Exit;

  if FDeviceRefreshThread <> nil then
  begin
    if not FDeviceRefreshThread.Finished or
      FDeviceRefreshThread.Delivering then
    begin
      FRefreshScheduler.Schedule(
        SerialRefreshSettleRetryMs,
        @ScheduledRefresh
      );
      Exit;
    end;
    CancelSerialDeviceRefresh(FDeviceRefreshThread);
  end;

  FRefreshPending := True;
  FLastRefreshChanged := False;
  try
    FDeviceRefreshThread := TSerialDeviceRefreshThread.Create(
      @LoadDevices,
      @ApplyDevices,
      @RefreshFinished
    );
    FDeviceRefreshThread.Start;
  except
    FRefreshPending := False;
    raise;
  end;
end;

procedure TSerialWatcher.RefreshFinished;
var
  RetryDelayMs: Cardinal;
begin
  if not FRefreshPending then
    Exit;
  FRefreshPending := False;
  if FWatching and FRefreshDirty then
  begin
    FRefreshDirty := False;
    FRefreshScheduler.Schedule(FChangeDelayMs, @ScheduledRefresh);
    Exit;
  end;
  if not FWatching then
    Exit;
  if not FDeviceRefreshThread.LoadSucceeded then
  begin
    if FFailureRetryCount < SerialRefreshFailureRetryCount then
    begin
      Inc(FFailureRetryCount);
      FRefreshScheduler.Schedule(SerialRefreshFailureRetryDelayMs,
        @ScheduledRefresh);
    end;
    Exit;
  end;
  FFailureRetryCount := 0;
  if not FSettlingActive then
    Exit;
  if FLastRefreshChanged or (FSettleRetriesRemaining = 0) then
  begin
    FSettleRetriesRemaining := 0;
    FSettlingActive := False;
    Exit;
  end;

  RetryDelayMs := SettleRetryDelay;
  Dec(FSettleRetriesRemaining);
  FRefreshScheduler.Schedule(RetryDelayMs, @ScheduledRefresh);
end;

procedure TSerialWatcher.ChangeDetected(Sender: TObject);
begin
  if not FWatching then
    Exit;
  FFailureRetryCount := 0;
  FSettlingActive := FChangeSource.RequiresSettling and
    (FSettleRetryCount > 0);
  if FSettlingActive then
    FSettleRetriesRemaining := FSettleRetryCount
  else
    FSettleRetriesRemaining := 0;
  if FRefreshPending then
  begin
    FRefreshDirty := True;
    Exit;
  end;
  FRefreshScheduler.Schedule(FChangeDelayMs, @ScheduledRefresh);
end;

function TSerialWatcher.SettleRetryDelay: Cardinal;
var
  Attempt: Cardinal;
begin
  Result := FSettleRetryDelayMs;
  Attempt := FSettleRetryCount - FSettleRetriesRemaining;
  while Attempt > 0 do
  begin
    if Result > High(Cardinal) div 2 then
      Exit(High(Cardinal));
    Result := Result * 2;
    Dec(Attempt);
  end;
end;

procedure TSerialWatcher.ScheduledRefresh(Sender: TObject);
begin
  if FWatching then
    StartBackgroundRefresh;
end;

procedure TSerialWatcher.InitializeInfrastructure(
  AChangeSource: TSerialChangeSource;
  ARefreshScheduler: TSerialRefreshScheduler;
  const AOwnInfrastructure: Boolean
);
begin
  if AChangeSource = nil then
    raise EArgumentNilException.Create('AChangeSource');
  if ARefreshScheduler = nil then
    raise EArgumentNilException.Create('ARefreshScheduler');

  FChangeSource := AChangeSource;
  FRefreshScheduler := ARefreshScheduler;
  FOwnInfrastructure := AOwnInfrastructure;
  FDevices := nil;
  FDeviceRefreshThread := nil;
  FInitialized := False;
  FLastRefreshChanged := False;
  FRefreshDirty := False;
  FFailureRetryCount := 0;
  FRefreshOnLoaded := True;
  FRefreshPending := False;
  FSettleRetriesRemaining := 0;
  FSettlingActive := False;
  FWatching := False;
  {$IFDEF Windows}
  ConfigureChangeTiming(
    WindowsChangeDebounceMs,
    WindowsSettleRetryDelayMs,
    WindowsSettleRetryCount
  );
  {$ELSE}
  ConfigureChangeTiming(0, 0, 0);
  {$ENDIF}
end;

procedure TSerialWatcher.ConfigureChangeTiming(
  const AChangeDelayMs: Cardinal;
  const ASettleRetryDelayMs: Cardinal;
  const ASettleRetryCount: Cardinal
);
begin
  FChangeDelayMs := AChangeDelayMs;
  FSettleRetryDelayMs := ASettleRetryDelayMs;
  FSettleRetryCount := ASettleRetryCount;
  FSettleRetriesRemaining := 0;
  FSettlingActive := False;
end;

procedure TSerialWatcher.SetInfrastructure(
  AChangeSource: TSerialChangeSource;
  ARefreshScheduler: TSerialRefreshScheduler;
  const AOwnInfrastructure: Boolean
);
begin
  if AChangeSource = nil then
    raise EArgumentNilException.Create('AChangeSource');
  if ARefreshScheduler = nil then
    raise EArgumentNilException.Create('ARefreshScheduler');

  StopWatching;
  if FOwnInfrastructure then
  begin
    FRefreshScheduler.Free;
    FChangeSource.Free;
  end;
  InitializeInfrastructure(
    AChangeSource,
    ARefreshScheduler,
    AOwnInfrastructure
  );
end;

constructor TSerialWatcher.Create(AOwner: TComponent);
var
  ChangeSource: TSerialChangeSource;
begin
  inherited Create(AOwner);
  {$IFDEF Windows}
  ChangeSource := CreateWindowsSerialChangeSource;
  {$ELSE}
  {$IFDEF Linux}
  ChangeSource := CreateLinuxSerialChangeSource;
  {$ELSE}
  {$IFDEF Darwin}
  ChangeSource := CreateMacSerialChangeSource;
  {$ELSE}
  ChangeSource := TSerialPollingChangeSource.Create(1000);
  {$ENDIF}
  {$ENDIF}
  {$ENDIF}
  try
    InitializeInfrastructure(
      ChangeSource,
      TSerialTimerScheduler.Create,
      True
    );
  except
    ChangeSource.Free;
    raise;
  end;
end;

procedure TSerialWatcher.StartWatching;
begin
  if FWatching then
    Exit;
  FWatching := True;
  try
    FChangeSource.Start(@ChangeDetected);
  except
    FWatching := False;
    raise;
  end;
end;

procedure TSerialWatcher.StopWatching;
begin
  FWatching := False;
  FRefreshDirty := False;
  FFailureRetryCount := 0;
  FSettleRetriesRemaining := 0;
  FSettlingActive := False;
  if FRefreshScheduler <> nil then
    FRefreshScheduler.Cancel;
  if FChangeSource <> nil then
    FChangeSource.Stop;
  CancelSerialDeviceRefresh(FDeviceRefreshThread);
  FRefreshPending := False;
end;

procedure TSerialWatcher.Loaded;
begin
  inherited Loaded;
  if FRefreshOnLoaded and not (csDesigning in ComponentState) then
    Refresh;
end;

function TSerialWatcher.ContainsDevice(const ADevice: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if not FInitialized or (ADevice = '') then Exit;
  if ContainsSerialDevice(FDevices, ADevice) then Exit(True);
  for I := Low(FDevices) to High(FDevices) do
    {$IFDEF MSWINDOWS}
    if CompareText(FDevices[I].PersistentId, ADevice) = 0 then
    {$ELSE}
    if FDevices[I].PersistentId = ADevice then
    {$ENDIF}
      Exit(True);
end;

destructor TSerialWatcher.Destroy;
begin
  StopWatching;
  if FOwnInfrastructure then
  begin
    FRefreshScheduler.Free;
    FChangeSource.Free;
  end;
  inherited Destroy;
end;

procedure Register;
begin
  {$I serialwatcher_icon.lrs}
  RegisterComponents('LazSerial', [TSerialWatcher]);
end;

initialization
  {$I serialwatcher_icon.lrs}

end.
