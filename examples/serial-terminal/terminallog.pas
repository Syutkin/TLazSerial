unit TerminalLog;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, SyncObjs;

type
  // An example-owned bounded writer. No UI or serial objects cross threads.
  TTerminalFileLog = class(TThread)
  private
    FStream: TFileStream;
    FLock: TCriticalSection;
    FWake: TEvent;
    FQueue: TStringList;
    FPendingBytes: SizeInt;
    FStopping: Boolean;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    function Append(const ALine: string): Boolean;
    procedure RequestStop;
    function ErrorMessage: string;
  end;

implementation

const MaxLogBytes = 1024 * 1024;

constructor TTerminalFileLog.Create(const AFileName: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FQueue := TStringList.Create;
  FStream := TFileStream.Create(AFileName, fmCreate);
end;

destructor TTerminalFileLog.Destroy;
begin
  if FLock <> nil then RequestStop;
  // Normal UI stopping polls Finished before freeing. At application exit,
  // drain accepted records before closing the file.
  // TThread.Destroy also starts/joins a suspended thread if construction or
  // Start failed. Keep every worker resource alive until that join finishes.
  inherited Destroy;
  FStream.Free;
  FQueue.Free;
  FWake.Free;
  FLock.Free;
end;

function TTerminalFileLog.Append(const ALine: string): Boolean;
var Line: string;
begin
  Line := ALine + LineEnding;
  FLock.Acquire;
  try
    Result := not FStopping;
    if not Result then Exit;
    if Length(Line) > MaxLogBytes - FPendingBytes then
    begin
      FError := 'File log stopped: its 1 MiB write buffer is full.';
      FStopping := True;
      Result := False;
    end
    else
    begin
      FQueue.Add(Line);
      Inc(FPendingBytes, Length(Line));
    end;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TTerminalFileLog.RequestStop;
begin
  FLock.Acquire;
  try FStopping := True;
  finally FLock.Release; end;
  if FWake <> nil then FWake.SetEvent;
end;

function TTerminalFileLog.ErrorMessage: string;
begin
  FLock.Acquire;
  try Result := FError;
  finally FLock.Release; end;
end;

procedure TTerminalFileLog.Execute;
var Line: string; Done: Boolean;
begin
  if (FLock = nil) or (FWake = nil) or (FQueue = nil) or (FStream = nil) then Exit;
  try
    while True do
    begin
      Line := '';
      FLock.Acquire;
      try
        Done := FStopping and (FQueue.Count = 0);
        if FQueue.Count > 0 then
        begin
          Line := FQueue[0];
          FQueue.Delete(0);
        end;
      finally FLock.Release; end;
      if Done then Exit;
      if Line = '' then FWake.WaitFor(250)
      else
      begin
        FStream.WriteBuffer(Line[1], Length(Line));
        FLock.Acquire;
        try Dec(FPendingBytes, Length(Line));
        finally FLock.Release; end;
      end;
    end;
  except
    on E: Exception do
    begin
      FLock.Acquire;
      try
        FError := 'File log stopped: ' + E.Message;
        FStopping := True;
        FQueue.Clear;
        FPendingBytes := 0;
      finally FLock.Release; end;
    end;
  end;
end;

end.
