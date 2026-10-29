unit ExternalInferrer;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Math,
  System.IOUtils,
  ExternalTypes,
  ExternalSchema,
  CSVReader;

type
  TColumnStats = record
    Name: string;
    SampleCount: Integer;
    NullCount: Integer;
    MaxLength: Integer;
    MinLength: Integer;

    CanBeBoolean: Boolean;
    CanBeInteger: Boolean;
    CanBeFloat: Boolean;
    CanBeDate: Boolean;
    CanBeTime: Boolean;
    CanBeTimestamp: Boolean;

    DetectedDateFormat: string;
    DetectedTimeFormat: string;
    DetectedTimestampFormat: string;

    MinIntVal: Int64;
    MaxIntVal: Int64;
    MaxScale: Integer;
    MaxPrecision: Integer;
  end;

  TCsvSchemaInferrer = class
  private
    FDelimiter: Char;
    FQuoteChar: Char;
    FCharacterSet: string;
    FMaxSampleRows: Integer;
    FDecimalSeparator: Char;

    function AnalyzeString(var AStats: TColumnStats; const AVal: string): Boolean;
  public
    constructor Create(const ADelimiter: Char = ';'; const AQuoteChar: Char = '"';
      const ACharacterSet: string = 'WIN1250');

    function InferSchema(const ACsvPath: string; const ATableName: string = ''): TFBTableSchema;

    property Delimiter: Char read FDelimiter write FDelimiter;
    property QuoteChar: Char read FQuoteChar write FQuoteChar;
    property CharacterSet: string read FCharacterSet write FCharacterSet;
    property MaxSampleRows: Integer read FMaxSampleRows write FMaxSampleRows;
    property DecimalSeparator: Char read FDecimalSeparator write FDecimalSeparator;
  end;

implementation

{ TCsvSchemaInferrer }

constructor TCsvSchemaInferrer.Create(const ADelimiter: Char; const AQuoteChar: Char;
  const ACharacterSet: string);
begin
  inherited Create;
  FDelimiter := ADelimiter;
  FQuoteChar := AQuoteChar;
  FCharacterSet := ACharacterSet;
  FMaxSampleRows := 50000; // Sample up to 50,000 rows by default
  FDecimalSeparator := ',';
end;

function TCsvSchemaInferrer.AnalyzeString(var AStats: TColumnStats; const AVal: string): Boolean;
var
  S: string;
  Len: Integer;
  IVal: Int64;
  DVal: Double;
  DotPos, CommaPos: Integer;
  DecPos: Integer;
  Scale: Integer;
  FS: TFormatSettings;
  D: TDate;
  T: TTime;
  DT: TDateTime;
  UpperS: string;
  NormStr: string;
begin
  Result := True;
  S := Trim(AVal);
  Len := Length(S);

  if Len = 0 then
  begin
    Inc(AStats.NullCount);
    Exit;
  end;

  Inc(AStats.SampleCount);
  if Len > AStats.MaxLength then
    AStats.MaxLength := Len;
  if (AStats.MinLength = 0) or (Len < AStats.MinLength) then
    AStats.MinLength := Len;

  // Check Boolean
  if AStats.CanBeBoolean then
  begin
    UpperS := UpperCase(S);
    if not ((UpperS = '0') or (UpperS = '1') or (UpperS = 'TRUE') or (UpperS = 'FALSE') or
            (UpperS = 'T') or (UpperS = 'F') or (UpperS = 'IGEN') or (UpperS = 'NEM') or
            (UpperS = 'I') or (UpperS = 'N')) then
      AStats.CanBeBoolean := False;
  end;

  // Check Integer
  if AStats.CanBeInteger then
  begin
    if TryStrToInt64(S, IVal) then
    begin
      if IVal < AStats.MinIntVal then AStats.MinIntVal := IVal;
      if IVal > AStats.MaxIntVal then AStats.MaxIntVal := IVal;
    end
    else
      AStats.CanBeInteger := False;
  end;

  // Check Float / Numeric
  if AStats.CanBeFloat then
  begin
    DotPos := Pos('.', S);
    CommaPos := Pos(',', S);
    if (DotPos > 0) or (CommaPos > 0) then
    begin
      if DotPos > 0 then DecPos := DotPos else DecPos := CommaPos;
      Scale := Len - DecPos;
      if Scale > AStats.MaxScale then
        AStats.MaxScale := Scale;

      NormStr := S;
      if CommaPos > 0 then
        NormStr := StringReplace(NormStr, ',', '.', [rfReplaceAll]);

      FS := TFormatSettings.Create;
      FS.DecimalSeparator := '.';
      if not TryStrToFloat(NormStr, DVal, FS) then
        AStats.CanBeFloat := False;
    end
    else if not AStats.CanBeInteger then
    begin
      AStats.CanBeFloat := False;
    end;
  end;

  // Check Date (only if length is typically 8..11)
  if AStats.CanBeDate then
  begin
    try
      D := ParseDateFlexible(S);
      if D = 0 then
        AStats.CanBeDate := False;
    except
      AStats.CanBeDate := False;
    end;
  end;

  // Check Time (length typically 5..12)
  if AStats.CanBeTime then
  begin
    try
      T := ParseTimeFlexible(S);
      if (T = 0) and (S <> '00:00:00') and (S <> '0:00:00') and (S <> '00:00') then
        AStats.CanBeTime := False;
    except
      AStats.CanBeTime := False;
    end;
  end;

  // Check Timestamp (length typically 14..25)
  if AStats.CanBeTimestamp then
  begin
    if (Pos(':', S) > 0) and ((Pos('-', S) > 0) or (Pos('.', S) > 0) or (Pos('/', S) > 0)) then
    begin
      try
        DT := ParseDateTimeFlexible(S);
        if DT = 0 then
          AStats.CanBeTimestamp := False;
      except
        AStats.CanBeTimestamp := False;
      end;
    end
    else
      AStats.CanBeTimestamp := False;
  end;
