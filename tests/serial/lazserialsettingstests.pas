unit LazSerialSettingsTests;

{$mode ObjFPC}{$H+}

interface

uses
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  Classes, SysUtils, FpcUnit, TestRegistry, LazSerial, LazSerialCommon,
  LazSerialTransportTests, LazSerialTransport, LazSynaSer, LazSerialRead,
  LazSerialWrite, LazSerialSetup, Forms, Controls;

type
  TLazSerialSettingsTests = class(TTestCase)
  private
    FOwner: TComponent;
    FSerial: TTestableLazSerial;
    FTransport: TLazSynapseSerialTransport;
    FBefore, FExpected: TSerialSettings;
    FStatusCount: Integer;
    FStatusAction: string;
    procedure Status(Sender: TObject; Reason: THookSerialReason;
      const Value: string);
    procedure AssertSettings(const AExpected, AActual: TSerialSettings);
    function Candidate: TSerialSettings;
    procedure AssertApplyRejected(const ASettings: TSerialSettings);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure SnapshotIsAnIndependentCopyOfEveryProperty;
    procedure ClosedBatchIsUsedOnNextOpening;
    procedure LiveBatchConfiguresDriverOnceAndCanRestoreSnapshot;
    procedure CustomRateTakesPrecedenceAndCanBeDisabled;
    procedure InvalidEnumerationsRejectWholeBatchBeforeIO;
    procedure OpeningLineConflictsAreValidatedBeforeCommit;
    procedure NativeFailureRestoresWholeConfigurationAndCanRetry;
    procedure RollbackFailureClosesAndPreservesOriginalError;
    procedure StatusObservesWholeCommittedOrRestoredSnapshot;
    procedure StatusCanDestroyOwner;
    procedure StatusCanCloseAndReopen;
    procedure StatusExceptionDoesNotRollBackCommittedSettings;
    procedure GetSettingsWorksDuringBufferedReadAndCleanup;
    procedure ApplyRejectsBufferedReadAndCleanup;
    procedure ApplyRejectsQueuedWritesBeforeNativeStart;
    procedure GetSettingsWorksDuringNativeWriteAndItsCleanup;
    procedure SetupCloseCallbackCanDestroyOwner;
    procedure SettingsApiRequiresMainThread;
    procedure SetupDialogPreservesCustomRateUsingBatchSettings;
  end;

implementation

type
  // Exercise the real Config/rollback code with only native driver calls replaced.
  TSettingsDriver = class(TBlockSerial)
  public
    DriverState: TDCB;
    ApplyCount, FailuresRemaining: Integer;
    EmitStatus: Boolean;
    procedure GetCommState; override;
    procedure SetCommState; override;
  end;

  TSettingsRead = class(TInterfacedObject, ISerialReadOperation)
  public
    Closing: Boolean;
    procedure Start;
    procedure Cancel;
    procedure ClosePort;
    procedure Detach;
    function DataAvailable(ALineMode: Boolean): Boolean;
    function TryReadData(ALineMode: Boolean; out AData: AnsiString): Boolean;
    function GetFailure(out AErrorCode: Integer; out AErrorMessage: string): Boolean;
    function GetClosePending: Boolean;
  end;

  TSettingsWrite = class(TInterfacedObject, ISerialWriteOperation)
  public
    Handler: TSerialWriteFinished;
    OperationId: QWord;
    procedure Start;
    procedure Cancel;
    procedure ClosePort;
    procedure Detach;
    procedure DeferDelivery;
    procedure Finish;
  end;

  TSettingsTransport = class(TLazSynapseSerialTransport)
  private
    FOpen: Boolean;
  protected
    function CreateSerial: TBlockSerial; override;
  public
    Reader: TSettingsRead;
    Writer: TSettingsWrite;
    WriteReference: ISerialWriteOperation;
    EmitCloseStatus: Boolean;
    ReadReference: ISerialReadOperation;
    function Driver: TSettingsDriver;
    procedure Connect(const ADevice: string); override;
    procedure Close; override;
    function IsOpen: Boolean; override;
    function CanRead(const ATimeout: Integer): Boolean; override;
    function CreateReadOperation(const ABufferLimit: Integer;
      const AOnChanged: TSerialReadChanged): ISerialReadOperation; override;
    function CreateWriteOperation(const AData: AnsiString; const AId: QWord;
      const ATimeoutMs: Cardinal; const AOnFinished: TSerialWriteFinished):
      ISerialWriteOperation; override;
  end;

  TSettingsThread = class(TThread)
  public
    Serial: TLazSerial;
    Settings: TSerialSettings;
    Rejected: Integer;
    procedure Execute; override;
  end;

