program LegacySerialConsole;

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
    procedure Received(Sender: TObject);
  public
    procedure Run(const ADevice: string);
  end;

procedure TSerialConsole.Received(Sender: TObject);
var
  Data: string;
begin
  { Packet reads return available bytes, not necessarily a complete message. }
  while FSerial.DataAvailable do
  begin
    Data := FSerial.ReadData;
    if Data = '' then Break;
    ConsoleMessage('RX: ' + Data, FInput);
  end;
end;

procedure TSerialConsole.Run(const ADevice: string);
var
  Line, Data: string;
  Count: Integer;
begin
  FSerial := TLazSerial.Create(nil);
  try
    FSerial.Device := ADevice;
    FSerial.BaudRate := br115200;
    FSerial.DataBits := db8bits;
    FSerial.Parity := pNone;
    FSerial.StopBits := sbOne;
    FSerial.FlowControl := fcNone;
    FSerial.RcvLineCRLF := False;
    FSerial.OnRxData := @Received;
    FSerial.SynSer.DeadlockTimeout := 1000;
    FSerial.Open;
    FSerial.SynSer.RaiseExcept := True;
    WriteLn('Connected to ', ADevice, ' (115200 8N1, no flow control).');
    WriteLn('Enter sends a line with CRLF. /quit, Escape or Ctrl+C exits.');
    Write('> ');
    while FSerial.Active do
    begin
      // TLazSerial and its callbacks stay on the main thread.
      CheckSynchronize(10);
      if not FSerial.Active then Break;
      if not TryReadConsoleLine(FInput, Line) then Continue;
      if Line = '/quit' then Break;
      Data := Line + #13#10;
      Count := FSerial.WriteData(Data); // May block until completion or timeout.
      if Count <> Length(Data) then
        WriteLn('Write incomplete: ', Count, '/', Length(Data), ' bytes.');
      Write('> ');
    end;
    if not FSerial.Active then
    begin
      WriteLn('The port was closed after a receive error or disconnection.');
      ExitCode := 1;
    end;
  finally
    FSerial.SynSer.RaiseExcept := False;
    try
      FSerial.Close;
    finally
      FSerial.Free;
    end;
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
