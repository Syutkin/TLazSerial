unit TerminalMain;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls, LCLType,
  LazSerial, LazSerialCommon, LazSerialStatistics, SerialSelector,
  TerminalView, TerminalLog;

type
  TPendingCommand = record
    Id: QWord;
    Data: AnsiString;
  end;

  TTerminalForm = class(TForm)
    BottomPanel, ViewPanel, FTools, FSendPanel, FSettingsPanel: TPanel;
    FConnect, FSettings, FPause, FClear, FLogButton, FSend: TPanel;
    FViewMode, FSendMode, FEnding, FDataBits, FParity, FStopBits,
      FFlow, FDtr, FRts: TComboBox;
    FDevice: TSerialSelector;
    FBaud, FSendText, FTimeout: TEdit;
    FAutoReconnect: TCheckBox;
    FFeedback, FLogLabel, TitleLabel, SubtitleLabel, ConnectionLabel,
      StateLabel, ModeLabel, RatesLabel, BufferLabel, DetailLabel,
      SettingsTitle, DeviceLabel, BaudLabel, DataLabel, ParityLabel,
      StopLabel, FlowLabel, DtrLabel, RtsLabel, TimeoutLabel: TLabel;
    ViewBackground: TPaintBox;
    ExchangeMemo: TMemo;
    FTimer: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ButtonPaint(Sender: TObject);
    procedure ButtonFocusChanged(Sender: TObject);
    procedure ButtonMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure ConnectClick(Sender: TObject);
    procedure SettingsClick(Sender: TObject);
    procedure PauseClick(Sender: TObject);
    procedure ClearClick(Sender: TObject);
    procedure LogClick(Sender: TObject);
    procedure SendClick(Sender: TObject);
    procedure ModeChanged(Sender: TObject);
    procedure SendKeyPress(Sender: TObject; var Key: Char);
    procedure Tick(Sender: TObject);
    procedure DeviceChanged(Sender: TObject);
  private
    FSerial: TLazSerial;
    FView: TTerminalView;
    FFileLog: TTerminalFileLog;
    FLogStopping: Boolean;
    FLogName, FLogError, FProblem: string;
    FPending: array of TPendingCommand;
    FPrevious: TSerialStatistics;
    FSampleTime: QWord;
    FReceiveRate, FSendRate: Double;
    procedure UpdateControls;
    procedure SampleStatistics;
    procedure ResetRates;
    function ConnectionDescription: string;
    procedure Info(const AText: string);
    procedure Problem(const AText: string);
    procedure FileRecord(const AKind, AText: string);
    procedure AbandonPending;
    procedure Receive(Sender: TObject);
    procedure WriteCompleted(Sender: TObject; const AResult: TSerialWriteResult);
    procedure ReadError(Sender: TObject; ErrorCode: Integer; const ErrorMessage: string);
    procedure Removed(Sender: TObject);
    procedure CloseCompleted(Sender: TObject);
    procedure Reconnected(Sender: TObject);
    procedure ReconnectFailed(Sender: TObject; ErrorCode: Integer; const ErrorMessage: string);
  end;

var TerminalForm: TTerminalForm;

implementation

{$R *.lfm}

