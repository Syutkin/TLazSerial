unit LazSerialRead;

{$mode ObjFPC}{$H+}

interface

type
  TSerialReadChanged = procedure of object;

  ISerialReadOperation = interface
    procedure Start;
    procedure Cancel;
    procedure ClosePort;
    procedure Detach;
    function DataAvailable(ALineMode: Boolean): Boolean;
    function TryReadData(ALineMode: Boolean; out AData: AnsiString): Boolean;
    function GetFailure(out AErrorCode: Integer;
      out AErrorMessage: string): Boolean;
    function GetClosePending: Boolean;
  end;

implementation

end.
