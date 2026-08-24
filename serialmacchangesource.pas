unit SerialMacChangeSource;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, ExtCtrls, SerialWatcherSupport;

type
  TSerialIOKitObject = Cardinal;
  TSerialIOKitNotificationPort = Pointer;
  TSerialIOKitRunLoop = Pointer;
  TSerialIOKitRunLoopSource = Pointer;

  TSerialIOKitNotificationKind = (
    siikMatched,
    siikTerminated
  );

  TSerialIOKitServiceCallback = procedure(
    AContext: Pointer;
    AIterator: TSerialIOKitObject
  ); cdecl;

  TSerialIOKitApi = class
  public
    function CreateNotificationPort: TSerialIOKitNotificationPort;
      virtual; abstract;
    procedure DestroyNotificationPort(
      APort: TSerialIOKitNotificationPort
    ); virtual; abstract;
    function GetRunLoopSource(
      APort: TSerialIOKitNotificationPort
    ): TSerialIOKitRunLoopSource; virtual; abstract;
    function GetMainRunLoop: TSerialIOKitRunLoop; virtual; abstract;
    procedure AddRunLoopSource(
      ARunLoop: TSerialIOKitRunLoop;
      ASource: TSerialIOKitRunLoopSource
    ); virtual; abstract;
    procedure RemoveRunLoopSource(
      ARunLoop: TSerialIOKitRunLoop;
      ASource: TSerialIOKitRunLoopSource
    ); virtual; abstract;
    function IsRunLoopSourceValid(
      ASource: TSerialIOKitRunLoopSource
    ): Boolean; virtual; abstract;
    function AddSerialNotification(
      APort: TSerialIOKitNotificationPort;
      const AKind: TSerialIOKitNotificationKind;
      const ACallback: TSerialIOKitServiceCallback;
      AContext: Pointer;
      out AIterator: TSerialIOKitObject
    ): Boolean; virtual; abstract;
    function NextObject(
      const AIterator: TSerialIOKitObject
    ): TSerialIOKitObject; virtual; abstract;
    procedure ReleaseObject(
      const AObject: TSerialIOKitObject
    ); virtual; abstract;
  end;

  TSerialMacNotificationDriver = class
  public
    function Start(
      const AOnChanged: TNotifyEvent;
      const AOnFailed: TNotifyEvent
    ): Boolean; virtual; abstract;
    procedure Stop; virtual; abstract;
  end;

  TSerialIOKitNotificationDriver = class(TSerialMacNotificationDriver)
  private
    FApi: TSerialIOKitApi;
    FHealthTimer: TTimer;
    FIterators: array[TSerialIOKitNotificationKind] of TSerialIOKitObject;
    FNotificationPort: TSerialIOKitNotificationPort;
    FOnChanged: TNotifyEvent;
    FOnFailed: TNotifyEvent;
    FOwnApi: Boolean;
    FRunLoop: TSerialIOKitRunLoop;
    FRunLoopSource: TSerialIOKitRunLoopSource;
    FRunLoopSourceAdded: Boolean;
    FStarted: Boolean;
    function DrainIterator(
      const AIterator: TSerialIOKitObject
    ): Boolean;
    procedure HealthTimerElapsed(Sender: TObject);
    procedure IteratorChanged(const AIterator: TSerialIOKitObject);
    class procedure ServiceChanged(
      AContext: Pointer;
      AIterator: TSerialIOKitObject
    ); cdecl; static;
    procedure SetHealthTimerEnabled(const AEnabled: Boolean);
  public
    constructor Create(
      AApi: TSerialIOKitApi;
      const AOwnApi: Boolean = True
    );
    destructor Destroy; override;
    procedure CheckHealth;
    function Start(
      const AOnChanged: TNotifyEvent;
      const AOnFailed: TNotifyEvent
    ): Boolean; override;
    procedure Stop; override;
  end;

  TSerialMacNotificationChangeSource = class(TSerialChangeSource)
  private
    FDriver: TSerialMacNotificationDriver;
    FOwnDriver: Boolean;
    procedure DriverChanged(Sender: TObject);
    procedure DriverFailed(Sender: TObject);
  protected
    procedure DoStart; override;
    procedure DoStop; override;
  public
    constructor Create(
      ADriver: TSerialMacNotificationDriver;
      const AOwnDriver: Boolean = True
    );
    destructor Destroy; override;
  end;