procedure TTerminalForm.FormCreate(Sender: TObject);
var Settings: TSerialSettings;
begin
  FView := TTerminalView.Create(ViewBackground, ExchangeMemo, ConnectionLabel,
    StateLabel, ModeLabel, RatesLabel, BufferLabel, DetailLabel);
  {$IFDEF MSWINDOWS}ExchangeMemo.Font.Name := 'Consolas';{$ENDIF}
  FSerial := TLazSerial.Create(Self);
  Settings := FSerial.GetSettings;
  Settings.BaudRate := br115200;
  Settings.CustomBaudRate := -1;
  Settings.DataBits := db8bits;
  Settings.Parity := pNone;
  Settings.StopBits := sbOne;
  Settings.FlowControl := fcNone;
  FSerial.ApplySettings(Settings);
  FSerial.BufferedRead := True;
  FSerial.RcvLineCRLF := False;
  FSerial.WriteQueueEnabled := True;
  FSerial.OnRxData := @Receive;
  FSerial.OnWriteCompleted := @WriteCompleted;
  FSerial.OnError := @ReadError;
  FSerial.OnRemoved := @Removed;
  FSerial.OnCloseCompleted := @CloseCompleted;
  FSerial.OnReconnected := @Reconnected;
  FSerial.OnReconnectFailed := @ReconnectFailed;
  if ParamCount > 0 then FDevice.Device := ParamStr(1);
  FDevice.Refresh;
  FTimer.Enabled := True;
  ResetRates;
  UpdateControls;
  SampleStatistics;
end;

procedure TTerminalForm.FormDestroy(Sender: TObject);
begin
  if FTimer <> nil then FTimer.Enabled := False;
  if FSerial <> nil then
  begin
    FSerial.OnRxData := nil;
    FSerial.OnWriteCompleted := nil;
    FSerial.OnError := nil;
    FSerial.OnRemoved := nil;
    FSerial.OnCloseCompleted := nil;
    FSerial.OnReconnected := nil;
    FSerial.OnReconnectFailed := nil;
    AbandonPending;
    FreeAndNil(FSerial);
  end;
  if FFileLog <> nil then
  begin
    FFileLog.RequestStop;
    FFileLog.WaitFor;
    FreeAndNil(FFileLog);
  end;
  FreeAndNil(FView);
end;

procedure TTerminalForm.ButtonPaint(Sender: TObject);
begin
  PaintTerminalButton(TPanel(Sender), (Sender = FConnect) or (Sender = FSend));
end;

procedure TTerminalForm.ButtonFocusChanged(Sender: TObject);
begin
  TPanel(Sender).Invalidate;
end;

procedure TTerminalForm.ButtonMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if (Button = mbLeft) and TPanel(Sender).CanFocus then TPanel(Sender).SetFocus;
end;

procedure TTerminalForm.FormKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
var Button: TPanel;
begin
  if (Key in [VK_SPACE, VK_RETURN]) and (Shift = []) and
    ((ActiveControl = FConnect) or (ActiveControl = FSettings) or
     (ActiveControl = FPause) or (ActiveControl = FClear) or
     (ActiveControl = FLogButton) or (ActiveControl = FSend)) then
  begin
    Button := TPanel(ActiveControl);
    if Button.Enabled and Assigned(Button.OnClick) then Button.OnClick(Button);
    Key := 0;
  end;
end;

function TTerminalForm.ConnectionDescription: string;
var Settings: TSerialSettings; Device, Parity: string; Baud: Integer;
begin
  Settings := FSerial.GetSettings;
  if FSerial.Active or FSerial.ReconnectPending or FSerial.ClosePending then
    Device := FSerial.Device else Device := FDevice.Device;
  if Device = '' then Device := 'No device selected';
  if Settings.CustomBaudRate >= 0 then Baud := Settings.CustomBaudRate
  else Baud := ConstsBaud[Settings.BaudRate];
  Parity := 'NOEMS';
  Result := Format('%s ' + #$C2#$B7 + ' %d ' + #$C2#$B7 + ' %d%s%s',
    [Device, Baud, ConstsBits[Settings.DataBits], Parity[Ord(Settings.Parity) + 1],
     FStopBits.Items[Ord(Settings.StopBits)]]);
end;

