unit ExternalRecord;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Math,
  System.DateUtils,
  ExternalTypes,
  EncodingUtils;

type
  TExt_Record = class
  private
    FBuffer: TBytes;
    FPos: Integer; // 1-based position for backward compatibility with pb/common/Ext_Record.pas
    FCapacity: Integer;
    FEncoding: TEncoding;
    FOwnsEncoding: Boolean;

    function GetLine: string;
    function GetLineAnsi: AnsiString;
    function GetRecordLength: Integer;
    procedure EnsureCapacity(const ANeeded: Integer);
    procedure SetEncoding(const Value: TEncoding);
  protected
    procedure CheckOffset(ANextSize: Integer; AChar: Boolean = False);
    procedure AppendBytes(const ABytes: PByte; const ACount: Integer);
  public
    constructor Create(const AInitialCapacity: Integer = 4096; const AEncoding: TEncoding = nil);
    destructor Destroy; override;

    procedure Reset;

    // String appenders
    procedure AppendChar(AValor: string; ASize: Integer);
    procedure AppendVarChar(AValor: string; ASize: Integer);

    // Integer appenders
    procedure AppendSmallInt(AValor: SmallInt);
    procedure AppendInteger(AValor: Integer);
    procedure AppendBigInt(AValor: Int64);

    // Floating-point appenders
    procedure AppendFloat(AValor: Int64); overload; // Legacy support from original Ext_Record
    procedure AppendFloat(AValor: Integer); overload; // Legacy support
    procedure AppendSingle(AValor: Single); // Firebird FLOAT (32-bit)
    procedure AppendDouble(AValor: Double); // Firebird DOUBLE PRECISION (64-bit)

    // Boolean appender
    procedure AppendBoolean(AValor: Boolean);

    // Date and time appenders (Firebird 5 format)
    procedure AppendDate(AValor: TDate);
    procedure AppendTime(AValor: TTime);
    procedure AppendTimeStamp(AValor: TDateTime);
    procedure AppTimeStamp(AValor: TDateTime); // Backward compatibility alias

    // Scaled decimal/numeric appenders
    procedure AppendNumeric(AValor: Double; APrecision, AScale: Integer); overload;
    procedure AppendNumeric(AValor: Int64; APrecision, AScale: Integer); overload;

    // Optional CRLF line termination (for tables with CRLF CHAR(2) or CHAR(1))
    procedure AppendCRLF;
    procedure AppendLF;

    // Null / empty field appender according to Firebird external file conventions
    procedure AppendNull(const AType: TFBFieldType; const ASize: Integer = 0; const APrecision: Integer = 0);

    // Stream and buffer output
    function GetBuffer: TBytes;
    procedure WriteToStream(const AStream: TStream);

    // Properties
    property Line: string read GetLine;
    property LineAnsi: AnsiString read GetLineAnsi;
    property Pos: Integer read FPos write FPos;
    property RecordLength: Integer read GetRecordLength;
    property Encoding: TEncoding read FEncoding write SetEncoding;
  end;

  // Modern type alias
  TFBExternalRecord = TExt_Record;

implementation

{ TExt_Record }

constructor TExt_Record.Create(const AInitialCapacity: Integer; const AEncoding: TEncoding);
begin
  inherited Create;
  FCapacity := Max(256, AInitialCapacity);
  SetLength(FBuffer, FCapacity);
  FOwnsEncoding := False;
  if AEncoding <> nil then
    FEncoding := AEncoding
  else
    FEncoding := ResolveEncoding('WIN1250');
  Reset;
end;

destructor TExt_Record.Destroy;
begin
  if FOwnsEncoding and (FEncoding <> nil) then
    FEncoding.Free;
  inherited;
end;

procedure TExt_Record.SetEncoding(const Value: TEncoding);
begin
  if FOwnsEncoding and (FEncoding <> nil) then
    FEncoding.Free;
  FEncoding := Value;
  FOwnsEncoding := False;
end;

procedure TExt_Record.Reset;
begin
  FPos := 1;
  if FCapacity > 0 then
    FillChar(FBuffer[0], Length(FBuffer), 0);
end;

function TExt_Record.GetRecordLength: Integer;
begin
  Result := FPos - 1;
end;

procedure TExt_Record.EnsureCapacity(const ANeeded: Integer);
begin
  if ANeeded > Length(FBuffer) then
  begin
    while FCapacity < ANeeded do
      FCapacity := FCapacity * 2;
    SetLength(FBuffer, FCapacity);
  end;
end;

{ Firebird 5 (ODS 11+) alignment implementation:
  Items are aligned to Min(Size, 8) boundary.
  CHAR fields are NOT aligned (1-byte boundary).
  VARCHAR fields are aligned to 2-byte boundary (for the USHORT length prefix).
  FPos is 1-based (i.e. 0-based offset is FPos - 1). }
procedure TExt_Record.CheckOffset(ANextSize: Integer; AChar: Boolean);
var
  Alignment: Integer;
  CurOffset: Integer;
  Pad: Integer;
