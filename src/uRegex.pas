{ uRegex - the regular-expression engine behind the search tool.

  FPC does ship TRegExpr, and it compiles and links cleanly under this
  project's flags; this unit exists anyway, and the reason is hangs.  The
  bundled TRegExpr is 0.987, a plain backtracker with no step limit, no
  deadline and no abort hook anywhere in its source.  Measured here, the
  pattern (a+)+$ against a run of 'a's takes 0 ms at 13 characters, 1.7 s at
  24 and 17.7 s at 27 - a clean doubling per character.  The search tool runs
  synchronously inside a tool call and there is no timeout above it: the 120 s
  deadline in this codebase belongs to the shell runner, not to the tool
  layer.  So one pathological pattern against one ordinary line of code would
  freeze the whole session with no way out short of killing the process.
  Nothing bolted on from outside fixes that - an input-length cap cannot beat
  an exponent, a watchdog cannot interrupt a compute loop, and screening for
  nested quantifiers is a heuristic that misses (a|a)+ and a?a?a?...

  The engine here is therefore a Thompson NFA simulation rather than a
  backtracker.  Every live thread advances over the subject in lockstep, one
  byte at a time, and a per-position visited set collapses duplicate program
  counters, so the cost of a match is bounded by Length(S) * ProgramSize.
  Catastrophic backtracking is not screened for; it cannot be expressed.  The
  price is no capture groups, no leftmost-longest rule and no greedy/lazy
  distinction - all of which cost nothing here, because search reports whole
  matched lines and never a slice of one.

  Semantics are byte-oriented and ASCII: classes, \w and \b treat bytes, and
  anything >= $80 is a non-word byte matched only as a literal.  That is safe
  for the UTF-8 rule this codebase lives by, because the caller emits whole
  lines - a match can never cut a multi-byte sequence in half - and the
  simulation additionally refuses to start a match on a continuation byte. }
unit uRegex;

{$mode objfpc}{$H+}

interface

uses SysUtils;

const
  { Caps, all reported as ordinary compile errors rather than enforced by
    crashing.  A pattern arrives from the model, so every one of these is
    reachable by accident. }
  MaxRegexPattern    = 1000;      { bytes of pattern text }
  MaxRegexProgram    = 1000;      { compiled instructions }
  MaxRegexRepeat     = 255;       { upper bound allowed in a repeat count }
  MaxRegexNesting    = 64;        { parser recursion guard }
  DefaultRegexBudget = 20000000;  { simulation steps for one whole search }

type
  { Why a match attempt ended.  rrBudget is not "no match": it means the engine
    stopped early and the answer is unknown, and callers must say so rather
    than report a clean miss. }
  TReResult = (rrNoMatch, rrMatch, rrBudget);

  { The instruction set.  X and Y are absolute program indices, which makes
    duplicating a compiled fragment a matter of re-offsetting two fields. }
  TReOp = (roChar, roClass, roAny, roSplit, roJmp, roMatch,
           roBol, roEol, roWordB, roNotWordB);

  TReByteSet = set of Byte;

  TReInst = record
    Op: TReOp;
    Ch: Byte;
    Cls: TReByteSet;
    X, Y: Integer;
  end;

  TReIntArray = array of Integer;

  TRegex = class
  private
    FProg: array of TReInst;
    FCount: Integer;          { instructions emitted }
    FCI: Boolean;             { case-insensitive, folded at compile time }
    FPat: string;
    FPos: Integer;            { 1-based read position in FPat }
    FErr: string;
    { simulation state, kept as fields so the recursive thread adder does not
      have to carry the subject through every call }
    FSubj: string;
    FSubjLen: Integer;
    FCur, FNxt: TReIntArray;
    FGen: TReIntArray;
    FGenId: Integer;
    FOver: Boolean;           { budget ran out mid-match }

    procedure Fail(const What: string);
    function Emit(Op: TReOp): Integer;
    function CopyTail(FromIdx, ToIdx: Integer): Boolean;
    function InsertInst(Idx: Integer): Boolean;
    function EmitStar(S: Integer): Boolean;
    function EmitPlus(S: Integer): Boolean;
    function EmitOpt(S: Integer): Boolean;
    function EmitRepeat(S, N, M: Integer; Unbounded: Boolean): Boolean;
    procedure AddFolded(var C: TReByteSet; B: Byte);
    function ClassEscape(var C: TReByteSet; out B: Byte;
      out Single: Boolean): Boolean;
    function ParseClass: Boolean;
    function ParseEscape: Boolean;
    function ParseAtom(Depth: Integer): Boolean;
    function ParseRep(Depth: Integer): Boolean;
    function ParseConcat(Depth: Integer): Boolean;
    function ParseAlt(Depth: Integer): Boolean;
    function WordAt(P: Integer): Boolean;
    procedure AddThread(var L: TReIntArray; var N: Integer;
      ListId, PC, P: Integer);
  public
    { Steps left.  Set once per search, not per line, so the cap bounds the
      whole tool call.  Decremented by every thread added and every
      instruction stepped. }
    Budget: Int64;

    { Builds Rx from Pattern.  Returns False with Err set and Rx nil - never a
      half-built object, which under -gh would be a leak as well as a bug. }
    class function Compile(const Pattern: string; CaseSensitive: Boolean;
      out Rx: TRegex; out Err: string): Boolean;

    { True when S contains a match anywhere.  No backtracking: threads run in
      lockstep over S, so cost is bounded by Length(S) * ProgramSize. }
    function Match(const S: string): TReResult;

    { Test seam: how many instructions the pattern compiled to. }
    function ProgramSize: Integer;
  end;