procedure TTerminalForm.UpdateControls;
var Busy: Boolean; State: string; StateColor: TColor;
begin
  Busy := FSerial.Active or FSerial.ClosePending or FSerial.WritePending or
    FSerial.ReconnectPending;
  FDevice.Enabled := not Busy;
  FBaud.Enabled := not Busy;
  FDataBits.Enabled := not Busy;
  FParity.Enabled := not Busy;
  FStopBits.Enabled := not Busy;
  FFlow.Enabled := not Busy;
  FDtr.Enabled := not Busy;
  FRts.Enabled := not Busy;
  FAutoReconnect.Enabled := not Busy;
  FSend.Enabled := FSerial.Active and not FSerial.ClosePending;
  FEnding.Enabled := FSendMode.ItemIndex = 0;
  if FSerial.Active or FSerial.ReconnectPending then FConnect.Caption := 'Disconnect'
  else FConnect.Caption := 'Connect';
  FConnect.Enabled := FSerial.Active or FSerial.ReconnectPending or
    not (FSerial.ClosePending or FSerial.WritePending);
  if FSerial.ClosePending then begin State := 'Closing'; StateColor := TerminalAmber; end
  else if FSerial.Active then begin State := 'Connected'; StateColor := TerminalGreen; end
  else if FSerial.ReconnectPending then begin State := 'Reconnecting'; StateColor := TerminalAmber; end
  else begin State := 'Disconnected'; StateColor := TerminalMuted; end;
  FView.SetConnection(ConnectionDescription, State, StateColor);
  FFeedback.Caption := FProblem;
  FFeedback.Hint := FProblem;
  FFeedback.Font.Color := TerminalMuted;
  if FProblem <> '' then FFeedback.Font.Color := TerminalRed;
  FConnect.Invalidate;
  FSend.Invalidate;
end;

procedure TTerminalForm.ResetRates;
begin
  FPrevious := FSerial.Statistics;
  FSampleTime := GetTickCount64;
  FReceiveRate := 0;
  FSendRate := 0;
end;

procedure TTerminalForm.SampleStatistics;
const CloseReasons: array[TSerialCloseReason] of string =
  ('', 'user request', 'device removed', 'read error', 'configuration error', 'destroyed');
var Stats: TSerialStatistics; Stamp, Elapsed: QWord; Detail: string; Usage: Double;
begin
  Stats := FSerial.Statistics;
  Stamp := GetTickCount64;
  Elapsed := Stamp - FSampleTime;
  if (Elapsed > 0) and (Stats.BytesReceived >= FPrevious.BytesReceived) and
    (Stats.BytesSent >= FPrevious.BytesSent) then
  begin
    FReceiveRate := (Stats.BytesReceived - FPrevious.BytesReceived) / Elapsed;
    FSendRate := (Stats.BytesSent - FPrevious.BytesSent) / Elapsed;
  end;
  FPrevious := Stats;
  FSampleTime := Stamp;
  Usage := Stats.ReadBufferUsed * 100.0 / FSerial.ReadBufferLimit;
  Detail := Format('RX %d B  /  TX %d B    Peak %d B    Pending TX %d / %d B    Errors %d',
    [Stats.BytesReceived, Stats.BytesSent, Stats.ReadBufferPeak,
     FSerial.PendingWriteCount, FSerial.PendingWriteBytes, Stats.ErrorCount]);
  if Stats.CloseReason <> scrNone then
    Detail := Detail + '    Closed: ' + CloseReasons[Stats.CloseReason];
  if Stats.LastErrorMessage <> '' then Detail := Detail + '  ' + Stats.LastErrorMessage;
  FView.SetStatistics(Format('RX %.1f KB/s ' + #$C2#$B7 + ' TX %.1f KB/s',
    [FReceiveRate, FSendRate]), Format('Buffer %.0f%%', [Usage]), Detail);
end;

procedure TTerminalForm.FileRecord(const AKind, AText: string);
begin
  if (FFileLog <> nil) and not FLogStopping then
    FFileLog.Append(FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + '  ' +
      AKind + '  ' + AText);
end;

procedure TTerminalForm.Info(const AText: string);
begin
  FView.AddMessage(AText);
  FileRecord('INFO', AText);
end;

