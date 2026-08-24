unit SerialWatcherSupport;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, Contnrs, ExtCtrls, SysUtils;

type
  TSerialChangeSource = class
  private
    FActive: Boolean;
    FOnChanged: TNotifyEvent;
    FOnFailed: TNotifyEvent;
  protected
    procedure Changed;
    procedure Failed;
    procedure DoStart; virtual; abstract;
    procedure DoStop; virtual; abstract;
    function GetRequiresSettling: Boolean; virtual;
  public
    destructor Destroy; override;
    procedure Start(
      const AOnChanged: TNotifyEvent;
      const AOnFailed: TNotifyEvent = nil
    );
    procedure Stop;
    property Active: Boolean read FActive;
    property RequiresSettling: Boolean read GetRequiresSettling;
  end;

  TSerialFallbackChangeSource = class(TSerialChangeSource)
  private
    FCandidates: TObjectList;
    FCurrentIndex: Integer;
    procedure CandidateChanged(Sender: TObject);
    procedure CandidateFailed(Sender: TObject);
    function CurrentSource: TSerialChangeSource;
    procedure StartNextCandidate;
  protected
    procedure DoStart; override;
    procedure DoStop; override;
    function GetRequiresSettling: Boolean; override;
  public
    constructor Create(const ACandidates: array of TSerialChangeSource);
    destructor Destroy; override;
    property CurrentIndex: Integer read FCurrentIndex;
  end;

  TSerialManualChangeSource = class(TSerialChangeSource)
  protected
    procedure DoStart; override;
    procedure DoStop; override;
  end;

  TSerialPollingChangeSource = class(TSerialChangeSource)
  private
    FTimer: TTimer;
    procedure TimerElapsed(Sender: TObject);
  protected
    procedure DoStart; override;
    procedure DoStop; override;
  public
    constructor Create(const AIntervalMs: Cardinal);
    destructor Destroy; override;
  end;

  TSerialRefreshScheduler = class
  private
    FCallback: TNotifyEvent;
    FScheduled: Boolean;
  protected
    procedure DoCancel; virtual; abstract;
    procedure DoSchedule(const ADelayMs: Cardinal); virtual; abstract;
    procedure RunScheduled;
  public
    destructor Destroy; override;
    procedure Cancel;
    procedure Schedule(
      const ADelayMs: Cardinal;
      const ACallback: TNotifyEvent
    );
    property Scheduled: Boolean read FScheduled;
  end;

  TSerialTimerScheduler = class(TSerialRefreshScheduler)
  private
    FTimer: TTimer;
    procedure TimerElapsed(Sender: TObject);
  protected
    procedure DoCancel; override;
    procedure DoSchedule(const ADelayMs: Cardinal); override;
  public
    constructor Create;
    destructor Destroy; override;
  end;

implementation

function TSerialChangeSource.GetRequiresSettling: Boolean;
begin
  Result := False;
end;

procedure TSerialChangeSource.Changed;
begin
  if FActive and Assigned(FOnChanged) then
    FOnChanged(Self);
end;

procedure TSerialChangeSource.Failed;
begin
  if FActive and Assigned(FOnFailed) then
    FOnFailed(Self);
end;

procedure TSerialChangeSource.Start(
  const AOnChanged: TNotifyEvent;
  const AOnFailed: TNotifyEvent
);
begin
  if FActive then
    Exit;

  FOnChanged := AOnChanged;
  FOnFailed := AOnFailed;
  FActive := True;
  try
    DoStart;
  except
    FActive := False;
    FOnChanged := nil;
    FOnFailed := nil;
    raise;
  end;
end;

procedure TSerialChangeSource.Stop;
begin
  if not FActive then
  begin
    FOnChanged := nil;
    FOnFailed := nil;
    Exit;
  end;

  FActive := False;
  try
    DoStop;
  finally
    FOnChanged := nil;
    FOnFailed := nil;
  end;
end;

destructor TSerialChangeSource.Destroy;
begin
  Stop;
  inherited Destroy;
end;

constructor TSerialFallbackChangeSource.Create(
  const ACandidates: array of TSerialChangeSource
);
var
  Candidate: TSerialChangeSource;
begin
  inherited Create;
  FCandidates := TObjectList.Create(True);
  FCurrentIndex := -1;
  for Candidate in ACandidates do
  begin
    if Candidate = nil then
      raise EArgumentNilException.Create('ACandidates');
    FCandidates.Add(Candidate);
  end;
  if FCandidates.Count = 0 then
    raise EArgumentException.Create('At least one change source is required');
end;

function TSerialFallbackChangeSource.CurrentSource: TSerialChangeSource;
begin
  if (FCurrentIndex < 0) or (FCurrentIndex >= FCandidates.Count) then
    Exit(nil);
  Result := TSerialChangeSource(FCandidates[FCurrentIndex]);
