unit LazSerialLifecycleTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, FpcUnit, TestRegistry, LazSerial, LazSynaSer;

type
  TLazSerialLifecycleTests = class(TTestCase)
  private
    FCanReadStatusCount: Integer;
    FClosing: Boolean;
    FLateCallbackCount: Integer;
    FSerialCloseCount: Integer;
    FStatusThreadId: TThreadID;
    procedure DataReceived(Sender: TObject);
    procedure StatusChanged(Sender: TObject; Reason: THookSerialReason;
      const Value: string);
  published
    procedure CloseActiveSerialDeliversCloseStatus;
    procedure DestroyActiveSerialDoesNotDeliverCallbackWhileClosing;
    procedure ReceiveStatusRunsOnMainThread;
  end;

implementation

{$IFDEF UNIX}
uses
  BaseUnix, ctypes;

function OpenPty(AMaster, ASlave: pcint; AName: PChar;
  ATermios, AWindowSize: Pointer): cint; cdecl;
  external 'util' name 'openpty';
{$ENDIF}

procedure TLazSerialLifecycleTests.DataReceived(Sender: TObject);
begin
  if FClosing then
    Inc(FLateCallbackCount);
end;

procedure TLazSerialLifecycleTests.StatusChanged(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
begin
  if Reason = HR_SerialClose then
    Inc(FSerialCloseCount)
  else if Reason = HR_CanRead then
  begin
    Inc(FCanReadStatusCount);
    FStatusThreadId := GetCurrentThreadID;
  end;
end;

procedure TLazSerialLifecycleTests.CloseActiveSerialDeliversCloseStatus;
{$IFDEF UNIX}
var
  MasterHandle: cint;
  NameBuffer: array[0..255] of Char;
  Serial: TLazSerial;
  SlaveHandle: cint;
{$ENDIF}
begin
  {$IFDEF UNIX}
  MasterHandle := -1;
  SlaveHandle := -1;
  FillChar(NameBuffer, SizeOf(NameBuffer), 0);
  AssertEquals(
    0,
    OpenPty(@MasterHandle, @SlaveHandle, @NameBuffer[0], nil, nil)
  );
  try
    fpClose(SlaveHandle);
    SlaveHandle := -1;

    FSerialCloseCount := 0;
    Serial := TLazSerial.Create(nil);
    try
      Serial.Device := StrPas(@NameBuffer[0]);
      Serial.OnStatus := @StatusChanged;
      Serial.Active := True;

      Serial.Close;

      AssertFalse(Serial.Active);
      AssertEquals(1, FSerialCloseCount);
    finally
      Serial.Free;
    end;
  finally
    if SlaveHandle >= 0 then
      fpClose(SlaveHandle);
    if MasterHandle >= 0 then
      fpClose(MasterHandle);
  end;
  {$ENDIF}
end;

procedure TLazSerialLifecycleTests.
  DestroyActiveSerialDoesNotDeliverCallbackWhileClosing;
{$IFDEF UNIX}
const
  TestData: AnsiString = 'x';
var
  MasterHandle: cint;
  NameBuffer: array[0..255] of Char;
  Serial: TLazSerial;
  SlaveHandle: cint;
{$ENDIF}
begin
  {$IFDEF UNIX}
  MasterHandle := -1;
  SlaveHandle := -1;
  FillChar(NameBuffer, SizeOf(NameBuffer), 0);
  AssertEquals(
    0,
    OpenPty(@MasterHandle, @SlaveHandle, @NameBuffer[0], nil, nil)
  );
  try
    fpClose(SlaveHandle);
    SlaveHandle := -1;

    FClosing := False;
    FLateCallbackCount := 0;
    Serial := TLazSerial.Create(nil);
    try
      Serial.Device := StrPas(@NameBuffer[0]);
      Serial.OnRxData := @DataReceived;
      Serial.Active := True;
      AssertEquals(
        Length(TestData),
        fpWrite(MasterHandle, TestData[1], Length(TestData))
      );
      Sleep(50);

      FClosing := True;
      Serial.Free;
      Serial := nil;
      FClosing := False;

      AssertEquals(0, FLateCallbackCount);
    finally
      Serial.Free;
    end;
  finally
    if SlaveHandle >= 0 then
      fpClose(SlaveHandle);
    if MasterHandle >= 0 then
      fpClose(MasterHandle);
  end;
  {$ENDIF}
end;

procedure TLazSerialLifecycleTests.ReceiveStatusRunsOnMainThread;
{$IFDEF UNIX}
const
  TestData: AnsiString = 'x';
var
  Deadline: QWord;
  MainThreadId: TThreadID;
  MasterHandle: cint;
  NameBuffer: array[0..255] of Char;
  Serial: TLazSerial;
  SlaveHandle: cint;
{$ENDIF}
begin
  {$IFDEF UNIX}
  MasterHandle := -1;
  SlaveHandle := -1;
  FillChar(NameBuffer, SizeOf(NameBuffer), 0);
  AssertEquals(
    0,
    OpenPty(@MasterHandle, @SlaveHandle, @NameBuffer[0], nil, nil)
  );
  try
    fpClose(SlaveHandle);
    SlaveHandle := -1;

    FCanReadStatusCount := 0;
    FStatusThreadId := 0;
    MainThreadId := GetCurrentThreadID;
    Serial := TLazSerial.Create(nil);
    try
      Serial.Device := StrPas(@NameBuffer[0]);
      Serial.OnStatus := @StatusChanged;
      Serial.Active := True;
      AssertEquals(
        Length(TestData),
        fpWrite(MasterHandle, TestData[1], Length(TestData))
      );

      Deadline := GetTickCount64 + 1000;
      repeat
        CheckSynchronize(10);
      until (FCanReadStatusCount > 0) or (GetTickCount64 >= Deadline);

      AssertTrue('Expected HR_CanRead status', FCanReadStatusCount > 0);
      AssertEquals('Serial status must be delivered on the main thread',
        QWord(MainThreadId), QWord(FStatusThreadId));
    finally
      Serial.Free;
    end;
  finally
    if SlaveHandle >= 0 then
      fpClose(SlaveHandle);
    if MasterHandle >= 0 then
      fpClose(MasterHandle);
  end;
  {$ENDIF}
end;

initialization
  RegisterTest(TLazSerialLifecycleTests);

end.
