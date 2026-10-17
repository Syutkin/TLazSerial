unit LazSerialReconnectPolicyTests;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, FpcUnit, TestRegistry, LazSerialDevices,
  LazSerialReconnect, SerialWatcherSupport, SerialWatcherComponentTests;

type
  TLazSerialReconnectPolicyTests = class(TTestCase)
  private
    FPolicy: TSerialReconnect;
    FScheduler: TFakeSerialRefreshScheduler;
    FDevice: TSerialDeviceInfo;
    FReady: Integer;
    procedure Ready(Sender: TObject);
    procedure Arm;
    procedure ReturnDevice;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure DefaultsNeedOnlyEnabling;
    procedure DisabledModeDoesNotSchedule;
    procedure ReconnectFollowsPersistentIdToNewPort;
    procedure SerialAndUsbIdsProvideFallbackIdentity;
    procedure NoIdentityNeverUsesPortNameOrVidPidAlone;
    procedure MissingPersistentIdDoesNotWeakenSavedIdentity;
    procedure AmbiguousMatchesWaitWithoutOpening;
    procedure ReaderFailureWaitsForConfirmedDisappearance;
    procedure ReaderFailureRecognizesAlreadyRemovedDevice;
    procedure MetadataCanArriveAfterOpening;
    procedure IdentityDoesNotSwitchToReplacementOnSamePort;
    procedure AttemptsAreBoundedAcrossSnapshots;
    procedure CleanupDeferralDoesNotConsumeAttempts;
    procedure CancelAndDisableStopPendingWork;
    procedure SuccessStartsFreshBudgetForNextRemoval;
    procedure SettingsRejectZero;
    procedure PersistentAliasCapturesCanonicalPort;
    procedure ChangedAttemptLimitAppliesToNextRecovery;
  end;

implementation

type
  TReconnectAccess = class(TSerialReconnect);

procedure TLazSerialReconnectPolicyTests.SetUp;
begin
  inherited SetUp;
  FPolicy := TSerialReconnect.Create(nil);
  FScheduler := TFakeSerialRefreshScheduler.Create;
  TReconnectAccess(FPolicy).ReplaceScheduler(FScheduler);
  FPolicy.OnReady := @Ready;
  FReady := 0;
  FDevice := Default(TSerialDeviceInfo);
  FDevice.Device := 'port0';
  FDevice.PersistentId := 'persistent-adapter';
  FDevice.VendorId := '0403';
  FDevice.ProductId := '6001';
  FDevice.SerialShort := 'serial-A';
end;

procedure TLazSerialReconnectPolicyTests.TearDown;
begin
  FPolicy.Free;
  inherited TearDown;
end;

procedure TLazSerialReconnectPolicyTests.Ready(Sender: TObject);
begin
  Inc(FReady);
end;

procedure TLazSerialReconnectPolicyTests.Arm;
begin
  FPolicy.Enabled := True;
  FPolicy.Observe([FDevice]);
  FPolicy.Connected(FDevice.Device);
end;

procedure TLazSerialReconnectPolicyTests.ReturnDevice;
begin
  FDevice.Device := 'port7';
  FPolicy.Observe([FDevice]);
end;

procedure TLazSerialReconnectPolicyTests.DefaultsNeedOnlyEnabling;
begin
  AssertFalse(FPolicy.Enabled);
  AssertFalse(FPolicy.Pending);
  AssertEquals(1000, FPolicy.IntervalMs);
  AssertEquals(5, FPolicy.MaxAttempts);
  Arm;
  FPolicy.Observe([]);
  FPolicy.ConnectionLost(True);
  AssertTrue(FPolicy.Pending);
  AssertFalse(FScheduler.Scheduled);
  ReturnDevice;
  AssertTrue(FScheduler.Scheduled);
  AssertEquals(1000, FScheduler.LastDelayMs);
end;

procedure TLazSerialReconnectPolicyTests.DisabledModeDoesNotSchedule;
begin
  FPolicy.Observe([FDevice]);
  FPolicy.Connected(FDevice.Device);
  FPolicy.ConnectionLost(True);
  AssertFalse(FPolicy.Pending);
  ReturnDevice;
  AssertFalse(FScheduler.Scheduled);
end;