implementation

const
  { The named classes, as byte sets.  Negated forms are the complement over
    all 256 values, so a byte >= $80 satisfies \D, \W and \S - it is not a
    digit, word character or space, and pretending otherwise would make
    [^\d] miss half of a UTF-8 sequence. }
  DigitSet: TReByteSet = [Ord('0')..Ord('9')];
  WordSet: TReByteSet  = [Ord('0')..Ord('9'), Ord('A')..Ord('Z'),
                          Ord('a')..Ord('z'), Ord('_')];
  SpaceSet: TReByteSet = [9, 10, 11, 12, 13, 32];

{ --------------------------------------------------------------- emission -- }

procedure TRegex.Fail(const What: string);
begin
  { The first failure is the informative one; later ones are just the parser
    unwinding, so they must not overwrite it. }
  if FErr = '' then
    FErr := Format('%s at offset %d', [What, FPos]);
end;

function TRegex.Emit(Op: TReOp): Integer;
begin
  if FCount >= MaxRegexProgram then
  begin
    Fail('pattern too complex');
    Exit(-1);
  end;
  if FCount >= Length(FProg) then
    SetLength(FProg, FCount + 64);
  { Slots are reused when a zero repeat truncates the program, so a fresh
    instruction has to be zeroed rather than trusted to be. }
  FillChar(FProg[FCount], SizeOf(TReInst), 0);
  FProg[FCount].Op := Op;
  Result := FCount;
  Inc(FCount);
end;

{ Re-appends the instructions [FromIdx..ToIdx) at the end of the program with
  every jump target shifted to match.  This is the single primitive behind
  a repeat count: the atom being quantified is always the tail of the program
  when its quantifier is read, so a repeat is a run of tail copies.  Targets
  inside the fragment - including the one-past-the-end target that means
  "continue after the atom" - all sit at or above FromIdx, so one offset
  covers them. }
function TRegex.CopyTail(FromIdx, ToIdx: Integer): Boolean;
var
  I, K, Delta: Integer;
begin
  Delta := FCount - FromIdx;
  for I := FromIdx to ToIdx - 1 do
  begin
    K := Emit(FProg[I].Op);
    if K < 0 then Exit(False);
    FProg[K] := FProg[I];
    case FProg[K].Op of
      roJmp:
        if FProg[K].X >= FromIdx then Inc(FProg[K].X, Delta);
      roSplit:
        begin
          if FProg[K].X >= FromIdx then Inc(FProg[K].X, Delta);
          if FProg[K].Y >= FromIdx then Inc(FProg[K].Y, Delta);
        end;
    end;
  end;
  Result := True;
end;

{ Opens a hole at Idx and fixes every jump target that moved.  A quantifier is
  read after its atom is already compiled, so * and ? need an instruction in
  front of code that exists; a full fixup pass over at most MaxRegexProgram
  entries is cheap and, unlike lifting the tail and re-appending it, has one
  obvious correctness argument. }