procedure TTerminalForm.Problem(const AText: string);
begin
  FProblem := AText;
  Info(AText);
  UpdateControls;
end;

procedure TTerminalForm.AbandonPending;
var I: Integer;
begin
  for I := 0 to High(FPending) do
    FileRecord('TX-CLOSED', Format('#%d: final result suppressed by closing', [FPending[I].Id]));
  SetLength(FPending, 0);
end;

procedure TTerminalForm.ConnectClick(Sender: TObject);
var Settings: TSerialSettings; Baud: Integer; WasActive: Boolean;
begin
  try
    FProblem := '';
    if FSerial.Active or FSerial.ReconnectPending then
    begin
      WasActive := FSerial.Active;
      FSerial.Close;
      AbandonPending;
      if WasActive then Info('Closing connection...')
      else Info('Automatic reconnection cancelled.');
    end
    else
    begin
      if Trim(FDevice.Device) = '' then
        raise EArgumentException.Create('Choose a device or enter its port name.');
      if not TryStrToInt(FBaud.Text, Baud) or (Baud <= 0) then
        raise EArgumentException.Create('Baud rate must be a positive integer.');
      Settings := FSerial.GetSettings;
      Settings.CustomBaudRate := Baud;
      Settings.DataBits := TDataBits(FDataBits.ItemIndex);
      Settings.Parity := TParity(FParity.ItemIndex);
      Settings.StopBits := TStopBits(FStopBits.ItemIndex);
      case FFlow.ItemIndex of
        1: Settings.FlowControl := fcRTS_CTS;
        2: Settings.FlowControl := fcXonXoff_no_DTR;
        3: Settings.FlowControl := fcDTR_DSR;
      else Settings.FlowControl := fcNone;
      end;
      // Reset old explicit line settings before applying a new flow-control
      // profile; Open validates the final flow/DTR/RTS combination together.
      FSerial.DtrOnOpen := olsDefault;
      FSerial.RtsOnOpen := olsDefault;
      FSerial.ApplySettings(Settings);
      FSerial.DtrOnOpen := TSerialOpenLineState(FDtr.ItemIndex);
      FSerial.RtsOnOpen := TSerialOpenLineState(FRts.ItemIndex);
      FSerial.AutoReconnect := FAutoReconnect.Checked;
      FSerial.Device := FDevice.Device;
      FView.SetConnection(ConnectionDescription, 'Opening', TerminalAmber);
      FView.Repaint;
      FSerial.Open;
      ResetRates;
      Info('Connected: ' + ConnectionDescription);
    end;
  except on E: Exception do Problem(E.Message); end;
  UpdateControls;
end;

procedure TTerminalForm.SettingsClick(Sender: TObject);
begin
  FSettingsPanel.Visible := not FSettingsPanel.Visible;
  if FSettingsPanel.Visible then FSettings.Caption := 'Hide settings'
  else FSettings.Caption := 'Settings';
  FSettings.Invalidate;
end;

procedure TTerminalForm.PauseClick(Sender: TObject);
begin
  FView.Paused := not FView.Paused;
  if FView.Paused then FPause.Caption := 'Resume view'
  else
  begin
    FPause.Caption := 'Pause view';
    FView.AddMessage('View resumed; data received while paused was not displayed.');
  end;
  FPause.Invalidate;
  FView.Invalidate;
end;

procedure TTerminalForm.ClearClick(Sender: TObject);
begin FView.Clear; end;