end;

function TSerialFallbackChangeSource.GetRequiresSettling: Boolean;
var
  Source: TSerialChangeSource;
begin
  Source := CurrentSource;
  Result := (Source <> nil) and Source.RequiresSettling;
end;

procedure TSerialFallbackChangeSource.CandidateChanged(Sender: TObject);
begin
  if Sender = CurrentSource then
    Changed;
end;

procedure TSerialFallbackChangeSource.CandidateFailed(Sender: TObject);
var
  Source: TSerialChangeSource;
begin
  if Sender <> CurrentSource then
    Exit;

  Source := CurrentSource;
  if Source <> nil then
    Source.Stop;
  Inc(FCurrentIndex);
  StartNextCandidate;
  Changed;
end;

procedure TSerialFallbackChangeSource.StartNextCandidate;
var
  Source: TSerialChangeSource;
begin
  while FCurrentIndex < FCandidates.Count do
  begin
    Source := CurrentSource;
    try
      Source.Start(@CandidateChanged, @CandidateFailed);
      Exit;
    except
      Source.Stop;
      Inc(FCurrentIndex);
    end;
  end;
  raise EInvalidOperation.Create('No serial change source is available');
end;

procedure TSerialFallbackChangeSource.DoStart;
begin
  FCurrentIndex := 0;
  StartNextCandidate;
end;

procedure TSerialFallbackChangeSource.DoStop;
var
  Source: TSerialChangeSource;
begin
  Source := CurrentSource;
  if Source <> nil then
    Source.Stop;
  FCurrentIndex := -1;
end;

destructor TSerialFallbackChangeSource.Destroy;
begin
  Stop;
  FCandidates.Free;
  inherited Destroy;
end;

procedure TSerialManualChangeSource.DoStart;
begin
end;

procedure TSerialManualChangeSource.DoStop;
begin
end;

constructor TSerialPollingChangeSource.Create(const AIntervalMs: Cardinal);
begin
  inherited Create;
  FTimer := TTimer.Create(nil);
  FTimer.Enabled := False;
  if AIntervalMs = 0 then
    FTimer.Interval := 1
  else
    FTimer.Interval := AIntervalMs;
  FTimer.OnTimer := @TimerElapsed;
end;

procedure TSerialPollingChangeSource.DoStart;
begin
  FTimer.Enabled := True;
end;

procedure TSerialPollingChangeSource.DoStop;
begin
  FTimer.Enabled := False;
end;

procedure TSerialPollingChangeSource.TimerElapsed(Sender: TObject);
begin
  Changed;
end;

destructor TSerialPollingChangeSource.Destroy;
begin
  Stop;
  FTimer.Free;
  inherited Destroy;
end;

procedure TSerialRefreshScheduler.Schedule(
  const ADelayMs: Cardinal;
  const ACallback: TNotifyEvent
);
begin
  Cancel;
  if not Assigned(ACallback) then
    Exit;

  FCallback := ACallback;
  FScheduled := True;
  try
    DoSchedule(ADelayMs);
  except
    FScheduled := False;
    FCallback := nil;
    raise;
  end;
end;

procedure TSerialRefreshScheduler.Cancel;
begin
  if not FScheduled then
  begin
    FCallback := nil;
    Exit;
  end;

  FScheduled := False;
  try
    DoCancel;
  finally
    FCallback := nil;
  end;
end;

procedure TSerialRefreshScheduler.RunScheduled;
var
  Callback: TNotifyEvent;
begin
  if not FScheduled then
    Exit;

  Callback := FCallback;
  FScheduled := False;
  FCallback := nil;
  DoCancel;
  if Assigned(Callback) then
    Callback(Self);
end;

destructor TSerialRefreshScheduler.Destroy;
begin
  Cancel;
  inherited Destroy;
end;

constructor TSerialTimerScheduler.Create;
begin
  inherited Create;
  FTimer := TTimer.Create(nil);
  FTimer.Enabled := False;
  FTimer.OnTimer := @TimerElapsed;
end;

procedure TSerialTimerScheduler.DoCancel;
begin
  FTimer.Enabled := False;
end;

procedure TSerialTimerScheduler.DoSchedule(const ADelayMs: Cardinal);
begin
  FTimer.Enabled := False;
  if ADelayMs = 0 then
    FTimer.Interval := 1
  else
    FTimer.Interval := ADelayMs;
  FTimer.Enabled := True;
end;

procedure TSerialTimerScheduler.TimerElapsed(Sender: TObject);
begin
  RunScheduled;
end;

destructor TSerialTimerScheduler.Destroy;
begin
  Cancel;
  FTimer.Free;
  inherited Destroy;
end;

end.
