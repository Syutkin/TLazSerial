unit LazSerialCommon;

{$mode ObjFPC}{$H+}

interface

resourcestring
  lngAddedPorts = 'Added ports: ';
  lngRemovedPorts = 'Removed ports: ';
  lngNoDevicesAvailable = 'No devices available';
  lngManualDevice = 'Manual device: %s';

  lngNone = 'None';
  lngXonXoff_DTR = 'XonXoff w DTR';
  lngRTS_CTS = 'RTS CTS';
  lngXonXoff = 'XonXoff w/o DTR';
  lngXonXoff_and_RTS_CTS = 'XonXoff RTS CTS';
  lngDTR_DSR = 'DTR DSR';
  lngXonXoff_and_DTR_DSR = 'XonXoff DTR DSR';
  lngDTR = 'DTR';

  lngOdd = 'Odd';
  lngEven = 'Even';
  lngMark = 'Mark';
  lngSpace = 'Space';

type
  TSerialOpenLineState = (olsDefault, olsInactive, olsActive);

  TSerialWriteOutcome = (swoCompleted, swoFailed, swoCancelled, swoTimedOut);

  TSerialWriteResult = record
    OperationId: QWord;
    BytesRequested: Integer;
    BytesWritten: Integer;
    Outcome: TSerialWriteOutcome;
    ErrorCode: Integer;
    ErrorMessage: string;
  end;

  TFlowControl = (
    fcNone = 0,
    fcXonXoff = 1,
    fcHardware = 2,
    fcXonXoff_no_DTR = 3,
    fcXonXoff_and_RTS_CTS = 4,
    fcDTR_DSR = 5,
    fcXonXoff_and_DTR_DSR = 6,
    fcDTR = 7,
    fcXonXoff_and_DTR = 1,
    fcRTS_CTS = 2
  );

const
  ErrReadBufferOverflow = 9990;
  Cr = #$0D;
  Lf = #$0A;
  CrLf = Cr + Lf;
  cSerialChunk = 8192;

procedure ValidateSerialOpenLines(ADtr, ARts: TSerialOpenLineState;
  AFlowControl: TFlowControl);

implementation

uses SysUtils;

procedure ValidateSerialOpenLines(ADtr, ARts: TSerialOpenLineState;
  AFlowControl: TFlowControl);
begin
  if (ADtr <> olsDefault) and
    (AFlowControl in [fcDTR_DSR, fcXonXoff_and_DTR_DSR]) then
    raise EArgumentException.Create('DtrOnOpen conflicts with DTR handshaking');
  if (ADtr = olsInactive) and
    (AFlowControl in [fcDTR, fcXonXoff_and_DTR, fcXonXoff_and_RTS_CTS]) then
    raise EArgumentException.Create('Flow control requires an active DTR line');
  if (ARts <> olsDefault) and
    (AFlowControl in [fcRTS_CTS, fcXonXoff_and_RTS_CTS,
      fcDTR_DSR, fcXonXoff_and_DTR_DSR]) then
    raise EArgumentException.Create('RtsOnOpen conflicts with driver-controlled RTS');
end;

end.
