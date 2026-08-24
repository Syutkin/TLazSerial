unit SerialWatcherSupport;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, ExtCtrls;

type
  TSerialChangeSource = class
  private
    FActive: Boolean;
    FOnChanged: TNotifyEvent;
  protected
    procedure Changed;
    procedure DoStart; virtual; abstract;
    procedure DoStop; virtual; abstract;
  public
    destructor Destroy; override;
    procedure Start(const AOnChanged: TNotifyEvent);
    procedure Stop;
    property Active: Boolean read FActive;
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

procedure TSerialChangeSource.Changed;
begin
  if FActive and Assigned(FOnChanged) then
    FOnChanged(Self);
end;

procedure TSerialChangeSource.Start(const AOnChanged: TNotifyEvent);
begin
  if FActive then
    Exit;

  FOnChanged := AOnChanged;
  FActive := True;
  try
    DoStart;
  except
    FActive := False;
    FOnChanged := nil;
    raise;
  end;
end;

procedure TSerialChangeSource.Stop;
begin
  if not FActive then
  begin
    FOnChanged := nil;
    Exit;
  end;

  FActive := False;
  try
    DoStop;
  finally
    FOnChanged := nil;
  end;
end;

destructor TSerialChangeSource.Destroy;
begin
  Stop;
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