procedure TTerminalForm.LogClick(Sender: TObject);
var Dialog: TSaveDialog;
begin
  if FFileLog <> nil then
  begin
    FileRecord('INFO', 'File log stopped by user.');
    FFileLog.RequestStop;
    FLogStopping := True;
    FLogButton.Enabled := False;
    FLogButton.Caption := 'Finishing log...';
    FLogButton.Invalidate;
    Exit;
  end;
  Dialog := TSaveDialog.Create(Self);
  try
    Dialog.Title := 'Save serial exchange log';
    Dialog.Filter := 'Log files|*.log|All files|*';
    Dialog.DefaultExt := 'log';
    Dialog.FileName := 'serial-' + FormatDateTime('yyyymmdd-hhnnss', Now) + '.log';
    Dialog.Options := Dialog.Options + [ofOverwritePrompt];
    if not Dialog.Execute then Exit;
    try
      FFileLog := TTerminalFileLog.Create(Dialog.FileName);
      try FFileLog.Start;
      except FreeAndNil(FFileLog); raise; end;
      FLogName := Dialog.FileName;
      FLogError := '';
      FLogStopping := False;
      FLogButton.Caption := 'Stop file log';
      FLogButton.Invalidate;
      FLogLabel.Caption := ExtractFileName(FLogName);
      FLogLabel.Hint := FLogName;
      Info('File log started: ' + FLogName);
    except on E: Exception do Problem(E.Message); end;
  finally Dialog.Free; end;
end;

