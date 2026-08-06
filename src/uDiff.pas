{ uDiff - a line diff, used to show what an edit will do before it is approved.

  Approving a write blind is the weakest part of a permission prompt: "edit
  src\uAgent.pas" says nothing about what changes.  This unit turns the old and
  new text into a unified-style hunk list, so the prompt can show the actual
  lines.

  The algorithm is a plain LCS over lines.  That is O(n*m) in memory, which is
  fine for a source file and disastrous for a large one, so anything past
  MaxLcsLines falls back to a whole-file replacement summary rather than
  allocating gigabytes to pretty-print a diff nobody will read. }
unit uDiff;

{$mode objfpc}{$H+}

interface

type
  TDiffKind = (dkContext, dkAdd, dkRemove, dkGap);

  TDiffLine = record
    Kind: TDiffKind;
    Text: string;
    OldNo: Integer;   { 1-based; 0 when the line does not exist on that side }
    NewNo: Integer;
  end;
  TDiffLines = array of TDiffLine;

  TDiffStat = record
    Added: Integer;
    Removed: Integer;
    Truncated: Boolean;   { the file was too large to diff line by line }
  end;

const
  { Beyond this the LCS table is not worth the memory. }
  MaxLcsLines = 4000;
  { Unchanged lines kept around each change. }
  DiffContext = 3;

{ Diffs the two texts and returns the changed regions with context.  Stat
  carries the counts, which is what a summary line wants. }
function DiffText(const OldText, NewText: string; out Stat: TDiffStat): TDiffLines;

{ Renders a diff as text: "+ added", "- removed", "  context", "@@ ..." for a
  skipped region.  MaxLines caps the output; 0 means no cap. }
function RenderDiff(const Lines: TDiffLines; MaxLines: Integer): string;

{ Convenience: diff and render in one step, with a leading summary line. }
function DiffSummary(const OldText, NewText: string; MaxLines: Integer): string;

implementation

uses SysUtils, Classes;

{ Splits into lines without TStringList's trailing-newline surprises: a text
  ending in a newline has no phantom final element, and one that does not is
  still counted. }
procedure SplitLines(const S: string; out A: TStringArray);
var
  Count, Start, I: Integer;
