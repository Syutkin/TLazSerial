unit SerialLinuxChangeSourceTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, FpcUnit, TestRegistry, SerialWatcherSupport
  {$IFDEF Linux}
  , SyncObjs, SerialLinuxChangeSource
  {$ENDIF};

type
  TFakeFallbackChangeSource = class(TSerialChangeSource)
  private
    FFailOnStart: Boolean;
    FStartCount: Integer;
    FStopCount: Integer;
  protected
    procedure DoStart; override;
    procedure DoStop; override;
  public
    procedure SignalChanged;
    procedure SignalFailed;
    property FailOnStart: Boolean read FFailOnStart write FFailOnStart;
    property StartCount: Integer read FStartCount;
    property StopCount: Integer read FStopCount;
  end;

  TChangeObserver = class
  private
    FChangedCount: Integer;
    FFailedCount: Integer;
  public
    procedure Changed(Sender: TObject);
    procedure Failed(Sender: TObject);
    property ChangedCount: Integer read FChangedCount;
    property FailedCount: Integer read FFailedCount;
  end;

  {$IFDEF Linux}
  TFakeLinuxMonitorDriver = class(TSerialLinuxMonitorDriver)
  private
    FEvent: TEvent;
    FNextResult: TSerialLinuxMonitorResult;
    FStartCount: Integer;
    FStartResult: Boolean;
    FStopCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    function Start: Boolean; override;
    procedure Stop; override;
    function WaitForEvent(
      const ATimeoutMs: Cardinal
    ): TSerialLinuxMonitorResult; override;
    procedure Signal(const AResult: TSerialLinuxMonitorResult);
    property StartCount: Integer read FStartCount;
    property StartResult: Boolean read FStartResult write FStartResult;
    property StopCount: Integer read FStopCount;
  end;
  {$ENDIF}

  TSerialLinuxChangeSourceTests = class(TTestCase)
  published
    procedure SelectsFirstAvailableCandidate;
    procedure RuntimeFailureStartsNextCandidateAndRequestsRefresh;
    procedure StopReleasesActiveCandidate;
    {$IFDEF Linux}
    procedure OverflowRequestsFullRefresh;
    procedure RuntimeMonitorFailureFallsBackAndReleasesDriver;
    procedure StopWaitsForMonitorAndReleasesDriver;
    {$ENDIF}
  end;

implementation

procedure TFakeFallbackChangeSource.DoStart;
begin
  Inc(FStartCount);
  if FFailOnStart then
    raise EInvalidOperation.Create('Unavailable test source');
end;

procedure TFakeFallbackChangeSource.DoStop;
begin
  Inc(FStopCount);
end;

procedure TFakeFallbackChangeSource.SignalChanged;
begin
  Changed;
end;

procedure TFakeFallbackChangeSource.SignalFailed;
begin
  Failed;
end;

procedure TChangeObserver.Changed(Sender: TObject);
begin
  Inc(FChangedCount);
end;

procedure TChangeObserver.Failed(Sender: TObject);
begin
  Inc(FFailedCount);
end;

{$IFDEF Linux}
constructor TFakeLinuxMonitorDriver.Create;
begin
  inherited Create;
  FEvent := TEvent.Create(nil, True, False, '');
  FNextResult := slmrTimeout;
  FStartResult := True;
end;

destructor TFakeLinuxMonitorDriver.Destroy;
begin
  FEvent.Free;
  inherited Destroy;
end;

function TFakeLinuxMonitorDriver.Start: Boolean;
begin
  Inc(FStartCount);
  Result := FStartResult;
end;

procedure TFakeLinuxMonitorDriver.Stop;
begin
  Inc(FStopCount);
  FEvent.SetEvent;
end;

function TFakeLinuxMonitorDriver.WaitForEvent(
  const ATimeoutMs: Cardinal
): TSerialLinuxMonitorResult;
begin
  if FEvent.WaitFor(ATimeoutMs) <> wrSignaled then
    Exit(slmrTimeout);
  FEvent.ResetEvent;
  Result := FNextResult;
end;

procedure TFakeLinuxMonitorDriver.Signal(
  const AResult: TSerialLinuxMonitorResult
);
begin
  FNextResult := AResult;
  FEvent.SetEvent;
end;
{$ENDIF}

procedure TSerialLinuxChangeSourceTests.SelectsFirstAvailableCandidate;
var
  First: TFakeFallbackChangeSource;
  Observer: TChangeObserver;
  Second: TFakeFallbackChangeSource;
  Source: TSerialFallbackChangeSource;
  Third: TFakeFallbackChangeSource;
begin
  First := TFakeFallbackChangeSource.Create;
  First.FailOnStart := True;
  Second := TFakeFallbackChangeSource.Create;
  Third := TFakeFallbackChangeSource.Create;
  Observer := TChangeObserver.Create;
  Source := TSerialFallbackChangeSource.Create([First, Second, Third]);
  try
    Source.Start(@Observer.Changed, @Observer.Failed);

    AssertEquals(1, Source.CurrentIndex);
    AssertEquals(1, First.StartCount);
    AssertEquals(1, Second.StartCount);
    AssertEquals(0, Third.StartCount);
    AssertTrue(Second.Active);
  finally
    Source.Free;
    Observer.Free;
  end;