function ParseHex(const AText: string): AnsiString;
var I, N, HighNibble, Value: Integer; C: Char;
begin
  Result := '';
  SetLength(Result, Length(AText) div 2);
  N := 0;
  HighNibble := -1;
  for I := 1 to Length(AText) do
  begin
    C := AText[I];
    if C in [#9, #10, #13, ' '] then Continue;
    case C of
      '0'..'9': Value := Ord(C) - Ord('0');
      'a'..'f': Value := Ord(C) - Ord('a') + 10;
      'A'..'F': Value := Ord(C) - Ord('A') + 10;
    else raise EArgumentException.CreateFmt('Invalid HEX character at position %d.', [I]);
    end;
    if HighNibble < 0 then HighNibble := Value
    else
    begin
      Inc(N);
      Result[N] := AnsiChar(HighNibble * 16 + Value);
      HighNibble := -1;
    end;
  end;
  if HighNibble >= 0 then
    raise EArgumentException.Create('HEX input must contain complete byte pairs.');
  SetLength(Result, N);
end;

procedure TTerminalForm.SendClick(Sender: TObject);
var Data: AnsiString; Timeout: Integer; Id: QWord; N: Integer;
begin
  try
    if not TryStrToInt(FTimeout.Text, Timeout) or (Timeout <= 0) then
      raise EArgumentException.Create('TX timeout must be a positive number of milliseconds.');
    if FSendMode.ItemIndex = 1 then Data := ParseHex(FSendText.Text)
    else
    begin
      Data := FSendText.Text; // LCL text is already UTF-8; preserve its bytes.
      case FEnding.ItemIndex of
        1: Data := Data + #13;
        2: Data := Data + #10;
        3: Data := Data + #13#10;
      end;
    end;
    if Data = '' then raise EArgumentException.Create('Enter data to send.');
    Id := FSerial.WriteDataAsync(Data, Cardinal(Timeout));
    N := Length(FPending);
    SetLength(FPending, N + 1);
    FPending[N].Id := Id;
    FPending[N].Data := Data;
    FProblem := '';
    Info(Format('Queued TX #%d: %d bytes', [Id, Length(Data)]));
    FileRecord('TX-QUEUED', Format('#%d %d B  HEX %s  ASCII %s',
      [Id, Length(Data), HexBytes(Data), AsciiBytes(Data)]));
  except on E: Exception do Problem(E.Message); end;
  UpdateControls;
end;

procedure TTerminalForm.ModeChanged(Sender: TObject);
begin
  if FView <> nil then FView.HexView := FViewMode.ItemIndex = 0;
  FEnding.Enabled := FSendMode.ItemIndex = 0;
end;

procedure TTerminalForm.SendKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then
  begin
    if FSend.Enabled then SendClick(Sender);
    Key := #0;
  end;
end;

procedure TTerminalForm.Receive(Sender: TObject);
var Data: string; I: Integer;
begin
  // Keep each callback bounded under a continuous stream. Consuming input
  // schedules another notification for any remaining ready data.
  for I := 1 to 8 do
  begin
    if not FSerial.TryReadData(Data) then Break;
    FView.AddData('RX', Data);
    if FFileLog <> nil then
      FileRecord('RX', 'HEX ' + HexBytes(Data) + '  ASCII ' + AsciiBytes(Data));
  end;
end;

procedure TTerminalForm.WriteCompleted(Sender: TObject; const AResult: TSerialWriteResult);
const Outcomes: array[TSerialWriteOutcome] of string =
  ('completed', 'failed', 'cancelled', 'timed out');
var I, J: Integer; Data: AnsiString; Summary: string;
begin
  Data := '';
  for I := 0 to High(FPending) do
    if FPending[I].Id = AResult.OperationId then
    begin
      Data := Copy(FPending[I].Data, 1, AResult.BytesWritten);
      for J := I to High(FPending) - 1 do FPending[J] := FPending[J + 1];
      SetLength(FPending, Length(FPending) - 1);
      Break;
    end;
  Summary := Format('TX #%d %s: %d/%d bytes', [AResult.OperationId,
    Outcomes[AResult.Outcome], AResult.BytesWritten, AResult.BytesRequested]);
  if AResult.ErrorMessage <> '' then Summary := Summary + ' (' + AResult.ErrorMessage + ')';
  if Data <> '' then FView.AddData('TX #' + UIntToStr(AResult.OperationId), Data);
  FView.AddMessage(Summary);
  FileRecord('TX-RESULT', Summary + '  HEX ' + HexBytes(Data) + '  ASCII ' + AsciiBytes(Data));
  if AResult.Outcome in [swoFailed, swoTimedOut] then FProblem := Summary;
  UpdateControls;
end;

procedure TTerminalForm.ReadError(Sender: TObject; ErrorCode: Integer; const ErrorMessage: string);
begin
  AbandonPending;
  Problem(Format('Read error %d: %s', [ErrorCode, ErrorMessage]));
end;

procedure TTerminalForm.DeviceChanged(Sender: TObject);
begin
  if FSerial <> nil then UpdateControls;
end;

procedure TTerminalForm.CloseCompleted(Sender: TObject);
begin
  Info('Connection closed.');
  UpdateControls;
  SampleStatistics;
end;

procedure TTerminalForm.Removed(Sender: TObject);
begin
  AbandonPending;
  Info('Device removed.');
  UpdateControls;
end;

procedure TTerminalForm.Reconnected(Sender: TObject);
begin
  FDevice.Device := FSerial.Device;
  ResetRates;
  FProblem := '';
  Info('Reconnected: ' + ConnectionDescription);
  UpdateControls;
end;

procedure TTerminalForm.ReconnectFailed(Sender: TObject; ErrorCode: Integer;
  const ErrorMessage: string);
begin Problem(Format('Reconnect failed %d: %s', [ErrorCode, ErrorMessage])); end;

procedure TTerminalForm.Tick(Sender: TObject);
var Error: string;
begin
  if FFileLog <> nil then
  begin
    Error := FFileLog.ErrorMessage;
    if (Error <> '') and (Error <> FLogError) then
    begin
      FLogError := Error;
      FLogStopping := True;
      FProblem := Error;
      FView.AddMessage(Error);
      UpdateControls;
    end;
    if FFileLog.Finished then
    begin
      FreeAndNil(FFileLog);
      FLogStopping := False;
      FLogButton.Caption := 'Log to file...';
      FLogButton.Enabled := True;
      FLogButton.Invalidate;
      FLogLabel.Caption := 'Log saved';
      if FLogError <> '' then FLogLabel.Caption := 'Log stopped';
    end;
  end;
  SampleStatistics;
  FView.RefreshDisplay;
end;

end.
