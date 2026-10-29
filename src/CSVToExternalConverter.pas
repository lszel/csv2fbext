unit CSVToExternalConverter;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils,
  System.Classes,
  System.DateUtils,
  System.Diagnostics,
  System.IOUtils,
  ExternalTypes,
  EncodingUtils,
  ExternalRecord,
  ExternalSchema,
  CSVReader;

type
  TConverterProgressEvent = reference to procedure(const AProcessedRecords: Int64; const APercent: Double;
    const ARecordsPerSec: Double);
  TConverterLogEvent = reference to procedure(const ALevel: string; const AMessage: string);

  TConversionStats = record
    RecordCount: Int64;
    RecordSize: Integer;
    TotalBytesWritten: Int64;
    ElapsedMilliseconds: Int64;
    RecordsPerSecond: Double;
  end;

  TCsvToExternalConverter = class
  private
    FSchema: TFBTableSchema;
    FOwnsSchema: Boolean;
    FOnProgress: TConverterProgressEvent;
    FOnLog: TConverterLogEvent;
    FBufferSize: Integer;
    FMaxErrors: Integer;
    FErrorCount: Integer;

    procedure Log(const ALevel, AMessage: string);
    function ParseBooleanValue(const AStr: string): Boolean;
    function ParseNumericValue(const AStr: string; const ADecimalSep: Char; const AScale: Integer): Int64;
    function ParseFloatValue(const AStr: string; const ADecimalSep: Char): Double;
  public
    constructor Create(const ASchema: TFBTableSchema = nil; const AOwnsSchema: Boolean = False);
    destructor Destroy; override;

    function Execute(const ACsvPath: string; const AExtPath: string;
      const ASqlPath: string = ''): TConversionStats;

    property Schema: TFBTableSchema read FSchema write FSchema;
    property BufferSize: Integer read FBufferSize write FBufferSize;
    property MaxErrors: Integer read FMaxErrors write FMaxErrors;
    property ErrorCount: Integer read FErrorCount;
    property OnProgress: TConverterProgressEvent read FOnProgress write FOnProgress;
    property OnLog: TConverterLogEvent read FOnLog write FOnLog;
  end;

implementation

const
  DEFAULT_OUTPUT_BUFFER_SIZE = 1024 * 1024; // 1 MB write buffer

{ TCsvToExternalConverter }

constructor TCsvToExternalConverter.Create(const ASchema: TFBTableSchema; const AOwnsSchema: Boolean);
begin
  inherited Create;
  FSchema := ASchema;
  FOwnsSchema := AOwnsSchema;
  FBufferSize := DEFAULT_OUTPUT_BUFFER_SIZE;
  FMaxErrors := 100;
  FErrorCount := 0;
end;

destructor TCsvToExternalConverter.Destroy;
begin
  if FOwnsSchema and (FSchema <> nil) then
    FSchema.Free;
  inherited;
end;

procedure TCsvToExternalConverter.Log(const ALevel, AMessage: string);
begin
  if Assigned(FOnLog) then
    FOnLog(ALevel, AMessage);
end;

function TCsvToExternalConverter.ParseBooleanValue(const AStr: string): Boolean;
var
  S: string;
begin
  S := UpperCase(Trim(AStr));
  Result := (S = '1') or (S = 'TRUE') or (S = 'T') or (S = 'YES') or (S = 'Y') or
            (S = 'IGEN') or (S = 'I');
end;

function TCsvToExternalConverter.ParseFloatValue(const AStr: string; const ADecimalSep: Char): Double;
var
  S: string;
  FS: TFormatSettings;
begin
  S := Trim(AStr);
  if S = '' then
    Exit(0.0);

  FS := TFormatSettings.Create;
  if ADecimalSep <> #0 then
    FS.DecimalSeparator := ADecimalSep
  else
    FS.DecimalSeparator := '.';

  // If input string has comma but decimal separator is dot, or vice versa
  if (FS.DecimalSeparator = '.') and (Pos(',', S) > 0) and (Pos('.', S) = 0) then
    S := StringReplace(S, ',', '.', [rfReplaceAll])
  else if (FS.DecimalSeparator = ',') and (Pos('.', S) > 0) and (Pos(',', S) = 0) then
    S := StringReplace(S, '.', ',', [rfReplaceAll]);

  if not TryStrToFloat(S, Result, FS) then
    Result := 0.0;
