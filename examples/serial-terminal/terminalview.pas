unit TerminalView;

{$mode ObjFPC}{$H+}

interface

uses Classes, SysUtils, Contnrs, Controls, Graphics, StdCtrls, ExtCtrls, Types;

const
  TerminalBackground = $000E0E0E;
  TerminalText = $00E6E6E6;
  TerminalMuted = $00BFC4CC;
  TerminalGreen = $0076D52B;
  TerminalAmber = $0065CBE8;
  TerminalRed = $007779EF;

type
  TTerminalView = class
  private
    FSurface: TPaintBox;
    FMemo: TMemo;
    FConnectionLabel, FStateLabel, FModeLabel, FRatesLabel, FBufferLabel,
      FDetailLabel: TLabel;
    FEntries: TObjectList;
    FBytes: SizeInt;
    FDirty, FHex, FPaused: Boolean;
    function S(AValue: Integer): Integer;
    procedure SetHex(AValue: Boolean);
    procedure SetPaused(AValue: Boolean);
    procedure UpdateMode;
    procedure Paint(Sender: TObject);
    procedure AddEntry(const ADirection: string; const AData: AnsiString;
      const ANote: string);
  public
    constructor Create(ASurface: TPaintBox; AMemo: TMemo;
      AConnectionLabel, AStateLabel, AModeLabel, ARatesLabel, ABufferLabel,
      ADetailLabel: TLabel);
    destructor Destroy; override;
    procedure AddData(const ADirection: string; const AData: AnsiString);
    procedure AddMessage(const AText: string);
    procedure Clear;
    procedure RefreshDisplay;
    procedure Invalidate;
    procedure Repaint;
    procedure SetConnection(const ADescription, AState: string; AColor: TColor);
    procedure SetStatistics(const ARates, ABuffer, ADetail: string);
    property HexView: Boolean read FHex write SetHex;
    property Paused: Boolean read FPaused write SetPaused;
  end;

procedure PaintTerminalButton(AButton: TPanel; AAccent: Boolean);

function HexBytes(const AData: AnsiString): string;
function AsciiBytes(const AData: AnsiString): string;

implementation

const
  MaxEntries = 1000;
  MaxDisplayBytes = 65536;
  MaxEntryBytes = 1024;

type
  TTerminalEntry = class
    Stamp, Direction, Note: string;
    Data: AnsiString;
    OriginalSize: SizeInt;
  end;

function HexBytes(const AData: AnsiString): string;
const Digits: array[0..15] of Char = '0123456789ABCDEF';
var I, B: Integer;
begin
  if AData = '' then Exit('');
  SetLength(Result, Length(AData) * 3 - 1);
  for I := 1 to Length(AData) do
  begin
    B := Ord(AData[I]);
    Result[I * 3 - 2] := Digits[B shr 4];
    Result[I * 3 - 1] := Digits[B and 15];
    if I < Length(AData) then Result[I * 3] := ' ';
  end;
end;

function AsciiBytes(const AData: AnsiString): string;
var I: Integer;
begin
  Result := '';
  for I := 1 to Length(AData) do
    case AData[I] of
      #0: Result := Result + '\0';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #32..#126: Result := Result + AData[I];
    else
      Result := Result + '\x' + IntToHex(Ord(AData[I]), 2);
    end;
end;

constructor TTerminalView.Create(ASurface: TPaintBox; AMemo: TMemo;
  AConnectionLabel, AStateLabel, AModeLabel, ARatesLabel, ABufferLabel,
  ADetailLabel: TLabel);
begin
  inherited Create;
  FSurface := ASurface;
  FMemo := AMemo;
  FConnectionLabel := AConnectionLabel;
  FStateLabel := AStateLabel;
  FModeLabel := AModeLabel;
  FRatesLabel := ARatesLabel;
  FBufferLabel := ABufferLabel;
  FDetailLabel := ADetailLabel;
  FEntries := TObjectList.Create(True);
  FHex := True;
  FSurface.OnPaint := @Paint;
  UpdateMode;