{$IFDEF Darwin}
function CreateMacSerialChangeSource: TSerialChangeSource;
{$ENDIF}

implementation

uses
  SysUtils
  {$IFDEF Darwin}
  , MacOSAll
  {$ENDIF};

const
  IOKitHealthIntervalMs = 1000;

{$IFDEF Darwin}
{$linkframework IOKit}

const
  MacPollingIntervalMs = 1000;
  IOKitSerialServiceClass = 'IOSerialBSDClient';
  IOKitMatchedNotification = 'IOServiceMatched';
  IOKitTerminatedNotification = 'IOServiceTerminate';
  IOKitSuccess = 0;

function IOServiceMatching(AName: PChar): CFMutableDictionaryRef; cdecl;
  external name 'IOServiceMatching';
function IONotificationPortCreate(
  AMainPort: Cardinal
): TSerialIOKitNotificationPort; cdecl;
  external name 'IONotificationPortCreate';
procedure IONotificationPortDestroy(
  APort: TSerialIOKitNotificationPort
); cdecl; external name 'IONotificationPortDestroy';
function IONotificationPortGetRunLoopSource(
  APort: TSerialIOKitNotificationPort
): CFRunLoopSourceRef; cdecl;
  external name 'IONotificationPortGetRunLoopSource';
function IOServiceAddMatchingNotification(
  APort: TSerialIOKitNotificationPort;
  ANotificationType: PChar;
  AMatching: CFDictionaryRef;
  ACallback: TSerialIOKitServiceCallback;
  AContext: Pointer;
  var AIterator: TSerialIOKitObject
): SInt32; cdecl; external name 'IOServiceAddMatchingNotification';
function IOIteratorNext(
  AIterator: TSerialIOKitObject
): TSerialIOKitObject; cdecl; external name 'IOIteratorNext';
function IOObjectRelease(
  AObject: TSerialIOKitObject
): SInt32; cdecl; external name 'IOObjectRelease';

type
  TSerialDarwinIOKitApi = class(TSerialIOKitApi)
  public
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
  end;
{$ENDIF}

constructor TSerialIOKitNotificationDriver.Create(
  AApi: TSerialIOKitApi;
  const AOwnApi: Boolean
);
begin
  inherited Create;
  if AApi = nil then
    raise EArgumentNilException.Create('AApi');
  FApi := AApi;
  FOwnApi := AOwnApi;
  FHealthTimer := TTimer.Create(nil);
  FHealthTimer.Enabled := False;
  FHealthTimer.Interval := IOKitHealthIntervalMs;
  FHealthTimer.OnTimer := @HealthTimerElapsed;
end;

procedure TSerialIOKitNotificationDriver.SetHealthTimerEnabled(
  const AEnabled: Boolean
);
begin
  FHealthTimer.Enabled := AEnabled;
end;

function TSerialIOKitNotificationDriver.DrainIterator(
  const AIterator: TSerialIOKitObject
): Boolean;
var
  Service: TSerialIOKitObject;
begin
  Result := False;
  if AIterator = 0 then
    Exit;
  repeat
    Service := FApi.NextObject(AIterator);
    if Service = 0 then
      Exit;
    Result := True;
    FApi.ReleaseObject(Service);
  until False;
end;

class procedure TSerialIOKitNotificationDriver.ServiceChanged(
  AContext: Pointer;
  AIterator: TSerialIOKitObject
); cdecl;
begin
  if AContext <> nil then
    TSerialIOKitNotificationDriver(AContext).IteratorChanged(AIterator);
end;