end;

function TCsvSchemaInferrer.InferSchema(const ACsvPath: string; const ATableName: string): TFBTableSchema;
var
  Reader: TCsvReader;
  Headers: TCsvFieldArray;
  Row: TCsvFieldArray;
  ColStats: array of TColumnStats;
  ColCount: Integer;
  RowCount: Integer;
  I: Integer;
  ColDef: TFBColumnDef;
  TblName: string;
  VarcharLen: Integer;
begin
  Result := TFBTableSchema.Create;
  if ATableName <> '' then
    TblName := ATableName
  else
    TblName := 'EXT_' + UpperCase(TPath.GetFileNameWithoutExtension(ACsvPath));

  Result.TableName := TblName;
  Result.ExternalFileName := TPath.GetFileNameWithoutExtension(ACsvPath) + '.ext';
  Result.CharacterSet := FCharacterSet;
  Result.Delimiter := FDelimiter;
  Result.QuoteChar := FQuoteChar;
  Result.HasHeader := True;

  Reader := TCsvReader.Create(ACsvPath, FDelimiter, FQuoteChar, FCharacterSet);
  try
    if not Reader.ReadHeader(Headers) then
      Exit;

    ColCount := Length(Headers);
    SetLength(ColStats, ColCount);

    for I := 0 to ColCount - 1 do
    begin
      ColStats[I].Name := Trim(Headers[I]);
      if ColStats[I].Name = '' then
        ColStats[I].Name := Format('FIELD_%d', [I + 1]);
      ColStats[I].SampleCount := 0;
      ColStats[I].NullCount := 0;
      ColStats[I].MaxLength := 0;
      ColStats[I].MinLength := 0;
      ColStats[I].CanBeBoolean := True;
      ColStats[I].CanBeInteger := True;
      ColStats[I].CanBeFloat := True;
      ColStats[I].CanBeDate := True;
      ColStats[I].CanBeTime := True;
      ColStats[I].CanBeTimestamp := True;
      ColStats[I].MinIntVal := 0;
      ColStats[I].MaxIntVal := 0;
      ColStats[I].MaxScale := 0;
      ColStats[I].MaxPrecision := 0;
    end;

    RowCount := 0;
    while Reader.ReadRecord(Row) do
    begin
      Inc(RowCount);
      for I := 0 to Min(ColCount, Length(Row)) - 1 do
        AnalyzeString(ColStats[I], Row[I]);

      if (FMaxSampleRows > 0) and (RowCount >= FMaxSampleRows) then
        Break;
    end;

    // Convert statistics to schema column definitions
    for I := 0 to ColCount - 1 do
    begin
      ColDef := TFBColumnDef.Create;
      ColDef.Name := ColStats[I].Name;

      // Type decision ladder
      if (ColStats[I].SampleCount > 0) and ColStats[I].CanBeBoolean then
      begin
        ColDef.FieldType := fbftBoolean;
      end
      else if (ColStats[I].SampleCount > 0) and ColStats[I].CanBeDate then
      begin
        ColDef.FieldType := fbftDate;
        ColDef.DateFormat := 'yyyy-mm-dd';
      end
      else if (ColStats[I].SampleCount > 0) and ColStats[I].CanBeTime then
      begin
        ColDef.FieldType := fbftTime;
        ColDef.TimeFormat := 'hh:nn:ss';
      end
      else if (ColStats[I].SampleCount > 0) and ColStats[I].CanBeTimestamp then
      begin
        ColDef.FieldType := fbftTimestamp;
        ColDef.TimestampFormat := 'yyyy-mm-dd hh:nn:ss';
      end
      else if (ColStats[I].SampleCount > 0) and ColStats[I].CanBeInteger then
      begin
        if (ColStats[I].MinIntVal >= -32768) and (ColStats[I].MaxIntVal <= 32767) then
          ColDef.FieldType := fbftSmallInt
        else if (ColStats[I].MinIntVal >= -2147483648) and (ColStats[I].MaxIntVal <= 2147483647) then
          ColDef.FieldType := fbftInteger
        else
          ColDef.FieldType := fbftBigInt;
      end
      else if (ColStats[I].SampleCount > 0) and ColStats[I].CanBeFloat then
      begin
        if ColStats[I].MaxScale > 0 then
        begin
          ColDef.FieldType := fbftNumeric;
          ColDef.Precision := Min(18, Max(ColStats[I].MaxLength, ColStats[I].MaxScale + 4));
          ColDef.Scale := ColStats[I].MaxScale;
        end
        else
          ColDef.FieldType := fbftDouble;
      end
      else
      begin
        // String type
        VarcharLen := Max(10, ColStats[I].MaxLength);
        // Round up to nice boundaries (e.g. 10, 20, 50, 100, 255)
        if VarcharLen <= 2 then
          VarcharLen := 2
        else if VarcharLen <= 5 then
          VarcharLen := 10
        else if VarcharLen <= 20 then
          VarcharLen := ((VarcharLen + 4) div 5) * 5
        else if VarcharLen <= 100 then
          VarcharLen := ((VarcharLen + 9) div 10) * 10
        else
          VarcharLen := Min(4000, ((VarcharLen + 49) div 50) * 50);

        ColDef.FieldType := fbftVarChar;
        ColDef.Length := VarcharLen;
      end;

      Result.AddColumn(ColDef.Name, ColDef.FieldType, ColDef.Length, ColDef.Precision, ColDef.Scale);
      ColDef.Free;
    end;
  finally
    Reader.Free;
  end;
end;

end.