procedure TLazSerialReconnectPolicyTests.ReconnectFollowsPersistentIdToNewPort;
var Name: string;
begin
  Arm;
  FPolicy.Observe([]);
  FPolicy.ConnectionLost(True);
  ReturnDevice;
  FScheduler.Fire;
  AssertEquals(1, FReady);
  AssertTrue(FPolicy.BeginAttempt(Name));
  AssertEquals('port7', Name);
end;

procedure TLazSerialReconnectPolicyTests.SerialAndUsbIdsProvideFallbackIdentity;
var Name: string;
begin
  FDevice.PersistentId := '';
  Arm;
  FPolicy.ConnectionLost(True);
  FDevice.VendorId := 'VID_0403';
  FDevice.ProductId := '0x6001';
  ReturnDevice;
  AssertTrue(FPolicy.BeginAttempt(Name));
  AssertEquals('port7', Name);
  FDevice.SerialShort := 'serial-B';
  FPolicy.Observe([FDevice]);
  AssertFalse(FPolicy.BeginAttempt(Name));
end;

procedure TLazSerialReconnectPolicyTests.NoIdentityNeverUsesPortNameOrVidPidAlone;
begin
  FDevice.PersistentId := '';
  FDevice.SerialShort := '';
  Arm;
  FPolicy.ConnectionLost(True);
  AssertFalse(FPolicy.Pending);
  ReturnDevice;
  AssertFalse(FScheduler.Scheduled);
end;

procedure TLazSerialReconnectPolicyTests.MissingPersistentIdDoesNotWeakenSavedIdentity;
var Name: string;
begin
  Arm;
  FPolicy.ConnectionLost(True);
  FDevice.PersistentId := '';
  ReturnDevice;
  AssertTrue(FPolicy.Pending);
  AssertFalse(FPolicy.BeginAttempt(Name));
  AssertFalse(FScheduler.Scheduled);
end;

procedure TLazSerialReconnectPolicyTests.AmbiguousMatchesWaitWithoutOpening;
var Other: TSerialDeviceInfo; Name: string;
begin
  Arm;
  FPolicy.ConnectionLost(True);
  ReturnDevice;
  Other := FDevice;
  Other.Device := 'port8';
  FPolicy.Observe([FDevice, Other]);
  AssertTrue(FPolicy.Pending);
  AssertFalse(FScheduler.Scheduled);
  AssertFalse(FPolicy.BeginAttempt(Name));
  FPolicy.Observe([FDevice]);
  AssertTrue(FPolicy.BeginAttempt(Name));
end;

procedure TLazSerialReconnectPolicyTests.ReaderFailureWaitsForConfirmedDisappearance;
var Name: string;
begin
  Arm;
  FPolicy.ConnectionLost(False);
  AssertTrue(FPolicy.Pending);
  AssertFalse(FScheduler.Scheduled);
  AssertFalse(FPolicy.BeginAttempt(Name));
  FPolicy.Observe([FDevice]);
  AssertFalse(FScheduler.Scheduled);
  FPolicy.Observe([]);
  ReturnDevice;
  AssertTrue(FPolicy.BeginAttempt(Name));
end;

procedure TLazSerialReconnectPolicyTests.ReaderFailureRecognizesAlreadyRemovedDevice;
var Name: string;
begin
  Arm;
  FPolicy.Observe([]);
  FPolicy.ConnectionLost(False);
  ReturnDevice;
  AssertTrue(FPolicy.BeginAttempt(Name));
end;

procedure TLazSerialReconnectPolicyTests.MetadataCanArriveAfterOpening;
var Name: string;
begin
  FPolicy.Enabled := True;
  FPolicy.Connected(FDevice.Device);
  FPolicy.Observe([FDevice]);
  FPolicy.Observe([]);
  FPolicy.ConnectionLost(True);
  ReturnDevice;
  AssertTrue(FPolicy.BeginAttempt(Name));
end;

procedure TLazSerialReconnectPolicyTests.IdentityDoesNotSwitchToReplacementOnSamePort;
var Other: TSerialDeviceInfo; Name: string;
begin
  Arm;
  Other := FDevice;
  Other.PersistentId := 'another-adapter';
  FPolicy.Observe([Other]);
  FPolicy.ConnectionLost(False);
  AssertFalse(FPolicy.BeginAttempt(Name));
  ReturnDevice;
  AssertTrue(FPolicy.BeginAttempt(Name));
  AssertEquals('port7', Name);
end;

