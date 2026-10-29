unit ExternalSchema;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.JSON,
  System.IOUtils,
  ExternalTypes;

type
  TFBColumnDef = class
  private
    FName: string;
    FFieldType: TFBFieldType;
    FLength: Integer;
    FPrecision: Integer;
    FScale: Integer;
    FDateFormat: string;
    FTimeFormat: string;
    FTimestampFormat: string;
    FDecimalSeparator: Char;
    FDefaultValue: string;
    FTrimSpaces: Boolean;
    FNullable: Boolean;
  public
    constructor Create;
    function Clone: TFBColumnDef;

    function ToSQLDefinition(const ACharset: string = ''): string;
    function ToJSONObject: TJSONObject;
    procedure FromJSONObject(const AObj: TJSONObject);

    property Name: string read FName write FName;
    property FieldType: TFBFieldType read FFieldType write FFieldType;
    property Length: Integer read FLength write FLength;
    property Precision: Integer read FPrecision write FPrecision;
    property Scale: Integer read FScale write FScale;
    property DateFormat: string read FDateFormat write FDateFormat;
    property TimeFormat: string read FTimeFormat write FTimeFormat;
    property TimestampFormat: string read FTimestampFormat write FTimestampFormat;
    property DecimalSeparator: Char read FDecimalSeparator write FDecimalSeparator;
    property DefaultValue: string read FDefaultValue write FDefaultValue;
    property TrimSpaces: Boolean read FTrimSpaces write FTrimSpaces;
    property Nullable: Boolean read FNullable write FNullable;
  end;

  TFBTableSchema = class
  private
    FTableName: string;
    FExternalFileName: string;
    FCharacterSet: string;
    FDelimiter: Char;
    FQuoteChar: Char;
    FHasHeader: Boolean;
    FIncludeCRLF: Boolean;
    FDateFormat: string;
    FTimeFormat: string;
    FTimestampFormat: string;
    FDecimalSeparator: Char;
    FColumns: TObjectList<TFBColumnDef>;

    function GetColumnCount: Integer;
    function GetColumn(const AIndex: Integer): TFBColumnDef;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Clear;

    function AddColumn(const AName: string; const AType: TFBFieldType;
      const ALength: Integer = 0; const APrecision: Integer = 0;
      const AScale: Integer = 0): TFBColumnDef;

    function FindColumn(const AName: string): TFBColumnDef;
    function ColumnIndex(const AName: string): Integer;

    function CalculateRecordSize: Integer;
    function GenerateSQL(const ASQLFilePath: string = ''): string;

    procedure SaveToJSONFile(const AFileName: string);
    procedure LoadFromJSONFile(const AFileName: string);
    procedure LoadFromJSONString(const AJSONStr: string);
    function SaveToJSONString: string;

    // Backward-compatibility: load column lengths from old .str file
    procedure LoadFromLegacyStrFile(const AFileName: string; const ADefaultType: TFBFieldType = fbftVarChar);

    property TableName: string read FTableName write FTableName;
    property ExternalFileName: string read FExternalFileName write FExternalFileName;
    property CharacterSet: string read FCharacterSet write FCharacterSet;
    property Delimiter: Char read FDelimiter write FDelimiter;
    property QuoteChar: Char read FQuoteChar write FQuoteChar;
    property HasHeader: Boolean read FHasHeader write FHasHeader;
    property IncludeCRLF: Boolean read FIncludeCRLF write FIncludeCRLF;
    property DateFormat: string read FDateFormat write FDateFormat;
    property TimeFormat: string read FTimeFormat write FTimeFormat;
    property TimestampFormat: string read FTimestampFormat write FTimestampFormat;
    property DecimalSeparator: Char read FDecimalSeparator write FDecimalSeparator;
    property ColumnCount: Integer read GetColumnCount;
    property Columns[const AIndex: Integer]: TFBColumnDef read GetColumn; default;
  end;

implementation

