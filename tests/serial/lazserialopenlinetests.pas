unit LazSerialOpenLineTests;

{$mode ObjFPC}{$H+}

interface

uses
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  {$IFDEF UNIX}Termio,{$ENDIF}
  Classes, SysUtils, FpcUnit, TestRegistry, LazSerialCommon, LazSynaSer,
  LazSerialTransport;

type
  TLazSerialOpenLineTests = class(TTestCase)
  published
    procedure ExplicitStatesAreAppliedBeforeConnectStatus;
    procedure DefaultsKeepLegacyLineSequence;
    procedure ConfigurationPreservesExplicitLineStates;
    procedure FlowConflictsLeaveConfigurationUntouched;
    procedure CompatibleFlowControlRetainsOwnership;
    procedure FailedOpeningLinesCloseAndPreserveError;
    procedure CleanupFailureDoesNotReplaceOpeningError;
    {$IFDEF UNIX}
    procedure NativeModemWriteFailureIsReported;
    procedure OpeningFailureReleasesUnixLock;
    {$ENDIF}
    procedure DriverFailureIsReportedRegardlessOfExceptionPreference;
    procedure ReopeningCanReturnToDefaults;
    procedure NativeOpeningSettingsRequireClosedPort;
    procedure UnsupportedNativeControlLinesFailAndReleaseHandle;
    {$IFDEF MSWINDOWS}
    procedure StateReadFailureDoesNotApplyOpeningLines;
    {$ENDIF}
  end;

implementation

const
  {$IFDEF MSWINDOWS}NullDevice = 'NUL';{$ELSE}NullDevice = '/dev/null';{$ENDIF}

type
  { Real Connect/Config and handle ownership, scripted driver operations. }
  TOpenLineSerial = class(TBlockSerial)
  protected
    procedure SetDTRF(Value: Boolean); override;
    procedure SetRTSF(Value: Boolean); override;
    {$IFDEF UNIX}
    procedure SetOpeningModemLines(AValues: Integer); override;
    {$ENDIF}
  public
    Calls: string;
    OpeningCalls, StateReads, StateWrites: Integer;
    OpeningError, ReadError: Integer;
    DriverFlags: LongWord;
    AtConnectStatus: string;
    procedure Status(Sender: TObject; Reason: THookSerialReason; const Value: string);
    procedure GetCommState; override;
    procedure SetCommState; override;
    procedure Purge; override;
  end;

  TFailingOpenCleanupSerial = class(TOpenLineSerial)
  public
    FailCleanup: Boolean;
    procedure CloseSocket; override;
  end;

  {$IFDEF UNIX}
  TOpenLineLockSerial = class(TOpenLineSerial)
  public
    LockReleases: Integer;
    function cpomComportAccessible: Boolean; override;
    procedure cpomReleaseComport; override;
  end;

  TNativeModemWriteFailureSerial = class(TBlockSerial)
  public
    function ModemStatus: Integer; override;
    procedure ApplyOpeningLines;
  end;
  {$ENDIF}

  TOpenLineTransport = class(TLazSynapseSerialTransport)
  protected
    function CreateSerial: TBlockSerial; override;
  public
    function Probe: TOpenLineSerial;
  end;

procedure TOpenLineSerial.SetDTRF(Value: Boolean);
begin
  if Value then Calls := Calls + 'D+' else Calls := Calls + 'D-';
end;

procedure TOpenLineSerial.SetRTSF(Value: Boolean);
begin
  if Value then Calls := Calls + 'R+' else Calls := Calls + 'R-';
end;

{$IFDEF UNIX}
procedure TOpenLineSerial.SetOpeningModemLines(AValues: Integer);
begin
  Inc(OpeningCalls);
  if (AValues and TIOCM_DTR) <> 0 then Calls := Calls + 'D+'
  else Calls := Calls + 'D-';
  if (AValues and TIOCM_RTS) <> 0 then Calls := Calls + 'R+'
  else Calls := Calls + 'R-';
  RaiseSynaError(OpeningError);
