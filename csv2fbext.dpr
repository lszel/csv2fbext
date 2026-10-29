program csv2fbext;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  ExternalTypes in 'src\ExternalTypes.pas',
  EncodingUtils in 'src\EncodingUtils.pas',
  ExternalRecord in 'src\ExternalRecord.pas',
  ExternalSchema in 'src\ExternalSchema.pas',
  CSVReader in 'src\CSVReader.pas',
  CSVToExternalConverter in 'src\CSVToExternalConverter.pas',
  ExternalInferrer in 'src\ExternalInferrer.pas',
  ExternalTests in 'src\ExternalTests.pas';

procedure PrintBanner;
begin
  Writeln('================================================================');
  Writeln('  csv2fbext - CSV to Firebird 5 External Table Converter');
  Writeln('  Cross-platform (Windows & Linux)');
  Writeln('================================================================');
end;

procedure PrintUsage;
begin
  PrintBanner;
  Writeln('Usage:');
  Writeln('  csv2fbext <command> [options]');
  Writeln;
  Writeln('Commands:');
  Writeln('  convert    Convert CSV file to Firebird 5 external binary table (.ext)');
  Writeln('  infer      Inspect CSV file and generate JSON schema & SQL DDL');
  Writeln('  test       Run built-in unit tests verifying all Firebird 5 types');
  Writeln;
  Writeln('Convert Options:');
  Writeln('  -i, --input <file>        Input CSV file path (required)');
  Writeln('  -o, --output <file>       Output .ext file path (default: <csv_name>.ext)');
  Writeln('  -s, --schema <file>       JSON schema file path');
  Writeln('  -t, --table <name>        Table name (default: EXT_<csv_name>)');
  Writeln('  --sql <file>              Output SQL CREATE TABLE DDL script');
  Writeln('  -d, --delimiter <char>    CSV delimiter character (default: ";")');
  Writeln('  -q, --quote <char>        CSV quote character (default: ''"'')');
  Writeln('  -c, --charset <name>      Character set (default: "WIN1250")');
  Writeln('  --no-header               CSV has no header row');
  Writeln('  --crlf                    Append CRLF (#13#10) to each external record');
  Writeln('  --legacy-str <file>       Import old .str file from pb project');
  Writeln;
  Writeln('Infer Options:');
  Writeln('  -i, --input <file>        Input CSV file path (required)');
  Writeln('  -s, --schema <file>       Output JSON schema file path');
  Writeln('  --sql <file>              Output SQL CREATE TABLE script path');
  Writeln('  -t, --table <name>        Table name');
  Writeln('  --sample <n>              Max sample rows (default: 50000)');
  Writeln;
  Writeln('Quick syntax:');
  Writeln('  csv2fbext <input.csv> [output.ext] [tablename] [schema.json]');
  Writeln;
end;

function GetParamValue(const AIndex: Integer; const AParamCount: Integer; var ACurrent: Integer): string;
begin
  if ACurrent < AParamCount then
  begin
    Inc(ACurrent);
    Result := ParamStr(ACurrent);
  end
  else
    Result := '';
end;

procedure DoLog(const ALevel: string; const AMessage: string);
begin
  Writeln(Format('[%s] %s', [ALevel, AMessage]));
end;

