unit LazSerialPortSessionTests;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, SyncObjs, FpcUnit, TestRegistry, LazSynaSer, LazSerialWrite;

type
  TLazSerialPortSessionTests = class(TTestCase)
  published
    procedure CloseWaitsForBothReleaseOrders;
    procedure ClosingRejectsNewReservations;
    procedure ClosingWithoutOperationsDoesNotWaitForNativeClose;
  end;

implementation

type
  TCloseState = class(TInterfacedObject)
  public
    Entered, Released: TEvent;
    Calls: LongInt;
    ThreadId: TThreadID;
    constructor Create;
    destructor Destroy; override;
  end;

  TSessionSerial = class(TBlockSerial)
  private
    FState: TCloseState;
    FReference: IInterface;
  public
    constructor Create(AState: TCloseState);
    procedure CloseSocket; override;
  end;

constructor TCloseState.Create;
begin
  inherited Create;
  Entered := TEvent.Create(nil, True, False, '');
  Released := TEvent.Create(nil, True, False, '');
end;

destructor TCloseState.Destroy;
begin
  Entered.Free;
  Released.Free;
  inherited Destroy;
end;

constructor TSessionSerial.Create(AState: TCloseState);
begin
  inherited Create;
  FState := AState;
  FReference := AState;
  FInstanceActive := True;
end;

procedure TSessionSerial.CloseSocket;
begin
  if not FInstanceActive then Exit;
  FState.ThreadId := GetCurrentThreadID;
  InterlockedIncrement(FState.Calls);
  FState.Entered.SetEvent;
  FState.Released.WaitFor(2000);
  FInstanceActive := False;
end;

procedure AwaitClosed(const Port: ISerialPortLifecycle);
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + 2000;
  while Port.GetClosePending and (GetTickCount64 < Deadline) do Sleep(1);
  TAssert.AssertFalse('Native close did not finish', Port.GetClosePending);
end;

procedure TLazSerialPortSessionTests.CloseWaitsForBothReleaseOrders;
var
  State: TCloseState;
  Reference: IInterface;
  Port: ISerialPortLifecycle;
  ReadFirst: Boolean;
begin
  for ReadFirst := False to True do
  begin
    State := TCloseState.Create;
    Reference := State;
    Port := TSerialWritePort.Create(TSessionSerial.Create(State));
    try
      Port.AcquireIO(True);
      Port.AcquireIO(False);
      Port.RequestClose;
      AssertTrue(Port.GetClosePending);
      Port.ReleaseIO(ReadFirst);
      AssertEquals('Remaining operation retains the handle', 0, State.Calls);
      Port.ReleaseIO(not ReadFirst);
      AssertEquals(Ord(wrSignaled), Ord(State.Entered.WaitFor(2000)));
      AssertTrue(Port.GetClosePending);
      State.Released.SetEvent;
      AwaitClosed(Port);
      Port.RequestClose;
      AssertEquals('Repeated close does not close twice', 1, State.Calls);
      AssertTrue(State.ThreadId <> MainThreadID);
    finally
      State.Released.SetEvent;
      Port := nil;
      Reference := nil;
    end;
  end;
end;

procedure TLazSerialPortSessionTests.ClosingRejectsNewReservations;
var
  Port: ISerialPortLifecycle;
  State: TCloseState;
  Reference: IInterface;
  Raised: Boolean;
begin
  State := TCloseState.Create;
  Reference := State;
  Port := TSerialWritePort.Create(TSessionSerial.Create(State));
  try
    Port.AcquireIO(True);
    Port.RequestClose;
    Raised := False;
    try Port.AcquireIO(False);
    except on E: EInvalidOperation do Raised := True; end;
    AssertTrue(Raised);
    Port.ReleaseIO(True);
    State.Released.SetEvent;
    AwaitClosed(Port);
  finally
    State.Released.SetEvent;
    Port := nil;
    Reference := nil;
  end;
end;

procedure TLazSerialPortSessionTests.ClosingWithoutOperationsDoesNotWaitForNativeClose;
var
  Port: ISerialPortLifecycle;
  State: TCloseState;
  Reference: IInterface;
begin
  State := TCloseState.Create;
  Reference := State;
  Port := TSerialWritePort.Create(TSessionSerial.Create(State));
  try
    Port.RequestClose;
    AssertEquals(Ord(wrSignaled), Ord(State.Entered.WaitFor(2000)));
    AssertTrue('Close returns while native cleanup is held', Port.GetClosePending);
    AssertTrue(State.ThreadId <> MainThreadID);
    State.Released.SetEvent;
    AwaitClosed(Port);
  finally
    State.Released.SetEvent;
    Port := nil;
    Reference := nil;
  end;
end;

initialization
  RegisterTest(TLazSerialPortSessionTests);
end.
