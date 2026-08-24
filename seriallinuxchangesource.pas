unit SerialLinuxChangeSource;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SerialWatcherSupport;

{$IFDEF Linux}
type
  TSerialLinuxMonitorResult = (
    slmrTimeout,
    slmrChanged,
    slmrOverflow,
    slmrFailed
  );

  TSerialLinuxMonitorDriver = class
  public
    function Start: Boolean; virtual; abstract;
    procedure Stop; virtual; abstract;
    function WaitForEvent(
      const ATimeoutMs: Cardinal
    ): TSerialLinuxMonitorResult; virtual; abstract;
  end;

  TSerialLinuxMonitorChangeSource = class;

  TSerialLinuxMonitorChangeSource = class(TSerialChangeSource)
  private
    FDriver: TSerialLinuxMonitorDriver;
    FOwnDriver: Boolean;
    FThread: TThread;
    procedure DeliverChanged;
    procedure DeliverFailed;
  protected
    procedure DoStart; override;
    procedure DoStop; override;
  public
    constructor Create(
      ADriver: TSerialLinuxMonitorDriver;
      const AOwnDriver: Boolean = True
    );
    destructor Destroy; override;
  end;

function CreateLinuxSerialChangeSource: TSerialChangeSource;
{$ENDIF}

implementation

{$IFDEF Linux}
uses
  BaseUnix, Dynlibs, Linux, SysUtils, LazSerialDeviceCollectors;

const
  LinuxMonitorWaitMs = 100;
  InotifyEventHeaderSize = 16;
  InotifyBufferSize = 8192;

type
  TSerialLinuxMonitorThread = class(TThread)
  private
    FSource: TSerialLinuxMonitorChangeSource;
  protected
    procedure Execute; override;
  public
    constructor Create(ASource: TSerialLinuxMonitorChangeSource);
  end;

  TUdevNew = function: Pointer; cdecl;
  TUdevUnref = function(AUdev: Pointer): Pointer; cdecl;
  TUdevMonitorNewFromNetlink = function(
    AUdev: Pointer;
    AName: PChar
  ): Pointer; cdecl;
  TUdevMonitorFilterAddMatchSubsystemDevtype = function(
    AMonitor: Pointer;
    ASubsystem: PChar;
    ADeviceType: PChar
  ): CInt; cdecl;
  TUdevMonitorEnableReceiving = function(AMonitor: Pointer): CInt; cdecl;
  TUdevMonitorGetFd = function(AMonitor: Pointer): CInt; cdecl;
  TUdevMonitorReceiveDevice = function(AMonitor: Pointer): Pointer; cdecl;
  TUdevMonitorUnref = function(AMonitor: Pointer): Pointer; cdecl;
  TUdevDeviceUnref = function(ADevice: Pointer): Pointer; cdecl;

  TSerialUdevMonitorDriver = class(TSerialLinuxMonitorDriver)
  private
    FLibrary: TLibHandle;
    FMonitor: Pointer;
    FUdev: Pointer;
    FUdevDeviceUnref: TUdevDeviceUnref;
    FUdevMonitorEnableReceiving: TUdevMonitorEnableReceiving;
    FUdevMonitorFilterAddMatchSubsystemDevtype:
      TUdevMonitorFilterAddMatchSubsystemDevtype;
    FUdevMonitorGetFd: TUdevMonitorGetFd;
    FUdevMonitorNewFromNetlink: TUdevMonitorNewFromNetlink;
    FUdevMonitorReceiveDevice: TUdevMonitorReceiveDevice;
    FUdevMonitorUnref: TUdevMonitorUnref;
    FUdevNew: TUdevNew;
    FUdevUnref: TUdevUnref;
    function LoadApi: Boolean;
  public
    function Start: Boolean; override;
    procedure Stop; override;
    function WaitForEvent(
      const ATimeoutMs: Cardinal
    ): TSerialLinuxMonitorResult; override;
  end;

  TSerialInotifyMonitorDriver = class(TSerialLinuxMonitorDriver)
  private
    FFileDescriptor: CInt;
    FWatchDescriptor: CInt;
  public
    constructor Create;
    function Start: Boolean; override;
    procedure Stop; override;
    function WaitForEvent(
      const ATimeoutMs: Cardinal
    ): TSerialLinuxMonitorResult; override;
  end;