end;
{$ENDIF}

procedure TOpenLineSerial.GetCommState;
begin
  Inc(StateReads);
  DCB.Flags := DriverFlags;
  RaiseSynaError(ReadError);
end;

procedure TOpenLineSerial.SetCommState;
begin
  Inc(StateWrites);
  DriverFlags := DCB.Flags;
  {$IFDEF MSWINDOWS}
  if (DriverFlags and dcb_DtrControlMask) = dcb_DtrControlEnable then
    Calls := Calls + 'D+' else Calls := Calls + 'D-';
  if (DriverFlags and dcb_RtsControlMask) = dcb_RtsControlEnable then
    Calls := Calls + 'R+' else Calls := Calls + 'R-';
  {$ENDIF}
  RaiseSynaError(OpeningError);
end;

procedure TOpenLineSerial.Purge;
begin
  Calls := Calls + 'P';
  SetSynaError(0);
end;

procedure TOpenLineSerial.Status(Sender: TObject; Reason: THookSerialReason;
  const Value: string);
begin
  if Reason = HR_Connect then AtConnectStatus := Calls;
end;

function TOpenLineTransport.CreateSerial: TBlockSerial;
begin
  Result := TOpenLineSerial.Create;
end;

function TOpenLineTransport.Probe: TOpenLineSerial;
begin
  Result := TOpenLineSerial(NativeSerial);
end;

procedure TLazSerialOpenLineTests.ExplicitStatesAreAppliedBeforeConnectStatus;
var
  Serial: TOpenLineSerial;
  Dtr, Rts: TSerialOpenLineState;
  Expected: string;
begin
  for Dtr := Low(Dtr) to High(Dtr) do
    for Rts := Low(Rts) to High(Rts) do
    begin
      if (Dtr = olsDefault) and (Rts = olsDefault) then Continue;
      Serial := TOpenLineSerial.Create;
      try
        Serial.LinuxLock := False;
        Serial.OnStatus := @Serial.Status;
        Serial.ConfigureOpenLines(Dtr, Rts, fcNone);
        Serial.Connect(NullDevice);
        AssertEquals(0, Serial.LastError);
        AssertTrue(Serial.InstanceActive);
        if Dtr = olsInactive then Expected := 'D-' else Expected := 'D+';
        if Rts = olsInactive then Expected := Expected + 'R-'
        else Expected := Expected + 'R+';
        AssertEquals('No intermediate activation or duplicate line writes',
          Expected + 'P', Serial.AtConnectStatus);
        {$IFDEF UNIX}AssertEquals(1, Serial.OpeningCalls);{$ELSE}
        AssertEquals(1, Serial.StateReads);
        AssertEquals(1, Serial.StateWrites);{$ENDIF}
      finally
        Serial.Free;
      end;
    end;
end;

procedure TLazSerialOpenLineTests.DefaultsKeepLegacyLineSequence;
var Serial: TOpenLineSerial;
begin
  Serial := TOpenLineSerial.Create;
  try
    Serial.LinuxLock := False;
    Serial.Connect(NullDevice);
    AssertEquals('R+D+P', Serial.Calls);
    AssertEquals(0, Serial.StateWrites);
    {$IFDEF UNIX}AssertEquals(0, Serial.OpeningCalls);{$ENDIF}
    Serial.CloseSocket;
    AssertEquals('Closing retains purge, RTS off, DTR off',
      'R+D+PPR-D-', Serial.Calls);
  finally Serial.Free; end;
end;

procedure TLazSerialOpenLineTests.ConfigurationPreservesExplicitLineStates;
var
  Serial: TOpenLineSerial;
  Dtr, Rts: TSerialOpenLineState;
  Expected: LongWord;