function TRegex.InsertInst(Idx: Integer): Boolean;
var
  I: Integer;
begin
  if Emit(roJmp) < 0 then Exit(False);
  for I := FCount - 1 downto Idx + 1 do
    FProg[I] := FProg[I - 1];
  FillChar(FProg[Idx], SizeOf(TReInst), 0);
  for I := 0 to FCount - 1 do
  begin
    if I = Idx then Continue;
    case FProg[I].Op of
      roJmp:
        if FProg[I].X >= Idx then Inc(FProg[I].X);
      roSplit:
        begin
          if FProg[I].X >= Idx then Inc(FProg[I].X);
          if FProg[I].Y >= Idx then Inc(FProg[I].Y);
        end;
    end;
  end;
  Result := True;
end;

{ L1: split L2, END / L2: <A> / jmp L1 / END: }
function TRegex.EmitStar(S: Integer): Boolean;
var
  J: Integer;
begin
  if not InsertInst(S) then Exit(False);
  FProg[S].Op := roSplit;
  J := Emit(roJmp);
  if J < 0 then Exit(False);
  FProg[J].X := S;
  FProg[S].X := S + 1;
  FProg[S].Y := FCount;
  Result := True;
end;

{ <A> / split A, END - one instruction rather than a second copy of the atom. }
function TRegex.EmitPlus(S: Integer): Boolean;
var
  K: Integer;
begin
  K := Emit(roSplit);
  if K < 0 then Exit(False);
  FProg[K].X := S;
  FProg[K].Y := FCount;
  Result := True;
end;

{ split A, END / <A> }
function TRegex.EmitOpt(S: Integer): Boolean;
begin
  if not InsertInst(S) then Exit(False);
  FProg[S].Op := roSplit;
  FProg[S].X := S + 1;
  FProg[S].Y := FCount;
  Result := True;
end;

{ A counted repeat is compiled as literal repetition: a 2-to-4 repeat of A
  becomes A A A? A?, and a 2-or-more repeat becomes A A A*.  Both are exactly
  equivalent for a boolean match, and they
  keep the simulation free of counters.  The copies are made first and the
  optional splits inserted afterwards, front to back, so each recorded split
  index stays valid while the later ones are inserted. }
function TRegex.EmitRepeat(S, N, M: Integer; Unbounded: Boolean): Boolean;
var
  E, AtomLen, Total, I, J, At: Integer;
  NSplits: Integer;
  Splits: array[0..MaxRegexRepeat] of Integer;
begin
  E := FCount;
  AtomLen := E - S;
  { An empty atom - an empty group with a count after it - repeats to nothing. }
  if AtomLen = 0 then Exit(True);

  if Unbounded then
    Total := N + 1      { n mandatory copies plus one starred copy }
  else
    Total := M;         { n mandatory copies plus m-n optional ones }

  if Total = 0 then
  begin
    FCount := S;
    Exit(True);
  end;

  for I := 2 to Total do
    if not CopyTail(S, E) then Exit(False);

  NSplits := 0;
  if Unbounded then
  begin
    if not EmitStar(S + (Total - 1) * AtomLen) then Exit(False);
  end
  else
    for J := N to Total - 1 do
    begin
      At := S + J * AtomLen + NSplits;
      if not InsertInst(At) then Exit(False);
      FProg[At].Op := roSplit;
      FProg[At].X := At + 1;
      { Patched once the whole run is built.  A negative placeholder is used
        because InsertInst shifts every target at or above the insertion
        point, and 0 is a valid target. }
      FProg[At].Y := -1;
      Splits[NSplits] := At;
      Inc(NSplits);
    end;

  for I := 0 to NSplits - 1 do
    FProg[Splits[I]].Y := FCount;
  Result := True;
end;

{ ------------------------------------------------------- character classes -- }

{ Case folding happens here, at compile time, so the simulation never has to
  lower-case a byte it is stepping over. }
procedure TRegex.AddFolded(var C: TReByteSet; B: Byte);
begin
  Include(C, B);
  if not FCI then Exit;
  if (B >= Ord('A')) and (B <= Ord('Z')) then Include(C, B + 32)
  else if (B >= Ord('a')) and (B <= Ord('z')) then Include(C, B - 32);