end;

procedure TSerialLinuxChangeSourceTests.
  RuntimeFailureStartsNextCandidateAndRequestsRefresh;
var
  First: TFakeFallbackChangeSource;
  Observer: TChangeObserver;
  Second: TFakeFallbackChangeSource;
  Source: TSerialFallbackChangeSource;
begin
  First := TFakeFallbackChangeSource.Create;
  Second := TFakeFallbackChangeSource.Create;
  Observer := TChangeObserver.Create;
  Source := TSerialFallbackChangeSource.Create([First, Second]);
  try
    Source.Start(@Observer.Changed, @Observer.Failed);
    First.SignalFailed;

    AssertEquals(1, Source.CurrentIndex);
    AssertEquals(1, First.StopCount);
    AssertEquals(1, Second.StartCount);
    AssertEquals(1, Observer.ChangedCount);
    AssertEquals(0, Observer.FailedCount);
  finally
    Source.Free;
    Observer.Free;
  end;
end;

procedure TSerialLinuxChangeSourceTests.StopReleasesActiveCandidate;
var
  Candidate: TFakeFallbackChangeSource;
  Observer: TChangeObserver;
  Source: TSerialFallbackChangeSource;
begin
  Candidate := TFakeFallbackChangeSource.Create;
  Observer := TChangeObserver.Create;
  Source := TSerialFallbackChangeSource.Create([Candidate]);
  try
    Source.Start(@Observer.Changed, @Observer.Failed);
    Source.Stop;

    AssertEquals(1, Candidate.StopCount);
    AssertFalse(Candidate.Active);
    AssertEquals(-1, Source.CurrentIndex);
  finally
    Source.Free;
    Observer.Free;
  end;
end;

{$IFDEF Linux}
procedure TSerialLinuxChangeSourceTests.OverflowRequestsFullRefresh;
var
  Deadline: QWord;
  Driver: TFakeLinuxMonitorDriver;
  Observer: TChangeObserver;
  Source: TSerialLinuxMonitorChangeSource;
begin
  Driver := TFakeLinuxMonitorDriver.Create;
  Observer := TChangeObserver.Create;
  Source := TSerialLinuxMonitorChangeSource.Create(Driver, False);
  try
    Source.Start(@Observer.Changed, @Observer.Failed);
    Driver.Signal(slmrOverflow);

    Deadline := GetTickCount64 + 1000;
    repeat
      CheckSynchronize(10);
    until (Observer.ChangedCount > 0) or (GetTickCount64 >= Deadline);

    AssertEquals(1, Observer.ChangedCount);
    AssertEquals(0, Observer.FailedCount);
    AssertTrue(Source.Active);
  finally
    Source.Free;
    Observer.Free;
    Driver.Free;
  end;
end;

procedure TSerialLinuxChangeSourceTests.
  RuntimeMonitorFailureFallsBackAndReleasesDriver;
var
  Backup: TFakeFallbackChangeSource;
  Deadline: QWord;
  Driver: TFakeLinuxMonitorDriver;
  Monitor: TSerialLinuxMonitorChangeSource;
  Observer: TChangeObserver;
  Source: TSerialFallbackChangeSource;
begin
  Driver := TFakeLinuxMonitorDriver.Create;
  Monitor := TSerialLinuxMonitorChangeSource.Create(Driver, False);
  Backup := TFakeFallbackChangeSource.Create;
  Observer := TChangeObserver.Create;
  Source := TSerialFallbackChangeSource.Create([Monitor, Backup]);
  try
    Source.Start(@Observer.Changed, @Observer.Failed);
    Driver.Signal(slmrFailed);

    Deadline := GetTickCount64 + 1000;
    repeat
      CheckSynchronize(10);
    until (Source.CurrentIndex = 1) or (GetTickCount64 >= Deadline);

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

procedure TSerialLinuxChangeSourceTests.StopWaitsForMonitorAndReleasesDriver;
var
  Driver: TFakeLinuxMonitorDriver;
  Observer: TChangeObserver;
  Source: TSerialLinuxMonitorChangeSource;
begin
  Driver := TFakeLinuxMonitorDriver.Create;
  Observer := TChangeObserver.Create;
  Source := TSerialLinuxMonitorChangeSource.Create(Driver, False);
  try
    Source.Start(@Observer.Changed, @Observer.Failed);
    Source.Stop;

    AssertEquals(1, Driver.StartCount);
    AssertEquals(1, Driver.StopCount);
    AssertFalse(Source.Active);
  finally
    Source.Free;
    Observer.Free;
    Driver.Free;
  end;
end;
{$ENDIF}

initialization
  RegisterTest(TSerialLinuxChangeSourceTests);

end.
