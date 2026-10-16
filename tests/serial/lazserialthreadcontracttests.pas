unit LazSerialThreadContractTests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, TypInfo, FpcUnit, TestRegistry, LazSerial,
  LazSerialCommon;

type
  TSerialThreadOperation = (
    stoOpen,
    stoClose,
    stoShowSetupDialog,
    stoDataAvailable,
    stoReadData,
    stoWriteData,
    stoWriteBuffer,
    stoModemSignals,
    stoGetDSR,
    stoGetCTS,
    stoGetRing,
    stoGetCarrier,
    stoSetDTR,
    stoSetRTS,
    stoSetActive,
    stoSetBaudRate,
    stoSetCustomBaudRate,
    stoSetDataBits,
    stoSetParity,
    stoSetFlowControl,
    stoSetStopBits,
    stoSetDevice,
    stoSetRcvLineCRLF,
    stoGetSynSer
  );

  TSerialThreadCall = class(TThread)
  private
    FOperation: TSerialThreadOperation;
    FRejected: Boolean;
    FSerial: TLazSerial;
  protected
    procedure Execute; override;
  public
    constructor Create(ASerial: TLazSerial;
      AOperation: TSerialThreadOperation);
    property Rejected: Boolean read FRejected;
  end;

  TLazSerialThreadContractTests = class(TTestCase)
  private
    procedure AssertRejectedFromWorkerThread(
      ASerial: TLazSerial; AOperation: TSerialThreadOperation);
  published
    procedure TransportOperationsRequireMainThread;
    procedure SerialSettingsRequireMainThread;
    procedure SynSerAccessRequiresMainThread;
  end;

implementation

constructor TSerialThreadCall.Create(ASerial: TLazSerial;
  AOperation: TSerialThreadOperation);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FSerial := ASerial;
  FOperation := AOperation;
  FRejected := False;
end;

procedure TSerialThreadCall.Execute;
var
  Buffer: Byte;
begin
  Buffer := 0;
  try
    case FOperation of
      stoOpen:
        FSerial.Open;
      stoClose:
        FSerial.Close;
      stoShowSetupDialog:
        FSerial.ShowSetupDialog;
      stoDataAvailable:
        if FSerial.DataAvailable then
          FRejected := False;
      stoReadData:
        FSerial.ReadData;
      stoWriteData:
        FSerial.WriteData('test');
      stoWriteBuffer:
        FSerial.WriteBuffer(Buffer, SizeOf(Buffer));
      stoModemSignals:
        if FSerial.ModemSignals <> [] then
          FRejected := False;
      stoGetDSR:
        if FSerial.GetDSR then
          FRejected := False;
      stoGetCTS:
        if FSerial.GetCTS then
          FRejected := False;
      stoGetRing:
        if FSerial.GetRing then
          FRejected := False;
      stoGetCarrier:
        if FSerial.GetCarrier then
          FRejected := False;
      stoSetDTR:
        FSerial.SetDTR(False);
      stoSetRTS:
        FSerial.SetRTS(False);
      stoSetActive:
        FSerial.Active := False;
      stoSetBaudRate:
        FSerial.BaudRate := br__9600;
      stoSetCustomBaudRate:
        FSerial.CustomBaudRate := -1;
      stoSetDataBits:
        FSerial.DataBits := db8bits;
      stoSetParity:
        FSerial.Parity := pNone;
      stoSetFlowControl:
        FSerial.FlowControl := fcNone;
      stoSetStopBits:
        FSerial.StopBits := sbOne;
      stoSetDevice:
        FSerial.Device := 'test';
      stoSetRcvLineCRLF:
        FSerial.RcvLineCRLF := False;
      stoGetSynSer:
        if FSerial.SynSer.LastError <> 0 then
          FRejected := False;
    end;
  except
    on E: ELazSerialThreadError do
      FRejected := True;
  end;
end;

procedure TLazSerialThreadContractTests.AssertRejectedFromWorkerThread(
  ASerial: TLazSerial; AOperation: TSerialThreadOperation);
var
  Thread: TSerialThreadCall;
begin
  Thread := TSerialThreadCall.Create(ASerial, AOperation);
  try
    Thread.Start;
    Thread.WaitFor;
    AssertTrue('Worker-thread transport call must be rejected',
      Thread.Rejected);
  finally
    Thread.Free;
  end;
end;

procedure TLazSerialThreadContractTests.TransportOperationsRequireMainThread;
var
  Operation: TSerialThreadOperation;
  Serial: TLazSerial;
begin
  Serial := TLazSerial.Create(nil);
  try
    for Operation := stoOpen to stoSetRTS do
      AssertRejectedFromWorkerThread(Serial, Operation);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialThreadContractTests.SerialSettingsRequireMainThread;
var
  Operation: TSerialThreadOperation;
  Serial: TLazSerial;
begin
  Serial := TLazSerial.Create(nil);
  try
    for Operation := stoSetActive to stoSetRcvLineCRLF do
      AssertRejectedFromWorkerThread(Serial, Operation);
  finally
    Serial.Free;
  end;
end;

procedure TLazSerialThreadContractTests.SynSerAccessRequiresMainThread;
var
  PropInfo: PPropInfo;
  Serial: TLazSerial;
begin
  Serial := TLazSerial.Create(nil);
  try
    PropInfo := GetPropInfo(Serial, 'SynSer');
    AssertNotNull('SynSer must remain a published property', PropInfo);
    AssertTrue('SynSer must not expose a writer', PropInfo^.SetProc = nil);
    AssertNotNull(Serial.SynSer);
    AssertRejectedFromWorkerThread(Serial, stoGetSynSer);
  finally
    Serial.Free;
  end;
end;

initialization
  RegisterTest(TLazSerialThreadContractTests);

end.