function PollDescriptor(
  const AFileDescriptor: CInt;
  const ATimeoutMs: Cardinal;
  out AEvents: CShort
): CInt;
var
  Descriptor: TPollFD;
begin
  FillChar(Descriptor, SizeOf(Descriptor), 0);
  Descriptor.fd := AFileDescriptor;
  Descriptor.events := POLLIN;
  Result := fpPoll(@Descriptor, 1, ATimeoutMs);
  AEvents := Descriptor.revents;
end;

constructor TSerialLinuxMonitorThread.Create(
  ASource: TSerialLinuxMonitorChangeSource
);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FSource := ASource;
end;

procedure TSerialLinuxMonitorThread.Execute;
var
  MonitorResult: TSerialLinuxMonitorResult;
begin
  while not Terminated do
  begin
    try
      MonitorResult := FSource.FDriver.WaitForEvent(LinuxMonitorWaitMs);
    except
      MonitorResult := slmrFailed;
    end;
    if Terminated then
      Exit;

    case MonitorResult of
      slmrChanged,
      slmrOverflow:
        TThread.Queue(Self, @FSource.DeliverChanged);
      slmrFailed:
        begin
          TThread.Queue(Self, @FSource.DeliverFailed);
          Exit;
        end;
    end;
  end;
end;

constructor TSerialLinuxMonitorChangeSource.Create(
  ADriver: TSerialLinuxMonitorDriver;
  const AOwnDriver: Boolean
);
begin
  inherited Create;
  if ADriver = nil then
    raise EArgumentNilException.Create('ADriver');
  FDriver := ADriver;
  FOwnDriver := AOwnDriver;
end;

procedure TSerialLinuxMonitorChangeSource.DoStart;
begin
  try
    if not FDriver.Start then
      raise EInvalidOperation.Create('Serial monitor is unavailable');
  except
    FDriver.Stop;
    raise;
  end;

  try
    FThread := TSerialLinuxMonitorThread.Create(Self);
    FThread.Start;
  except
    FreeAndNil(FThread);
    FDriver.Stop;
    raise;
  end;
end;

procedure TSerialLinuxMonitorChangeSource.DoStop;
var
  Thread: TThread;
begin
  Thread := FThread;
  FThread := nil;
  if Thread <> nil then
  begin
    Thread.Terminate;
    Thread.WaitFor;
    TThread.RemoveQueuedEvents(Thread);
    Thread.Free;
  end;
  FDriver.Stop;
end;

procedure TSerialLinuxMonitorChangeSource.DeliverChanged;
begin
  Changed;
end;

procedure TSerialLinuxMonitorChangeSource.DeliverFailed;
begin
  Failed;
end;

destructor TSerialLinuxMonitorChangeSource.Destroy;
begin
  Stop;
  if FOwnDriver then
    FDriver.Free;
  inherited Destroy;
end;

function TSerialUdevMonitorDriver.LoadApi: Boolean;

  function Symbol(const AName: string): Pointer;
  begin
    Result := GetProcedureAddress(FLibrary, PChar(AName));
  end;

begin
  Pointer(FUdevNew) := Symbol('udev_new');
  Pointer(FUdevUnref) := Symbol('udev_unref');
  Pointer(FUdevMonitorNewFromNetlink) :=
    Symbol('udev_monitor_new_from_netlink');
  Pointer(FUdevMonitorFilterAddMatchSubsystemDevtype) :=
    Symbol('udev_monitor_filter_add_match_subsystem_devtype');
  Pointer(FUdevMonitorEnableReceiving) :=
    Symbol('udev_monitor_enable_receiving');
  Pointer(FUdevMonitorGetFd) := Symbol('udev_monitor_get_fd');
  Pointer(FUdevMonitorReceiveDevice) :=
    Symbol('udev_monitor_receive_device');
  Pointer(FUdevMonitorUnref) := Symbol('udev_monitor_unref');
  Pointer(FUdevDeviceUnref) := Symbol('udev_device_unref');

  Result :=
    Assigned(FUdevNew) and Assigned(FUdevUnref) and
    Assigned(FUdevMonitorNewFromNetlink) and
    Assigned(FUdevMonitorFilterAddMatchSubsystemDevtype) and
    Assigned(FUdevMonitorEnableReceiving) and
    Assigned(FUdevMonitorGetFd) and
    Assigned(FUdevMonitorReceiveDevice) and
    Assigned(FUdevMonitorUnref) and Assigned(FUdevDeviceUnref);
