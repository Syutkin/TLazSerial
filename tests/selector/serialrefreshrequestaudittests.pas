unit SerialRefreshRequestAuditTests;
{$mode objfpc}{$H+}
interface
uses Classes, SyncObjs, FpcUnit, TestRegistry, LazSerialDevices,
  SerialSelectorComponentTests;
type
  TSerialRefreshRequestAuditTests = class(TTestCase)
  published
    procedure ManualRefreshDuringLoadPublishesLatestSnapshot;
    procedure RefreshFromApplyDoesNotLoop;
  end;
implementation
procedure TSerialRefreshRequestAuditTests.ManualRefreshDuringLoadPublishesLatestSnapshot;
var
  Selector: TBackgroundTestSerialSelector;
  Started, Released: TEvent;
  OldDevice, NewDevice: TSerialDeviceInfo;
begin
  Started := TEvent.Create(nil, True, False, '');
  Released := TEvent.Create(nil, True, False, '');
  Selector := TBackgroundTestSerialSelector.Create(nil);
  try
    OldDevice := Default(TSerialDeviceInfo);
    OldDevice.Device := 'COM1';
    NewDevice := Default(TSerialDeviceInfo);
    NewDevice.Device := 'COM2';
    Selector.LoadStarted := Started;
    Selector.ReleaseLoad := Released;
    Selector.SetSnapshot([OldDevice]);
    Selector.Refresh;
    AssertEquals(Ord(wrSignaled), Ord(Started.WaitFor(1000)));
    Selector.SetSnapshot([NewDevice]);
    Selector.Refresh;
    Selector.Refresh;
    AssertEquals(1, Selector.LoadCount);
    Released.SetEvent;
    Selector.WaitForRefresh;
    AssertTrue('Coalesce manual requests into a subsequent refresh',
      Selector.RefreshScheduled);
    Selector.FireScheduledRefresh;
    Selector.WaitForRefresh;
    AssertEquals(2, Selector.LoadCount);
    AssertEquals('COM2', Selector.Device);
    AssertFalse(Selector.RefreshScheduled);
  finally
    Released.SetEvent;
    Selector.Free;
    Released.Free;
    Started.Free;
  end;
end;
procedure TSerialRefreshRequestAuditTests.RefreshFromApplyDoesNotLoop;
var Selector: TBackgroundTestSerialSelector; Device: TSerialDeviceInfo;
begin
  Selector := TBackgroundTestSerialSelector.Create(nil);
  try
    Device := Default(TSerialDeviceInfo);
    Device.Device := 'COM1';
    Selector.SetSnapshot([Device]);
    Selector.RefreshDuringApply := True;
    Selector.Refresh;
    Selector.WaitForRefresh;
    AssertEquals(1, Selector.LoadCount);
    AssertFalse(Selector.RefreshScheduled);
  finally Selector.Free; end;
end;
initialization RegisterTest(TSerialRefreshRequestAuditTests);
end.