procedure TLazSerialReconnectPolicyTests.AttemptsAreBoundedAcrossSnapshots;
var Name: string; I: Integer;
begin
  Arm;
  FPolicy.ConnectionLost(True);
  ReturnDevice;
  for I := 1 to 5 do
  begin
    FScheduler.Fire;
    AssertTrue(FPolicy.BeginAttempt(Name));
    AssertEquals(I = 5, FPolicy.AttemptFailed);
    FPolicy.Observe([FDevice]);
    AssertEquals(I < 5, FPolicy.Pending);
  end;
  AssertFalse(FScheduler.Scheduled);
  AssertFalse(FPolicy.BeginAttempt(Name));
end;

procedure TLazSerialReconnectPolicyTests.CleanupDeferralDoesNotConsumeAttempts;
var Name: string; I: Integer;
begin
  Arm;
  FPolicy.MaxAttempts := 1;
  FPolicy.IntervalMs := 250;
  FPolicy.ConnectionLost(True);
  ReturnDevice;
  for I := 1 to 10 do
  begin
    FScheduler.Fire;
    FPolicy.DeferAttempt;
    AssertTrue(FScheduler.Scheduled);
    AssertEquals(250, FScheduler.LastDelayMs);
  end;
  AssertTrue(FPolicy.BeginAttempt(Name));
  AssertTrue(FPolicy.AttemptFailed);
end;

procedure TLazSerialReconnectPolicyTests.CancelAndDisableStopPendingWork;
begin
  Arm;
  FPolicy.ConnectionLost(True);
  ReturnDevice;
  FPolicy.Cancel;
  AssertFalse(FPolicy.Pending);
  AssertFalse(FScheduler.Scheduled);
  FPolicy.Observe([FDevice]);
  AssertFalse(FScheduler.Scheduled);
  Arm;
  FPolicy.ConnectionLost(True);
  ReturnDevice;
  FPolicy.Enabled := False;
  AssertFalse(FPolicy.Pending);
  AssertFalse(FScheduler.Scheduled);
end;

procedure TLazSerialReconnectPolicyTests.SuccessStartsFreshBudgetForNextRemoval;
var Name: string;
begin
  Arm;
  FPolicy.MaxAttempts := 1;
  FPolicy.ConnectionLost(True);
  ReturnDevice;
  AssertTrue(FPolicy.BeginAttempt(Name));
  FPolicy.Connected(Name);
  AssertFalse(FPolicy.Pending);
  FPolicy.ConnectionLost(True);
  AssertTrue(FPolicy.BeginAttempt(Name));
  AssertTrue(FPolicy.AttemptFailed);
end;

procedure TLazSerialReconnectPolicyTests.SettingsRejectZero;
begin
  try
    FPolicy.IntervalMs := 0;
    Fail('Zero interval must be rejected');
  except on E: EArgumentException do ; end;
  try
    FPolicy.MaxAttempts := 0;
    Fail('Zero attempts must be rejected');
  except on E: EArgumentException do ; end;
end;

procedure TLazSerialReconnectPolicyTests.PersistentAliasCapturesCanonicalPort;
var Name: string;
begin
  FPolicy.Enabled := True;
  FPolicy.Observe([FDevice]);
  FPolicy.Connected(FDevice.PersistentId);
  FPolicy.ConnectionLost(False);
  AssertFalse(FScheduler.Scheduled);
  FPolicy.Observe([]);
  ReturnDevice;
  AssertTrue(FPolicy.BeginAttempt(Name));
  AssertEquals('port7', Name);
end;

procedure TLazSerialReconnectPolicyTests.ChangedAttemptLimitAppliesToNextRecovery;
var Name: string;
begin
  Arm;
  FPolicy.MaxAttempts := 2;
  FPolicy.ConnectionLost(True);
  FPolicy.MaxAttempts := 1;
  ReturnDevice;
  AssertTrue(FPolicy.BeginAttempt(Name));
  AssertFalse(FPolicy.AttemptFailed);
  AssertTrue(FPolicy.BeginAttempt(Name));
  FPolicy.Connected(Name);
  FPolicy.ConnectionLost(True);
  AssertTrue(FPolicy.BeginAttempt(Name));
  AssertTrue(FPolicy.AttemptFailed);
end;

initialization
  RegisterTest(TLazSerialReconnectPolicyTests);

end.