end;

function TSerialUdevMonitorDriver.Start: Boolean;
begin
  Result := False;
  Stop;
  FLibrary := LoadLibrary('libudev.so.1');
  if (FLibrary = NilHandle) or not LoadApi then
  begin
    Stop;
    Exit;
  end;

  FUdev := FUdevNew();
  if FUdev = nil then
  begin
    Stop;
    Exit;
  end;

  FMonitor := FUdevMonitorNewFromNetlink(FUdev, 'udev');
  if FMonitor = nil then
  begin
    Stop;
    Exit;
  end;
  if FUdevMonitorFilterAddMatchSubsystemDevtype(
    FMonitor,
    'tty',
    nil
  ) < 0 then
  begin
    Stop;
    Exit;
  end;
  if FUdevMonitorEnableReceiving(FMonitor) < 0 then
  begin
    Stop;
    Exit;
  end;
  if FUdevMonitorGetFd(FMonitor) < 0 then
  begin
    Stop;
    Exit;
  end;
  Result := True;
end;

procedure TSerialUdevMonitorDriver.Stop;
begin
  if (FMonitor <> nil) and Assigned(FUdevMonitorUnref) then
    FUdevMonitorUnref(FMonitor);
  FMonitor := nil;
  if (FUdev <> nil) and Assigned(FUdevUnref) then
    FUdevUnref(FUdev);
  FUdev := nil;
  if FLibrary <> NilHandle then
    UnloadLibrary(FLibrary);
  FLibrary := NilHandle;
  FUdevNew := nil;
  FUdevUnref := nil;
  FUdevMonitorNewFromNetlink := nil;
  FUdevMonitorFilterAddMatchSubsystemDevtype := nil;
  FUdevMonitorEnableReceiving := nil;
  FUdevMonitorGetFd := nil;
  FUdevMonitorReceiveDevice := nil;
  FUdevMonitorUnref := nil;
  FUdevDeviceUnref := nil;
end;

function TSerialUdevMonitorDriver.WaitForEvent(
  const ATimeoutMs: Cardinal
): TSerialLinuxMonitorResult;
var
  Device: Pointer;
  Events: CShort;
  FileDescriptor: CInt;
  PollResult: CInt;
begin
  if (FMonitor = nil) or not Assigned(FUdevMonitorGetFd) then
    Exit(slmrFailed);

  FileDescriptor := FUdevMonitorGetFd(FMonitor);
  if FileDescriptor < 0 then
    Exit(slmrFailed);
  PollResult := PollDescriptor(
    FileDescriptor,
    ATimeoutMs,
    Events
  );
  if PollResult = 0 then
    Exit(slmrTimeout);
  if PollResult < 0 then
  begin
    if fpGetErrNo = ESysEINTR then
      Exit(slmrTimeout);
    Exit(slmrFailed);
  end;
  if (Events and (POLLERR or POLLHUP or POLLNVAL)) <> 0 then
    Exit(slmrFailed);
  if (Events and POLLIN) = 0 then
    Exit(slmrTimeout);

  Device := FUdevMonitorReceiveDevice(FMonitor);
  if Device = nil then
    Exit(slmrTimeout);
  FUdevDeviceUnref(Device);
  Result := slmrChanged;
end;

constructor TSerialInotifyMonitorDriver.Create;
begin
  inherited Create;
  FFileDescriptor := -1;
  FWatchDescriptor := -1;
end;