end;

destructor TTerminalView.Destroy;
begin
  FSurface.OnPaint := nil;
  FEntries.Free;
  inherited Destroy;
end;

function TTerminalView.S(AValue: Integer): Integer;
begin Result := FSurface.Scale96ToForm(AValue); end;

procedure TTerminalView.Invalidate;
begin FSurface.Invalidate; end;

procedure TTerminalView.Repaint;
begin FSurface.Parent.Repaint; end;

procedure TTerminalView.Paint(Sender: TObject);
var R: TRect; X, Y, W, H: Integer; Canvas: TCanvas;
begin
  Canvas := FSurface.Canvas;
  W := FSurface.Width;
  H := FSurface.Height;
  Canvas.Brush.Color := TerminalBackground;
  Canvas.FillRect(FSurface.ClientRect);
  Canvas.Pen.Color := $00333333;
  Canvas.Brush.Color := $000F0F0F;
  Canvas.RoundRect(0, 0, W - 1, H - 1, S(12), S(12));
  // Small cable icon, kept as vector drawing at every display scale.
  X := S(28); Y := S(80);
  Canvas.Pen.Color := TerminalMuted;
  Canvas.Pen.Width := S(2);
  Canvas.Line(X, Y, X, Y + S(13));
  Canvas.Line(X + S(10), Y, X + S(10), Y + S(13));
  Canvas.Line(X, Y + S(13), X + S(5), Y + S(16));
  Canvas.Line(X + S(5), Y + S(16), X + S(10), Y + S(13));
  Canvas.Line(X + S(5), Y + S(16), X + S(5), Y + S(20));
  Canvas.Line(X - S(2), Y + S(3), X + S(2), Y + S(3));
  Canvas.Line(X + S(8), Y + S(3), X + S(12), Y + S(3));
  Canvas.Pen.Width := 1;
  Canvas.Pen.Color := $00202020;
  Canvas.Line(S(26), S(122), W - S(26), S(122));
  R := Rect(S(26), S(143), W - S(26), H - S(62));
  Canvas.Brush.Color := $002F2F2F;
  Canvas.Pen.Color := $002F2F2F;
  Canvas.RoundRect(R, S(10), S(10));
end;

procedure TTerminalView.AddEntry(const ADirection: string; const AData: AnsiString;
  const ANote: string);
var Entry: TTerminalEntry;
begin
  if FPaused then Exit;
  Entry := TTerminalEntry.Create;
  Entry.Stamp := FormatDateTime('hh:nn:ss.zzz', Now);
  Entry.Direction := ADirection;
  Entry.Note := ANote;
  Entry.OriginalSize := Length(AData);
  Entry.Data := Copy(AData, 1, MaxEntryBytes);
  FEntries.Add(Entry);
  Inc(FBytes, Length(Entry.Data));
  while (FEntries.Count > MaxEntries) or (FBytes > MaxDisplayBytes) do
  begin
    Dec(FBytes, Length(TTerminalEntry(FEntries[0]).Data));
    FEntries.Delete(0);
  end;
  FDirty := True;
end;

procedure TTerminalView.AddData(const ADirection: string; const AData: AnsiString);
begin AddEntry(ADirection, AData, ''); end;
procedure TTerminalView.AddMessage(const AText: string);
begin AddEntry('INFO', '', AText); end;

procedure TTerminalView.Clear;
begin
  FEntries.Clear;
  FBytes := 0;
  FDirty := False;
  FMemo.Clear;
end;

procedure TTerminalView.SetHex(AValue: Boolean);
begin
  if FHex = AValue then Exit;
  FHex := AValue;
  FDirty := True;
  UpdateMode;
end;

procedure TTerminalView.SetPaused(AValue: Boolean);
begin
  if FPaused = AValue then Exit;
  FPaused := AValue;
  UpdateMode;
