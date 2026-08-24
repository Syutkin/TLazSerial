unit LazSerialLifecycleTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, FpcUnit, TestRegistry, LazSerial, LazSynaSer;

type
  TLazSerialLifecycleTests = class(TTestCase)
  private
    FCallbackCount: Integer;
    FCallbackSerial: TLazSerial;
    FCanReadStatusCount: Integer;
    FClosing: Boolean;
    FDataCallbackCount: Integer;
    FLateCallbackCount: Integer;
    FSerialCloseCount: Integer;
    FStatusThreadId: TThreadID;
    procedure CloseFromData(Sender: TObject);
    procedure ConsumeData(Sender: TObject);
    procedure DataReceived(Sender: TObject);
    procedure DestroyFromReadStatus(Sender: TObject;
      Reason: THookSerialReason; const Value: string);
    procedure RaiseOnceFromData(Sender: TObject);
    procedure RaiseOnceFromReadStatus(Sender: TObject;
      Reason: THookSerialReason; const Value: string);
    procedure StatusChanged(Sender: TObject; Reason: THookSerialReason;
      const Value: string);
  published
    procedure CloseFromReceiveCallbackDoesNotDeadlock;
    procedure CloseActiveSerialDeliversCloseStatus;
    procedure DestroyActiveSerialDoesNotDeliverCallbackWhileClosing;
    procedure DestroyFromReadStatusDoesNotDeadlock;
    procedure ReceiveCallbackExceptionDoesNotStopReader;
    procedure ReceiveStatusRunsOnMainThread;
    procedure StatusCallbackExceptionDoesNotStopReader;
  end;

implementation

{$IFDEF UNIX}
uses
  BaseUnix, ctypes;

function OpenPty(AMaster, ASlave: pcint; AName: PChar;
  ATermios, AWindowSize: Pointer): cint; cdecl;
  external 'util' name 'openpty';
{$ENDIF}

const
  CallbackExceptionMessage = 'intentional serial callback exception';

procedure TLazSerialLifecycleTests.CloseFromData(Sender: TObject);
begin
  Inc(FCallbackCount);
  TLazSerial(Sender).ReadData;
  TLazSerial(Sender).Close;
end;

procedure TLazSerialLifecycleTests.ConsumeData(Sender: TObject);
begin
  Inc(FDataCallbackCount);
  TLazSerial(Sender).ReadData;
end;

procedure TLazSerialLifecycleTests.DataReceived(Sender: TObject);
begin
  if FClosing then
    Inc(FLateCallbackCount);
end;

