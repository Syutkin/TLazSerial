program BufferedSerialConsole;

{$mode ObjFPC}{$H+}

uses
  {$IFDEF UNIX}CThreads,{$ENDIF}
  Interfaces, Forms, Classes, SysUtils, LazSerial, LazSerialCommon,
  ConsoleCommon;

type
  TSerialConsole = class
  private
    FSerial: TLazSerial;
    FInput: string;
    FClosed: Boolean;
    procedure CloseCompleted(Sender: TObject);
    procedure Received(Sender: TObject);
    procedure WriteCompleted(Sender: TObject; const AResult: TSerialWriteResult);
    procedure Failed(Sender: TObject; Code: Integer; const Message: string);
  public
    procedure Run(const ADevice: string);
  end;

procedure TSerialConsole.Received(Sender: TObject);
var
  Data: string;
begin
  // Memory-only reads; packet boundaries need not match writes.
  while FSerial.TryReadData(Data) do ConsoleMessage('RX: ' + Data, FInput);
end;

procedure TSerialConsole.WriteCompleted(Sender: TObject;
  const AResult: TSerialWriteResult);
const
  OutcomeNames: array[TSerialWriteOutcome] of string =
    ('completed', 'failed', 'cancelled', 'timed out');
begin
  ConsoleMessage(Format('TX %d %s: %d/%d bytes',
    [AResult.OperationId, OutcomeNames[AResult.Outcome],
     AResult.BytesWritten, AResult.BytesRequested]), FInput);
  if AResult.ErrorCode <> 0 then
    ConsoleMessage('Write error: ' + AResult.ErrorMessage, FInput);
end;

procedure TSerialConsole.CloseCompleted(Sender: TObject);
begin
  FClosed := True;
end;

procedure TSerialConsole.Failed(Sender: TObject; Code: Integer;
  const Message: string);
begin
  ConsoleMessage(Format('Port error %d: %s', [Code, Message]), FInput);
  ExitCode := 1;
end;

procedure TSerialConsole.Run(const ADevice: string);
var
  Line: string;
begin
  FSerial := TLazSerial.Create(nil);
  try
    FSerial.Device := ADevice;
    FSerial.BaudRate := br115200;
    FSerial.DataBits := db8bits;
    FSerial.Parity := pNone;
    FSerial.StopBits := sbOne;
    FSerial.FlowControl := fcNone;
    FSerial.BufferedRead := True;
    FSerial.ReadBufferLimit := 65536;
    FSerial.RcvLineCRLF := False;
    FSerial.OnRxData := @Received;
    FSerial.OnWriteCompleted := @WriteCompleted;
    FSerial.OnError := @Failed;
    FSerial.OnCloseCompleted := @CloseCompleted;
    FSerial.Open;
    FClosed := False;
    WriteLn('Connected to ', ADevice, ' (115200 8N1, no flow control).');
    WriteLn('Enter sends a line with CRLF. /quit, Escape or Ctrl+C exits.');
    Write('> ');
    try
      while FSerial.Active do
      begin
        // Deliver receive and write-completion events while accepting input.
        CheckSynchronize(10);
        if not FSerial.Active then Break;
        if not TryReadConsoleLine(FInput, Line) then Continue;
        if Line = '/quit' then Break;
        if FSerial.WritePending then
          WriteLn('A write is still pending. Retry after its completion.')
        else FSerial.WriteDataAsync(Line + #13#10, 1000);
        Write('> ');
      end;
    finally
      FSerial.Close; // Cancels pending input/output without a native I/O wait.
      // Keep event delivery running until shared native cleanup has finished.
      while not FClosed do CheckSynchronize(10);
    end;
  finally
    FSerial.Free;
  end;
end;

var
  Console: TSerialConsole;
  Device: string;
begin
  try
    Application.Initialize; // LCL dependency; no forms or GUI loop are needed.
    Device := SelectSerialPort;
    if Device = '' then Exit;
    Console := TSerialConsole.Create;
    try
      Console.Run(Device);
    finally
      Console.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn('Error: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
