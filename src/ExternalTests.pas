unit ExternalTests;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils,
  System.Classes,
  System.DateUtils,
  System.Math,
  System.IOUtils,
  ExternalTypes,
  EncodingUtils,
  ExternalRecord,
  ExternalSchema,
  CSVReader,
  CSVToExternalConverter;

type
  TTestRunner = class
  private
    FPassedCount: Integer;
    FFailedCount: Integer;
    procedure Assert(const ACondition: Boolean; const ATestName: string; const ADetail: string = '');
  public
    constructor Create;
    function RunAllTests: Boolean;

    // Unit test groups
    procedure TestDateConversions;
    procedure TestTimeConversions;
    procedure TestTimestampConversions;
    procedure TestAlignmentsAndOffsets;
    procedure TestEncodingWindows1250;
    procedure TestNumericScales;
    procedure TestCSVReader;
    procedure TestEndToEndConversion;

    property PassedCount: Integer read FPassedCount;
    property FailedCount: Integer read FFailedCount;
  end;

function RunTestsConsole: Boolean;

implementation

{ TTestRunner }

constructor TTestRunner.Create;
begin
  inherited Create;
  FPassedCount := 0;
  FFailedCount := 0;
end;

procedure TTestRunner.Assert(const ACondition: Boolean; const ATestName: string; const ADetail: string);
begin
  if ACondition then
  begin
    Inc(FPassedCount);
    Writeln('  [PASS] ', ATestName);
  end
  else
  begin
    Inc(FFailedCount);
    Writeln('  [FAIL] ', ATestName, ' - ', ADetail);
  end;
end;

procedure TTestRunner.TestDateConversions;
var
  D, D2: TDate;
  FBDate: Integer;
begin
  Writeln('--- Testing Date Conversions ---');

  // Base date: 1858-11-17 -> Day 0 in Firebird
  D := EncodeDate(1858, 11, 17);
  FBDate := DelphiDateToFirebirdDate(D);
  Assert(FBDate = 0, '1858-11-17 corresponds to Firebird Day 0', Format('Got %d', [FBDate]));

  // Delphi Epoch: 1899-12-30 -> Day 15018 in Firebird
  D := EncodeDate(1899, 12, 30);
  FBDate := DelphiDateToFirebirdDate(D);
  Assert(FBDate = 15018, '1899-12-30 corresponds to Firebird Day 15018', Format('Got %d', [FBDate]));

  // Current era date: 2026-10-29 roundtrip
  D := EncodeDate(2026, 10, 29);
  FBDate := DelphiDateToFirebirdDate(D);
  D2 := FirebirdDateToDelphiDate(FBDate);
  Assert(SameDate(D, D2), '2026-10-29 Date Roundtrip', DateToStr(D2));

  // Flexible parsers
  D := ParseDateFlexible('2026-10-29');
  Assert(SameDate(D, EncodeDate(2026, 10, 29)), 'Parse ISO date: 2026-10-29');

  D := ParseDateFlexible('2026.10.29.');
  Assert(SameDate(D, EncodeDate(2026, 10, 29)), 'Parse Hungarian date with trailing dot: 2026.10.29.');

  D := ParseDateFlexible('29/10/2026', 'dd/mm/yyyy');
  Assert(SameDate(D, EncodeDate(2026, 10, 29)), 'Parse custom format: 29/10/2026');

  D := ParseDateFlexible('20261029');
  Assert(SameDate(D, EncodeDate(2026, 10, 29)), 'Parse compact date: 20261029');
end;

procedure TTestRunner.TestTimeConversions;
var
  T, T2: TTime;
  FBTime: Cardinal;
begin
  Writeln('--- Testing Time Conversions ---');

  // Midnight: 00:00:00 -> 0 ticks
  T := EncodeTime(0, 0, 0, 0);
  FBTime := DelphiTimeToFirebirdTime(T);
  Assert(FBTime = 0, '00:00:00 corresponds to 0 ticks', Format('Got %u', [FBTime]));

  // Noon: 12:00:00 -> 12 * 3600 * 10000 = 432,000,000 ticks
  T := EncodeTime(12, 0, 0, 0);
  FBTime := DelphiTimeToFirebirdTime(T);
  Assert(FBTime = 432000000, '12:00:00 corresponds to 432,000,000 ticks', Format('Got %u', [FBTime]));

  // Time with milliseconds: 14:30:15.500
  T := EncodeTime(14, 30, 15, 500);
  FBTime := DelphiTimeToFirebirdTime(T);
  T2 := FirebirdTimeToDelphiTime(FBTime);
  Assert(SameTime(T, T2), '14:30:15.500 Time Roundtrip', TimeToStr(T2));

  // Flexible parsers
  T := ParseTimeFlexible('14:30:00');
  Assert(SameTime(T, EncodeTime(14, 30, 0, 0)), 'Parse standard time: 14:30:00');

  T := ParseTimeFlexible('08:15:30.250');
  Assert(SameTime(T, EncodeTime(8, 15, 30, 250)), 'Parse time with milliseconds: 08:15:30.250');
