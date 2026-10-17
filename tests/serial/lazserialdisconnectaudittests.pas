unit LazSerialDisconnectAuditTests;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, FpcUnit, TestRegistry, LazSerial, LazSerialDevices,
  LazSerialTransportTests, LazSynaSer;
type
  TLazSerialDisconnectAuditTests = class(TTestCase)
  private
    Serial: TTestableLazSerial;
    Owner: TComponent;
    Removed: Integer;
    FreeOwner, Reopen, CloseAgain, RaiseStatus: Boolean;
    procedure Status(Sender: TObject; Reason: THookSerialReason; const Value: string);
    procedure Disconnected(Sender: TObject);
    procedure CreateSerial;
    procedure Snapshot(const Name: string; const Persistent: string = '');
  protected
    procedure TearDown; override;
  published
    procedure DestroyFromCloseStatusDoesNotDeliverRemoved;
    procedure DestroyOwnerFromCloseStatusDoesNotDeliverRemoved;
    procedure ReopenFromCloseStatusDoesNotReportNewConnectionRemoved;
    procedure CloseStatusExceptionPropagatesWithoutRemoved;
    procedure ReopenAndCloseDoesNotReceiveOldRemoval;
    procedure PersistentAliasRemainsConnected;
    procedure SettingNextDeviceDoesNotChangeOpenIdentity;
    procedure UnlistedPathIsNotRemovedByUnrelatedHotplug;
    {$IFDEF UNIX}
    procedure SymlinkRemovalStillTracksResolvedDevice;
    {$ENDIF}
  end;
implementation
uses SerialWatcher, SerialWatcherSupport, SerialWatcherComponentTests
  {$IFDEF UNIX}, BaseUnix{$ENDIF};
type
  TDisconnectTransport = class(TFakeSerialTransport)
  private
    Handler: THookSerialStatus;
  public
    procedure Close; override;
    procedure SetStatusHandler(const AHandler: THookSerialStatus); override;
  end;
  TDisconnectWatcherAccess = class(TSerialWatcher)
  public
    procedure Isolate;
    procedure Stop;
  end;
procedure TDisconnectTransport.SetStatusHandler(const AHandler: THookSerialStatus);
begin Handler := AHandler; inherited SetStatusHandler(AHandler); end;
procedure TDisconnectTransport.Close;
var WasOpen: Boolean;
begin
  WasOpen := IsOpen;
  inherited Close;
  if WasOpen and Assigned(Handler) then Handler(Self, HR_SerialClose, '');
end;
procedure TDisconnectWatcherAccess.Isolate;
begin
  SetInfrastructure(TSerialManualChangeSource.Create,
    TFakeSerialRefreshScheduler.Create, True);
