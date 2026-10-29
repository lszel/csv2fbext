unit ExternalTypes;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils,
  System.DateUtils;

type
  TFBFieldType = (
    fbftChar,
    fbftVarChar,
    fbftSmallInt,
    fbftInteger,
    fbftBigInt,
    fbftFloat,
    fbftDouble,
    fbftBoolean,
    fbftDate,
    fbftTime,
    fbftTimestamp,
    fbftNumeric,
    fbftDecimal,
    fbftCRLF
  );

  TFBTimestamp = packed record
    DatePart: Integer;   // ISC_DATE: Days since 1858-11-17
    TimePart: Cardinal;  // ISC_TIME: Fractions of 1/10000 sec since midnight
  end;

const
  // Firebird 5 / ODS 11+ maximum alignment
  FB_MAX_ALIGNMENT = 8;

  // Firebird Modified Julian Date Epoch (November 17, 1858)
  // Delphi TDateTime Epoch is December 30, 1899.
  // Number of days between 1858-11-17 and 1899-12-30 is 15018.
  FB_BASE_DATE_OFFSET = 15018;

  // ISC_TIME precision: 10000 ticks per second (0.1 ms precision)
  FB_TIME_TICKS_PER_SECOND = 10000;
  FB_TIME_TICKS_PER_DAY: Int64 = 86400 * 10000; // 864,000,000

// Conversion routines
function DelphiDateToFirebirdDate(const ADate: TDate): Integer;
function FirebirdDateToDelphiDate(const AFBDate: Integer): TDate;

function DelphiTimeToFirebirdTime(const ATime: TTime): Cardinal;
function FirebirdTimeToDelphiTime(const AFBTime: Cardinal): TTime;

procedure DelphiDateTimeToFirebirdTimestamp(const ADateTime: TDateTime;
  out ADatePart: Integer; out ATimePart: Cardinal);
function FirebirdTimestampToDelphiDateTime(const ADatePart: Integer;
  const ATimePart: Cardinal): TDateTime;

function GetFieldAlignment(const AType: TFBFieldType; const APrecision: Integer = 0): Integer;
function GetScaleFactor(const AScale: Integer): Int64;

// Type string parsing and formatting
function FBFieldTypeToString(const AType: TFBFieldType): string;
function StringToFBFieldType(const AStr: string): TFBFieldType;

// Flexible date/time parsers
function ParseDateFlexible(const AValue: string; const AFormat: string = ''): TDate;
function ParseTimeFlexible(const AValue: string; const AFormat: string = ''): TTime;
function ParseDateTimeFlexible(const AValue: string; const AFormat: string = ''): TDateTime;

implementation

function DelphiDateToFirebirdDate(const ADate: TDate): Integer;
begin
  Result := Trunc(ADate) + FB_BASE_DATE_OFFSET;
end;

function FirebirdDateToDelphiDate(const AFBDate: Integer): TDate;
begin
  Result := AFBDate - FB_BASE_DATE_OFFSET;
end;

function DelphiTimeToFirebirdTime(const ATime: TTime): Cardinal;
var
  Hour, Min, Sec, MSec: Word;
  TotalSec: Cardinal;
begin
  DecodeTime(ATime, Hour, Min, Sec, MSec);
  TotalSec := (Cardinal(Hour) * 3600) + (Cardinal(Min) * 60) + Cardinal(Sec);
  Result := (TotalSec * FB_TIME_TICKS_PER_SECOND) + (Cardinal(MSec) * 10);
end;

function FirebirdTimeToDelphiTime(const AFBTime: Cardinal): TTime;
var
  TotalSec, Remainder: Cardinal;
  Hour, Min, Sec, MSec: Word;
begin
  TotalSec := AFBTime div FB_TIME_TICKS_PER_SECOND;
  Remainder := AFBTime mod FB_TIME_TICKS_PER_SECOND;
  MSec := Remainder div 10;
  Sec := TotalSec mod 60;
  Min := (TotalSec div 60) mod 60;
  Hour := TotalSec div 3600;
  Result := EncodeTime(Hour, Min, Sec, MSec);
end;

procedure DelphiDateTimeToFirebirdTimestamp(const ADateTime: TDateTime;
  out ADatePart: Integer; out ATimePart: Cardinal);
begin
  ADatePart := DelphiDateToFirebirdDate(DateOf(ADateTime));
  ATimePart := DelphiTimeToFirebirdTime(TimeOf(ADateTime));
end;

function FirebirdTimestampToDelphiDateTime(const ADatePart: Integer;
  const ATimePart: Cardinal): TDateTime;
begin
  Result := FirebirdDateToDelphiDate(ADatePart) + FirebirdTimeToDelphiTime(ATimePart);
end;