end;

procedure TTestRunner.TestTimestampConversions;
var
  DT, DT2: TDateTime;
  DatePart: Integer;
  TimePart: Cardinal;
begin
  Writeln('--- Testing Timestamp Conversions ---');

  DT := EncodeDateTime(2026, 10, 29, 15, 45, 30, 0);
  DelphiDateTimeToFirebirdTimestamp(DT, DatePart, TimePart);
  DT2 := FirebirdTimestampToDelphiDateTime(DatePart, TimePart);

  Assert(SameDateTime(DT, DT2), '2026-10-29 15:45:30 Timestamp Roundtrip', DateTimeToStr(DT2));

  // Flexible parser
  DT := ParseDateTimeFlexible('2026-10-29 15:45:30');
  Assert(SameDateTime(DT, EncodeDateTime(2026, 10, 29, 15, 45, 30, 0)), 'Parse standard timestamp string');

  DT := ParseDateTimeFlexible('2026-10-29T15:45:30');
  Assert(SameDateTime(DT, EncodeDateTime(2026, 10, 29, 15, 45, 30, 0)), 'Parse ISO-T timestamp string');
end;

procedure TTestRunner.TestAlignmentsAndOffsets;
var
  Schema: TFBTableSchema;
  Rec: TExt_Record;
  Buf: TBytes;
  ExpectedSize: Integer;
begin
  Writeln('--- Testing Firebird 5 Alignments and Offsets ---');

  { Define a table with mixed fields:
    1. C1: CHAR(5)            -> size 5, offset 0..4, no alignment (align 1)
    2. I1: INTEGER            -> align to 4 bytes: offset becomes 8 (pad 3 bytes: 5,6,7), size 4 -> 8..11
    3. S1: SMALLINT           -> align to 2 bytes: offset 12 is already even, size 2 -> 12..13
    4. B1: BIGINT             -> align to 8 bytes: offset becomes 16 (pad 2 bytes: 14,15), size 8 -> 16..23
    5. V1: VARCHAR(10)        -> align to 2 bytes: offset 24 is even, size 2 (len) + 10 = 12 -> 24..35
    6. D1: DOUBLE PRECISION   -> align to 8 bytes: offset becomes 40 (pad 4 bytes: 36..39), size 8 -> 40..47
    7. DT: DATE               -> align to 4 bytes: offset 48 is div 4, size 4 -> 48..51
    Total Record Size = 52 bytes }

  Schema := TFBTableSchema.Create;
  try
    Schema.AddColumn('C1', fbftChar, 5);
    Schema.AddColumn('I1', fbftInteger);
    Schema.AddColumn('S1', fbftSmallInt);
    Schema.AddColumn('B1', fbftBigInt);
    Schema.AddColumn('V1', fbftVarChar, 10);
    Schema.AddColumn('D1', fbftDouble);
    Schema.AddColumn('DT', fbftDate);

    ExpectedSize := Schema.CalculateRecordSize;
    Assert(ExpectedSize = 52, 'Schema calculated size is 52 bytes', Format('Got %d', [ExpectedSize]));

    Rec := TExt_Record.Create(256);
    try
      Rec.AppendChar('HELLO', 5);
      Assert(Rec.RecordLength = 5, 'After CHAR(5), offset is 5', Format('Got %d', [Rec.RecordLength]));

      Rec.AppendInteger(123456);
      Assert(Rec.RecordLength = 12, 'After INTEGER (aligned to 4), offset is 12', Format('Got %d', [Rec.RecordLength]));

      Rec.AppendSmallInt(42);
      Assert(Rec.RecordLength = 14, 'After SMALLINT, offset is 14', Format('Got %d', [Rec.RecordLength]));

      Rec.AppendBigInt(9876543210);
      Assert(Rec.RecordLength = 24, 'After BIGINT (aligned to 8), offset is 24', Format('Got %d', [Rec.RecordLength]));

      Rec.AppendVarChar('TEST', 10);
      Assert(Rec.RecordLength = 36, 'After VARCHAR(10) (aligned to 2), offset is 36', Format('Got %d', [Rec.RecordLength]));

      Rec.AppendDouble(3.14159265);
      Assert(Rec.RecordLength = 48, 'After DOUBLE (aligned to 8), offset is 48', Format('Got %d', [Rec.RecordLength]));

      Rec.AppendDate(EncodeDate(2026, 10, 29));
      Assert(Rec.RecordLength = 52, 'After DATE (aligned to 4), total record length is 52', Format('Got %d', [Rec.RecordLength]));

      Buf := Rec.GetBuffer;
      Assert(Length(Buf) = 52, 'Buffer length matches 52 bytes');

      // Verify padding bytes at 5,6,7 are #0
      Assert((Buf[5] = 0) and (Buf[6] = 0) and (Buf[7] = 0), 'Alignment padding bytes before INTEGER are zeroed');

      // Verify VARCHAR length prefix at offset 24..25 is Word(4) ('TEST')
      Assert((Buf[24] = 4) and (Buf[25] = 0), 'VARCHAR 2-byte length prefix equals 4', Format('Got %d,%d', [Buf[24], Buf[25]]));
      // Verify VARCHAR payload 'TEST' at offset 26..29
      Assert((Char(Buf[26]) = 'T') and (Char(Buf[27]) = 'E') and (Char(Buf[28]) = 'S') and (Char(Buf[29]) = 'T'),
        'VARCHAR payload bytes match "TEST"');
    finally
      Rec.Free;
    end;
  finally
    Schema.Free;
  end;