begin
  A := nil;
  if S = '' then Exit;
  Count := 0;
  for I := 1 to Length(S) do
    if S[I] = #10 then Inc(Count);
  if S[Length(S)] <> #10 then Inc(Count);
  SetLength(A, Count);
  Count := 0;
  Start := 1;
  for I := 1 to Length(S) do
    if S[I] = #10 then
    begin
      A[Count] := Copy(S, Start, I - Start);
      { A CRLF file must not leave a stray CR on every line. }
      if (A[Count] <> '') and (A[Count][Length(A[Count])] = #13) then
        SetLength(A[Count], Length(A[Count]) - 1);
      Inc(Count);
      Start := I + 1;
    end;
  if Start <= Length(S) then
  begin
    A[Count] := Copy(S, Start, MaxInt);
    if (A[Count] <> '') and (A[Count][Length(A[Count])] = #13) then
      SetLength(A[Count], Length(A[Count]) - 1);
  end;
end;

type
  TRawKind = (rkSame, rkAdd, rkRemove);
  TRawOp = record
    Kind: TRawKind;
    Text: string;
    OldNo, NewNo: Integer;
  end;
  TRawOps = array of TRawOp;

procedure PushOp(var Ops: TRawOps; var N: Integer; K: TRawKind;
  const Text: string; OldNo, NewNo: Integer);
begin
  if N >= Length(Ops) then
    SetLength(Ops, (N + 1) * 2);
  Ops[N].Kind := K;
  Ops[N].Text := Text;
  Ops[N].OldNo := OldNo;
  Ops[N].NewNo := NewNo;
  Inc(N);
end;

{ Classic LCS length table, walked backwards to emit the edit script in
  forward order.  Rows are LongInt because a 4000x4000 table of them is 64 MB
  and that is already the point at which the caller should not be here. }
function LcsOps(const A, B: TStringArray): TRawOps;
var
  N, M, I, J, Count: Integer;
  L: array of array of LongInt;
begin
  N := Length(A);
  M := Length(B);
  SetLength(L, N + 1, M + 1);
  for I := N - 1 downto 0 do
    for J := M - 1 downto 0 do
      if A[I] = B[J] then
        L[I][J] := L[I + 1][J + 1] + 1
      else if L[I + 1][J] >= L[I][J + 1] then
        L[I][J] := L[I + 1][J]
      else
        L[I][J] := L[I][J + 1];

  Result := nil;
  Count := 0;
  I := 0;
  J := 0;
  while (I < N) and (J < M) do
  begin
    if A[I] = B[J] then
    begin
      PushOp(Result, Count, rkSame, A[I], I + 1, J + 1);
      Inc(I);
      Inc(J);
    end
    else if L[I + 1][J] >= L[I][J + 1] then
    begin
      PushOp(Result, Count, rkRemove, A[I], I + 1, 0);
      Inc(I);
    end
    else
    begin
      PushOp(Result, Count, rkAdd, B[J], 0, J + 1);
      Inc(J);
    end;
  end;
  while I < N do
  begin
    PushOp(Result, Count, rkRemove, A[I], I + 1, 0);
    Inc(I);
  end;
  while J < M do
  begin
    PushOp(Result, Count, rkAdd, B[J], 0, J + 1);
    Inc(J);
  end;
  SetLength(Result, Count);
end;

{ Whole-file replacement, used when the input is too big to diff properly. }
function BulkOps(const A, B: TStringArray): TRawOps;
var
  I, Count: Integer;
begin
  Result := nil;
  Count := 0;
  for I := 0 to High(A) do
    PushOp(Result, Count, rkRemove, A[I], I + 1, 0);
  for I := 0 to High(B) do
    PushOp(Result, Count, rkAdd, B[I], 0, I + 1);
  SetLength(Result, Count);
end;

procedure PushLine(var Lines: TDiffLines; var N: Integer; K: TDiffKind;
  const Text: string; OldNo, NewNo: Integer);
begin
  if N >= Length(Lines) then
    SetLength(Lines, (N + 1) * 2);
  Lines[N].Kind := K;
  Lines[N].Text := Text;
  Lines[N].OldNo := OldNo;
  Lines[N].NewNo := NewNo;
  Inc(N);
end;

function DiffText(const OldText, NewText: string; out Stat: TDiffStat): TDiffLines;
var
  A, B: TStringArray;
  Ops: TRawOps;
  Keep: array of Boolean;
  I, J, Lo, Hi, N, Out_: Integer;
  LastEmitted: Integer;
begin
  Stat.Added := 0;
  Stat.Removed := 0;
  Stat.Truncated := False;
  Result := nil;

  SplitLines(OldText, A);
  SplitLines(NewText, B);

  if (Length(A) > MaxLcsLines) or (Length(B) > MaxLcsLines) then
  begin
    Stat.Truncated := True;
    Ops := BulkOps(A, B);
  end
  else
    Ops := LcsOps(A, B);

  N := Length(Ops);
  for I := 0 to N - 1 do
    case Ops[I].Kind of
      rkAdd: Inc(Stat.Added);
      rkRemove: Inc(Stat.Removed);
    end;
  if (Stat.Added = 0) and (Stat.Removed = 0) then Exit;

  { Mark the context window around every change, then emit the marked runs
    with a gap marker between them.  Doing it in two passes keeps overlapping
    windows from producing duplicate lines. }
  SetLength(Keep, N);
  for I := 0 to N - 1 do
    if Ops[I].Kind <> rkSame then
    begin
      Lo := I - DiffContext;
      if Lo < 0 then Lo := 0;
      Hi := I + DiffContext;
      if Hi > N - 1 then Hi := N - 1;
      for J := Lo to Hi do
        Keep[J] := True;
    end;

  Out_ := 0;
  LastEmitted := -1;
  for I := 0 to N - 1 do
  begin
    if not Keep[I] then Continue;
    if (LastEmitted >= 0) and (I > LastEmitted + 1) then
      PushLine(Result, Out_, dkGap,
        Format('@@ %d unchanged lines @@', [I - LastEmitted - 1]), 0, 0);
    case Ops[I].Kind of
      rkSame: PushLine(Result, Out_, dkContext, Ops[I].Text, Ops[I].OldNo, Ops[I].NewNo);
      rkAdd: PushLine(Result, Out_, dkAdd, Ops[I].Text, 0, Ops[I].NewNo);
      rkRemove: PushLine(Result, Out_, dkRemove, Ops[I].Text, Ops[I].OldNo, 0);
    end;
    LastEmitted := I;
  end;
  SetLength(Result, Out_);
end;

function RenderDiff(const Lines: TDiffLines; MaxLines: Integer): string;
var
  I, Shown: Integer;
  Marker: string;
begin
  Result := '';
  Shown := Length(Lines);
  if (MaxLines > 0) and (Shown > MaxLines) then Shown := MaxLines;
  for I := 0 to Shown - 1 do
  begin
    case Lines[I].Kind of
      dkAdd: Marker := '+ ';
      dkRemove: Marker := '- ';
      dkGap: Marker := '';
    else
      Marker := '  ';
    end;
    Result := Result + Marker + Lines[I].Text + #10;
  end;
  if Shown < Length(Lines) then
    Result := Result + Format('... %d more diff lines'#10,
      [Length(Lines) - Shown]);
end;

function DiffSummary(const OldText, NewText: string; MaxLines: Integer): string;
var
  Stat: TDiffStat;
  Lines: TDiffLines;
begin
  Lines := DiffText(OldText, NewText, Stat);
  if (Stat.Added = 0) and (Stat.Removed = 0) then
    Exit('no change');
  Result := Format('%d added, %d removed', [Stat.Added, Stat.Removed]);
  if Stat.Truncated then
    Result := Result + ' (file too large for a line diff)';
  Result := Result + #10 + RenderDiff(Lines, MaxLines);
end;

end.