{ TFBColumnDef }

constructor TFBColumnDef.Create;
begin
  inherited Create;
  FName := '';
  FFieldType := fbftVarChar;
  FLength := 50;
  FPrecision := 18;
  FScale := 2;
  FDateFormat := '';
  FTimeFormat := '';
  FTimestampFormat := '';
  FDecimalSeparator := #0; // #0 means use schema default
  FDefaultValue := '';
  FTrimSpaces := True;
  FNullable := True;
end;

function TFBColumnDef.Clone: TFBColumnDef;
begin
  Result := TFBColumnDef.Create;
  Result.FName := Self.FName;
  Result.FFieldType := Self.FFieldType;
  Result.FLength := Self.FLength;
  Result.FPrecision := Self.FPrecision;
  Result.FScale := Self.FScale;
  Result.FDateFormat := Self.FDateFormat;
  Result.FTimeFormat := Self.FTimeFormat;
  Result.FTimestampFormat := Self.FTimestampFormat;
  Result.FDecimalSeparator := Self.FDecimalSeparator;
  Result.FDefaultValue := Self.FDefaultValue;
  Result.FTrimSpaces := Self.FTrimSpaces;
  Result.FNullable := Self.FNullable;
end;

function TFBColumnDef.ToSQLDefinition(const ACharset: string): string;
var
  TypeStr: string;
  CS: string;
begin
  if (ACharset <> '') and ((FFieldType = fbftChar) or (FFieldType = fbftVarChar)) then
    CS := ' CHARACTER SET ' + ACharset
  else
    CS := '';

  case FFieldType of
    fbftChar:
      TypeStr := Format('CHAR(%d)%s', [FLength, CS]);
    fbftVarChar:
      TypeStr := Format('VARCHAR(%d)%s', [FLength, CS]);
    fbftSmallInt:
      TypeStr := 'SMALLINT';
    fbftInteger:
      TypeStr := 'INTEGER';
    fbftBigInt:
      TypeStr := 'BIGINT';
    fbftFloat:
      TypeStr := 'FLOAT';
    fbftDouble:
      TypeStr := 'DOUBLE PRECISION';
    fbftBoolean:
      TypeStr := 'BOOLEAN';
    fbftDate:
      TypeStr := 'DATE';
    fbftTime:
      TypeStr := 'TIME';
    fbftTimestamp:
      TypeStr := 'TIMESTAMP';
    fbftNumeric:
      TypeStr := Format('NUMERIC(%d, %d)', [FPrecision, FScale]);
    fbftDecimal:
      TypeStr := Format('DECIMAL(%d, %d)', [FPrecision, FScale]);
    fbftCRLF:
      TypeStr := 'CHAR(2)';
  else
    TypeStr := Format('VARCHAR(%d)', [FLength]);
  end;

  Result := Format('  %-20s %s', [FName, TypeStr]);
end;

function TFBColumnDef.ToJSONObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', FName);
  Result.AddPair('type', FBFieldTypeToString(FFieldType));
  if (FFieldType = fbftChar) or (FFieldType = fbftVarChar) then
    Result.AddPair('length', TJSONNumber.Create(FLength));
  if (FFieldType = fbftNumeric) or (FFieldType = fbftDecimal) then
  begin
    Result.AddPair('precision', TJSONNumber.Create(FPrecision));
    Result.AddPair('scale', TJSONNumber.Create(FScale));
  end;
  if FDateFormat <> '' then
    Result.AddPair('dateFormat', FDateFormat);
  if FTimeFormat <> '' then
    Result.AddPair('timeFormat', FTimeFormat);
  if FTimestampFormat <> '' then
    Result.AddPair('timestampFormat', FTimestampFormat);
  if FDecimalSeparator <> #0 then
    Result.AddPair('decimalSeparator', string(FDecimalSeparator));
  if FDefaultValue <> '' then
    Result.AddPair('defaultValue', FDefaultValue);
  Result.AddPair('trimSpaces', TJSONBool.Create(FTrimSpaces));
  Result.AddPair('nullable', TJSONBool.Create(FNullable));