procedure TSettingsDriver.GetCommState;
begin
  DCB := DriverState;
  RaiseSynaError(0);
end;

procedure TSettingsDriver.SetCommState;
begin
  Inc(ApplyCount);
  if EmitStatus then DoStatus(HR_Connect, 'settings');
  if FailuresRemaining > 0 then
  begin
    Dec(FailuresRemaining);
    // A driver can change some settings before reporting an error.
    DriverState := DCB;
    RaiseSynaError(ErrWrongParameter);
  end
  else
  begin
    DriverState := DCB;
    RaiseSynaError(0);
  end;
end;

procedure TSettingsRead.Start;
begin end;
procedure TSettingsRead.Cancel;
begin end;
procedure TSettingsRead.ClosePort;
begin Closing := True; end;
procedure TSettingsRead.Detach;
begin end;
function TSettingsRead.DataAvailable(ALineMode: Boolean): Boolean;
begin Result := False; end;
function TSettingsRead.TryReadData(ALineMode: Boolean; out AData: AnsiString): Boolean;
begin AData := ''; Result := False; end;
function TSettingsRead.GetFailure(out AErrorCode: Integer;
  out AErrorMessage: string): Boolean;
begin AErrorCode := 0; AErrorMessage := ''; Result := False; end;
function TSettingsRead.GetClosePending: Boolean;
begin Result := Closing; end;

function TSettingsTransport.CreateSerial: TBlockSerial;
begin Result := TSettingsDriver.Create; end;
function TSettingsTransport.Driver: TSettingsDriver;
begin Result := TSettingsDriver(NativeSerial); end;
procedure TSettingsTransport.Connect(const ADevice: string);
begin FOpen := True; end;
procedure TSettingsTransport.Close;
begin
  FOpen := False;
  NativeSerial.SetSynaError(0);
  if EmitCloseStatus and Assigned(NativeSerial.OnStatus) then
    NativeSerial.OnStatus(Self, HR_SerialClose, 'settings');
end;
function TSettingsTransport.IsOpen: Boolean;
begin Result := FOpen; end;
function TSettingsTransport.CanRead(const ATimeout: Integer): Boolean;
begin Sleep(1); Result := False; end;
function TSettingsTransport.CreateReadOperation(const ABufferLimit: Integer;
  const AOnChanged: TSerialReadChanged): ISerialReadOperation;
begin
  Reader := TSettingsRead.Create;
  ReadReference := Reader;
  Result := ReadReference;
end;

procedure TSettingsWrite.Start;
begin end;
procedure TSettingsWrite.Cancel;
begin end;
procedure TSettingsWrite.ClosePort;
begin end;
procedure TSettingsWrite.Detach;
begin Handler := nil; end;
procedure TSettingsWrite.DeferDelivery;
begin end;
procedure TSettingsWrite.Finish;
var Value: TSerialWriteResult; Callback: TSerialWriteFinished;
begin
  Value := Default(TSerialWriteResult);
  Value.OperationId := OperationId;
  Value.BytesRequested := 1;
  Value.Outcome := swoCancelled;
  Callback := Handler;
  if Assigned(Callback) then Callback(Value);
end;
function TSettingsTransport.CreateWriteOperation(const AData: AnsiString;
  const AId: QWord; const ATimeoutMs: Cardinal;
  const AOnFinished: TSerialWriteFinished): ISerialWriteOperation;
begin
  Writer := TSettingsWrite.Create;
  Writer.Handler := AOnFinished;
  Writer.OperationId := AId;
  WriteReference := Writer;
  Result := WriteReference;
end;

