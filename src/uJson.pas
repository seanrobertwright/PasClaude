{ uJson - a small, self-contained JSON DOM for pasclaude.

  Values are reference-free: a TJson owns its children and frees them.  Strings
  are UTF-8 AnsiStrings throughout; \uXXXX escapes (including surrogate pairs)
  are decoded to UTF-8 on parse and non-ASCII is emitted raw on write, which is
  legal JSON and keeps the payload small. }
unit uJson;

{$mode objfpc}{$H+}

interface

type
  TJsonKind = (jkNull, jkBool, jkNum, jkStr, jkArr, jkObj);

  TJson = class;
  TJsonArray = array of TJson;
  TKeyArray = array of string;

  TJson = class
  private
    FKind: TJsonKind;
    FBool: Boolean;
    FNum: Double;
    FStr: string;
    FItems: TJsonArray;
    FKeys: TKeyArray;
  public
    constructor Create(AKind: TJsonKind);
    destructor Destroy; override;

    class function NewNull: TJson;
    class function NewBool(B: Boolean): TJson;
    class function NewNum(D: Double): TJson;
    class function NewStr(const S: string): TJson;
    class function NewArr: TJson;
    class function NewObj: TJson;

    { Object access.  Add takes ownership of Value. }
    procedure Add(const Key: string; Value: TJson);
    procedure AddStr(const Key, Value: string);
    procedure AddNum(const Key: string; Value: Double);
    procedure AddBool(const Key: string; Value: Boolean);
    function Find(const Key: string): TJson;          { nil when absent }
    function Str(const Key: string; const Def: string = ''): string;
    function Num(const Key: string; Def: Double = 0): Double;
    function Bool(const Key: string; Def: Boolean = False): Boolean;

    { Array access.  Push takes ownership of Value. }
    procedure Push(Value: TJson);
    function Count: Integer;
    function Item(I: Integer): TJson;
    function Key(I: Integer): string;

    { Detach the child at index I so the caller owns it. }
    function Take(I: Integer): TJson;

    function AsString: string;                        { for jkStr/jkNum/jkBool }
    function AsNumber: Double;
    function AsBoolean: Boolean;

    function ToJson: string;
    property Kind: TJsonKind read FKind;
  end;

{ Parses Text.  Returns nil on malformed input and sets Err. }
function JsonParse(const Text: string; out Err: string): TJson; overload;
function JsonParse(const Text: string): TJson; overload;

{ Escapes S as a JSON string literal, quotes included. }
function JsonQuote(const S: string): string;

implementation

uses SysUtils;

constructor TJson.Create(AKind: TJsonKind);
begin
  inherited Create;
  FKind := AKind;
end;

destructor TJson.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FItems) do
    FItems[I].Free;
  inherited Destroy;
end;

class function TJson.NewNull: TJson;
begin
  Result := TJson.Create(jkNull);
end;

class function TJson.NewBool(B: Boolean): TJson;
begin
  Result := TJson.Create(jkBool);
  Result.FBool := B;
end;

class function TJson.NewNum(D: Double): TJson;
begin
  Result := TJson.Create(jkNum);
  Result.FNum := D;
end;

class function TJson.NewStr(const S: string): TJson;
begin
  Result := TJson.Create(jkStr);
  Result.FStr := S;
end;

class function TJson.NewArr: TJson;
begin
  Result := TJson.Create(jkArr);
end;

class function TJson.NewObj: TJson;
begin
  Result := TJson.Create(jkObj);
end;

procedure TJson.Add(const Key: string; Value: TJson);
var
  N: Integer;
begin
  N := Length(FItems);
  SetLength(FItems, N + 1);
  SetLength(FKeys, N + 1);
  FItems[N] := Value;
  FKeys[N] := Key;
end;

procedure TJson.AddStr(const Key, Value: string);
begin
  Add(Key, TJson.NewStr(Value));
end;

procedure TJson.AddNum(const Key: string; Value: Double);
begin
  Add(Key, TJson.NewNum(Value));
end;

procedure TJson.AddBool(const Key: string; Value: Boolean);
begin
  Add(Key, TJson.NewBool(Value));
end;

function TJson.Find(const Key: string): TJson;
var
  I: Integer;
begin
  for I := 0 to High(FKeys) do
    if FKeys[I] = Key then
      Exit(FItems[I]);
  Result := nil;
