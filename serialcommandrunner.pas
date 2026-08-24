unit SerialCommandRunner;

{$mode ObjFPC}{$H+}

interface

function RunSerialCommand(
  const AExecutable: string;
  const AParameters: array of string;
  const ATimeoutMs: Cardinal;
  out AOutput: string
): Boolean;

implementation

uses
  Classes, Process, SysUtils;

const
  CommandPollIntervalMs = 10;
  MaxReadChunksPerPoll = 16;

type
  TOutputBuffer = array[0..8191] of Byte;

function CurrentThreadTerminated: Boolean;
begin
  Result := False;
  if GetCurrentThreadID = MainThreadID then
    Exit;
  try
    Result := TThread.CheckTerminated;
  except
    on E: EThreadExternalException do
      Result := False;
  end;
end;

procedure ReadAvailableOutput(AProcess: TProcess; var AOutput: string);
var
  Available: DWord;
  Buffer: TOutputBuffer;
  BytesRead: LongInt;
  ChunkCount: Integer;
  OldLength: SizeInt;
begin
  Buffer := Default(TOutputBuffer);
  ChunkCount := 0;
  repeat
    Available := AProcess.Output.NumBytesAvailable;
    if Available = 0 then
      Exit;
    if Available > SizeOf(Buffer) then
      Available := SizeOf(Buffer);
    BytesRead := AProcess.Output.Read(Buffer[0], Available);
    if BytesRead <= 0 then
      Exit;
    OldLength := Length(AOutput);
    SetLength(AOutput, OldLength + BytesRead);
    Move(Buffer[0], AOutput[OldLength + 1], BytesRead);
    Inc(ChunkCount);
  until ChunkCount >= MaxReadChunksPerPoll;
end;

function RunSerialCommand(
  const AExecutable: string;
  const AParameters: array of string;
  const ATimeoutMs: Cardinal;
  out AOutput: string
): Boolean;
var
  Cancelled: Boolean;
  I: Integer;
  ProcessInstance: TProcess;
  StartedAt: QWord;
  TimedOut: Boolean;
begin
  Result := False;
  AOutput := '';
  if ATimeoutMs = 0 then
    Exit;
  ProcessInstance := TProcess.Create(nil);
  try
    ProcessInstance.Executable := AExecutable;
    for I := Low(AParameters) to High(AParameters) do
      ProcessInstance.Parameters.Add(AParameters[I]);
    ProcessInstance.Options := [poUsePipes, poStderrToOutput];

    try
      ProcessInstance.Execute;
    except
      on E: Exception do
        Exit;
    end;

    StartedAt := GetTickCount64;
    Cancelled := False;
    TimedOut := False;
    while ProcessInstance.Running do
    begin
      ReadAvailableOutput(ProcessInstance, AOutput);
      Cancelled := CurrentThreadTerminated;
      TimedOut := GetTickCount64 - StartedAt >= ATimeoutMs;
      if Cancelled or TimedOut then
      begin
        ProcessInstance.Terminate(1);
        if ProcessInstance.Running then
          ProcessInstance.WaitOnExit(1000);
        Break;
      end;
      Sleep(CommandPollIntervalMs);
    end;
    ReadAvailableOutput(ProcessInstance, AOutput);
    Result := not Cancelled and not TimedOut and
      (ProcessInstance.ExitStatus = 0);
  finally
    ProcessInstance.Free;
  end;
end;

end.