begin
  Serial := TOpenLineSerial.Create;
  try
    for Dtr := Low(Dtr) to High(Dtr) do
      for Rts := Low(Rts) to High(Rts) do
      begin
        Serial.ConfigureOpenLines(Dtr, Rts, fcNone);
        Serial.Config(9600, 8, 'N', SB1, fcNone);
        Serial.Config(115200, 8, 'N', SB1, fcNone);
        Expected := 0;
        if Dtr = olsActive then Expected := Expected or dcb_DtrControlEnable;
        if Rts = olsActive then Expected := Expected or dcb_RtsControlEnable;
        AssertEquals(Int64(Expected), Int64(Serial.DCB.Flags and
          (dcb_DtrControlMask or dcb_RtsControlMask)));
      end;
  finally Serial.Free; end;
end;

procedure TLazSerialOpenLineTests.FlowConflictsLeaveConfigurationUntouched;
var
  Serial: TOpenLineSerial;
  Flow: TFlowControl;
  Dtr, Rts: TSerialOpenLineState;
  Conflict, Raised: Boolean;
begin
  Serial := TOpenLineSerial.Create;
  try
    for Dtr := Low(Dtr) to High(Dtr) do
      for Rts := Low(Rts) to High(Rts) do
        for Flow := Low(Flow) to High(Flow) do
        begin
          Conflict := ((Dtr <> olsDefault) and
            (Flow in [fcDTR_DSR, fcXonXoff_and_DTR_DSR])) or
            ((Dtr = olsInactive) and
            (Flow in [fcDTR, fcXonXoff_and_DTR, fcXonXoff_and_RTS_CTS])) or
            ((Rts <> olsDefault) and (Flow in [fcRTS_CTS,
              fcXonXoff_and_RTS_CTS, fcDTR_DSR, fcXonXoff_and_DTR_DSR]));
          Serial.ConfigureOpenLines(Dtr, Rts, fcNone);
          Serial.StateReads := 0;
          Serial.StateWrites := 0;
          Raised := False;
          try Serial.Config(9600, 8, 'N', SB1, Flow);
          except on E: EArgumentException do Raised := True; end;
          AssertEquals(Conflict, Raised);
          if Conflict then
          begin
            AssertEquals(0, Serial.StateReads);
            AssertEquals(0, Serial.StateWrites);
          end;
        end;
  finally Serial.Free; end;
end;

procedure TLazSerialOpenLineTests.CompatibleFlowControlRetainsOwnership;
var Serial: TOpenLineSerial;
begin
  Serial := TOpenLineSerial.Create;
  try
    Serial.ConfigureOpenLines(olsInactive, olsDefault, fcRTS_CTS);
    Serial.Config(115200, 8, 'N', SB1, fcRTS_CTS);
    AssertEquals(Int64(dcb_RtsControlHandshake),
      Int64(Serial.DCB.Flags and dcb_RtsControlMask));
    AssertEquals(0, Serial.DCB.Flags and dcb_DtrControlMask);
    Serial.ConfigureOpenLines(olsActive, olsInactive, fcXonXoff_and_DTR);
    Serial.Config(115200, 8, 'N', SB1, fcXonXoff_and_DTR);
    AssertEquals(Int64(dcb_DtrControlEnable),
      Int64(Serial.DCB.Flags and dcb_DtrControlMask));
    AssertEquals(0, Serial.DCB.Flags and dcb_RtsControlMask);
    AssertTrue((Serial.DCB.Flags and (dcb_OutX or dcb_InX)) = (dcb_OutX or dcb_InX));
  finally Serial.Free; end;
end;

procedure TLazSerialOpenLineTests.FailedOpeningLinesCloseAndPreserveError;
var
  Serial: TOpenLineSerial;
  RaiseNative, Raised: Boolean;