end;
procedure TDisconnectWatcherAccess.Stop;
begin StopWatching; end;
procedure TLazSerialDisconnectAuditTests.Status(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
begin
  if Reason <> HR_SerialClose then Exit;
  if RaiseStatus then raise EInvalidOperation.Create('close-status');
  if Reopen then
  begin
    Reopen := False;
    Serial.OnStatus := nil;
    Serial.Device := 'COM2';
    Serial.Open;
    if CloseAgain then Serial.Close;
  end
  else if FreeOwner then
  begin
    Serial := nil;
    FreeAndNil(Owner);
  end
  else FreeAndNil(Serial);
end;
procedure TLazSerialDisconnectAuditTests.Disconnected(Sender: TObject);
begin Inc(Removed); end;
procedure TLazSerialDisconnectAuditTests.CreateSerial;
var I: Integer;
begin
  Removed := 0;
  Owner := TComponent.Create(nil);
  Serial := TTestableLazSerial.Create(Owner);
  Serial.InstallTransport(TDisconnectTransport.Create);
  Serial.Device := 'COM1';
  Serial.OnRemoved := @Disconnected;
  for I := 0 to Serial.ComponentCount - 1 do
    if Serial.Components[I] is TSerialWatcher then
      TDisconnectWatcherAccess(Serial.Components[I]).Isolate;
  Serial.Open;
  for I := 0 to Serial.ComponentCount - 1 do
    if Serial.Components[I] is TSerialWatcher then
      TDisconnectWatcherAccess(Serial.Components[I]).Stop;
  Snapshot('COM1');
  Serial.CheckForDisconnectedDevice;
end;
procedure TLazSerialDisconnectAuditTests.Snapshot(const Name: string;
  const Persistent: string);
var Device: TSerialDeviceInfo;
begin
  if Name = '' then Serial.AdoptWatcherSnapshot([])
  else
  begin
    Device := Default(TSerialDeviceInfo);
    Device.Device := Name;
    Device.PersistentId := Persistent;
    Serial.AdoptWatcherSnapshot([Device]);
  end;
end;
procedure TLazSerialDisconnectAuditTests.TearDown;
begin
  if Serial <> nil then Serial.OnStatus := nil;
  FreeAndNil(Owner);
  Serial := nil;
  inherited TearDown;
end;
procedure TLazSerialDisconnectAuditTests.DestroyFromCloseStatusDoesNotDeliverRemoved;
begin
  CreateSerial;
  Serial.OnStatus := @Status;
  Snapshot('');
  Serial.CheckForDisconnectedDevice;
  AssertNull(Serial);
  AssertEquals(0, Removed);
end;
procedure TLazSerialDisconnectAuditTests.DestroyOwnerFromCloseStatusDoesNotDeliverRemoved;
begin
  FreeOwner := True;
  DestroyFromCloseStatusDoesNotDeliverRemoved;
  AssertNull(Owner);
end;
procedure TLazSerialDisconnectAuditTests.ReopenFromCloseStatusDoesNotReportNewConnectionRemoved;
begin
  CreateSerial;
  Reopen := True;
  Serial.OnStatus := @Status;
  Snapshot('');
  Serial.CheckForDisconnectedDevice;
  AssertTrue(Serial.Active);
  AssertEquals(0, Removed);
end;
procedure TLazSerialDisconnectAuditTests.ReopenAndCloseDoesNotReceiveOldRemoval;
begin
  CreateSerial;
  Reopen := True;
  CloseAgain := True;
  Serial.OnStatus := @Status;
  Snapshot('');
  Serial.CheckForDisconnectedDevice;
  AssertFalse(Serial.Active);
  AssertEquals(0, Removed);
end;
procedure TLazSerialDisconnectAuditTests.CloseStatusExceptionPropagatesWithoutRemoved;
begin
  CreateSerial;
  RaiseStatus := True;
  Serial.OnStatus := @Status;
  Snapshot('');
  try
    Serial.CheckForDisconnectedDevice;
    Fail('The status exception must propagate');
  except on E: EInvalidOperation do AssertEquals('close-status', E.Message); end;
  AssertFalse(Serial.Active);
  AssertEquals(0, Removed);
end;
procedure TLazSerialDisconnectAuditTests.PersistentAliasRemainsConnected;
begin
  CreateSerial;
  Serial.Close;
  Serial.Device := '/dev/serial/by-id/audit-device';
  Serial.Open;
  Snapshot('/dev/ttyUSB0', '/dev/serial/by-id/audit-device');
  Serial.CheckForDisconnectedDevice;
  AssertTrue(Serial.Active);
  Snapshot('');
  Serial.CheckForDisconnectedDevice;
  AssertFalse(Serial.Active);
  AssertEquals(1, Removed);
end;
procedure TLazSerialDisconnectAuditTests.SettingNextDeviceDoesNotChangeOpenIdentity;
begin
  CreateSerial;
  Serial.Device := 'COM2';
  Serial.CheckForDisconnectedDevice;
  AssertTrue(Serial.Active);
  AssertEquals('COM2', Serial.Device);
  Snapshot('COM2');
  Serial.CheckForDisconnectedDevice;
  AssertFalse(Serial.Active);
  AssertEquals(1, Removed);
  Serial.Open;
  Serial.CheckForDisconnectedDevice;
  AssertTrue(Serial.Active);
end;
procedure TLazSerialDisconnectAuditTests.UnlistedPathIsNotRemovedByUnrelatedHotplug;
begin
  CreateSerial;
  Serial.Close;
  Serial.Device := '/dev/unlisted-audit-path';
  Serial.Open;
  Snapshot('COM2');
  Serial.CheckForDisconnectedDevice;
  AssertTrue(Serial.Active);
  AssertEquals(0, Removed);
end;
{$IFDEF UNIX}
procedure TLazSerialDisconnectAuditTests.SymlinkRemovalStillTracksResolvedDevice;
var Target, AliasName: string; FileStream: TFileStream;
begin
  Target := GetTempFileName;
  AliasName := Target + '-alias';
  FileStream := TFileStream.Create(Target, fmCreate);
  FileStream.Free;
  AssertEquals(0, fpSymlink(PChar(Target), PChar(AliasName)));
  try
    CreateSerial;
    Serial.Close;
    Serial.Device := AliasName;
    Serial.Open;
    Snapshot(Target);
    Serial.CheckForDisconnectedDevice;
    AssertTrue(Serial.Active);
    AssertTrue(DeleteFile(AliasName));
    Snapshot('COM2');
    Serial.CheckForDisconnectedDevice;
    AssertFalse(Serial.Active);
    AssertEquals(1, Removed);
  finally
    DeleteFile(AliasName);
    DeleteFile(Target);
  end;
end;
{$ENDIF}
initialization RegisterTest(TLazSerialDisconnectAuditTests);
end.