procedure TSerialIOKitNotificationDriver.IteratorChanged(
  const AIterator: TSerialIOKitObject
);
begin
  if not FStarted then
    Exit;
  if DrainIterator(AIterator) and Assigned(FOnChanged) then
    FOnChanged(Self);
end;

procedure TSerialIOKitNotificationDriver.HealthTimerElapsed(Sender: TObject);
begin
  CheckHealth;
end;

procedure TSerialIOKitNotificationDriver.CheckHealth;
var
  FailedCallback: TNotifyEvent;
begin
  if not FStarted then
    Exit;
  if (FRunLoopSource <> nil) and
    FApi.IsRunLoopSourceValid(FRunLoopSource) then
    Exit;

  FailedCallback := FOnFailed;
  if Assigned(FailedCallback) then
    FailedCallback(Self);
end;

function TSerialIOKitNotificationDriver.Start(
  const AOnChanged: TNotifyEvent;
  const AOnFailed: TNotifyEvent
): Boolean;
var
  Kind: TSerialIOKitNotificationKind;
begin
  Result := False;
  Stop;
  FOnChanged := AOnChanged;
  FOnFailed := AOnFailed;
  try
    FNotificationPort := FApi.CreateNotificationPort;
    if FNotificationPort = nil then
      Exit;
    FRunLoopSource := FApi.GetRunLoopSource(FNotificationPort);
    FRunLoop := FApi.GetMainRunLoop;
    if (FRunLoopSource = nil) or (FRunLoop = nil) then
      Exit;

    for Kind := Low(TSerialIOKitNotificationKind) to
      High(TSerialIOKitNotificationKind) do
    begin
      if not FApi.AddSerialNotification(
        FNotificationPort,
        Kind,
        @ServiceChanged,
        Self,
        FIterators[Kind]
      ) then
        Exit;
      DrainIterator(FIterators[Kind]);
    end;

    FApi.AddRunLoopSource(FRunLoop, FRunLoopSource);
    FRunLoopSourceAdded := True;
    if not FApi.IsRunLoopSourceValid(FRunLoopSource) then
      Exit;
    FStarted := True;
    SetHealthTimerEnabled(True);
    Result := True;
  finally
    if not Result then
      Stop;
  end;
end;

procedure TSerialIOKitNotificationDriver.Stop;
var
  Kind: TSerialIOKitNotificationKind;
begin
  SetHealthTimerEnabled(False);
  FStarted := False;
  FOnChanged := nil;
  FOnFailed := nil;

  if FRunLoopSourceAdded then
    FApi.RemoveRunLoopSource(FRunLoop, FRunLoopSource);
  FRunLoopSourceAdded := False;

  for Kind := Low(TSerialIOKitNotificationKind) to
    High(TSerialIOKitNotificationKind) do
  begin
    if FIterators[Kind] <> 0 then
      FApi.ReleaseObject(FIterators[Kind]);
    FIterators[Kind] := 0;
  end;

  if FNotificationPort <> nil then
    FApi.DestroyNotificationPort(FNotificationPort);
  FNotificationPort := nil;
  FRunLoopSource := nil;
  FRunLoop := nil;
end;

destructor TSerialIOKitNotificationDriver.Destroy;
begin
  Stop;
  FHealthTimer.Free;
  if FOwnApi then
    FApi.Free;
  inherited Destroy;
end;

constructor TSerialMacNotificationChangeSource.Create(
  ADriver: TSerialMacNotificationDriver;
  const AOwnDriver: Boolean
);
begin
  inherited Create;
  if ADriver = nil then
    raise EArgumentNilException.Create('ADriver');
  FDriver := ADriver;
  FOwnDriver := AOwnDriver;
end;

procedure TSerialMacNotificationChangeSource.DriverChanged(Sender: TObject);
begin
  Changed;
end;

procedure TSerialMacNotificationChangeSource.DriverFailed(Sender: TObject);
begin
  Failed;
end;