procedure DoProgress(const AProcessedRecords: Int64; const APercent: Double; const ARecordsPerSec: Double);
begin
  Write(Format(#13'Processed: %d records (%.0f rec/sec)...', [AProcessedRecords, ARecordsPerSec]));
end;

function RunConvert(const AParamOffset: Integer): Integer;
var
  InputFile, OutputFile, SchemaFile, SqlFile, LegacyStrFile, TableName, CharSet: string;
  Delimiter, QuoteChar: Char;
  HasHeader, IncludeCRLF: Boolean;
  I, PCount: Integer;
  P: string;
  Schema: TFBTableSchema;
  Converter: TCsvToExternalConverter;
  Inferrer: TCsvSchemaInferrer;
  Stats: TConversionStats;
  SDelim, SQuote: string;
begin
  InputFile := '';
  OutputFile := '';
  SchemaFile := '';
  SqlFile := '';
  LegacyStrFile := '';
  TableName := '';
  CharSet := 'WIN1250';
  Delimiter := ';';
  QuoteChar := '"';
  HasHeader := True;
  IncludeCRLF := False;

  PCount := ParamCount;
  I := AParamOffset;

  while I <= PCount do
  begin
    P := ParamStr(I);
    if (P = '-i') or (P = '--input') then
      InputFile := GetParamValue(I, PCount, I)
    else if (P = '-o') or (P = '--output') then
      OutputFile := GetParamValue(I, PCount, I)
    else if (P = '-s') or (P = '--schema') then
      SchemaFile := GetParamValue(I, PCount, I)
    else if (P = '-t') or (P = '--table') then
      TableName := GetParamValue(I, PCount, I)
    else if P = '--sql' then
      SqlFile := GetParamValue(I, PCount, I)
    else if (P = '-d') or (P = '--delimiter') then
    begin
      SDelim := GetParamValue(I, PCount, I);
      if SDelim <> '' then Delimiter := SDelim[1];
    end
    else if (P = '-q') or (P = '--quote') then
    begin
      SQuote := GetParamValue(I, PCount, I);
      if SQuote <> '' then QuoteChar := SQuote[1];
    end
    else if (P = '-c') or (P = '--charset') then
      CharSet := GetParamValue(I, PCount, I)
    else if P = '--no-header' then
      HasHeader := False
    else if P = '--crlf' then
      IncludeCRLF := True
    else if P = '--legacy-str' then
      LegacyStrFile := GetParamValue(I, PCount, I)
    else if InputFile = '' then
      InputFile := P
    else if OutputFile = '' then
      OutputFile := P
    else if TableName = '' then
      TableName := P
    else if SchemaFile = '' then
      SchemaFile := P;

    Inc(I);
  end;

  if InputFile = '' then
  begin
    Writeln('Error: Input CSV file is required.');
    Exit(1);
  end;

  if not TFile.Exists(InputFile) then
  begin
    Writeln(Format('Error: Input file "%s" does not exist.', [InputFile]));
    Exit(1);
  end;

  if OutputFile = '' then
    OutputFile := TPath.ChangeExtension(InputFile, '.ext');

  if TableName = '' then
    TableName := 'EXT_' + UpperCase(TPath.GetFileNameWithoutExtension(InputFile));

  if SqlFile = '' then
    SqlFile := TPath.ChangeExtension(OutputFile, '.sql');

  Schema := nil;
  try
    if (SchemaFile <> '') and TFile.Exists(SchemaFile) then
    begin
      DoLog('INFO', Format('Loading schema from JSON: %s', [SchemaFile]));
      Schema := TFBTableSchema.Create;
      Schema.LoadFromJSONFile(SchemaFile);
      if TableName <> '' then Schema.TableName := TableName;
      if OutputFile <> '' then Schema.ExternalFileName := TPath.GetFileName(OutputFile);
    end
    else if (LegacyStrFile <> '') and TFile.Exists(LegacyStrFile) then
    begin
      DoLog('INFO', Format('Loading schema from legacy .str file: %s', [LegacyStrFile]));
      Schema := TFBTableSchema.Create;
      Schema.TableName := TableName;
      Schema.ExternalFileName := TPath.GetFileName(OutputFile);
      Schema.CharacterSet := CharSet;
      Schema.Delimiter := Delimiter;
      Schema.QuoteChar := QuoteChar;
      Schema.HasHeader := HasHeader;
      Schema.IncludeCRLF := IncludeCRLF;
      Schema.LoadFromLegacyStrFile(LegacyStrFile);
    end
    else
    begin
      DoLog('INFO', 'No schema provided, inferring schema automatically from CSV...');
      Inferrer := TCsvSchemaInferrer.Create(Delimiter, QuoteChar, CharSet);
      try
        Schema := Inferrer.InferSchema(InputFile, TableName);
        Schema.ExternalFileName := TPath.GetFileName(OutputFile);
        Schema.IncludeCRLF := IncludeCRLF;

        // Auto-save inferred schema JSON if requested or alongside output
        if SchemaFile <> '' then
          Schema.SaveToJSONFile(SchemaFile)
        else
          Schema.SaveToJSONFile(TPath.ChangeExtension(OutputFile, '.json'));
      finally
        Inferrer.Free;
      end;
    end;

    Converter := TCsvToExternalConverter.Create(Schema, False);
    try
      Converter.OnLog := DoLog;
      Converter.OnProgress := DoProgress;

      Stats := Converter.Execute(InputFile, OutputFile, SqlFile);
      Writeln;
      Writeln('----------------------------------------------------------------');
      Writeln(Format('Success! Converted %d records.', [Stats.RecordCount]));
      Writeln(Format('External Table File : %s (%d bytes)', [OutputFile, Stats.TotalBytesWritten]));
      Writeln(Format('Table Record Size   : %d bytes', [Stats.RecordSize]));
      Writeln(Format('SQL Definition Script: %s', [SqlFile]));
      Writeln('----------------------------------------------------------------');
      Result := 0;
    finally
      Converter.Free;
    end;
  finally
    Schema.Free;
  end;
end;

function RunInfer(const AParamOffset: Integer): Integer;
var
  InputFile, SchemaFile, SqlFile, TableName, CharSet: string;
  Delimiter, QuoteChar: Char;
  MaxSamples: Integer;
  I, PCount: Integer;
  P: string;
  Inferrer: TCsvSchemaInferrer;
  Schema: TFBTableSchema;
  SDelim, SQuote: string;
begin
  InputFile := '';
  SchemaFile := '';
  SqlFile := '';
  TableName := '';
  CharSet := 'WIN1250';
  Delimiter := ';';
  QuoteChar := '"';
  MaxSamples := 50000;

  PCount := ParamCount;
  I := AParamOffset;

  while I <= PCount do
  begin
    P := ParamStr(I);
    if (P = '-i') or (P = '--input') then
      InputFile := GetParamValue(I, PCount, I)
    else if (P = '-s') or (P = '--schema') then
      SchemaFile := GetParamValue(I, PCount, I)
    else if P = '--sql' then
      SqlFile := GetParamValue(I, PCount, I)
    else if (P = '-t') or (P = '--table') then
      TableName := GetParamValue(I, PCount, I)
    else if (P = '-d') or (P = '--delimiter') then
    begin
      SDelim := GetParamValue(I, PCount, I);
      if SDelim <> '' then Delimiter := SDelim[1];
    end
    else if (P = '-q') or (P = '--quote') then
    begin
      SQuote := GetParamValue(I, PCount, I);
      if SQuote <> '' then QuoteChar := SQuote[1];
    end
    else if (P = '-c') or (P = '--charset') then
      CharSet := GetParamValue(I, PCount, I)
    else if P = '--sample' then
      MaxSamples := StrToIntDef(GetParamValue(I, PCount, I), 50000)
    else if InputFile = '' then
      InputFile := P
    else if SchemaFile = '' then
      SchemaFile := P;

    Inc(I);
  end;

  if InputFile = '' then
  begin
    Writeln('Error: Input CSV file is required.');
    Exit(1);
  end;

  if not TFile.Exists(InputFile) then
  begin
    Writeln(Format('Error: Input file "%s" does not exist.', [InputFile]));
    Exit(1);
  end;

  if SchemaFile = '' then
    SchemaFile := TPath.ChangeExtension(InputFile, '.json');

  if SqlFile = '' then
    SqlFile := TPath.ChangeExtension(InputFile, '.sql');

  DoLog('INFO', Format('Inferring schema from: %s', [InputFile]));
  Inferrer := TCsvSchemaInferrer.Create(Delimiter, QuoteChar, CharSet);
  try
    Inferrer.MaxSampleRows := MaxSamples;
    Schema := Inferrer.InferSchema(InputFile, TableName);
    try
      Schema.SaveToJSONFile(SchemaFile);
      DoLog('INFO', Format('Saved schema JSON to: %s', [SchemaFile]));

      TFile.WriteAllText(SqlFile, Schema.GenerateSQL, TEncoding.UTF8);
      DoLog('INFO', Format('Saved SQL DDL to: %s', [SqlFile]));

      Writeln;
      Writeln(Format('Inferred %d columns with external record size: %d bytes',
        [Schema.ColumnCount, Schema.CalculateRecordSize]));
      Result := 0;
    finally
      Schema.Free;
    end;
  finally
    Inferrer.Free;
  end;
end;

var
  Cmd: string;
begin
  try
    if ParamCount = 0 then
    begin
      PrintUsage;
      Exit;
    end;

    Cmd := LowerCase(ParamStr(1));

    if (Cmd = 'test') or (Cmd = '-test') or (Cmd = '--test') then
    begin
      if RunTestsConsole then
        ExitCode := 0
      else
        ExitCode := 1;
    end
    else if Cmd = 'infer' then
    begin
      ExitCode := RunInfer(2);
    end
    else if Cmd = 'convert' then
    begin
      ExitCode := RunConvert(2);
    end
    else if (Cmd = '-h') or (Cmd = '--help') or (Cmd = 'help') or (Cmd = '/?') then
    begin
      PrintUsage;
      ExitCode := 0;
    end
    else
    begin
      // Direct syntax: first param is file
      ExitCode := RunConvert(1);
    end;

  except
    on E: Exception do
    begin
      Writeln('Fatal Error: ', E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
