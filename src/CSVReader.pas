unit CSVReader;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  EncodingUtils;

type
  TCsvFieldArray = TArray<string>;

  TCsvReader = class
  private
    FStream: TStream;
    FOwnsStream: Boolean;
    FEncoding: TEncoding;
    FOwnsEncoding: Boolean;
    FDelimiter: Char;
    FQuoteChar: Char;
    FTrimFields: Boolean;

    // Buffer management
    FBuffer: TBytes;
    FBufPos: Integer;
    FBufCount: Integer;
    FEOF: Boolean;

    // Current line/record state
    FLineNumber: Int64;
    FRecordNumber: Int64;
    FCurrentFields: TCsvFieldArray;

    procedure FillBuffer;
    function ReadNextChar(out AChar: Char): Boolean;
    procedure SkipBOM;
  public
    constructor Create(const AFileName: string; const ADelimiter: Char = ';';
      const AQuoteChar: Char = '"'; const AEncodingName: string = ''); overload;
    constructor Create(const AStream: TStream; const ADelimiter: Char = ';';
      const AQuoteChar: Char = '"'; const AEncoding: TEncoding = nil;
      const AOwnsStream: Boolean = False); overload;
    destructor Destroy; override;

    function ReadRecord(out AFields: TCsvFieldArray): Boolean;
    function ReadHeader(out AHeaders: TCsvFieldArray): Boolean;

    property Delimiter: Char read FDelimiter write FDelimiter;
    property QuoteChar: Char read FQuoteChar write FQuoteChar;
    property TrimFields: Boolean read FTrimFields write FTrimFields;
    property LineNumber: Int64 read FLineNumber;
    property RecordNumber: Int64 read FRecordNumber;
    property EOF: Boolean read FEOF;
    property CurrentFields: TCsvFieldArray read FCurrentFields;
  end;

implementation

const
  CSV_BUFFER_SIZE = 64 * 1024; // 64 KB read buffer

{ TCsvReader }

constructor TCsvReader.Create(const AFileName: string; const ADelimiter: Char;
  const AQuoteChar: Char; const AEncodingName: string);
var
  FS: TFileStream;
  Enc: TEncoding;
begin
  FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  if AEncodingName <> '' then
    Enc := ResolveEncoding(AEncodingName)
  else
    Enc := nil;
  Create(FS, ADelimiter, AQuoteChar, Enc, True);
end;

constructor TCsvReader.Create(const AStream: TStream; const ADelimiter: Char;
  const AQuoteChar: Char; const AEncoding: TEncoding; const AOwnsStream: Boolean);
begin
  inherited Create;
  FStream := AStream;
  FOwnsStream := AOwnsStream;
  FDelimiter := ADelimiter;
  FQuoteChar := AQuoteChar;
  FTrimFields := True;

  if AEncoding <> nil then
  begin
    FEncoding := AEncoding;
    FOwnsEncoding := False;
  end
  else
  begin
    FEncoding := TEncoding.UTF8;
    FOwnsEncoding := False;
  end;

  SetLength(FBuffer, CSV_BUFFER_SIZE);
  FBufPos := 0;
  FBufCount := 0;
  FEOF := False;
  FLineNumber := 0;
  FRecordNumber := 0;

  SkipBOM;
end;

destructor TCsvReader.Destroy;
begin
  if FOwnsEncoding and (FEncoding <> nil) then
    FEncoding.Free;
  if FOwnsStream and (FStream <> nil) then
    FStream.Free;
  inherited;
end;

procedure TCsvReader.FillBuffer;
begin
  if (FStream <> nil) and (FBufPos >= FBufCount) then
  begin
    FBufCount := FStream.Read(FBuffer[0], Length(FBuffer));
    FBufPos := 0;
    if FBufCount = 0 then
      FEOF := True;
  end;
end;

procedure TCsvReader.SkipBOM;
var
  B0, B1, B2: Byte;
  PosBackup: Int64;
begin
  if FStream = nil then
    Exit;
  PosBackup := FStream.Position;
  if FStream.Size - PosBackup >= 3 then
  begin
    FStream.ReadBuffer(B0, 1);
    FStream.ReadBuffer(B1, 1);
    FStream.ReadBuffer(B2, 1);
    if (B0 = $EF) and (B1 = $BB) and (B2 = $BF) then
    begin
      // UTF-8 BOM detected
      FEncoding := TEncoding.UTF8;
      Exit;
    end
    else if (B0 = $FF) and (B1 = $FE) then
    begin
      // UTF-16 LE
      FEncoding := TEncoding.Unicode;
      FStream.Position := PosBackup + 2;
      Exit;
    end;
    FStream.Position := PosBackup;
  end;