procedure TSerialMacNotificationChangeSource.DoStart;
begin
  if not FDriver.Start(@DriverChanged, @DriverFailed) then
  begin
    FDriver.Stop;
    raise EInvalidOperation.Create(
      'macOS serial device notifications are unavailable'
    );
  end;
end;

procedure TSerialMacNotificationChangeSource.DoStop;
begin
  FDriver.Stop;
end;

destructor TSerialMacNotificationChangeSource.Destroy;
begin
  Stop;
  if FOwnDriver then
    FDriver.Free;
  inherited Destroy;
end;

{$IFDEF Darwin}
function TSerialDarwinIOKitApi.CreateNotificationPort:
  TSerialIOKitNotificationPort;
begin
  Result := IONotificationPortCreate(0);
end;

procedure TSerialDarwinIOKitApi.DestroyNotificationPort(
  APort: TSerialIOKitNotificationPort
);
begin
  IONotificationPortDestroy(APort);
end;

function TSerialDarwinIOKitApi.GetRunLoopSource(
  APort: TSerialIOKitNotificationPort
): TSerialIOKitRunLoopSource;
begin
  Result := IONotificationPortGetRunLoopSource(APort);
end;

function TSerialDarwinIOKitApi.GetMainRunLoop: TSerialIOKitRunLoop;
begin
  Result := CFRunLoopGetMain;
end;

procedure TSerialDarwinIOKitApi.AddRunLoopSource(
  ARunLoop: TSerialIOKitRunLoop;
  ASource: TSerialIOKitRunLoopSource
);
begin
  CFRunLoopAddSource(
    CFRunLoopRef(ARunLoop),
    CFRunLoopSourceRef(ASource),
    kCFRunLoopCommonModes
  );
end;

procedure TSerialDarwinIOKitApi.RemoveRunLoopSource(
  ARunLoop: TSerialIOKitRunLoop;
  ASource: TSerialIOKitRunLoopSource
);
begin
  CFRunLoopRemoveSource(
    CFRunLoopRef(ARunLoop),
    CFRunLoopSourceRef(ASource),
    kCFRunLoopCommonModes
  );
end;

function TSerialDarwinIOKitApi.IsRunLoopSourceValid(
  ASource: TSerialIOKitRunLoopSource
): Boolean;
begin
  Result := CFRunLoopSourceIsValid(CFRunLoopSourceRef(ASource));
end;

function TSerialDarwinIOKitApi.AddSerialNotification(
  APort: TSerialIOKitNotificationPort;
  const AKind: TSerialIOKitNotificationKind;
  const ACallback: TSerialIOKitServiceCallback;
  AContext: Pointer;
  out AIterator: TSerialIOKitObject
): Boolean;
var
  Matching: CFMutableDictionaryRef;
  NotificationName: PChar;
begin
  Result := False;
  AIterator := 0;
  Matching := IOServiceMatching(PChar(IOKitSerialServiceClass));
  if Matching = nil then
    Exit;
  case AKind of
    siikMatched:
      NotificationName := PChar(IOKitMatchedNotification);
    siikTerminated:
      NotificationName := PChar(IOKitTerminatedNotification);
  end;
  Result := IOServiceAddMatchingNotification(
    APort,
    NotificationName,
    Matching,
    ACallback,
    AContext,
    AIterator
  ) = IOKitSuccess;
end;

function TSerialDarwinIOKitApi.NextObject(
  const AIterator: TSerialIOKitObject
): TSerialIOKitObject;
begin
  Result := IOIteratorNext(AIterator);
end;

procedure TSerialDarwinIOKitApi.ReleaseObject(
  const AObject: TSerialIOKitObject
);
begin
  IOObjectRelease(AObject);
end;

function CreateMacSerialChangeSource: TSerialChangeSource;
begin
  Result := TSerialFallbackChangeSource.Create([
    TSerialMacNotificationChangeSource.Create(
      TSerialIOKitNotificationDriver.Create(TSerialDarwinIOKitApi.Create)
    ),
    TSerialPollingChangeSource.Create(MacPollingIntervalMs)
  ]);
end;
{$ENDIF}

end.
