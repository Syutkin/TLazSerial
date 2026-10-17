unit ConsoleCommon;

{$mode ObjFPC}{$H+}

interface

function SelectSerialPort: string;
function TryReadConsoleLine(var AInput: string; out ALine: string): Boolean;
procedure ConsoleMessage(const AMessage, AInput: string);

implementation

uses
  SysUtils, Crt, LazSerialDevices;

function SelectSerialPort: string;
var
  Devices: TSerialDeviceInfoArray;
  I, Choice: Integer;
  Answer: string;
begin
  Result := '';
  if ParamCount > 0 then
  begin
    if (ParamStr(1) = '--help') or (ParamStr(1) = '-h') then
      WriteLn('Usage: ', ExtractFileName(ParamStr(0)), ' [serial-port]')
    else Result := ParamStr(1);
    Exit;
  end;

  try
    Devices := GetSerialDevices;
  except
    on E: Exception do
    begin
      WriteLn('Cannot list ports: ', E.Message);
      Devices := nil;
    end;
  end;
  for I := 0 to High(Devices) do
    WriteLn(I + 1, '. ', FormatSerialDeviceDisplayName(Devices[I]));
  if Length(Devices) = 0 then WriteLn('No serial ports found.');
  repeat
    Write('Port number or device path/name (empty to quit): ');
    ReadLn(Answer);
    Answer := Trim(Answer);
    if Answer = '' then Exit;
    if not TryStrToInt(Answer, Choice) then Exit(Answer);
    if (Choice >= 1) and (Choice <= Length(Devices)) then
      Exit(Devices[Choice - 1].Device);
    WriteLn('Choose a listed number or enter a device such as COM3 or /dev/ttyUSB0.');
  until False;
end;

function TryReadConsoleLine(var AInput: string; out ALine: string): Boolean;
var
  Key: Char;
begin
  Result := False;
  ALine := '';
  { Polling the keyboard keeps the main thread available for CheckSynchronize.
    A blocking ReadLn here would prevent receive/completion event delivery. }
  while KeyPressed do
  begin
    Key := ReadKey;
    case Key of
      #0: ReadKey; // Ignore function and cursor keys.
      #3, #27: begin ALine := '/quit'; WriteLn; Exit(True); end;
      #13: begin ALine := AInput; AInput := ''; WriteLn; Exit(True); end;
      #8, #127:
        if AInput <> '' then
        begin
          Delete(AInput, Length(AInput), 1);
          Write(#8' '#8);
        end;
      #32..#126, #128..#255: begin AInput := AInput + Key; Write(Key); end;
    end;
  end;
end;

procedure ConsoleMessage(const AMessage, AInput: string);
begin
  Write(#13);
  ClrEol;
  WriteLn(AMessage);
  Write('> ', AInput);
end;

initialization
  CheckBreak := False; // Handle Ctrl+C in the loop so the port is closed.
end.