function GetFieldAlignment(const AType: TFBFieldType; const APrecision: Integer): Integer;
begin
  case AType of
    fbftChar:
      Result := 1;
    fbftVarChar:
      Result := 2; // Firebird aligns VARCHAR to 2 bytes (length prefix USHORT)
    fbftSmallInt:
      Result := 2;
    fbftInteger, fbftFloat, fbftDate, fbftTime:
      Result := 4;
    fbftBigInt, fbftDouble, fbftTimestamp:
      Result := 8;
    fbftBoolean:
      Result := 1;
    fbftNumeric, fbftDecimal:
      begin
        if APrecision <= 4 then
          Result := 2
        else if APrecision <= 9 then
          Result := 4
        else
          Result := 8;
      end;
    fbftCRLF:
      Result := 1;
  else
    Result := 1;
  end;
end;

function GetScaleFactor(const AScale: Integer): Int64;
var
  I: Integer;
begin
  Result := 1;
  for I := 1 to AScale do
    Result := Result * 10;
end;

function FBFieldTypeToString(const AType: TFBFieldType): string;
begin
  case AType of
    fbftChar: Result := 'CHAR';
    fbftVarChar: Result := 'VARCHAR';
    fbftSmallInt: Result := 'SMALLINT';
    fbftInteger: Result := 'INTEGER';
    fbftBigInt: Result := 'BIGINT';
    fbftFloat: Result := 'FLOAT';
    fbftDouble: Result := 'DOUBLE PRECISION';
    fbftBoolean: Result := 'BOOLEAN';
    fbftDate: Result := 'DATE';
    fbftTime: Result := 'TIME';
    fbftTimestamp: Result := 'TIMESTAMP';
    fbftNumeric: Result := 'NUMERIC';
    fbftDecimal: Result := 'DECIMAL';
    fbftCRLF: Result := 'CRLF';
  else
    Result := 'VARCHAR';
  end;
end;

function StringToFBFieldType(const AStr: string): TFBFieldType;
var
  S: string;
begin
  S := UpperCase(Trim(AStr));
  if (S = 'CHAR') or (S = 'CHARACTER') then
    Result := fbftChar
  else if (S = 'VARCHAR') or (S = 'CHAR VARYING') or (S = 'CHARACTER VARYING') then
    Result := fbftVarChar
  else if (S = 'SMALLINT') or (S = 'SHORT') or (S = 'INT2') then
    Result := fbftSmallInt
  else if (S = 'INTEGER') or (S = 'INT') or (S = 'INT4') then
    Result := fbftInteger
  else if (S = 'BIGINT') or (S = 'INT64') or (S = 'INT8') then
    Result := fbftBigInt
  else if (S = 'FLOAT') or (S = 'REAL') or (S = 'SINGLE') then
    Result := fbftFloat
  else if (S = 'DOUBLE') or (S = 'DOUBLE PRECISION') or (S = 'FLOAT8') then
    Result := fbftDouble
  else if (S = 'BOOLEAN') or (S = 'BOOL') then
    Result := fbftBoolean
  else if (S = 'DATE') then
    Result := fbftDate
  else if (S = 'TIME') or (S = 'TIME WITHOUT TIME ZONE') then
    Result := fbftTime
  else if (S = 'TIMESTAMP') or (S = 'DATETIME') or (S = 'TIMESTAMP WITHOUT TIME ZONE') then
    Result := fbftTimestamp
  else if (S = 'NUMERIC') then
    Result := fbftNumeric
  else if (S = 'DECIMAL') or (S = 'DEC') then
    Result := fbftDecimal
  else if (S = 'CRLF') then
    Result := fbftCRLF
  else
    raise Exception.CreateFmt('Unknown Firebird field type: %s', [AStr]);
end;

function CleanDateStr(const S: string): string;
begin
  Result := Trim(S);
  // Remove trailing dots (common in Hungarian date notation like 2026.10.29.)
  while (Length(Result) > 0) and (Result[Length(Result)] = '.') do
    Delete(Result, Length(Result), 1);
end;

function ParseDateFlexible(const AValue: string; const AFormat: string): TDate;
var
  S: string;
  FS: TFormatSettings;
  DT: TDateTime;
  IY, IM, ID: Integer;