end;

function TCsvToExternalConverter.ParseNumericValue(const AStr: string; const ADecimalSep: Char; const AScale: Integer): Int64;
var
  S: string;
  Factor: Int64;
  DotPos: Integer;
  IntPartStr, FracPartStr: string;
  IntPart, FracPart: Int64;
  Sign: Int64;
begin
  S := Trim(AStr);
  if S = '' then
    Exit(0);

  Factor := GetScaleFactor(AScale);

  // Exact fixed-point parsing to avoid floating point precision loss
  Sign := 1;
  if (Length(S) > 0) and (S[1] = '-') then
  begin
    Sign := -1;
    Delete(S, 1, 1);
  end
  else if (Length(S) > 0) and (S[1] = '+') then
    Delete(S, 1, 1);

  // Normalize decimal separator to '.'
  if ADecimalSep <> #0 then
    S := StringReplace(S, string(ADecimalSep), '.', [rfReplaceAll])
  else
    S := StringReplace(S, ',', '.', [rfReplaceAll]);

  DotPos := Pos('.', S);
  if DotPos > 0 then
  begin
    IntPartStr := Copy(S, 1, DotPos - 1);
    FracPartStr := Copy(S, DotPos + 1, MaxInt);
  end
  else
  begin
    IntPartStr := S;
    FracPartStr := '';
  end;

  IntPart := StrToInt64Def(IntPartStr, 0);

  // Pad or truncate fraction to AScale digits
  while Length(FracPartStr) < AScale do
    FracPartStr := FracPartStr + '0';
  if Length(FracPartStr) > AScale then
    FracPartStr := Copy(FracPartStr, 1, AScale);

  FracPart := StrToInt64Def(FracPartStr, 0);
  Result := Sign * (IntPart * Factor + FracPart);
end;

function TCsvToExternalConverter.Execute(const ACsvPath: string; const AExtPath: string;
  const ASqlPath: string): TConversionStats;
var
  Reader: TCsvReader;
  ExtRec: TExt_Record;
  OutStream: TFileStream;
  OutBuffer: TBytes;
  OutBufPos: Integer;
  RecordSize: Integer;
  RowFields: TCsvFieldArray;
  HeaderFields: TCsvFieldArray;
  ColMapping: TArray<Integer>;
  I, ColIdx: Integer;
  ColDef: TFBColumnDef;
  RawVal: string;
  Stopwatch: TStopwatch;
  RecBytes: TBytes;
  TotalRecords: Int64;
  LastLogTicks: Int64;
  NowTicks: Int64;
  Rate: Double;
  ColEncoding: TEncoding;
  D: TDate;
  T: TTime;
  DT: TDateTime;
  FmtDate, FmtTime, FmtTimestamp: string;
  DecSep: Char;
  SqlScript: string;
