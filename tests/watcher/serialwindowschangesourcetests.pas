unit SerialWindowsChangeSourceTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, FpcUnit, TestRegistry, SerialWatcherSupport
  {$IFDEF Windows}
  , SerialWindowsChangeSource
  {$ENDIF};

{$IFDEF Windows}
type
  TFakeWindowsNotificationDriver = class(TSerialWindowsNotificationDriver)
  private
    FOnChanged: TNotifyEvent;
    FOnFailed: TNotifyEvent;
    FStartCount: Integer;
    FStartResult: Boolean;
    FStopCount: Integer;
  public
    constructor Create;
    function Start(
      const AOnChanged: TNotifyEvent;
      const AOnFailed: TNotifyEvent
    ): Boolean; override;
    procedure Stop; override;
    procedure SignalChanged;
    procedure SignalFailed;
    property StartCount: Integer read FStartCount;
    property StartResult: Boolean read FStartResult write FStartResult;
    property StopCount: Integer read FStopCount;
  end;

  TFakeWindowsBackupSource = class(TSerialChangeSource)
  private
    FStartCount: Integer;
    FStopCount: Integer;
  protected
    procedure DoStart; override;
    procedure DoStop; override;
  public
    property StartCount: Integer read FStartCount;
    property StopCount: Integer read FStopCount;
  end;

  TWindowsChangeObserver = class
  private
    FChangedCount: Integer;
  public
    procedure Changed(Sender: TObject);
    property ChangedCount: Integer read FChangedCount;
  end;
{$ENDIF}

type
  TSerialWindowsChangeSourceTests = class(TTestCase)
  published
    {$IFDEF Windows}
    procedure NativeSignalRequestsSettlingRefresh;
    procedure StartFailureFallsBackAndReleasesDriver;
    procedure RuntimeFailureFallsBackAndRequestsRefresh;
    procedure StopReleasesDriverAndSuppressesLateSignals;
    {$ENDIF}
  end;

implementation

{$IFDEF Windows}
constructor TFakeWindowsNotificationDriver.Create;
begin
  inherited Create;
  FStartResult := True;
end;

function TFakeWindowsNotificationDriver.Start(
  const AOnChanged: TNotifyEvent;
  const AOnFailed: TNotifyEvent
): Boolean;
begin
  Inc(FStartCount);
  FOnChanged := AOnChanged;
  FOnFailed := AOnFailed;
  Result := FStartResult;
end;

procedure TFakeWindowsNotificationDriver.Stop;
begin
  Inc(FStopCount);
  FOnChanged := nil;
  FOnFailed := nil;
end;

procedure TFakeWindowsNotificationDriver.SignalChanged;
begin
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

procedure TFakeWindowsNotificationDriver.SignalFailed;
begin
  if Assigned(FOnFailed) then
    FOnFailed(Self);
end;

procedure TFakeWindowsBackupSource.DoStart;
begin
  Inc(FStartCount);
end;

procedure TFakeWindowsBackupSource.DoStop;
begin
  Inc(FStopCount);
end;

procedure TWindowsChangeObserver.Changed(Sender: TObject);
begin
  Inc(FChangedCount);
end;

procedure TSerialWindowsChangeSourceTests.NativeSignalRequestsSettlingRefresh;
var
  Driver: TFakeWindowsNotificationDriver;
  Observer: TWindowsChangeObserver;
  Source: TSerialWindowsNotificationChangeSource;
begin
  Driver := TFakeWindowsNotificationDriver.Create;
  Observer := TWindowsChangeObserver.Create;
  Source := TSerialWindowsNotificationChangeSource.Create(Driver, False);
  try
    Source.Start(@Observer.Changed);
    Driver.SignalChanged;

    AssertEquals(1, Observer.ChangedCount);
    AssertTrue(Source.RequiresSettling);
  finally
    Source.Free;
    Observer.Free;
    Driver.Free;
  end;
end;

procedure TSerialWindowsChangeSourceTests.
  StartFailureFallsBackAndReleasesDriver;
var
  Backup: TFakeWindowsBackupSource;
  Driver: TFakeWindowsNotificationDriver;
  Monitor: TSerialWindowsNotificationChangeSource;
  Observer: TWindowsChangeObserver;
  Source: TSerialFallbackChangeSource;
begin
  Driver := TFakeWindowsNotificationDriver.Create;
  Driver.StartResult := False;
  Monitor := TSerialWindowsNotificationChangeSource.Create(Driver, False);
  Backup := TFakeWindowsBackupSource.Create;
  Observer := TWindowsChangeObserver.Create;
  Source := TSerialFallbackChangeSource.Create([Monitor, Backup]);
  try
    Source.Start(@Observer.Changed);

    AssertEquals(1, Source.CurrentIndex);
    AssertEquals(1, Driver.StartCount);
    AssertEquals(1, Driver.StopCount);
    AssertEquals(1, Backup.StartCount);
    AssertFalse(Source.RequiresSettling);
  finally
    Source.Free;
    Observer.Free;
    Driver.Free;
  end;
end;

procedure TSerialWindowsChangeSourceTests.
  RuntimeFailureFallsBackAndRequestsRefresh;
var
  Backup: TFakeWindowsBackupSource;
  Driver: TFakeWindowsNotificationDriver;
  Monitor: TSerialWindowsNotificationChangeSource;
  Observer: TWindowsChangeObserver;
  Source: TSerialFallbackChangeSource;
begin
  Driver := TFakeWindowsNotificationDriver.Create;
  Monitor := TSerialWindowsNotificationChangeSource.Create(Driver, False);
  Backup := TFakeWindowsBackupSource.Create;
  Observer := TWindowsChangeObserver.Create;
  Source := TSerialFallbackChangeSource.Create([Monitor, Backup]);
  try
    Source.Start(@Observer.Changed);
    Driver.SignalFailed;

    AssertEquals(1, Source.CurrentIndex);
    AssertEquals(1, Driver.StopCount);
    AssertEquals(1, Backup.StartCount);
    AssertEquals(1, Observer.ChangedCount);
  finally
    Source.Free;
    Observer.Free;
    Driver.Free;
  end;
end;

procedure TSerialWindowsChangeSourceTests.
  StopReleasesDriverAndSuppressesLateSignals;
var
  Driver: TFakeWindowsNotificationDriver;
  Observer: TWindowsChangeObserver;
  Source: TSerialWindowsNotificationChangeSource;
begin
  Driver := TFakeWindowsNotificationDriver.Create;
  Observer := TWindowsChangeObserver.Create;
  Source := TSerialWindowsNotificationChangeSource.Create(Driver, False);
  try
    Source.Start(@Observer.Changed);
    Source.Stop;
    Driver.SignalChanged;

    AssertEquals(1, Driver.StopCount);
    AssertEquals(0, Observer.ChangedCount);
  finally
    Source.Free;
    Observer.Free;
    Driver.Free;
  end;
end;
{$ENDIF}

initialization
  {$IFDEF Windows}
  RegisterTest(TSerialWindowsChangeSourceTests);
  {$ENDIF}

end.
