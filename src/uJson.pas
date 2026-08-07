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
    { Removes and frees the child at index I. }
    procedure Drop(I: Integer);

    { Index of Name, or -1 when absent.  Exposed so a caller can replace a
      value in place instead of rebuilding the object around it.  The parameter
      is not called Key because the Key method above already owns that name in
      this scope. }
    function IndexOf(const Name: string): Integer;

    { Replaces the child at I: the old one is freed, Value is owned from here.
      The key at I is untouched, so an object keeps its field order - rewriting
      a document must not reshuffle fields nobody asked about. }
    procedure SetAt(I: Integer; Value: TJson);

    { Inserts Value before index I, appending when I is past the end.  Takes
      ownership.  Named InsertAt, not Insert, so it cannot shadow System.Insert
      inside this unit's own methods. }
    procedure InsertAt(I: Integer; Value: TJson);

    function AsString: string;                        { for jkStr/jkNum/jkBool }
    function AsNumber: Double;
    function AsBoolean: Boolean;

    function ToJson: string;

    { Serialises with one space of indent per level and ": " after each key,
      optionally with object keys in alphabetical order.  ToJson's compact form
      is right for a request body; a file that git and a human will read wants
      line structure, and Jupyter's own writer emits exactly this shape - so a
      notebook we rewrite differs from the original only where we changed it. }
    function ToJsonPretty(SortKeys: Boolean = False): string;

    property Kind: TJsonKind read FKind;
  end;

{ Parses Text.  Returns nil on malformed input and sets Err. }
function JsonParse(const Text: string; out Err: string): TJson; overload;
function JsonParse(const Text: string): TJson; overload;

{ Escapes S as a JSON string literal, quotes included. }
function JsonQuote(const S: string): string;

{ The longest prefix of S that is at most MaxBytes long and does not end in
  the middle of a UTF-8 character - and, when S itself ends mid-character,
  without that stump either.  Every cap in this program is a byte count, and
  a byte cut through a multi-byte sequence produces text the API rejects
  whole: one truncated 'e' loses the entire turn, not just the value it was
  in.  The rule lives at the bottom of the ladder because both the notebook
  summariser and the tool layer need it and the ladder forbids the lower one
  from reaching up for it.  Bytes that were not valid UTF-8 to begin with are
  passed through unchanged; deciding what to do about those belongs to the
  caller that knows whether they are OEM output or a binary file. }
function Utf8Cut(const S: string; MaxBytes: Integer): string;

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

function TJson.IndexOf(const Name: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FKeys) do
    if FKeys[I] = Name then
      Exit(I);
  Result := -1;
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

procedure TJson.Drop(I: Integer);
var
  J: Integer;
begin
  if (I < 0) or (I > High(FItems)) then Exit;
  FItems[I].Free;
  for J := I to High(FItems) - 1 do
  begin
    FItems[J] := FItems[J + 1];
    FKeys[J] := FKeys[J + 1];
  end;
  SetLength(FItems, Length(FItems) - 1);
  SetLength(FKeys, Length(FKeys) - 1);
end;

procedure TJson.SetAt(I: Integer; Value: TJson);
begin
  { Ownership passed at the call, so an out-of-range index frees Value rather
    than dropping it on the floor: a silent no-op here would be an unfreed
    block, and the suites build with -gh. }
  if (I < 0) or (I > High(FItems)) then
  begin
    Value.Free;
    Exit;
  end;
  if FItems[I] = Value then Exit;
  FItems[I].Free;
  FItems[I] := Value;
end;

procedure TJson.InsertAt(I: Integer; Value: TJson);
var
  J, N: Integer;
begin
  N := Length(FItems);
  if I < 0 then I := 0;
  if I > N then I := N;
  SetLength(FItems, N + 1);
  SetLength(FKeys, N + 1);
  for J := N downto I + 1 do
  begin
    FItems[J] := FItems[J - 1];
    FKeys[J] := FKeys[J - 1];
  end;
  FItems[I] := Value;
  { An inserted element is an array element; objects grow through Add, which
    is the only place a key is meaningful. }
  FKeys[I] := '';
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

function Utf8Cut(const S: string; MaxBytes: Integer): string;
var
  N, K, Need: Integer;
  B: Byte;
begin
  N := Length(S);
  if MaxBytes < N then N := MaxBytes;
  if N < 0 then N := 0;
  { Walk back over the continuation bytes at the cut to the byte that starts
    the last character, then keep that character only if the whole of it is
    inside the cut.  A run of continuation bytes with no lead byte in front
    of it is already malformed, so there is nothing to preserve and the cut
    stands where it fell. }
  K := N;
  while (K > 0) and ((Byte(S[K]) and $C0) = $80) do Dec(K);
  if K > 0 then
  begin
    B := Byte(S[K]);
    if B < $80 then Need := 1
    else if (B and $E0) = $C0 then Need := 2
    else if (B and $F0) = $E0 then Need := 3
    else if (B and $F8) = $F0 then Need := 4
    else Need := 1;                      { $F8..$FF: not UTF-8, leave it be }
    if K + Need - 1 > N then N := K - 1;
  end;
  Result := Copy(S, 1, N);
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

type
  TIndexArray = array of Integer;

{ The order the children of J should be written in, as an index permutation.
  Sorting an object's keys is what makes two writers agree on a document:
  Jupyter's own writer sorts, so a notebook we rewrite differs from the file
  it came from only where the edit landed.  Insertion sort keeps it stable,
  so duplicate keys - legal JSON, however unwise - keep their relative
  order instead of shuffling on every save. }
function KeyOrder(J: TJson; Sort: Boolean): TIndexArray;
var
  I, K, V: Integer;
begin
  SetLength(Result, J.Count);
  for I := 0 to J.Count - 1 do
    Result[I] := I;
  if not (Sort and (J.Kind = jkObj)) then Exit;
  for I := 1 to High(Result) do
  begin
    V := Result[I];
    K := I - 1;
    { CompareStr, not '>': the operator can be locale-aware, and the order has
      to be byte order to agree with a writer that sorts by code point. }
    while (K >= 0) and (CompareStr(J.Key(Result[K]), J.Key(V)) > 0) do
    begin
      Result[K + 1] := Result[K];
      Dec(K);
    end;
    Result[K + 1] := V;
  end;
end;

function EmitPretty(J: TJson; Depth: Integer; Sort: Boolean): string;
var
  I, Idx: Integer;
  Pad, Inner: string;
  Order: TIndexArray;
begin
  { Scalars have no layout of their own, so they are exactly what the compact
    writer produces - which is also what keeps the two forms parse-identical. }
  if not (J.Kind in [jkArr, jkObj]) then Exit(J.ToJson);
  if J.Count = 0 then
  begin
    if J.Kind = jkArr then Exit('[]') else Exit('{}');
  end;
  Pad := StringOfChar(' ', Depth);
  Inner := StringOfChar(' ', Depth + 1);
  if J.Kind = jkArr then Result := '[' else Result := '{';
  Order := KeyOrder(J, Sort);
  for I := 0 to High(Order) do
  begin
    Idx := Order[I];
    if I > 0 then Result := Result + ',';
    Result := Result + #10 + Inner;
    if J.Kind = jkObj then
      Result := Result + JsonQuote(J.Key(Idx)) + ': ';
    Result := Result + EmitPretty(J.Item(Idx), Depth + 1, Sort);
  end;
  Result := Result + #10 + Pad;
  if J.Kind = jkArr then Result := Result + ']' else Result := Result + '}';
end;

function TJson.ToJsonPretty(SortKeys: Boolean): string;
begin
  Result := EmitPretty(Self, 0, SortKeys);
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
