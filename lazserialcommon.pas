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

implementation

end.