procedure TSettingsThread.Execute;
var Value: TSerialSettings;
begin
  try Value := Serial.GetSettings;
  except on E: ELazSerialThreadError do Inc(Rejected); end;
  try Serial.ApplySettings(Settings);
  except on E: ELazSerialThreadError do Inc(Rejected); end;
end;

procedure TLazSerialSettingsTests.SetUp;
begin
  inherited SetUp;
  FOwner := TComponent.Create(nil);
  FSerial := TTestableLazSerial.Create(FOwner);
  FTransport := TSettingsTransport.Create;
  FSerial.InstallTransport(FTransport);
  FSerial.Device := 'settings-test';
  FSerial.BaudRate := br__9600;
  FSerial.CustomBaudRate := -1;
  FSerial.DataBits := db8bits;
  FSerial.Parity := pNone;
  FSerial.StopBits := sbOne;
  FSerial.FlowControl := fcNone;
  FBefore.BaudRate := FSerial.BaudRate;
  FBefore.CustomBaudRate := FSerial.CustomBaudRate;
  FBefore.DataBits := FSerial.DataBits;
  FBefore.Parity := FSerial.Parity;
  FBefore.StopBits := FSerial.StopBits;
  FBefore.FlowControl := FSerial.FlowControl;
  FExpected := FBefore;
  FStatusCount := 0;
  FStatusAction := '';
end;

procedure TLazSerialSettingsTests.TearDown;
begin
  FOwner.Free;
  inherited TearDown;
end;

procedure TLazSerialSettingsTests.AssertSettings(const AExpected,
  AActual: TSerialSettings);
begin
  AssertEquals('BaudRate', Ord(AExpected.BaudRate), Ord(AActual.BaudRate));
  AssertEquals('CustomBaudRate', AExpected.CustomBaudRate, AActual.CustomBaudRate);
  AssertEquals('DataBits', Ord(AExpected.DataBits), Ord(AActual.DataBits));
  AssertEquals('Parity', Ord(AExpected.Parity), Ord(AActual.Parity));
  AssertEquals('StopBits', Ord(AExpected.StopBits), Ord(AActual.StopBits));
  AssertEquals('FlowControl', Ord(AExpected.FlowControl), Ord(AActual.FlowControl));
end;

function TLazSerialSettingsTests.Candidate: TSerialSettings;
begin
  Result := FBefore;
  Result.BaudRate := br_57600;
  Result.CustomBaudRate := 123456;
  Result.DataBits := db7bits;
  Result.Parity := pEven;
  Result.StopBits := sbTwo;
  Result.FlowControl := fcRTS_CTS;
end;

procedure TLazSerialSettingsTests.AssertApplyRejected(const ASettings: TSerialSettings);
var Raised: Boolean;
begin
  Raised := False;
  try FSerial.ApplySettings(ASettings);
  except on E: EInvalidOperation do Raised := True; end;
  AssertTrue('Configuration must be rejected while I/O or cleanup is pending', Raised);
  AssertSettings(FBefore, FSerial.GetSettings);
end;