end;

{ An escape inside [...].  Single says whether it produced one byte (which the
  caller may then use as the low end of a range) or a whole set already folded
  into C. }
function TRegex.ClassEscape(var C: TReByteSet; out B: Byte;
  out Single: Boolean): Boolean;
var
  Ch: Char;
  H: Integer;
begin
  B := 0;
  Single := True;
  Inc(FPos);                                  { past the backslash }
  if FPos > Length(FPat) then
  begin
    Fail('pattern ends in a backslash');
    Exit(False);
  end;
  Ch := FPat[FPos];
  Inc(FPos);
  case Ch of
    'd': begin C := C + DigitSet; Single := False; end;
    'D': begin C := C + ([0..255] - DigitSet); Single := False; end;
    'w': begin C := C + WordSet; Single := False; end;
    'W': begin C := C + ([0..255] - WordSet); Single := False; end;
    's': begin C := C + SpaceSet; Single := False; end;
    'S': begin C := C + ([0..255] - SpaceSet); Single := False; end;
    'n': B := 10;
    'r': B := 13;
    't': B := 9;
    'f': B := 12;
    'v': B := 11;
    '0': B := 0;
    'x':
      begin
        if (FPos + 1 > Length(FPat)) or
           (not (FPat[FPos] in ['0'..'9', 'a'..'f', 'A'..'F'])) or
           (not (FPat[FPos + 1] in ['0'..'9', 'a'..'f', 'A'..'F'])) then
        begin
          Fail('\x needs two hex digits');
          Exit(False);
        end;
        H := StrToInt('$' + Copy(FPat, FPos, 2));
        Inc(FPos, 2);
        B := Byte(H);
      end;
  else
    { An escaped letter or digit that is not in the list is a typo, not a
      literal: silently matching 'q' for \q would hide the mistake. }
    if Ch in ['a'..'z', 'A'..'Z', '0'..'9'] then
    begin
      Fail('unknown escape \' + Ch);
      Exit(False);
    end;
    B := Byte(Ch);
  end;
  Result := True;
end;

function TRegex.ParseClass: Boolean;
var
  Neg, Single: Boolean;
  C: TReByteSet;
  B, B2: Byte;
  I, K: Integer;
begin
  Inc(FPos);                                  { past '[' }
  C := [];
  Neg := (FPos <= Length(FPat)) and (FPat[FPos] = '^');
  if Neg then Inc(FPos);
  { A ']' straight after the opening bracket is a literal, as everywhere else. }
  if (FPos <= Length(FPat)) and (FPat[FPos] = ']') then
  begin
    AddFolded(C, Ord(']'));
    Inc(FPos);
  end;

  while (FPos <= Length(FPat)) and (FPat[FPos] <> ']') do
  begin
    if FPat[FPos] = '\' then
    begin
      if not ClassEscape(C, B, Single) then Exit(False);
      if not Single then Continue;
    end
    else
    begin
      B := Byte(FPat[FPos]);
      Inc(FPos);
    end;

    { 'a-z', but a '-' just before the closing bracket is itself a literal. }
    if (FPos + 1 <= Length(FPat)) and (FPat[FPos] = '-') and
       (FPat[FPos + 1] <> ']') then
    begin
      Inc(FPos);
      if FPat[FPos] = '\' then
      begin
        if not ClassEscape(C, B2, Single) then Exit(False);
        if not Single then
        begin
          Fail('a class shorthand cannot end a range');
          Exit(False);
        end;
      end
      else
      begin
        B2 := Byte(FPat[FPos]);
        Inc(FPos);
      end;
      if B2 < B then
      begin
        Fail('reversed range in [');
        Exit(False);
      end;
      for I := B to B2 do
        AddFolded(C, Byte(I));
    end
    else
      AddFolded(C, B);
  end;

  if FPos > Length(FPat) then
  begin
    Fail('unterminated [');
    Exit(False);
  end;
  Inc(FPos);                                  { past ']' }
  if Neg then C := [0..255] - C;
  K := Emit(roClass);
  if K < 0 then Exit(False);
  FProg[K].Cls := C;
  Result := True;
end;

{ ----------------------------------------------------------------- parser -- }

function TRegex.ParseEscape: Boolean;
var
  C: TReByteSet;
  B: Byte;
  Single: Boolean;
  K: Integer;
begin
  C := [];
  { The same escape table serves inside and outside a class; only \b differs,
    and \b inside a class is not supported here at all. }
  if (FPos + 1 <= Length(FPat)) and (FPat[FPos + 1] in ['b', 'B']) then
  begin
    Inc(FPos, 2);
    if FPat[FPos - 1] = 'b' then K := Emit(roWordB) else K := Emit(roNotWordB);
    Exit(K >= 0);
  end;
  if not ClassEscape(C, B, Single) then Exit(False);
  if not Single then
  begin
    K := Emit(roClass);
    if K < 0 then Exit(False);
    FProg[K].Cls := C;
    Exit(True);
  end;
  C := [];
  AddFolded(C, B);
  { A folded letter needs a set; anything else is one byte and stays cheap. }
  if C = [B] then
  begin
    K := Emit(roChar);
    if K < 0 then Exit(False);
    FProg[K].Ch := B;
  end
  else
  begin
    K := Emit(roClass);
    if K < 0 then Exit(False);
    FProg[K].Cls := C;
  end;
  Result := True;
end;

function TRegex.ParseAtom(Depth: Integer): Boolean;
var
  C: TReByteSet;
  B: Byte;
  K: Integer;
  Ch: Char;
begin
  if FPos > Length(FPat) then
  begin
    Fail('unexpected end of pattern');
    Exit(False);
  end;
  Ch := FPat[FPos];
  case Ch of
    '(':
      begin
        { Without this the parser's own stack is the only limit, and 200
          nested groups would crash the process rather than report a typo. }
        if Depth >= MaxRegexNesting then
        begin
          Fail('groups nested too deeply');
          Exit(False);
        end;
        Inc(FPos);
        if (FPos + 1 <= Length(FPat)) and (FPat[FPos] = '?') and
           (FPat[FPos + 1] = ':') then
          Inc(FPos, 2)
        else if (FPos <= Length(FPat)) and (FPat[FPos] = '?') then
        begin
          { Lookaround and named groups cannot be expressed by a lockstep
            simulation, so they are refused rather than silently mismatched. }
          Fail('unsupported group (?...)');
          Exit(False);
        end;
        if not ParseAlt(Depth + 1) then Exit(False);
        if (FPos > Length(FPat)) or (FPat[FPos] <> ')') then
        begin
          Fail('unterminated (');
          Exit(False);
        end;
        Inc(FPos);
        Result := True;
      end;
    '[':
      Result := ParseClass;
    '\':
      Result := ParseEscape;
    '.':
      begin
        Inc(FPos);
        Result := Emit(roAny) >= 0;
      end;
    '^':
      begin
        Inc(FPos);
        Result := Emit(roBol) >= 0;
      end;
    '$':
      begin
        Inc(FPos);
        Result := Emit(roEol) >= 0;
      end;
    '*', '+', '?':
      begin
        Fail('nothing to repeat before ' + Ch);
        Result := False;
      end;
  else
    begin
      B := Byte(Ch);
      Inc(FPos);
      C := [];
      AddFolded(C, B);
      if C = [B] then
      begin
        K := Emit(roChar);
        if K < 0 then Exit(False);
        FProg[K].Ch := B;
      end
      else
      begin
        K := Emit(roClass);
        if K < 0 then Exit(False);
        FProg[K].Cls := C;
      end;
      Result := True;
    end;
  end;
end;

function TRegex.ParseRep(Depth: Integer): Boolean;
var
  S, Save, N, M, V: Integer;
  Unbounded, Ok: Boolean;
begin
  S := FCount;
  if not ParseAtom(Depth) then Exit(False);
  if FPos > Length(FPat) then Exit(True);

  case FPat[FPos] of
    '*': begin Inc(FPos); Ok := EmitStar(S); end;
    '+': begin Inc(FPos); Ok := EmitPlus(S); end;
    '?': begin Inc(FPos); Ok := EmitOpt(S); end;
    '{':
      begin
        Save := FPos;
        Inc(FPos);
        V := 0;
        if (FPos > Length(FPat)) or not (FPat[FPos] in ['0'..'9']) then
        begin
          { Not a quantifier at all - the brace is then an ordinary character,
            which is what code searches want far more often than counting. }
          FPos := Save;
          Exit(True);
        end;
        while (FPos <= Length(FPat)) and (FPat[FPos] in ['0'..'9']) do
        begin
          if V < 1000000 then V := V * 10 + (Ord(FPat[FPos]) - Ord('0'));
          Inc(FPos);
        end;
        N := V;
        M := V;
        Unbounded := False;
        if (FPos <= Length(FPat)) and (FPat[FPos] = ',') then
        begin
          Inc(FPos);
          if (FPos <= Length(FPat)) and (FPat[FPos] in ['0'..'9']) then
          begin
            V := 0;
            while (FPos <= Length(FPat)) and (FPat[FPos] in ['0'..'9']) do
            begin
              if V < 1000000 then V := V * 10 + (Ord(FPat[FPos]) - Ord('0'));
              Inc(FPos);
            end;
            M := V;
          end
          else
            Unbounded := True;
        end;
        if (FPos > Length(FPat)) or (FPat[FPos] <> '}') then
        begin
          FPos := Save;
          Exit(True);
        end;
        Inc(FPos);
        if (N > MaxRegexRepeat) or ((not Unbounded) and (M > MaxRegexRepeat)) then
        begin
          Fail('repeat count above ' + IntToStr(MaxRegexRepeat));
          Exit(False);
        end;
        if (not Unbounded) and (M < N) then
        begin
          Fail('reversed repeat range');
          Exit(False);
        end;
        Ok := EmitRepeat(S, N, M, Unbounded);
      end;
  else
    Exit(True);
  end;

  { A trailing '?' is the lazy marker.  Boolean matching cannot tell greedy
    from lazy, so it is accepted and ignored rather than rejected - the model
    writes \d+? often enough that refusing it would be a nuisance. }
  if Ok and (FPos <= Length(FPat)) and (FPat[FPos] = '?') then Inc(FPos);
  Result := Ok;
end;

function TRegex.ParseConcat(Depth: Integer): Boolean;
var
  Items: Integer;
begin
  Items := 0;
  while (FPos <= Length(FPat)) and (FPat[FPos] <> '|') and
        (FPat[FPos] <> ')') do
  begin
    if not ParseRep(Depth) then Exit(False);
    Inc(Items);
  end;
  { An empty branch - a trailing '|', or '()' - matches the empty string
    everywhere, which as a search is never what was meant.  Reporting it is
    more useful than returning every line in the tree. }
  if Items = 0 then
  begin
    Fail('empty branch');
    Exit(False);
  end;
  Result := True;
end;

function TRegex.ParseAlt(Depth: Integer): Boolean;
var
  S, J: Integer;
begin
  S := FCount;
  if not ParseConcat(Depth) then Exit(False);
  while (FPos <= Length(FPat)) and (FPat[FPos] = '|') do
  begin
    Inc(FPos);
    { split L, R / <left> / jmp END / R: <right> / END: - the split has to sit
      in front of code already emitted, which is what InsertInst is for. }
    if not InsertInst(S) then Exit(False);
    FProg[S].Op := roSplit;
    J := Emit(roJmp);
    if J < 0 then Exit(False);
    FProg[S].X := S + 1;
    FProg[S].Y := FCount;
    if not ParseConcat(Depth) then Exit(False);
    FProg[J].X := FCount;
  end;
  Result := True;
end;

class function TRegex.Compile(const Pattern: string; CaseSensitive: Boolean;
  out Rx: TRegex; out Err: string): Boolean;
var
  R: TRegex;
begin
  Rx := nil;
  Err := '';
  if Pattern = '' then
  begin
    Err := 'empty pattern';
    Exit(False);
  end;
  if Length(Pattern) > MaxRegexPattern then
  begin
    Err := Format('pattern longer than %d bytes', [MaxRegexPattern]);
    Exit(False);
  end;

  R := TRegex.Create;
  R.FCI := not CaseSensitive;
  R.FPat := Pattern;
  R.FPos := 1;
  R.Budget := DefaultRegexBudget;
  if R.ParseAlt(0) then
  begin
    if R.FPos <= Length(Pattern) then
      R.Fail('unexpected ' + Pattern[R.FPos])
    else
      R.Emit(roMatch);   { a failure here has already recorded itself in FErr }
  end;
  if R.FErr <> '' then
  begin
    Err := R.FErr;
    R.Free;
    Exit(False);
  end;
  Rx := R;
  Result := True;
end;

function TRegex.ProgramSize: Integer;
begin
  Result := FCount;
end;

{ ------------------------------------------------------------- simulation -- }

function TRegex.WordAt(P: Integer): Boolean;
begin
  if (P < 1) or (P > FSubjLen) then Exit(False);
  Result := Byte(FSubj[P]) in WordSet;
end;

{ Adds PC to L, following the control-flow instructions eagerly and settling
  the zero-width assertions against position P.  The generation stamp means a
  program counter joins a list at most once per position, which is what turns
  what would be exponential backtracking into a linear sweep. }
procedure TRegex.AddThread(var L: TReIntArray; var N: Integer;
  ListId, PC, P: Integer);
begin
  if FOver then Exit;
  Dec(Budget);
  if Budget <= 0 then
  begin
    FOver := True;
    Exit;
  end;
  if (PC < 0) or (PC >= FCount) then Exit;
  if FGen[PC] = ListId then Exit;
  FGen[PC] := ListId;
  case FProg[PC].Op of
    roJmp:
      AddThread(L, N, ListId, FProg[PC].X, P);
    roSplit:
      begin
        AddThread(L, N, ListId, FProg[PC].X, P);
        AddThread(L, N, ListId, FProg[PC].Y, P);
      end;
    roBol:
      if P = 1 then AddThread(L, N, ListId, PC + 1, P);
    roEol:
      if P = FSubjLen + 1 then AddThread(L, N, ListId, PC + 1, P);
    roWordB:
      if WordAt(P - 1) <> WordAt(P) then AddThread(L, N, ListId, PC + 1, P);
    roNotWordB:
      if WordAt(P - 1) = WordAt(P) then AddThread(L, N, ListId, PC + 1, P);
  else
    begin
      L[N] := PC;
      Inc(N);
    end;
  end;
end;

function TRegex.Match(const S: string): TReResult;
var
  P, I, PC, NCur, NNxt, CurId, NxtId: Integer;
  Tmp: TReIntArray;
begin
  FSubj := S;
  FSubjLen := Length(S);
  FOver := False;
  SetLength(FCur, FCount);
  SetLength(FNxt, FCount);
  SetLength(FGen, FCount);
  for I := 0 to FCount - 1 do
    FGen[I] := -1;
  FGenId := 0;
  CurId := 0;
  NCur := 0;

  for P := 1 to FSubjLen + 1 do
  begin
    { A fresh attempt starts at every position - but never on a UTF-8
      continuation byte, because a match reported as starting there would be a
      match on half a character. }
    if (P > FSubjLen) or not (Byte(S[P]) in [$80..$BF]) then
      AddThread(FCur, NCur, CurId, 0, P);
    if FOver then Exit(rrBudget);

    Inc(FGenId);
    NxtId := FGenId;
    NNxt := 0;
    for I := 0 to NCur - 1 do
    begin
      { The hard bound.  Without it a huge tree of long lines could run for
        minutes inside a tool call that nothing can interrupt.  AddThread
        charges the budget too, so both halves of a step are paid for. }
      Dec(Budget);
      if Budget <= 0 then Exit(rrBudget);
      PC := FCur[I];
      case FProg[PC].Op of
        roMatch:
          Exit(rrMatch);
        roChar:
          if (P <= FSubjLen) and (Byte(S[P]) = FProg[PC].Ch) then
            AddThread(FNxt, NNxt, NxtId, PC + 1, P + 1);
        roClass:
          if (P <= FSubjLen) and (Byte(S[P]) in FProg[PC].Cls) then
            AddThread(FNxt, NNxt, NxtId, PC + 1, P + 1);
        roAny:
          if (P <= FSubjLen) and (S[P] <> #10) then
            AddThread(FNxt, NNxt, NxtId, PC + 1, P + 1);
      end;
      if FOver then Exit(rrBudget);
    end;

    Tmp := FCur;
    FCur := FNxt;
    FNxt := Tmp;
    NCur := NNxt;
    CurId := NxtId;
  end;
  Result := rrNoMatch;
end;

end.