begin
  for RaiseNative := False to True do
  begin
    Serial := TOpenLineSerial.Create;
    try
      Serial.LinuxLock := False;
      Serial.RaiseExcept := RaiseNative;
      Serial.OpeningError := ErrNoDeviceAnswer;
      Serial.ConfigureOpenLines(olsInactive, olsInactive, fcNone);
      Serial.OnStatus := @Serial.Status;
      Raised := False;
      try Serial.Connect(NullDevice);
      except on E: ESynaSerError do
      begin Raised := True; AssertEquals(ErrNoDeviceAnswer, E.ErrorCode); end; end;
      AssertEquals(RaiseNative, Raised);
      AssertEquals(RaiseNative, Serial.RaiseExcept);
      AssertEquals(ErrNoDeviceAnswer, Serial.LastError);
      AssertFalse(Serial.InstanceActive);
      AssertTrue(Serial.Handle = THandle(-1));
      AssertEquals('', Serial.AtConnectStatus);
      Serial.OpeningError := 0;
      Serial.Connect(NullDevice);
      AssertTrue('The same serial object can retry after failure', Serial.InstanceActive);
    finally Serial.Free; end;
  end;
end;

procedure TLazSerialOpenLineTests.DriverFailureIsReportedRegardlessOfExceptionPreference;
var
  Transport: TOpenLineTransport;
  RaiseNative, Raised: Boolean;
begin
  for RaiseNative := False to True do
  begin
    Transport := TOpenLineTransport.Create;
    try
      Transport.NativeSerial.RaiseExcept := RaiseNative;
      Transport.Probe.OpeningError := ErrNoDeviceAnswer;
      Transport.ConfigureOpenLines(olsInactive, olsInactive, fcNone);
      Raised := False;
      try Transport.Connect(NullDevice);
      except on E: ESynaSerError do
      begin Raised := True; AssertEquals(ErrNoDeviceAnswer, E.ErrorCode); end; end;
      AssertTrue(Raised);
      AssertFalse(Transport.IsOpen);
      AssertEquals(RaiseNative, Transport.NativeSerial.RaiseExcept);
    finally Transport.Free; end;
  end;
end;

procedure TLazSerialOpenLineTests.ReopeningCanReturnToDefaults;
var Transport: TOpenLineTransport;
begin
  Transport := TOpenLineTransport.Create;
  try
    Transport.ConfigureOpenLines(olsInactive, olsInactive, fcNone);
    Transport.Connect(NullDevice);
    AssertEquals('D-R-P', Transport.Probe.Calls);
    Transport.Close;
    Transport.Probe.Calls := '';
    Transport.ConfigureOpenLines(olsDefault, olsDefault, fcNone);
    Transport.Connect(NullDevice);
    AssertEquals('R+D+P', Transport.Probe.Calls);
  finally Transport.Free; end;
end;

procedure TLazSerialOpenLineTests.NativeOpeningSettingsRequireClosedPort;
var Serial: TOpenLineSerial; Raised: Boolean;
begin
  Serial := TOpenLineSerial.Create;
  try
    Serial.LinuxLock := False;
    Serial.Connect(NullDevice);
    Raised := False;
    try Serial.ConfigureOpenLines(olsInactive, olsInactive, fcNone);
    except on E: EInvalidOperation do Raised := True; end;
    AssertTrue(Raised);
  finally Serial.Free; end;
end;

procedure TLazSerialOpenLineTests.UnsupportedNativeControlLinesFailAndReleaseHandle;
var Serial: TBlockSerial; RaiseNative, Raised: Boolean;
begin
  for RaiseNative := False to True do
  begin
    Serial := TBlockSerial.Create;
    try
      Serial.LinuxLock := False;
      Serial.RaiseExcept := RaiseNative;
      Serial.ConfigureOpenLines(olsInactive, olsInactive, fcNone);
      Raised := False;
      try Serial.Connect(NullDevice);
      except on E: ESynaSerError do
      begin Raised := True; AssertTrue(E.ErrorCode <> 0); end; end;
      AssertEquals(RaiseNative, Raised);
      AssertTrue('A non-serial descriptor must report the native error', Serial.LastError <> 0);
      AssertTrue('Failed initialization must release its descriptor', Serial.Handle = THandle(-1));
      AssertFalse(Serial.InstanceActive);
    finally Serial.Free; end;
  end;
end;