end;

function TCsvReader.ReadNextChar(out AChar: Char): Boolean;
var
  B: Byte;
  SeqLen: Integer;
  TempBytes: TBytes;
  I: Integer;
  DecodedChars: TCharArray;
  OneByte: array[0..0] of Byte;
begin
  if FBufPos >= FBufCount then
  begin
    FillBuffer;
    if FEOF then
    begin
      AChar := #0;
      Exit(False);
    end;
  end;

  B := FBuffer[FBufPos];
  Inc(FBufPos);
  // Basic single-byte ASCII fast path
  if B < 128 then
  begin
    AChar := Char(B);
    Exit(True);
  end;

  // Multi-byte or non-ASCII decoding via TEncoding
  // Back up 1 byte and let TEncoding handle it if needed
  Dec(FBufPos);
  // For UTF-8 multi-byte sequence
  if (FEncoding is TUTF8Encoding) or (FEncoding = TEncoding.UTF8) then
  begin
    SeqLen := 1;
    if (B and $E0) = $C0 then SeqLen := 2
    else if (B and $F0) = $E0 then SeqLen := 3
    else if (B and $F8) = $F0 then SeqLen := 4;

    SetLength(TempBytes, SeqLen);
    for I := 0 to SeqLen - 1 do
    begin
      if FBufPos >= FBufCount then
        FillBuffer;
      if FEOF then
        Break;
      TempBytes[I] := FBuffer[FBufPos];
      Inc(FBufPos);
    end;
    DecodedChars := FEncoding.GetChars(TempBytes);
    if Length(DecodedChars) > 0 then
      AChar := DecodedChars[0]
    else
      AChar := '?';
    Exit(True);
  end
  else
  begin
    // Single-byte encoding (like Windows-1250)
    Inc(FBufPos);
    OneByte[0] := B;
    DecodedChars := FEncoding.GetChars(OneByte);
    if Length(DecodedChars) > 0 then
      AChar := DecodedChars[0]
    else
      AChar := Char(B);
    Exit(True);
  end;
end;

function TCsvReader.ReadRecord(out AFields: TCsvFieldArray): Boolean;
var
  FieldBuilder: TStringBuilder;
  Ch, NextCh: Char;
  InQuote: Boolean;
  FieldList: TList<string>;
  HasData: Boolean;
  FieldVal: string;
begin
  AFields := nil;
  if FEOF and (FBufPos >= FBufCount) then
    Exit(False);

  FieldList := TList<string>.Create;
  FieldBuilder := TStringBuilder.Create;
  try
    InQuote := False;
    HasData := False;

    while ReadNextChar(Ch) do
    begin
      HasData := True;

      if InQuote then
      begin
        if Ch = FQuoteChar then
        begin
          // Peek next char to check for double quote escape ""
          if ReadNextChar(NextCh) then
          begin
            if NextCh = FQuoteChar then
              FieldBuilder.Append(FQuoteChar)
            else
            begin
              // Quote ended
              InQuote := False;
              // Put NextCh back into buffer stream
              Dec(FBufPos);
            end;
          end
          else
            InQuote := False;
        end
        else
        begin
          FieldBuilder.Append(Ch);
          if Ch = #10 then
            Inc(FLineNumber);
        end;
      end
      else
      begin
        // Not in quote
        if Ch = FQuoteChar then
        begin
          InQuote := True;
        end
        else if Ch = FDelimiter then
        begin
          FieldVal := FieldBuilder.ToString;
          if FTrimFields then
            FieldVal := Trim(FieldVal);
          FieldList.Add(FieldVal);
          FieldBuilder.Clear;
        end
        else if Ch = #13 then
        begin
          // Check for CRLF
          if ReadNextChar(NextCh) then
          begin
            if NextCh <> #10 then
              Dec(FBufPos);
          end;
          Inc(FLineNumber);
          Break;
        end
        else if Ch = #10 then
        begin
          Inc(FLineNumber);
          Break;
        end
        else
        begin
          FieldBuilder.Append(Ch);
        end;
      end;
    end;

    if HasData or (FieldList.Count > 0) then
    begin
      FieldVal := FieldBuilder.ToString;
      if FTrimFields then
        FieldVal := Trim(FieldVal);
      FieldList.Add(FieldVal);

      AFields := FieldList.ToArray;
      FCurrentFields := AFields;
      Inc(FRecordNumber);
      Result := True;
    end
    else
      Result := False;
  finally
    FieldBuilder.Free;
    FieldList.Free;
  end;
end;

function TCsvReader.ReadHeader(out AHeaders: TCsvFieldArray): Boolean;
begin
  Result := ReadRecord(AHeaders);
end;

end.