end;

function TJson.Str(const Key: string; const Def: string): string;
var
  V: TJson;
begin
  V := Find(Key);
  if (V = nil) or (V.FKind = jkNull) then
    Result := Def
  else
    Result := V.AsString;
end;

function TJson.Num(const Key: string; Def: Double): Double;
var
  V: TJson;
begin
  V := Find(Key);
  if (V = nil) or (V.FKind <> jkNum) then
    Result := Def
  else
    Result := V.FNum;
end;

function TJson.Bool(const Key: string; Def: Boolean): Boolean;
var
  V: TJson;
begin
  V := Find(Key);
  if (V = nil) or (V.FKind <> jkBool) then
    Result := Def
  else
    Result := V.FBool;
end;

procedure TJson.Push(Value: TJson);
var
  N: Integer;
begin
  N := Length(FItems);
  SetLength(FItems, N + 1);
  SetLength(FKeys, N + 1);
  FItems[N] := Value;
  FKeys[N] := '';
end;

function TJson.Count: Integer;
begin
  Result := Length(FItems);
end;

function TJson.Item(I: Integer): TJson;
begin
  if (I < 0) or (I > High(FItems)) then
    Result := nil
  else
    Result := FItems[I];
end;

function TJson.Key(I: Integer): string;
begin
  if (I < 0) or (I > High(FKeys)) then
    Result := ''
  else
    Result := FKeys[I];
end;

function TJson.Take(I: Integer): TJson;
begin
  Result := Item(I);
  if Result <> nil then
    FItems[I] := TJson.Create(jkNull);
end;

function TJson.AsString: string;
begin
  case FKind of
    jkStr: Result := FStr;
    jkNum: Result := FloatToStr(FNum);
    jkBool: if FBool then Result := 'true' else Result := 'false';
    jkNull: Result := '';
  else
    Result := ToJson;
  end;
end;

function TJson.AsNumber: Double;
begin
  if FKind = jkNum then
    Result := FNum
  else
    Result := 0;
end;

function TJson.AsBoolean: Boolean;
begin
  Result := (FKind = jkBool) and FBool;
end;