end;

procedure TTestRunner.TestEncodingWindows1250;
var
  TestStr: string;
  Enc: TEncoding;
  Bytes: TBytes;
  DecodedStr: string;
begin
  Writeln('--- Testing Windows-1250 Encoding (Linux-safe) ---');

  TestStr := 'Árvíztűrő tükörfúrógép - ÁRVÍZTŰRŐ TÜKÖRFÚRÓGÉP';
  Enc := ResolveEncoding('WIN1250');
  Bytes := Enc.GetBytes(TestStr);
  DecodedStr := Enc.GetString(Bytes);

  Assert(TestStr = DecodedStr, 'Windows-1250 Hungarian characters roundtrip', DecodedStr);
end;

procedure TTestRunner.TestNumericScales;
var
  Rec: TExt_Record;
  Buf: TBytes;
  ScaledVal: Int64;
begin
  Writeln('--- Testing Scaled NUMERIC / DECIMAL ---');

  Rec := TExt_Record.Create(128);
  try
    // Price 123.45 with Scale 2 -> 12345
    Rec.AppendNumeric(123.45, 9, 2); // Precision 9 -> INTEGER (4 bytes)
    Buf := Rec.GetBuffer;
    Assert(Length(Buf) = 4, 'NUMERIC(9, 2) uses 4 bytes (INTEGER)', Format('Got %d', [Length(Buf)]));
    Move(Buf[0], ScaledVal, 4);
    Assert(ScaledVal = 12345, 'NUMERIC(9, 2) value 123.45 stored as scaled integer 12345', Format('Got %d', [ScaledVal]));
  finally
    Rec.Free;
  end;
end;

procedure TTestRunner.TestCSVReader;
var
  TempCSV: string;
  CSVContent: string;
  Reader: TCsvReader;
  Fields: TCsvFieldArray;
begin
  Writeln('--- Testing CSV Reader with Quotes and Delimiters ---');

  TempCSV := TPath.Combine(TPath.GetTempPath, 'test_sample.csv');
  CSVContent :=
    'ID;NAME;PRICE;CREATED_AT' + sLineBreak +
    '1;"Product; Alpha";19.99;2026-10-29' + sLineBreak +
    '2;"Product ""Beta""";25.50;2026-10-28' + sLineBreak;

  TFile.WriteAllText(TempCSV, CSVContent, TEncoding.UTF8);
  try
    Reader := TCsvReader.Create(TempCSV, ';', '"', 'UTF8');
    try
      Assert(Reader.ReadHeader(Fields), 'Read CSV Header');
      Assert(Length(Fields) = 4, 'Header field count is 4', Format('Got %d', [Length(Fields)]));
      Assert(Fields[1] = 'NAME', 'Header second column is NAME');

      Assert(Reader.ReadRecord(Fields), 'Read First Data Row');
      Assert(Fields[0] = '1', 'Row 1 ID is 1');
      Assert(Fields[1] = 'Product; Alpha', 'Row 1 escaped delimiter inside quotes handled');
      Assert(Fields[2] = '19.99', 'Row 1 Price is 19.99');

      Assert(Reader.ReadRecord(Fields), 'Read Second Data Row');
      Assert(Fields[1] = 'Product "Beta"', 'Row 2 escaped double quotes handled');
    finally
      Reader.Free;
    end;
  finally
    if TFile.Exists(TempCSV) then
      TFile.Delete(TempCSV);
  end;
end;