begin
  S := CleanDateStr(AValue);
  if S = '' then
    Exit(0);

  // If a specific format is provided
  if AFormat <> '' then
  begin
    FS := TFormatSettings.Create;
    FS.ShortDateFormat := AFormat;
    if TryStrToDate(S, DT, FS) then
      Exit(DateOf(DT));
  end;

  // Try standard ISO: yyyy-mm-dd
  FS := TFormatSettings.Create;
  FS.DateSeparator := '-';
  FS.ShortDateFormat := 'yyyy-mm-dd';
  if TryStrToDate(S, DT, FS) then
    Exit(DateOf(DT));

  // Try Hungarian format: yyyy.mm.dd
  FS.DateSeparator := '.';
  FS.ShortDateFormat := 'yyyy.mm.dd';
  if TryStrToDate(S, DT, FS) then
    Exit(DateOf(DT));

  // Try European format: dd.mm.yyyy
  FS.DateSeparator := '.';
  FS.ShortDateFormat := 'dd.mm.yyyy';
  if TryStrToDate(S, DT, FS) then
    Exit(DateOf(DT));

  // Try slash format: yyyy/mm/dd or dd/mm/yyyy
  FS.DateSeparator := '/';
  FS.ShortDateFormat := 'yyyy/mm/dd';
  if TryStrToDate(S, DT, FS) then
    Exit(DateOf(DT));

  FS.ShortDateFormat := 'dd/mm/yyyy';
  if TryStrToDate(S, DT, FS) then
    Exit(DateOf(DT));

  // Try compact: yyyymmdd (8 digits)
  if (Length(S) = 8) and TryStrToInt(Copy(S, 1, 4), IY) and
     TryStrToInt(Copy(S, 5, 2), IM) and TryStrToInt(Copy(S, 7, 2), ID) then
  begin
    if TryEncodeDate(Word(IY), Word(IM), Word(ID), DT) then
      Exit(DateOf(DT));
  end;

  // Fallback to system default
  Result := StrToDate(S);
end;

function ParseTimeFlexible(const AValue: string; const AFormat: string): TTime;
var
  S: string;
  FS: TFormatSettings;
  DT: TDateTime;
  Hour, Min, Sec, MSec: Word;
  Parts: TArray<string>;
  SecParts: TArray<string>;
  MSecStr: string;
begin
  S := Trim(AValue);
  if S = '' then
    Exit(0);

  if AFormat <> '' then
  begin
    FS := TFormatSettings.Create;
    FS.ShortTimeFormat := AFormat;
    FS.LongTimeFormat := AFormat;
    if TryStrToTime(S, DT, FS) then
      Exit(TimeOf(DT));
  end;

  FS := TFormatSettings.Create;
  FS.TimeSeparator := ':';
  FS.LongTimeFormat := 'hh:nn:ss';
  if TryStrToTime(S, DT, FS) then
    Exit(TimeOf(DT));

  // Direct manual parse if there are milliseconds or standard colons
  Parts := S.Split([':']);
  if Length(Parts) >= 2 then
  begin
    Hour := StrToIntDef(Parts[0], 0);
    Min := StrToIntDef(Parts[1], 0);
    Sec := 0;
    MSec := 0;
    if Length(Parts) >= 3 then
    begin
      SecParts := Parts[2].Split(['.', ',']);
      Sec := StrToIntDef(SecParts[0], 0);
      if Length(SecParts) >= 2 then
      begin
        // Milliseconds: pad or trim to 3 digits
        MSecStr := SecParts[1];
        if Length(MSecStr) > 3 then
          MSecStr := Copy(MSecStr, 1, 3)
        else
          while Length(MSecStr) < 3 do
            MSecStr := MSecStr + '0';
        MSec := StrToIntDef(MSecStr, 0);
      end;
    end;
    if TryEncodeTime(Hour, Min, Sec, MSec, DT) then
      Exit(TimeOf(DT));
  end;

  Result := StrToTime(S);
end;

function ParseDateTimeFlexible(const AValue: string; const AFormat: string): TDateTime;
var
  S: string;
  FS: TFormatSettings;
  SpacePos, TPos: Integer;
  DatePartStr, TimePartStr: string;
  D: TDate;
  T: TTime;
begin
  S := Trim(AValue);
  if S = '' then
    Exit(0);

  if AFormat <> '' then
  begin
    FS := TFormatSettings.Create;
    if TryStrToDateTime(S, Result, FS) then
      Exit;
  end;

  // Handle ISO 'T' separator e.g. 2026-10-29T14:30:00
  TPos := Pos('T', S);
  SpacePos := Pos(' ', S);
  if (TPos > 0) and ((SpacePos = 0) or (TPos < SpacePos)) then
  begin
    DatePartStr := Copy(S, 1, TPos - 1);
    TimePartStr := Copy(S, TPos + 1, MaxInt);
  end
  else if SpacePos > 0 then
  begin
    DatePartStr := Copy(S, 1, SpacePos - 1);
    TimePartStr := Copy(S, SpacePos + 1, MaxInt);
  end
  else
  begin
    // Pure date without time
    DatePartStr := S;
    TimePartStr := '';
  end;

  D := ParseDateFlexible(DatePartStr);
  if TimePartStr <> '' then
    T := ParseTimeFlexible(TimePartStr)
  else
    T := 0;

  Result := D + T;
end;

end.