procedure TLazSerialLifecycleTests.DestroyFromReadStatus(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
var
  Serial: TLazSerial;
begin
  if Reason <> HR_CanRead then
    Exit;

  Inc(FCallbackCount);
  Serial := FCallbackSerial;
  FCallbackSerial := nil;
  Serial.Free;
end;

procedure TLazSerialLifecycleTests.RaiseOnceFromData(Sender: TObject);
begin
  Inc(FCallbackCount);
  TLazSerial(Sender).ReadData;
  if FCallbackCount = 1 then
    raise Exception.Create(CallbackExceptionMessage);
end;

procedure TLazSerialLifecycleTests.RaiseOnceFromReadStatus(Sender: TObject;
  Reason: THookSerialReason; const Value: string);
begin
  if Reason <> HR_CanRead then
    Exit;

  Inc(FCallbackCount);
  if FCallbackCount = 1 then
    raise Exception.Create(CallbackExceptionMessage);
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

procedure TLazSerialLifecycleTests.CloseFromReceiveCallbackDoesNotDeadlock;
{$IFDEF UNIX}
const
  TestData: AnsiString = 'x';
var
  Deadline: QWord;
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
  AssertEquals(0, OpenPty(@MasterHandle, @SlaveHandle, @NameBuffer[0], nil,
    nil));
  try
    fpClose(SlaveHandle);
    SlaveHandle := -1;

    FCallbackCount := 0;
    Serial := TLazSerial.Create(nil);
    try
      Serial.Device := StrPas(@NameBuffer[0]);
      Serial.OnRxData := @CloseFromData;
      Serial.Active := True;
      AssertEquals(Length(TestData),
        fpWrite(MasterHandle, TestData[1], Length(TestData)));

      Deadline := GetTickCount64 + 1000;
      repeat
        CheckSynchronize(10);
      until (FCallbackCount > 0) or (GetTickCount64 >= Deadline);

      AssertEquals(1, FCallbackCount);
      AssertFalse(Serial.Active);
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

      CheckSynchronize(100);
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

procedure TLazSerialLifecycleTests.DestroyFromReadStatusDoesNotDeadlock;
{$IFDEF UNIX}
const
  TestData: AnsiString = 'x';
var
  Deadline: QWord;
  MasterHandle: cint;
  NameBuffer: array[0..255] of Char;
  SlaveHandle: cint;
{$ENDIF}
begin
  {$IFDEF UNIX}
  MasterHandle := -1;
  SlaveHandle := -1;
  FillChar(NameBuffer, SizeOf(NameBuffer), 0);
  AssertEquals(0, OpenPty(@MasterHandle, @SlaveHandle, @NameBuffer[0], nil,
    nil));
  try
    fpClose(SlaveHandle);
    SlaveHandle := -1;

    FCallbackCount := 0;
    FCallbackSerial := TLazSerial.Create(nil);
    try
      FCallbackSerial.Device := StrPas(@NameBuffer[0]);
      FCallbackSerial.OnStatus := @DestroyFromReadStatus;
      FCallbackSerial.Active := True;
      AssertEquals(Length(TestData),
        fpWrite(MasterHandle, TestData[1], Length(TestData)));

      Deadline := GetTickCount64 + 1000;
      repeat
        CheckSynchronize(10);
      until (FCallbackSerial = nil) or (GetTickCount64 >= Deadline);

      AssertEquals(1, FCallbackCount);
      AssertNull(FCallbackSerial);
    finally
      FreeAndNil(FCallbackSerial);
    end;
  finally
    if SlaveHandle >= 0 then
      fpClose(SlaveHandle);
    if MasterHandle >= 0 then
      fpClose(MasterHandle);
  end;
  {$ENDIF}
end;

procedure TLazSerialLifecycleTests.ReceiveCallbackExceptionDoesNotStopReader;
{$IFDEF UNIX}
const
  FirstData: AnsiString = 'x';
  SecondData: AnsiString = 'y';
var
  CallbackExceptionSeen: Boolean;
  Deadline: QWord;
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
  AssertEquals(0, OpenPty(@MasterHandle, @SlaveHandle, @NameBuffer[0], nil,
    nil));
  try
    fpClose(SlaveHandle);
    SlaveHandle := -1;

    CallbackExceptionSeen := False;
    FCallbackCount := 0;
    Serial := TLazSerial.Create(nil);
    try
      Serial.Device := StrPas(@NameBuffer[0]);
      Serial.OnRxData := @RaiseOnceFromData;
      Serial.Active := True;
      AssertEquals(Length(FirstData),
        fpWrite(MasterHandle, FirstData[1], Length(FirstData)));

      Deadline := GetTickCount64 + 1000;
      repeat
        try
          CheckSynchronize(10);
        except
          on E: Exception do
            if E.Message = CallbackExceptionMessage then
              CallbackExceptionSeen := True
            else
              raise;
        end;
      until (FCallbackCount > 0) or (GetTickCount64 >= Deadline);

      AssertTrue('Expected callback exception on the main thread',
        CallbackExceptionSeen);
      AssertEquals(Length(SecondData),
        fpWrite(MasterHandle, SecondData[1], Length(SecondData)));

      Deadline := GetTickCount64 + 1000;
      repeat
        CheckSynchronize(10);
      until (FCallbackCount > 1) or (GetTickCount64 >= Deadline);
      AssertEquals(2, FCallbackCount);
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

procedure TLazSerialLifecycleTests.StatusCallbackExceptionDoesNotStopReader;
{$IFDEF UNIX}
const
  FirstData: AnsiString = 'x';
  SecondData: AnsiString = 'y';
var
  CallbackExceptionSeen: Boolean;
  Deadline: QWord;
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
  AssertEquals(0, OpenPty(@MasterHandle, @SlaveHandle, @NameBuffer[0], nil,
    nil));
  try
    fpClose(SlaveHandle);
    SlaveHandle := -1;

    CallbackExceptionSeen := False;
    FCallbackCount := 0;
    FDataCallbackCount := 0;
    Serial := TLazSerial.Create(nil);
    try
      Serial.Device := StrPas(@NameBuffer[0]);
      Serial.OnRxData := @ConsumeData;
      Serial.OnStatus := @RaiseOnceFromReadStatus;
      Serial.Active := True;
      AssertEquals(Length(FirstData),
        fpWrite(MasterHandle, FirstData[1], Length(FirstData)));

      Deadline := GetTickCount64 + 1000;
      repeat
        try
          CheckSynchronize(10);
        except
          on E: Exception do
            if E.Message = CallbackExceptionMessage then
              CallbackExceptionSeen := True
            else
              raise;
        end;
      until (FDataCallbackCount > 0) or (GetTickCount64 >= Deadline);

      AssertTrue('Expected status exception on the main thread',
        CallbackExceptionSeen);
      AssertEquals(1, FCallbackCount);
      AssertEquals(Length(SecondData),
        fpWrite(MasterHandle, SecondData[1], Length(SecondData)));

      Deadline := GetTickCount64 + 1000;
      repeat
        CheckSynchronize(10);
      until (FCallbackCount > 1) or (GetTickCount64 >= Deadline);
      AssertEquals(2, FCallbackCount);
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