procedure TTestRunner.TestEndToEndConversion;
var
  TempDir: string;
  CsvFile, ExtFile, SqlFile, JsonFile: string;
  Schema: TFBTableSchema;
  Converter: TCsvToExternalConverter;
  Stats: TConversionStats;
  CSVContent: string;
  ExtStream: TFileStream;
  Buf: TBytes;
  Row1ID: Integer;
begin
  Writeln('--- Testing End-To-End CSV to Firebird External Conversion ---');

  TempDir := TPath.Combine(TPath.GetTempPath, 'fb_ext_test_' + FormatDateTime('hhnnsszzz', Now));
  TDirectory.CreateDirectory(TempDir);
  try
    CsvFile := TPath.Combine(TempDir, 'data.csv');
    ExtFile := TPath.Combine(TempDir, 'data.ext');
    SqlFile := TPath.Combine(TempDir, 'data.sql');
    JsonFile := TPath.Combine(TempDir, 'schema.json');

    CSVContent :=
      'ID;CUSTOMER;AMOUNT;ACTIVE;INVOICE_DATE;INVOICE_TIME' + sLineBreak +
      '1001;Kovács János;15250,50;1;2026-10-29;14:30:00' + sLineBreak +
      '1002;Nagy & Társa Kft;9800,00;0;2026.10.28.;09:15:22' + sLineBreak;

    TFile.WriteAllText(CsvFile, CSVContent, TEncoding.UTF8);

    Schema := TFBTableSchema.Create;
    try
      Schema.TableName := 'EXT_INVOICES';
      Schema.ExternalFileName := 'data.ext';
      Schema.CharacterSet := 'WIN1250';
      Schema.Delimiter := ';';
      Schema.QuoteChar := '"';
      Schema.HasHeader := True;
      Schema.DecimalSeparator := ',';

      Schema.AddColumn('ID', fbftInteger);
      Schema.AddColumn('CUSTOMER', fbftVarChar, 30);
      Schema.AddColumn('AMOUNT', fbftNumeric, 12, 2);
      Schema.AddColumn('ACTIVE', fbftBoolean);
      Schema.AddColumn('INVOICE_DATE', fbftDate);
      Schema.AddColumn('INVOICE_TIME', fbftTime);

      Schema.SaveToJSONFile(JsonFile);
      Assert(TFile.Exists(JsonFile), 'Schema saved to JSON file');

      Converter := TCsvToExternalConverter.Create(Schema, False);
      try
        Stats := Converter.Execute(CsvFile, ExtFile, SqlFile);

        Assert(Stats.RecordCount = 2, 'Converted 2 records', Format('Got %d', [Stats.RecordCount]));
        Assert(TFile.Exists(ExtFile), 'Output .ext file exists');
        Assert(TFile.Exists(SqlFile), 'Output .sql file exists');

        // Verify that file size matches 2 * RecordSize exactly
        ExtStream := TFileStream.Create(ExtFile, fmOpenRead);
        try
          Assert(ExtStream.Size = 2 * Stats.RecordSize,
            'File size exactly equals 2 * RecordSize (no garbage / no missing bytes)',
            Format('Size: %d, Expected: %d', [ExtStream.Size, 2 * Stats.RecordSize]));

          SetLength(Buf, Stats.RecordSize);
          ExtStream.ReadBuffer(Buf[0], Stats.RecordSize);

          // Verify Row 1: ID = 1001 (offset 0..3)
          Move(Buf[0], Row1ID, 4);
          Assert(Row1ID = 1001, 'Row 1 ID is 1001', Format('Got %d', [Row1ID]));
        finally
          ExtStream.Free;
        end;
      finally
        Converter.Free;
      end;
    finally
      Schema.Free;
    end;
  finally
    if TDirectory.Exists(TempDir) then
      TDirectory.Delete(TempDir, True);
  end;
end;

function TTestRunner.RunAllTests: Boolean;
begin
  Writeln('========================================');
  Writeln(' Firebird 5 External Engine Test Suite  ');
  Writeln('========================================');

  TestDateConversions;
  TestTimeConversions;
  TestTimestampConversions;
  TestAlignmentsAndOffsets;
  TestEncodingWindows1250;
  TestNumericScales;
  TestCSVReader;
  TestEndToEndConversion;

  Writeln('========================================');
  Writeln(Format(' Tests Completed: %d passed, %d failed', [FPassedCount, FFailedCount]));
  Writeln('========================================');
  Result := (FFailedCount = 0);
end;

function RunTestsConsole: Boolean;
var
  Runner: TTestRunner;
begin
  Runner := TTestRunner.Create;
  try
    Result := Runner.RunAllTests;
  finally
    Runner.Free;
  end;
end;

end.