function TSerialInotifyMonitorDriver.Start: Boolean;
const
  WatchMask = IN_ATTRIB or IN_CREATE or IN_DELETE or IN_MOVED_FROM or
    IN_MOVED_TO or IN_DELETE_SELF or IN_MOVE_SELF;
begin
  Stop;
  FFileDescriptor := inotify_init1(IN_NONBLOCK or IN_CLOEXEC);
  if FFileDescriptor < 0 then
    Exit(False);
  FWatchDescriptor := inotify_add_watch(
    FFileDescriptor,
    '/dev',
    WatchMask
  );
  if FWatchDescriptor < 0 then
  begin
    Stop;
    Exit(False);
  end;
  Result := True;
end;

procedure TSerialInotifyMonitorDriver.Stop;
begin
  if (FFileDescriptor >= 0) and (FWatchDescriptor >= 0) then
    inotify_rm_watch(FFileDescriptor, FWatchDescriptor);
  FWatchDescriptor := -1;
  if FFileDescriptor >= 0 then
    fpClose(FFileDescriptor);
  FFileDescriptor := -1;
end;

function TSerialInotifyMonitorDriver.WaitForEvent(
  const ATimeoutMs: Cardinal
): TSerialLinuxMonitorResult;
var
  Buffer: array[0..InotifyBufferSize - 1] of Byte;
  BytesRead: Int64;
  DevicePath: string;
  Event: PInotify_event;
  Events: CShort;
  Name: string;
  NameLength: SizeUInt;
  Offset: SizeUInt;
  PollResult: CInt;
begin
  if FFileDescriptor < 0 then
    Exit(slmrFailed);

  PollResult := PollDescriptor(FFileDescriptor, ATimeoutMs, Events);
  if PollResult = 0 then
    Exit(slmrTimeout);
  if PollResult < 0 then
  begin
    if fpGetErrNo = ESysEINTR then
      Exit(slmrTimeout);
    Exit(slmrFailed);
  end;
  if (Events and (POLLERR or POLLHUP or POLLNVAL)) <> 0 then
    Exit(slmrFailed);
  if (Events and POLLIN) = 0 then
    Exit(slmrTimeout);

  BytesRead := fpRead(FFileDescriptor, Buffer, SizeOf(Buffer));
  if BytesRead = 0 then
    Exit(slmrFailed);
  if BytesRead < 0 then
  begin
    if fpGetErrNo in [ESysEAGAIN, ESysEINTR] then
      Exit(slmrTimeout);
    Exit(slmrFailed);
  end;

  Result := slmrTimeout;
  Offset := 0;
  while Offset + InotifyEventHeaderSize <= SizeUInt(BytesRead) do
  begin
    Event := PInotify_event(@Buffer[Offset]);
    if (Event^.mask and IN_Q_OVERFLOW) <> 0 then
      Result := slmrOverflow;
    if (Event^.mask and (IN_IGNORED or IN_DELETE_SELF or IN_MOVE_SELF)) <> 0 then
      Exit(slmrFailed);

    if (Event^.len > 0) and
      (Offset + InotifyEventHeaderSize + Event^.len <= SizeUInt(BytesRead)) then
    begin
      NameLength := Event^.len;
      while (NameLength > 0) and
        (Buffer[Offset + InotifyEventHeaderSize + NameLength - 1] = 0) do
        Dec(NameLength);
      SetString(
        Name,
        PChar(@Buffer[Offset + InotifyEventHeaderSize]),
        NameLength
      );
      DevicePath := '/dev/' + Name;
      if MatchesLinuxSerialDevicePattern(DevicePath) then
        Result := slmrChanged;
    end;
    Inc(Offset, InotifyEventHeaderSize + Event^.len);
  end;
end;

function CreateLinuxSerialChangeSource: TSerialChangeSource;
begin
  Result := TSerialFallbackChangeSource.Create([
    TSerialLinuxMonitorChangeSource.Create(TSerialUdevMonitorDriver.Create),
    TSerialLinuxMonitorChangeSource.Create(TSerialInotifyMonitorDriver.Create),
    TSerialPollingChangeSource.Create(1000)
  ]);
end;
{$ENDIF}

end.
