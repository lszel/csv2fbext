unit EncodingUtils;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils,
  System.Classes;

type
  { Custom self-contained Windows-1250 encoding that runs anywhere,
    including Linux environments where code page 1250 might not be registered. }
  TWindows1250Encoding = class(TEncoding)
  private
    class var FInstance: TWindows1250Encoding;
    class constructor ClassCreate;
    class destructor ClassDestroy;
  protected
    function GetByteCount(Chars: PChar; CharCount: Integer): Integer; overload; override;
    function GetBytes(Chars: PChar; CharCount: Integer; Bytes: PByte; ByteCount: Integer): Integer; overload; override;
    function GetCharCount(Bytes: PByte; ByteCount: Integer): Integer; overload; override;
    function GetChars(Bytes: PByte; ByteCount: Integer; Chars: PChar; CharCount: Integer): Integer; overload; override;
  public
    function GetMaxByteCount(CharCount: Integer): Integer; override;
    function GetMaxCharCount(ByteCount: Integer): Integer; override;
    function GetPreamble: TBytes; override;
    function Clone: TEncoding; override;
    function GetEncodingName: string; override;
    class property Instance: TWindows1250Encoding read FInstance;
  end;

function ResolveEncoding(const ACharsetName: string): TEncoding;

implementation

const
  CP1250_TO_UNICODE: array[0..127] of Word = (
    $20AC, $FFFD, $201A, $FFFD, $201E, $2026, $2020, $2021, // 128..135
    $FFFD, $2030, $0160, $2039, $015A, $0164, $017D, $0179, // 136..143
    $FFFD, $2018, $2019, $201C, $201D, $2022, $2013, $2014, // 144..151
    $FFFD, $2122, $0161, $203A, $015B, $0165, $017E, $017A, // 152..159
    $00A0, $02C7, $02D8, $0141, $00A4, $0104, $00A6, $00A7, // 160..167
    $00A8, $00A9, $015E, $00AB, $00AC, $00AD, $00AE, $017B, // 168..175
    $00B0, $00B1, $02DB, $0142, $00B4, $00B5, $00B6, $00B7, // 176..183
    $00B8, $0105, $015F, $00BB, $013D, $02DD, $013E, $017C, // 184..191
    $0154, $00C1, $00C2, $0102, $00C4, $0139, $0106, $00C7, // 192..199
    $010C, $00C9, $0118, $00CB, $011A, $00CD, $00CE, $010E, // 200..207
    $0110, $0143, $0147, $00D3, $00D4, $0150, $00D6, $00D7, // 208..215
    $0158, $016E, $00DA, $0170, $00DC, $00DD, $0162, $00DF, // 216..223
    $0155, $00E1, $00E2, $0103, $00E4, $013A, $0107, $00E7, // 224..231
    $010D, $00E9, $0119, $00EB, $011B, $00ED, $00EE, $010F, // 232..239
    $0111, $0144, $0148, $00F3, $00F4, $0151, $00F6, $00F7, // 240..247
    $0159, $016F, $00FA, $0171, $00FC, $00FD, $0163, $02D9  // 248..255
  );

function UnicodeCharToCP1250(const C: Char): Byte;
var
  W: Word;
  I: Integer;
begin
  W := Word(C);
  if W < 128 then
    Exit(Byte(W));

  for I := 0 to 127 do
  begin
    if CP1250_TO_UNICODE[I] = W then
      Exit(Byte(128 + I));
  end;

  // Fallback: question mark
  Result := Byte(Ord('?'));
end;

function CP1250ByteToUnicode(const B: Byte): Char;
begin
  if B < 128 then
    Result := Char(B)
  else
    Result := Char(CP1250_TO_UNICODE[B - 128]);
end;

{ TWindows1250Encoding }

class constructor TWindows1250Encoding.ClassCreate;
begin
  FInstance := TWindows1250Encoding.Create;
end;

class destructor TWindows1250Encoding.ClassDestroy;
begin
  FreeAndNil(FInstance);
end;

function TWindows1250Encoding.Clone: TEncoding;
begin
  Result := TWindows1250Encoding.Create;
end;

function TWindows1250Encoding.GetEncodingName: string;
begin
  Result := 'windows-1250';
end;

function TWindows1250Encoding.GetByteCount(Chars: PChar; CharCount: Integer): Integer;
begin
  Result := CharCount;
end;

function TWindows1250Encoding.GetBytes(Chars: PChar; CharCount: Integer; Bytes: PByte; ByteCount: Integer): Integer;
var
  I, N: Integer;
begin
  N := CharCount;
  if N > ByteCount then
    N := ByteCount;
  for I := 0 to N - 1 do
    Bytes[I] := UnicodeCharToCP1250(Chars[I]);
  Result := N;
end;

function TWindows1250Encoding.GetCharCount(Bytes: PByte; ByteCount: Integer): Integer;
begin
  Result := ByteCount;
end;

function TWindows1250Encoding.GetChars(Bytes: PByte; ByteCount: Integer; Chars: PChar; CharCount: Integer): Integer;
var
  I, N: Integer;
begin
  N := ByteCount;
  if N > CharCount then
    N := CharCount;
  for I := 0 to N - 1 do
    Chars[I] := CP1250ByteToUnicode(Bytes[I]);
  Result := N;
end;

function TWindows1250Encoding.GetMaxByteCount(CharCount: Integer): Integer;
begin
  Result := CharCount;
end;

function TWindows1250Encoding.GetMaxCharCount(ByteCount: Integer): Integer;
begin
  Result := ByteCount;
end;

function TWindows1250Encoding.GetPreamble: TBytes;
begin
  Result := nil;
end;

function ResolveEncoding(const ACharsetName: string): TEncoding;
var
  S: string;
begin
  S := UpperCase(Trim(ACharsetName));
  if (S = '') or (S = 'WIN1250') or (S = 'WINDOWS-1250') or (S = '1250') or (S = 'CP1250') then
  begin
    try
      Result := TEncoding.GetEncoding(1250);
    except
      Result := TWindows1250Encoding.Instance;
    end;
  end
  else if (S = 'UTF8') or (S = 'UTF-8') then
    Result := TEncoding.UTF8
  else if (S = 'ASCII') or (S = 'US-ASCII') then
    Result := TEncoding.ASCII
  else if (S = 'UNICODE') or (S = 'UTF16') or (S = 'UTF-16') or (S = 'UTF-16LE') then
    Result := TEncoding.Unicode
  else if (S = 'BIGENDIANUNICODE') or (S = 'UTF-16BE') then
    Result := TEncoding.BigEndianUnicode
  else if (S = 'ANSI') or (S = 'DEFAULT') then
    Result := TEncoding.ANSI
  else
  begin
    try
      Result := TEncoding.GetEncoding(S);
    except
      try
        Result := TEncoding.GetEncoding(StrToInt(S));
      except
        Result := TWindows1250Encoding.Instance;
      end;
    end;
  end;
end;

end.