end;

procedure TFBColumnDef.FromJSONObject(const AObj: TJSONObject);
var
  Val: TJSONValue;
begin
  Val := AObj.Values['name'];
  if Val <> nil then
    FName := Val.Value;

  Val := AObj.Values['type'];
  if Val <> nil then
    FFieldType := StringToFBFieldType(Val.Value);

  Val := AObj.Values['length'];
  if Val is TJSONNumber then
    FLength := TJSONNumber(Val).AsInt;

  Val := AObj.Values['precision'];
  if Val is TJSONNumber then
    FPrecision := TJSONNumber(Val).AsInt;

  Val := AObj.Values['scale'];
  if Val is TJSONNumber then
    FScale := TJSONNumber(Val).AsInt;

  Val := AObj.Values['dateFormat'];
  if Val <> nil then
    FDateFormat := Val.Value;

  Val := AObj.Values['timeFormat'];
  if Val <> nil then
    FTimeFormat := Val.Value;

  Val := AObj.Values['timestampFormat'];
  if Val <> nil then
    FTimestampFormat := Val.Value;

  Val := AObj.Values['decimalSeparator'];
  if (Val <> nil) and (Val.Value <> '') then
    FDecimalSeparator := Val.Value[1];

  Val := AObj.Values['defaultValue'];
  if Val <> nil then
    FDefaultValue := Val.Value;

  Val := AObj.Values['trimSpaces'];
  if Val is TJSONBool then
    FTrimSpaces := TJSONBool(Val).AsBoolean;

  Val := AObj.Values['nullable'];
  if Val is TJSONBool then
    FNullable := TJSONBool(Val).AsBoolean;
end;

{ TFBTableSchema }

constructor TFBTableSchema.Create;
begin
  inherited Create;
  FColumns := TObjectList<TFBColumnDef>.Create(True);
  FTableName := 'EXT_DATA';
  FExternalFileName := 'data.ext';
  FCharacterSet := 'WIN1250';
  FDelimiter := ';';
  FQuoteChar := '"';
  FHasHeader := True;
  FIncludeCRLF := False;
  FDateFormat := 'yyyy-mm-dd';
  FTimeFormat := 'hh:nn:ss';
  FTimestampFormat := 'yyyy-mm-dd hh:nn:ss';
  FDecimalSeparator := ',';
end;

destructor TFBTableSchema.Destroy;
begin
  FColumns.Free;
  inherited;
end;

procedure TFBTableSchema.Clear;
begin
  FColumns.Clear;
end;

function TFBTableSchema.GetColumnCount: Integer;
begin
  Result := FColumns.Count;
end;

function TFBTableSchema.GetColumn(const AIndex: Integer): TFBColumnDef;
begin
  Result := FColumns[AIndex];
end;

function TFBTableSchema.AddColumn(const AName: string; const AType: TFBFieldType;
  const ALength: Integer; const APrecision: Integer; const AScale: Integer): TFBColumnDef;
begin
  Result := TFBColumnDef.Create;
  Result.Name := AName;
  Result.FieldType := AType;
  Result.Length := ALength;
  Result.Precision := APrecision;
  Result.Scale := AScale;
  FColumns.Add(Result);
end;

function TFBTableSchema.FindColumn(const AName: string): TFBColumnDef;
var
  Col: TFBColumnDef;
begin
  for Col in FColumns do
  begin
    if SameText(Col.Name, AName) then
      Exit(Col);
  end;
  Result := nil;
end;