begin
  if FSchema = nil then
    raise Exception.Create('No schema provided for conversion.');
  if FSchema.ColumnCount = 0 then
    raise Exception.Create('Schema has no columns defined.');

  FErrorCount := 0;
  TotalRecords := 0;

  Log('INFO', Format('Starting conversion: %s -> %s', [ExtractFileName(ACsvPath), ExtractFileName(AExtPath)]));

  // Determine field-to-column mapping
  SetLength(ColMapping, FSchema.ColumnCount);
  for I := 0 to FSchema.ColumnCount - 1 do
    ColMapping[I] := I; // Default 1:1 positional mapping

  // Prepare reader
  Reader := TCsvReader.Create(ACsvPath, FSchema.Delimiter, FSchema.QuoteChar, FSchema.CharacterSet);
  try
    // Read header if present
    if FSchema.HasHeader then
    begin
      if Reader.ReadHeader(HeaderFields) then
      begin
        Log('INFO', Format('CSV Header contains %d columns.', [Length(HeaderFields)]));
        // Match columns by name
        for I := 0 to FSchema.ColumnCount - 1 do
        begin
          for ColIdx := 0 to Length(HeaderFields) - 1 do
          begin
            if SameText(Trim(HeaderFields[ColIdx]), FSchema.Columns[I].Name) then
            begin
              ColMapping[I] := ColIdx;
              Break;
            end;
          end;
        end;
      end;
    end;

    // Resolve target encoding
    ColEncoding := ResolveEncoding(FSchema.CharacterSet);
    ExtRec := TExt_Record.Create(4096, ColEncoding);
    try
      // Open output file
      if TFile.Exists(AExtPath) then
        TFile.Delete(AExtPath);

      OutStream := TFileStream.Create(AExtPath, fmCreate or fmShareDenyWrite);
      try
        SetLength(OutBuffer, FBufferSize);
        OutBufPos := 0;

        RecordSize := FSchema.CalculateRecordSize;
        Log('INFO', Format('Calculated Firebird external record size: %d bytes.', [RecordSize]));

        Stopwatch := TStopwatch.StartNew;
        LastLogTicks := 0;

        while Reader.ReadRecord(RowFields) do
        begin
          ExtRec.Reset;

          for I := 0 to FSchema.ColumnCount - 1 do
          begin
            ColDef := FSchema.Columns[I];
            ColIdx := ColMapping[I];

            if (ColIdx >= 0) and (ColIdx < Length(RowFields)) then
              RawVal := RowFields[ColIdx]
            else
              RawVal := ColDef.DefaultValue;

            if ColDef.TrimSpaces then
              RawVal := Trim(RawVal);

            // Handle column type conversion
            case ColDef.FieldType of
              fbftChar:
                ExtRec.AppendChar(RawVal, ColDef.Length);

              fbftVarChar:
                ExtRec.AppendVarChar(RawVal, ColDef.Length);

              fbftSmallInt:
                begin
                  if RawVal = '' then
                    ExtRec.AppendSmallInt(0)
                  else
                    ExtRec.AppendSmallInt(SmallInt(StrToIntDef(RawVal, 0)));
                end;

              fbftInteger:
                begin
                  if RawVal = '' then
                    ExtRec.AppendInteger(0)
                  else
                    ExtRec.AppendInteger(StrToIntDef(RawVal, 0));
                end;

              fbftBigInt:
                begin
                  if RawVal = '' then
                    ExtRec.AppendBigInt(0)
                  else
                    ExtRec.AppendBigInt(StrToInt64Def(RawVal, 0));
                end;

              fbftFloat:
                begin
                  DecSep := ColDef.DecimalSeparator;
                  if DecSep = #0 then DecSep := FSchema.DecimalSeparator;
                  ExtRec.AppendSingle(Single(ParseFloatValue(RawVal, DecSep)));
                end;

              fbftDouble:
                begin
                  DecSep := ColDef.DecimalSeparator;
                  if DecSep = #0 then DecSep := FSchema.DecimalSeparator;
                  ExtRec.AppendDouble(ParseFloatValue(RawVal, DecSep));
                end;

              fbftBoolean:
                begin
                  ExtRec.AppendBoolean(ParseBooleanValue(RawVal));
                end;

              fbftDate:
                begin
                  if RawVal = '' then
                    ExtRec.AppendNull(fbftDate)
                  else
                  begin
                    FmtDate := ColDef.DateFormat;
                    if FmtDate = '' then FmtDate := FSchema.DateFormat;
                    try
                      D := ParseDateFlexible(RawVal, FmtDate);
                      ExtRec.AppendDate(D);
                    except
                      ExtRec.AppendNull(fbftDate);
                      Inc(FErrorCount);
                    end;
                  end;
                end;

              fbftTime:
                begin
                  if RawVal = '' then
                    ExtRec.AppendNull(fbftTime)
                  else
                  begin
                    FmtTime := ColDef.TimeFormat;
                    if FmtTime = '' then FmtTime := FSchema.TimeFormat;
                    try
                      T := ParseTimeFlexible(RawVal, FmtTime);
                      ExtRec.AppendTime(T);
                    except
                      ExtRec.AppendNull(fbftTime);
                      Inc(FErrorCount);
                    end;
                  end;
                end;

              fbftTimestamp:
                begin
                  if RawVal = '' then
                    ExtRec.AppendNull(fbftTimestamp)
                  else
                  begin
                    FmtTimestamp := ColDef.TimestampFormat;
                    if FmtTimestamp = '' then FmtTimestamp := FSchema.TimestampFormat;
                    try
                      DT := ParseDateTimeFlexible(RawVal, FmtTimestamp);
                      ExtRec.AppendTimeStamp(DT);
                    except
                      ExtRec.AppendNull(fbftTimestamp);
                      Inc(FErrorCount);
                    end;
                  end;
                end;

              fbftNumeric, fbftDecimal:
                begin
                  DecSep := ColDef.DecimalSeparator;
                  if DecSep = #0 then DecSep := FSchema.DecimalSeparator;
                  ExtRec.AppendNumeric(ParseNumericValue(RawVal, DecSep, ColDef.Scale), ColDef.Precision, ColDef.Scale);
                end;

              fbftCRLF:
                ExtRec.AppendCRLF;
            end;
          end;

          if FSchema.IncludeCRLF then
            ExtRec.AppendCRLF;

          // Write record to buffer
          RecBytes := ExtRec.GetBuffer;
          if Length(RecBytes) > 0 then
          begin
            if OutBufPos + Length(RecBytes) > Length(OutBuffer) then
            begin
              OutStream.WriteBuffer(OutBuffer[0], OutBufPos);
              OutBufPos := 0;
            end;
            Move(RecBytes[0], OutBuffer[OutBufPos], Length(RecBytes));
            Inc(OutBufPos, Length(RecBytes));
          end;

          Inc(TotalRecords);

          // Progress notification every 500 ms
          NowTicks := Stopwatch.ElapsedMilliseconds;
          if (NowTicks - LastLogTicks >= 500) and (NowTicks > 0) then
          begin
            Rate := (TotalRecords * 1000.0) / NowTicks;
            if Assigned(FOnProgress) then
              FOnProgress(TotalRecords, 0, Rate);
            LastLogTicks := NowTicks;
          end;
        end;

        // Flush remaining buffer
        if OutBufPos > 0 then
        begin
          OutStream.WriteBuffer(OutBuffer[0], OutBufPos);
          OutBufPos := 0;
        end;

        Stopwatch.Stop;
        Result.RecordCount := TotalRecords;
        Result.RecordSize := RecordSize;
        Result.TotalBytesWritten := OutStream.Size;
        Result.ElapsedMilliseconds := Stopwatch.ElapsedMilliseconds;
        if Result.ElapsedMilliseconds > 0 then
          Result.RecordsPerSecond := (TotalRecords * 1000.0) / Result.ElapsedMilliseconds
        else
          Result.RecordsPerSecond := TotalRecords;

        Log('INFO', Format('Completed: %d records in %d ms (%.0f rec/sec), file size: %d bytes.',
          [Result.RecordCount, Result.ElapsedMilliseconds, Result.RecordsPerSecond, Result.TotalBytesWritten]));

        // Generate SQL DDL script if requested
        if ASqlPath <> '' then
        begin
          SqlScript := FSchema.GenerateSQL(AExtPath);
          TFile.WriteAllText(ASqlPath, SqlScript, TEncoding.UTF8);
          Log('INFO', Format('SQL DDL written to %s', [ASqlPath]));
        end;
      finally
        OutStream.Free;
      end;
    finally
      ExtRec.Free;
    end;
  finally
    Reader.Free;
  end;
end;

end.