begin
  if AChar then
    Exit; // CHAR requires no alignment (alignment = 1)

  Alignment := Min(ANextSize, FB_MAX_ALIGNMENT);
  if Alignment <= 1 then
    Exit;

  CurOffset := FPos - 1; // Convert 1-based FPos to 0-based byte offset
  Pad := (Alignment - (CurOffset mod Alignment)) mod Alignment;

  if Pad > 0 then
  begin
    EnsureCapacity(FPos + Pad);
    FillChar(FBuffer[FPos - 1], Pad, 0);
    Inc(FPos, Pad);
  end;
end;

procedure TExt_Record.AppendBytes(const ABytes: PByte; const ACount: Integer);
begin
  if ACount <= 0 then
    Exit;
  EnsureCapacity(FPos + ACount);
  Move(ABytes^, FBuffer[FPos - 1], ACount);
  Inc(FPos, ACount);
end;

procedure TExt_Record.AppendChar(AValor: string; ASize: Integer);
var
  EncodedBytes: TBytes;
  ByteLen, CopyLen: Integer;
begin
  CheckOffset(ASize, True); // No alignment padding for CHAR
  EnsureCapacity(FPos + ASize);

  // Encode string to bytes according to configured encoding
  EncodedBytes := FEncoding.GetBytes(AValor);
  ByteLen := Length(EncodedBytes);
  CopyLen := Min(ByteLen, ASize);

  // Fill destination with spaces (#32)
  FillChar(FBuffer[FPos - 1], ASize, #32);

  // Copy encoded bytes
  if CopyLen > 0 then
    Move(EncodedBytes[0], FBuffer[FPos - 1], CopyLen);

  Inc(FPos, ASize);
end;

procedure TExt_Record.AppendVarChar(AValor: string; ASize: Integer);
var
  EncodedBytes: TBytes;
  ByteLen, CopyLen: Integer;
  LenWord: Word;
begin
  // Firebird aligns VARCHAR to 2-byte boundary (USHORT length)
  CheckOffset(2, False);
  EnsureCapacity(FPos + 2 + ASize);

  EncodedBytes := FEncoding.GetBytes(AValor);
  ByteLen := Length(EncodedBytes);
  CopyLen := Min(ByteLen, ASize);

  // 2-byte length prefix (little-endian)
  LenWord := Word(CopyLen);
  FBuffer[FPos - 1] := Byte(Lo(LenWord));
  FBuffer[FPos] := Byte(Hi(LenWord));
  Inc(FPos, 2);

  // Fill payload buffer with #0
  FillChar(FBuffer[FPos - 1], ASize, 0);

  // Copy string bytes
  if CopyLen > 0 then
    Move(EncodedBytes[0], FBuffer[FPos - 1], CopyLen);

  Inc(FPos, ASize);
end;

procedure TExt_Record.AppendSmallInt(AValor: SmallInt);
begin
  CheckOffset(2);
  EnsureCapacity(FPos + 2);
  Move(AValor, FBuffer[FPos - 1], 2);
  Inc(FPos, 2);
end;

procedure TExt_Record.AppendInteger(AValor: Integer);
begin
  CheckOffset(4);
  EnsureCapacity(FPos + 4);
  Move(AValor, FBuffer[FPos - 1], 4);
  Inc(FPos, 4);
end;

procedure TExt_Record.AppendBigInt(AValor: Int64);
begin
  CheckOffset(8);
  EnsureCapacity(FPos + 8);
  Move(AValor, FBuffer[FPos - 1], 8);
  Inc(FPos, 8);
end;

procedure TExt_Record.AppendFloat(AValor: Int64);
begin
  AppendBigInt(AValor);
end;

procedure TExt_Record.AppendFloat(AValor: Integer);
begin
  AppendBigInt(Int64(AValor));
end;

procedure TExt_Record.AppendSingle(AValor: Single);
begin
  CheckOffset(4);
  EnsureCapacity(FPos + 4);
  Move(AValor, FBuffer[FPos - 1], 4);
  Inc(FPos, 4);
end;

procedure TExt_Record.AppendDouble(AValor: Double);
begin
  CheckOffset(8);
  EnsureCapacity(FPos + 8);
  Move(AValor, FBuffer[FPos - 1], 8);
  Inc(FPos, 8);
end;

procedure TExt_Record.AppendBoolean(AValor: Boolean);
var
  B: Byte;
begin
  CheckOffset(1);
  EnsureCapacity(FPos + 1);
  if AValor then
    B := 1
  else
    B := 0;
  FBuffer[FPos - 1] := B;
  Inc(FPos, 1);
end;

procedure TExt_Record.AppendDate(AValor: TDate);
var
  FBDate: Integer;
begin
  CheckOffset(4);
  EnsureCapacity(FPos + 4);
  FBDate := DelphiDateToFirebirdDate(AValor);
  Move(FBDate, FBuffer[FPos - 1], 4);
  Inc(FPos, 4);
end;

procedure TExt_Record.AppendTime(AValor: TTime);
var
  FBTime: Cardinal;
begin
  CheckOffset(4);
  EnsureCapacity(FPos + 4);
  FBTime := DelphiTimeToFirebirdTime(AValor);
  Move(FBTime, FBuffer[FPos - 1], 4);
  Inc(FPos, 4);
end;

procedure TExt_Record.AppendTimeStamp(AValor: TDateTime);
var
  TS: TFBTimestamp;
begin
  CheckOffset(8);
  EnsureCapacity(FPos + 8);
  DelphiDateTimeToFirebirdTimestamp(AValor, TS.DatePart, TS.TimePart);
  Move(TS, FBuffer[FPos - 1], 8);
  Inc(FPos, 8);
end;

procedure TExt_Record.AppTimeStamp(AValor: TDateTime);
begin
  AppendTimeStamp(AValor);
end;

procedure TExt_Record.AppendNumeric(AValor: Double; APrecision, AScale: Integer);
var
  ScaledVal: Int64;
  Factor: Int64;
begin
  Factor := GetScaleFactor(AScale);
  ScaledVal := Round(AValor * Factor);
  AppendNumeric(ScaledVal, APrecision, AScale);
end;

procedure TExt_Record.AppendNumeric(AValor: Int64; APrecision, AScale: Integer);
var
  SI: SmallInt;
  I: Integer;
begin
  if APrecision <= 4 then
  begin
    SI := SmallInt(AValor);
    AppendSmallInt(SI);
  end
  else if APrecision <= 9 then
  begin
    I := Integer(AValor);
    AppendInteger(I);
  end
  else
    AppendBigInt(AValor);
end;

procedure TExt_Record.AppendCRLF;
begin
  CheckOffset(1, True);
  EnsureCapacity(FPos + 2);
  FBuffer[FPos - 1] := 13; // #13 CR
  FBuffer[FPos] := 10;     // #10 LF
  Inc(FPos, 2);
end;

procedure TExt_Record.AppendLF;
begin
  CheckOffset(1, True);
  EnsureCapacity(FPos + 1);
  FBuffer[FPos - 1] := 10; // #10 LF
  Inc(FPos, 1);
end;

procedure TExt_Record.AppendNull(const AType: TFBFieldType; const ASize: Integer; const APrecision: Integer);
begin
  case AType of
    fbftChar:
      begin
        CheckOffset(ASize, True);
        EnsureCapacity(FPos + ASize);
        FillChar(FBuffer[FPos - 1], ASize, #32); // Spaces for CHAR null
        Inc(FPos, ASize);
      end;
    fbftVarChar:
      begin
        CheckOffset(2, False);
        EnsureCapacity(FPos + 2 + ASize);
        // Length 0 followed by 0 bytes
        FBuffer[FPos - 1] := 0;
        FBuffer[FPos] := 0;
        Inc(FPos, 2);
        FillChar(FBuffer[FPos - 1], ASize, 0);
        Inc(FPos, ASize);
      end;
    fbftSmallInt:
      AppendSmallInt(0);
    fbftInteger:
      AppendInteger(0);
    fbftBigInt:
      AppendBigInt(0);
    fbftFloat:
      AppendSingle(0.0);
    fbftDouble:
      AppendDouble(0.0);
    fbftBoolean:
      AppendBoolean(False);
    fbftDate:
      begin
        // Firebird default null in external file is 0
        CheckOffset(4);
        EnsureCapacity(FPos + 4);
        FillChar(FBuffer[FPos - 1], 4, 0);
        Inc(FPos, 4);
      end;
    fbftTime:
      begin
        CheckOffset(4);
        EnsureCapacity(FPos + 4);
        FillChar(FBuffer[FPos - 1], 4, 0);
        Inc(FPos, 4);
      end;
    fbftTimestamp:
      begin
        CheckOffset(8);
        EnsureCapacity(FPos + 8);
        FillChar(FBuffer[FPos - 1], 8, 0);
        Inc(FPos, 8);
      end;
    fbftNumeric, fbftDecimal:
      AppendNumeric(Int64(0), APrecision, 0);
    fbftCRLF:
      AppendCRLF;
  end;
end;

function TExt_Record.GetBuffer: TBytes;
var
  Len: Integer;
begin
  Len := FPos - 1;
  SetLength(Result, Len);
  if Len > 0 then
    Move(FBuffer[0], Result[0], Len);
end;

procedure TExt_Record.WriteToStream(const AStream: TStream);
var
  Len: Integer;
begin
  Len := FPos - 1;
  if Len > 0 then
    AStream.WriteBuffer(FBuffer[0], Len);
end;

function TExt_Record.GetLine: string;
var
  Len: Integer;
begin
  Len := FPos - 1;
  if Len <= 0 then
    Exit('');
  Result := FEncoding.GetString(FBuffer, 0, Len);
end;

function TExt_Record.GetLineAnsi: AnsiString;
var
  Len: Integer;
begin
  Len := FPos - 1;
  if Len <= 0 then
    Exit('');
  SetLength(Result, Len);
  Move(FBuffer[0], Result[1], Len);
end;

end.