function TFBTableSchema.ColumnIndex(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FColumns.Count - 1 do
    if SameText(FColumns[I].Name, AName) then
      Exit(I);
  Result := -1;
end;

function TFBTableSchema.CalculateRecordSize: Integer;
var
  CurOffset: Integer;
  Col: TFBColumnDef;
  Alignment: Integer;
  Pad: Integer;
  FieldSize: Integer;
begin
  CurOffset := 0;

  for Col in FColumns do
  begin
    Alignment := GetFieldAlignment(Col.FieldType, Col.Precision);
    if Alignment > 1 then
    begin
      Pad := (Alignment - (CurOffset mod Alignment)) mod Alignment;
      Inc(CurOffset, Pad);
    end;

    case Col.FieldType of
      fbftChar:
        FieldSize := Col.Length;
      fbftVarChar:
        FieldSize := 2 + Col.Length;
      fbftSmallInt:
        FieldSize := 2;
      fbftInteger, fbftFloat, fbftDate, fbftTime:
        FieldSize := 4;
      fbftBigInt, fbftDouble, fbftTimestamp:
        FieldSize := 8;
      fbftBoolean:
        FieldSize := 1;
      fbftNumeric, fbftDecimal:
        begin
          if Col.Precision <= 4 then
            FieldSize := 2
          else if Col.Precision <= 9 then
            FieldSize := 4
          else
            FieldSize := 8;
        end;
      fbftCRLF:
        FieldSize := 2;
    else
      FieldSize := Col.Length;
    end;

    Inc(CurOffset, FieldSize);
  end;

  if FIncludeCRLF then
    Inc(CurOffset, 2);

  Result := CurOffset;
end;

function TFBTableSchema.GenerateSQL(const ASQLFilePath: string): string;
var
  SB: TStringBuilder;
  I: Integer;
  ExtPath: string;
begin
  if ASQLFilePath <> '' then
    ExtPath := ASQLFilePath
  else
    ExtPath := FExternalFileName;

  SB := TStringBuilder.Create;
  try
    SB.AppendLine(Format('/* Firebird 5 External Table Definition for %s */', [FTableName]));
    SB.AppendLine(Format('CREATE TABLE %s EXTERNAL ''%s'' (', [FTableName, ExtPath]));

    for I := 0 to FColumns.Count - 1 do
    begin
      SB.Append(FColumns[I].ToSQLDefinition(FCharacterSet));
      if (I < FColumns.Count - 1) or FIncludeCRLF then
        SB.Append(',');
      SB.AppendLine;
    end;

    if FIncludeCRLF then
    begin
      SB.AppendLine('  CRLF                 CHAR(2)');
    end;

    SB.AppendLine(');');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TFBTableSchema.SaveToJSONString: string;
var
  RootObj: TJSONObject;
  ColsArr: TJSONArray;
  Col: TFBColumnDef;
begin
  RootObj := TJSONObject.Create;
  try
    RootObj.AddPair('tableName', FTableName);
    RootObj.AddPair('externalFileName', FExternalFileName);
    RootObj.AddPair('characterSet', FCharacterSet);
    RootObj.AddPair('delimiter', string(FDelimiter));
    RootObj.AddPair('quoteChar', string(FQuoteChar));
    RootObj.AddPair('hasHeader', TJSONBool.Create(FHasHeader));
    RootObj.AddPair('includeCRLF', TJSONBool.Create(FIncludeCRLF));
    RootObj.AddPair('dateFormat', FDateFormat);
    RootObj.AddPair('timeFormat', FTimeFormat);
    RootObj.AddPair('timestampFormat', FTimestampFormat);
    RootObj.AddPair('decimalSeparator', string(FDecimalSeparator));

    ColsArr := TJSONArray.Create;
    for Col in FColumns do
      ColsArr.AddElement(Col.ToJSONObject);
    RootObj.AddPair('columns', ColsArr);

    Result := RootObj.Format(2);
  finally
    RootObj.Free;
  end;
end;

procedure TFBTableSchema.SaveToJSONFile(const AFileName: string);
var
  S: string;
begin
  S := SaveToJSONString;
  TFile.WriteAllText(AFileName, S, TEncoding.UTF8);
end;

procedure TFBTableSchema.LoadFromJSONString(const AJSONStr: string);
var
  JSONVal: TJSONValue;
  RootObj: TJSONObject;
  ColsArr: TJSONArray;
  Val: TJSONValue;
  I: Integer;
  Col: TFBColumnDef;
begin
  Clear;
  JSONVal := TJSONObject.ParseJSONValue(AJSONStr);
  if not (JSONVal is TJSONObject) then
  begin
    if JSONVal <> nil then
      JSONVal.Free;
    raise Exception.Create('Invalid JSON schema format.');
  end;

  RootObj := TJSONObject(JSONVal);
  try
    Val := RootObj.Values['tableName'];
    if Val <> nil then
      FTableName := Val.Value;

    Val := RootObj.Values['externalFileName'];
    if Val <> nil then
      FExternalFileName := Val.Value;

    Val := RootObj.Values['characterSet'];
    if Val <> nil then
      FCharacterSet := Val.Value;

    Val := RootObj.Values['delimiter'];
    if (Val <> nil) and (Val.Value <> '') then
      FDelimiter := Val.Value[1];

    Val := RootObj.Values['quoteChar'];
    if (Val <> nil) and (Val.Value <> '') then
      FQuoteChar := Val.Value[1];

    Val := RootObj.Values['hasHeader'];
    if Val is TJSONBool then
      FHasHeader := TJSONBool(Val).AsBoolean;

    Val := RootObj.Values['includeCRLF'];
    if Val is TJSONBool then
      FIncludeCRLF := TJSONBool(Val).AsBoolean;

    Val := RootObj.Values['dateFormat'];
    if Val <> nil then
      FDateFormat := Val.Value;

    Val := RootObj.Values['timeFormat'];
    if Val <> nil then
      FTimeFormat := Val.Value;

    Val := RootObj.Values['timestampFormat'];
    if Val <> nil then
      FTimestampFormat := Val.Value;

    Val := RootObj.Values['decimalSeparator'];
    if (Val <> nil) and (Val.Value <> '') then
      FDecimalSeparator := Val.Value[1];

    Val := RootObj.Values['columns'];
    if Val is TJSONArray then
    begin
      ColsArr := TJSONArray(Val);
      for I := 0 to ColsArr.Count - 1 do
      begin
        if ColsArr.Items[I] is TJSONObject then
        begin
          Col := TFBColumnDef.Create;
          Col.FromJSONObject(TJSONObject(ColsArr.Items[I]));
          FColumns.Add(Col);
        end;
      end;
    end;
  finally
    RootObj.Free;
  end;
end;

procedure TFBTableSchema.LoadFromJSONFile(const AFileName: string);
var
  S: string;
begin
  S := TFile.ReadAllText(AFileName, TEncoding.UTF8);
  LoadFromJSONString(S);
end;

procedure TFBTableSchema.LoadFromLegacyStrFile(const AFileName: string; const ADefaultType: TFBFieldType);
var
  Lines: TStringList;
  I: Integer;
  Line: string;
  Parts: TArray<string>;
  ColLen: Integer;
begin
  Clear;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(AFileName);
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Line = '') or Line.StartsWith('"Records:') or Line.StartsWith('Records:') then
        Continue;

      // Old .str lines had format: "COL_NAME";"LEN" or COL_NAME;LEN
      Line := StringReplace(Line, '"', '', [rfReplaceAll]);
      Parts := Line.Split([';', ':']);
      if Length(Parts) >= 2 then
      begin
        ColLen := StrToIntDef(Trim(Parts[1]), 50);
        AddColumn(Trim(Parts[0]), ADefaultType, ColLen);
      end
      else if Length(Parts) = 1 then
      begin
        ColLen := StrToIntDef(Trim(Parts[0]), 50);
        AddColumn(Format('COL_%d', [I + 1]), ADefaultType, ColLen);
      end;
    end;
  finally
    Lines.Free;
  end;
end;

end.