{$IFDEF MSWINDOWS}
procedure TLazSerialOpenLineTests.StateReadFailureDoesNotApplyOpeningLines;
var Serial: TOpenLineSerial;
begin
  Serial := TOpenLineSerial.Create;
  try
    Serial.LinuxLock := False;
    Serial.ConfigureOpenLines(olsInactive, olsInactive, fcNone);
    Serial.ReadError := ErrNoDeviceAnswer;
    Serial.Connect(NullDevice);
    AssertEquals(ErrNoDeviceAnswer, Serial.LastError);
    AssertEquals(0, Serial.StateWrites);
    AssertTrue(Serial.Handle = THandle(-1));
  finally Serial.Free; end;
end;
{$ENDIF}

procedure TFailingOpenCleanupSerial.CloseSocket;
begin
  inherited CloseSocket;
  if FailCleanup then
  begin
    FailCleanup := False;
    raise ESynaSerError.Create('Simulated cleanup failure');
  end;
end;

procedure TLazSerialOpenLineTests.CleanupFailureDoesNotReplaceOpeningError;
var Serial: TFailingOpenCleanupSerial; ErrorCode: Integer;
begin
  Serial := TFailingOpenCleanupSerial.Create;
  try
    Serial.LinuxLock := False;
    Serial.RaiseExcept := True;
    Serial.OpeningError := ErrNoDeviceAnswer;
    Serial.FailCleanup := True;
    Serial.ConfigureOpenLines(olsInactive, olsInactive, fcNone);
    ErrorCode := 0;
    try Serial.Connect(NullDevice);
    except on E: ESynaSerError do ErrorCode := E.ErrorCode; end;
    AssertEquals(ErrNoDeviceAnswer, ErrorCode);
    AssertEquals(ErrNoDeviceAnswer, Serial.LastError);
    AssertTrue(Serial.Handle = THandle(-1));
    AssertTrue(Serial.RaiseExcept);
  finally Serial.Free; end;
end;

{$IFDEF UNIX}
function TNativeModemWriteFailureSerial.ModemStatus: Integer;
begin
  // Let the production TIOCMSET call fail, independently of TIOCMGET.
  SetSynaError(0);
  Result := 0;
end;

procedure TNativeModemWriteFailureSerial.ApplyOpeningLines;
begin
  ApplyOpenLineStates;
end;

procedure TLazSerialOpenLineTests.NativeModemWriteFailureIsReported;
var
  Serial: TNativeModemWriteFailureSerial;
  RaiseNative, Raised: Boolean;
begin
  Serial := TNativeModemWriteFailureSerial.Create;
  try
    Serial.ConfigureOpenLines(olsInactive, olsDefault, fcNone);
    for RaiseNative := False to True do
    begin
      Serial.RaiseExcept := RaiseNative;
      Raised := False;
      try Serial.ApplyOpeningLines;
      except on E: ESynaSerError do
      begin Raised := True; AssertTrue(E.ErrorCode <> 0); end; end;
      AssertEquals(RaiseNative, Raised);
      AssertTrue(Serial.LastError <> 0);
    end;
  finally Serial.Free; end;
end;
{$ENDIF}

{$IFDEF UNIX}
function TOpenLineLockSerial.cpomComportAccessible: Boolean;
begin
  Result := True;
end;

procedure TOpenLineLockSerial.cpomReleaseComport;
begin
  Inc(LockReleases);
end;

procedure TLazSerialOpenLineTests.OpeningFailureReleasesUnixLock;
var Serial: TOpenLineLockSerial;
begin
  Serial := TOpenLineLockSerial.Create;
  try
    Serial.OpeningError := ErrNoDeviceAnswer;
    Serial.ConfigureOpenLines(olsInactive, olsInactive, fcNone);
    Serial.Connect(NullDevice);
    AssertEquals(1, Serial.LockReleases);
    Serial.OpeningError := 0;
    Serial.Connect(NullDevice);
    AssertTrue(Serial.InstanceActive);
    Serial.CloseSocket;
    AssertEquals(2, Serial.LockReleases);
  finally Serial.Free; end;
end;
{$ENDIF}

initialization
  RegisterTest(TLazSerialOpenLineTests);
end.