function JsonQuote(const S: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '"';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if C < #32 then
        Result := Result + '\u' + LowerCase(IntToHex(Ord(C), 4))
      else
        Result := Result + C;
    end;
  end;
  Result := Result + '"';
end;

{ FloatToStr would honour the locale's decimal separator, which JSON does not
  accept, so numbers go through an invariant format. }
function NumToJson(D: Double): string;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  if (Frac(D) = 0) and (Abs(D) < 1e15) then
    Result := IntToStr(Round(D))
  else
    Result := FloatToStr(D, FS);
end;

function TJson.ToJson: string;
var
  I: Integer;
begin
  case FKind of
    jkNull: Result := 'null';
    jkBool: if FBool then Result := 'true' else Result := 'false';
    jkNum: Result := NumToJson(FNum);
    jkStr: Result := JsonQuote(FStr);
    jkArr:
      begin
        Result := '[';
        for I := 0 to High(FItems) do
        begin
          if I > 0 then Result := Result + ',';
          Result := Result + FItems[I].ToJson;
        end;
        Result := Result + ']';
      end;
    jkObj:
      begin
        Result := '{';
        for I := 0 to High(FItems) do
        begin
          if I > 0 then Result := Result + ',';
          Result := Result + JsonQuote(FKeys[I]) + ':' + FItems[I].ToJson;
        end;
        Result := Result + '}';
      end;
  end;
end;

{ ---------------------------------------------------------------- parser -- }

type
  TParser = record
    S: string;
    P: Integer;
    Err: string;
  end;

function ParseValue(var Ps: TParser): TJson; forward;

procedure SkipWs(var Ps: TParser);
begin
  while (Ps.P <= Length(Ps.S)) and (Ps.S[Ps.P] in [#9, #10, #13, ' ']) do
    Inc(Ps.P);
end;

function Fail(var Ps: TParser; const Msg: string): TJson;
begin
  if Ps.Err = '' then
    Ps.Err := Format('%s at offset %d', [Msg, Ps.P]);
  Result := nil;
end;

{ Appends CP to S as UTF-8. }
procedure AppendUtf8(var S: string; CP: LongWord);
begin
  if CP < $80 then
    S := S + Chr(CP)
  else if CP < $800 then
    S := S + Chr($C0 or (CP shr 6)) + Chr($80 or (CP and $3F))
  else if CP < $10000 then
    S := S + Chr($E0 or (CP shr 12)) + Chr($80 or ((CP shr 6) and $3F)) +
             Chr($80 or (CP and $3F))
  else
    S := S + Chr($F0 or (CP shr 18)) + Chr($80 or ((CP shr 12) and $3F)) +
             Chr($80 or ((CP shr 6) and $3F)) + Chr($80 or (CP and $3F));
end;

function ParseHex4(var Ps: TParser; out V: LongWord): Boolean;
var
  I, D: Integer;
  C: Char;
begin
  V := 0;
  for I := 1 to 4 do
  begin
    if Ps.P > Length(Ps.S) then Exit(False);
    C := Ps.S[Ps.P];
    case C of
      '0'..'9': D := Ord(C) - Ord('0');
      'a'..'f': D := Ord(C) - Ord('a') + 10;
      'A'..'F': D := Ord(C) - Ord('A') + 10;
    else
      Exit(False);
    end;
    V := V * 16 + LongWord(D);
    Inc(Ps.P);
  end;
  Result := True;
end;

function ParseString(var Ps: TParser; out Value: string): Boolean;
var
  C: Char;
  CP, Lo: LongWord;
begin
  Value := '';
  Result := False;
  if (Ps.P > Length(Ps.S)) or (Ps.S[Ps.P] <> '"') then Exit;
  Inc(Ps.P);
  while Ps.P <= Length(Ps.S) do
  begin
    C := Ps.S[Ps.P];
    if C = '"' then
    begin
      Inc(Ps.P);
      Exit(True);
    end;
    if C = '\' then
    begin
      Inc(Ps.P);
      if Ps.P > Length(Ps.S) then Exit;
      C := Ps.S[Ps.P];
      Inc(Ps.P);
      case C of
        '"': Value := Value + '"';
        '\': Value := Value + '\';
        '/': Value := Value + '/';
        'b': Value := Value + #8;
        'f': Value := Value + #12;
        'n': Value := Value + #10;
        'r': Value := Value + #13;
        't': Value := Value + #9;
        'u':
          begin
            if not ParseHex4(Ps, CP) then Exit;
            { A high surrogate must be joined with the low one that follows;
              anything else is passed through as a lone code point. }
            if (CP >= $D800) and (CP <= $DBFF) and (Ps.P + 1 <= Length(Ps.S)) and
               (Ps.S[Ps.P] = '\') and (Ps.S[Ps.P + 1] = 'u') then
            begin
              Inc(Ps.P, 2);
              if not ParseHex4(Ps, Lo) then Exit;
              if (Lo >= $DC00) and (Lo <= $DFFF) then
                CP := $10000 + ((CP - $D800) shl 10) + (Lo - $DC00)
              else
              begin
                AppendUtf8(Value, CP);
                CP := Lo;
              end;
            end;
            AppendUtf8(Value, CP);
          end;
      else
        Exit;
      end;
    end
    else
    begin
      Value := Value + C;
      Inc(Ps.P);
    end;
  end;
end;

function ParseNumber(var Ps: TParser): TJson;
var
  Start: Integer;
  Text: string;
  D: Double;
  FS: TFormatSettings;
begin
  Start := Ps.P;
  if (Ps.P <= Length(Ps.S)) and (Ps.S[Ps.P] = '-') then Inc(Ps.P);
  while (Ps.P <= Length(Ps.S)) and (Ps.S[Ps.P] in ['0'..'9']) do Inc(Ps.P);
  if (Ps.P <= Length(Ps.S)) and (Ps.S[Ps.P] = '.') then
  begin
    Inc(Ps.P);
    while (Ps.P <= Length(Ps.S)) and (Ps.S[Ps.P] in ['0'..'9']) do Inc(Ps.P);
  end;
  if (Ps.P <= Length(Ps.S)) and (Ps.S[Ps.P] in ['e', 'E']) then
  begin
    Inc(Ps.P);
    if (Ps.P <= Length(Ps.S)) and (Ps.S[Ps.P] in ['+', '-']) then Inc(Ps.P);
    while (Ps.P <= Length(Ps.S)) and (Ps.S[Ps.P] in ['0'..'9']) do Inc(Ps.P);
  end;
  Text := Copy(Ps.S, Start, Ps.P - Start);
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  if not TryStrToFloat(Text, D, FS) then
    Exit(Fail(Ps, 'bad number'));
  Result := TJson.NewNum(D);
end;

function Literal(var Ps: TParser; const Word: string): Boolean;
begin
  Result := Copy(Ps.S, Ps.P, Length(Word)) = Word;
  if Result then Inc(Ps.P, Length(Word));
end;

function ParseValue(var Ps: TParser): TJson;
var
  Obj, Child: TJson;
  K: string;
begin
  SkipWs(Ps);
  if Ps.P > Length(Ps.S) then Exit(Fail(Ps, 'unexpected end'));
  case Ps.S[Ps.P] of
    '{':
      begin
        Inc(Ps.P);
        Obj := TJson.NewObj;
        SkipWs(Ps);
        if (Ps.P <= Length(Ps.S)) and (Ps.S[Ps.P] = '}') then
        begin
          Inc(Ps.P);
          Exit(Obj);
        end;
        repeat
          SkipWs(Ps);
          if not ParseString(Ps, K) then
          begin
            Obj.Free;
            Exit(Fail(Ps, 'expected key'));
          end;
          SkipWs(Ps);
          if (Ps.P > Length(Ps.S)) or (Ps.S[Ps.P] <> ':') then
          begin
            Obj.Free;
            Exit(Fail(Ps, 'expected ":"'));
          end;
          Inc(Ps.P);
          Child := ParseValue(Ps);
          if Child = nil then
          begin
            Obj.Free;
            Exit(nil);
          end;
          Obj.Add(K, Child);
          SkipWs(Ps);
          if (Ps.P <= Length(Ps.S)) and (Ps.S[Ps.P] = ',') then
          begin
            Inc(Ps.P);
            Continue;
          end;
          Break;
        until False;
        if (Ps.P > Length(Ps.S)) or (Ps.S[Ps.P] <> '}') then
        begin
          Obj.Free;
          Exit(Fail(Ps, 'expected "}"'));
        end;
        Inc(Ps.P);
        Result := Obj;
      end;
    '[':
      begin
        Inc(Ps.P);
        Obj := TJson.NewArr;
        SkipWs(Ps);
        if (Ps.P <= Length(Ps.S)) and (Ps.S[Ps.P] = ']') then
        begin
          Inc(Ps.P);
          Exit(Obj);
        end;
        repeat
          Child := ParseValue(Ps);
          if Child = nil then
          begin
            Obj.Free;
            Exit(nil);
          end;
          Obj.Push(Child);
          SkipWs(Ps);
          if (Ps.P <= Length(Ps.S)) and (Ps.S[Ps.P] = ',') then
          begin
            Inc(Ps.P);
            Continue;
          end;
          Break;
        until False;
        if (Ps.P > Length(Ps.S)) or (Ps.S[Ps.P] <> ']') then
        begin
          Obj.Free;
          Exit(Fail(Ps, 'expected "]"'));
        end;
        Inc(Ps.P);
        Result := Obj;
      end;
    '"':
      begin
        if not ParseString(Ps, K) then
          Exit(Fail(Ps, 'bad string'));
        Result := TJson.NewStr(K);
      end;
    't':
      if Literal(Ps, 'true') then Result := TJson.NewBool(True)
      else Result := Fail(Ps, 'bad literal');
    'f':
      if Literal(Ps, 'false') then Result := TJson.NewBool(False)
      else Result := Fail(Ps, 'bad literal');
    'n':
      if Literal(Ps, 'null') then Result := TJson.NewNull
      else Result := Fail(Ps, 'bad literal');
  else
    Result := ParseNumber(Ps);
  end;
end;

function JsonParse(const Text: string; out Err: string): TJson; overload;
var
  Ps: TParser;
begin
  Ps.S := Text;
  Ps.P := 1;
  Ps.Err := '';
  Result := ParseValue(Ps);
  Err := Ps.Err;
end;

function JsonParse(const Text: string): TJson; overload;
var
  Err: string;
begin
  Result := JsonParse(Text, Err);
end;

end.