end;

procedure TTerminalView.UpdateMode;
begin
  if FPaused then FModeLabel.Caption := 'RX / TX ' + #$C2#$B7 + ' Paused'
  else if FHex then FModeLabel.Caption := 'RX / TX ' + #$C2#$B7 + ' HEX view'
  else FModeLabel.Caption := 'RX / TX ' + #$C2#$B7 + ' ASCII view';
end;

procedure TTerminalView.RefreshDisplay;
var Lines: TStringList; Entry: TTerminalEntry; I, Offset: Integer; Part: AnsiString;
begin
  if not FDirty or FPaused then Exit;
  Lines := TStringList.Create;
  try
    for I := 0 to FEntries.Count - 1 do
    begin
      Entry := TTerminalEntry(FEntries[I]);
      if Entry.Note <> '' then
        Lines.Add(Entry.Stamp + '  ' + Entry.Direction + '  ' + Entry.Note)
      else
      begin
        Offset := 1;
        while Offset <= Length(Entry.Data) do
        begin
          Part := Copy(Entry.Data, Offset, 24);
          if FHex then
            Lines.Add(Entry.Stamp + '  ' + Entry.Direction + '  ' + HexBytes(Part))
          else
            Lines.Add(Entry.Stamp + '  ' + Entry.Direction + '  ' + AsciiBytes(Part));
          Inc(Offset, 24);
        end;
        if Entry.OriginalSize > Length(Entry.Data) then
          Lines.Add(Entry.Stamp + '  ' + Entry.Direction + '  [' +
            IntToStr(Entry.OriginalSize - Length(Entry.Data)) + ' bytes not shown]');
      end;
    end;
    // Bound rendered text as well as retained payloads.
    while Lines.Count > 2000 do Lines.Delete(0);
    FMemo.Lines.Assign(Lines);
    FMemo.SelStart := Length(FMemo.Text);
    FDirty := False;
  finally Lines.Free; end;
end;

procedure TTerminalView.SetConnection(const ADescription, AState: string; AColor: TColor);
begin
  FConnectionLabel.Caption := ADescription;
  FStateLabel.Caption := AState;
  FStateLabel.Font.Color := AColor;
end;

procedure TTerminalView.SetStatistics(const ARates, ABuffer, ADetail: string);
begin
  FRatesLabel.Caption := ARates;
  FBufferLabel.Caption := ABuffer;
  FDetailLabel.Caption := ADetail;
  FSurface.Hint := ADetail;
  FDetailLabel.Hint := ADetail;
end;

procedure PaintTerminalButton(AButton: TPanel; AAccent: Boolean);
var Canvas: TCanvas; W, H: Integer;
begin
  Canvas := AButton.Canvas;
  W := AButton.Width;
  H := AButton.Height;
  Canvas.Brush.Color := TerminalBackground;
  Canvas.FillRect(AButton.ClientRect);
  Canvas.Pen.Color := $00444444;
  if AAccent and AButton.Enabled then
  begin
    Canvas.Brush.Color := $002B4023;
    Canvas.Pen.Color := $004F703C;
  end
  else Canvas.Brush.Color := $00222222;
  Canvas.RoundRect(0, 0, W - 1, H - 1, 8, 8);
  Canvas.Font.Assign(AButton.Font);
  if not AButton.Enabled then Canvas.Font.Color := $00777777;
  Canvas.Brush.Style := bsClear;
  Canvas.TextOut((W - Canvas.TextWidth(AButton.Caption)) div 2,
    (H - Canvas.TextHeight(AButton.Caption)) div 2, AButton.Caption);
  if AButton.Focused then
  begin
    Canvas.Pen.Style := psDot;
    Canvas.RoundRect(3, 3, W - 4, H - 4, 6, 6);
    Canvas.Pen.Style := psSolid;
  end;
end;

end.