procedure TLazSerialSettingsTests.Status(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
var Action: string;
begin
  if Value <> 'settings' then Exit;
  Inc(FStatusCount);
  AssertSettings(FExpected, FSerial.GetSettings);
  Action := FStatusAction;
  FStatusAction := '';
  if Action = 'destroy' then
  begin
    FreeAndNil(FOwner);
    FSerial := nil;
    FTransport := nil;
  end
  else if Action = 'reopen' then
  begin
    TSettingsTransport(FTransport).Driver.EmitStatus := False;
    FSerial.Close;
    FSerial.Open;
  end
  else if Action = 'raise' then
    raise EAbort.Create('settings handler');
end;

procedure TLazSerialSettingsTests.SnapshotIsAnIndependentCopyOfEveryProperty;
var Settings: TSerialSettings;
begin
  Settings := FSerial.GetSettings;
  AssertSettings(FBefore, Settings);
  Settings.Parity := pOdd;
  AssertEquals(Ord(pNone), Ord(FSerial.Parity));
  FSerial.Parity := pEven;
  AssertEquals(Ord(pOdd), Ord(Settings.Parity));
  AssertEquals(0, TSettingsTransport(FTransport).Driver.ApplyCount);
end;

procedure TLazSerialSettingsTests.ClosedBatchIsUsedOnNextOpening;
var Settings: TSerialSettings;
begin
  Settings := Candidate;
  FSerial.ApplySettings(Settings);
  AssertSettings(Settings, FSerial.GetSettings);
  AssertFalse(FSerial.Active);
  AssertEquals('settings-test', FSerial.Device);
  AssertEquals(0, TSettingsTransport(FTransport).Driver.ApplyCount);
  FSerial.Open;
  AssertEquals(1, TSettingsTransport(FTransport).Driver.ApplyCount);
  AssertEquals(123456, Integer(FTransport.NativeSerial.DCB.BaudRate));
  AssertEquals(7, FTransport.NativeSerial.DCB.ByteSize);
end;

procedure TLazSerialSettingsTests.LiveBatchConfiguresDriverOnceAndCanRestoreSnapshot;
var Settings: TSerialSettings; Count: Integer;
begin
  FSerial.Open;
  Count := TSettingsTransport(FTransport).Driver.ApplyCount;
  Settings := Candidate;
  FSerial.ApplySettings(Settings);
  AssertEquals(Count + 1, TSettingsTransport(FTransport).Driver.ApplyCount);
  AssertSettings(Settings, FSerial.GetSettings);
  AssertTrue(FSerial.Active);
  AssertEquals(123456, Integer(FTransport.NativeSerial.DCB.BaudRate));
  AssertEquals(7, FTransport.NativeSerial.DCB.ByteSize);
  AssertEquals(2, FTransport.NativeSerial.DCB.Parity);
  AssertEquals(SB2, FTransport.NativeSerial.DCB.StopBits);
  FSerial.ApplySettings(FBefore);
  AssertSettings(FBefore, FSerial.GetSettings);
  AssertEquals(9600, Integer(FTransport.NativeSerial.DCB.BaudRate));
end;

procedure TLazSerialSettingsTests.CustomRateTakesPrecedenceAndCanBeDisabled;
var Settings: TSerialSettings;
begin
  FSerial.Open;
  Settings := Candidate;
  FSerial.ApplySettings(Settings);
  Settings.BaudRate := br115200;
  FSerial.ApplySettings(Settings);
  AssertEquals(123456, Integer(FTransport.NativeSerial.DCB.BaudRate));
  Settings.CustomBaudRate := -1;
  FSerial.ApplySettings(Settings);
  AssertEquals(115200, Integer(FTransport.NativeSerial.DCB.BaudRate));
  AssertSettings(Settings, FSerial.GetSettings);
end;

procedure TLazSerialSettingsTests.InvalidEnumerationsRejectWholeBatchBeforeIO;
var Settings: TSerialSettings; I, Count: Integer; Raised: Boolean;
begin
  FSerial.Open;
  Count := TSettingsTransport(FTransport).Driver.ApplyCount;
  for I := 0 to 4 do
  begin
    Settings := Candidate;
    case I of
      0: FillChar(Settings.BaudRate, SizeOf(Settings.BaudRate), $FF);
      1: FillChar(Settings.DataBits, SizeOf(Settings.DataBits), $FF);
      2: FillChar(Settings.Parity, SizeOf(Settings.Parity), $FF);
      3: FillChar(Settings.StopBits, SizeOf(Settings.StopBits), $FF);
      4: FillChar(Settings.FlowControl, SizeOf(Settings.FlowControl), $FF);
    end;
    Raised := False;
    try FSerial.ApplySettings(Settings);
    except on E: EArgumentException do Raised := True; end;
    AssertTrue('Invalid enum must fail with a clear argument error', Raised);
    AssertSettings(FBefore, FSerial.GetSettings);
    AssertEquals(Count, TSettingsTransport(FTransport).Driver.ApplyCount);
  end;
end;

procedure TLazSerialSettingsTests.OpeningLineConflictsAreValidatedBeforeCommit;
var Settings: TSerialSettings; Opened, Raised: Boolean;
begin
  FSerial.DtrOnOpen := olsInactive;
  Settings := Candidate;
  Settings.FlowControl := fcDTR;
  for Opened := False to True do
  begin
    if Opened then FSerial.Open;
    Raised := False;
    try FSerial.ApplySettings(Settings);
    except on E: EArgumentException do Raised := True; end;
    AssertTrue(Raised);
    AssertSettings(FBefore, FSerial.GetSettings);
  end;
end;

procedure TLazSerialSettingsTests.NativeFailureRestoresWholeConfigurationAndCanRetry;
var Settings: TSerialSettings; Previous: TDCB; Driver: TSettingsDriver;
  RaiseNative: Boolean; Code: Integer;
begin
  FSerial.Open;
  Settings := Candidate;
  Driver := TSettingsTransport(FTransport).Driver;
  for RaiseNative := False to True do
  begin
    FSerial.ApplySettings(FBefore);
    Previous := Driver.DriverState;
    Driver.RaiseExcept := RaiseNative;
    Driver.FailuresRemaining := 1;
    Code := 0;
    try FSerial.ApplySettings(Settings);
    except on E: ESynaSerError do Code := E.ErrorCode; end;
    AssertEquals(ErrWrongParameter, Code);
    AssertTrue(FSerial.Active);
    AssertSettings(FBefore, FSerial.GetSettings);
    AssertTrue('Rollback restores the entire native configuration',
      CompareMem(@Previous, @Driver.DriverState, SizeOf(Previous)));
    AssertEquals(RaiseNative, Driver.RaiseExcept);
    FSerial.ApplySettings(Settings);
    AssertSettings(Settings, FSerial.GetSettings);
  end;
end;

procedure TLazSerialSettingsTests.RollbackFailureClosesAndPreservesOriginalError;
var Driver: TSettingsDriver; Code: Integer;
begin
  FSerial.Open;
  Driver := TSettingsTransport(FTransport).Driver;
  Driver.FailuresRemaining := 2;
  Code := 0;
  try FSerial.ApplySettings(Candidate);
  except on E: ESynaSerError do Code := E.ErrorCode; end;
  AssertEquals(ErrWrongParameter, Code);
  AssertFalse(FSerial.Active);
  AssertFalse(FTransport.IsOpen);
  AssertSettings(FBefore, FSerial.GetSettings);
  FSerial.Open;
  AssertTrue(FSerial.Active);
end;

procedure TLazSerialSettingsTests.StatusObservesWholeCommittedOrRestoredSnapshot;
begin
  FSerial.Open;
  FSerial.OnStatus := @Status;
  TSettingsTransport(FTransport).Driver.EmitStatus := True;
  FExpected := Candidate;
  FSerial.ApplySettings(FExpected);
  AssertEquals(1, FStatusCount);
  TSettingsTransport(FTransport).Driver.FailuresRemaining := 1;
  try FSerial.ApplySettings(FBefore);
  except on E: ESynaSerError do AssertEquals(ErrWrongParameter, E.ErrorCode); end;
  AssertEquals(3, FStatusCount);
  AssertSettings(FExpected, FSerial.GetSettings);
end;

procedure TLazSerialSettingsTests.StatusCanDestroyOwner;
begin
  FSerial.Open;
  FSerial.OnStatus := @Status;
  FExpected := Candidate;
  FStatusAction := 'destroy';
  TSettingsTransport(FTransport).Driver.EmitStatus := True;
  FSerial.ApplySettings(FExpected);
  AssertTrue(FOwner = nil);
  AssertEquals(1, FStatusCount);
end;

procedure TLazSerialSettingsTests.StatusCanCloseAndReopen;
begin
  FSerial.Open;
  FSerial.OnStatus := @Status;
  FExpected := Candidate;
  FStatusAction := 'reopen';
  TSettingsTransport(FTransport).Driver.EmitStatus := True;
  FSerial.ApplySettings(FExpected);
  AssertTrue(FSerial.Active);
  AssertSettings(FExpected, FSerial.GetSettings);
end;

procedure TLazSerialSettingsTests.StatusExceptionDoesNotRollBackCommittedSettings;
var Raised: Boolean;
begin
  FSerial.Open;
  FSerial.OnStatus := @Status;
  FExpected := Candidate;
  FStatusAction := 'raise';
  TSettingsTransport(FTransport).Driver.EmitStatus := True;
  Raised := False;
  try FSerial.ApplySettings(FExpected);
  except on E: EAbort do Raised := True; end;
  AssertTrue(Raised);
  AssertTrue(FSerial.Active);
  AssertSettings(FExpected, FSerial.GetSettings);
end;

procedure TLazSerialSettingsTests.GetSettingsWorksDuringBufferedReadAndCleanup;
begin
  FSerial.BufferedRead := True;
  FSerial.Open;
  AssertSettings(FBefore, FSerial.GetSettings);
  FSerial.Close;
  AssertTrue(FSerial.ClosePending);
  AssertSettings(FBefore, FSerial.GetSettings);
end;

procedure TLazSerialSettingsTests.ApplyRejectsBufferedReadAndCleanup;
begin
  FSerial.BufferedRead := True;
  FSerial.Open;
  AssertApplyRejected(Candidate);
  FSerial.Close;
  AssertTrue(FSerial.ClosePending);
  AssertApplyRejected(Candidate);
  TSettingsTransport(FTransport).Reader.Closing := False;
  FSerial.ApplySettings(Candidate);
  AssertSettings(Candidate, FSerial.GetSettings);
end;

procedure TLazSerialSettingsTests.ApplyRejectsQueuedWritesBeforeNativeStart;
begin
  FSerial.Open;
  FSerial.WriteQueueEnabled := True;
  FSerial.WriteDataAsync('pending', 1000);
  AssertTrue(FSerial.WritePending);
  AssertApplyRejected(Candidate);
  FSerial.Close;
  AssertSettings(FBefore, FSerial.GetSettings);
end;

procedure TLazSerialSettingsTests.GetSettingsWorksDuringNativeWriteAndItsCleanup;
begin
  FSerial.Open;
  FSerial.WriteDataAsync('x', 1000);
  AssertTrue(FSerial.WritePending);
  AssertApplyRejected(Candidate);
  FSerial.Close;
  AssertTrue(FSerial.ClosePending);
  AssertApplyRejected(Candidate);
  TSettingsTransport(FTransport).Writer.Finish;
  AssertFalse(FSerial.ClosePending);
  AssertFalse(FSerial.WritePending);
  FSerial.ApplySettings(Candidate);
  AssertSettings(Candidate, FSerial.GetSettings);
end;

procedure TLazSerialSettingsTests.SetupCloseCallbackCanDestroyOwner;
var Form: TComSetupFrm;
begin
  FSerial.Open;
  Form := TComSetupFrm.Create(nil);
  try
    Form.LoadSettings(ReadComPortSettings(FSerial));
    FSerial.OnStatus := @Status;
    FStatusAction := 'destroy';
    TSettingsTransport(FTransport).EmitCloseStatus := True;
    ApplyComPortSetupResult(FSerial, Form, mrOK);
    AssertTrue(FOwner = nil);
    AssertEquals(1, FStatusCount);
  finally Form.Free; end;
end;

procedure TLazSerialSettingsTests.SettingsApiRequiresMainThread;
var Worker: TSettingsThread;
begin
  Worker := TSettingsThread.Create(True);
  try
    Worker.Serial := FSerial;
    Worker.Settings := Candidate;
    Worker.Start;
    Worker.WaitFor;
    AssertEquals(2, Worker.Rejected);
    AssertSettings(FBefore, FSerial.GetSettings);
  finally Worker.Free; end;
end;

procedure TLazSerialSettingsTests.SetupDialogPreservesCustomRateUsingBatchSettings;
var Form: TComSetupFrm; Settings: TComPortSettings;
begin
  FSerial.CustomBaudRate := 123456;
  Form := TComSetupFrm.Create(nil);
  try
    Settings := ReadComPortSettings(FSerial);
    Form.LoadSettings(Settings);
    ApplyComPortSetupResult(FSerial, Form, mrOK);
    AssertEquals(123456, FSerial.GetSettings.CustomBaudRate);
    AssertEquals(Ord(br__9600), Ord(FSerial.GetSettings.BaudRate));
  finally Form.Free; end;
end;

initialization
  RegisterTest(TLazSerialSettingsTests);
end.
