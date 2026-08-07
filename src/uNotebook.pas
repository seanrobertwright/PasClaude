{ uNotebook - reading and editing Jupyter notebooks as cells rather than JSON.

  Two facts shape everything here.  First, a .ipynb is a JSON document whose
  outputs routinely carry megabytes of base64 image data: that data must never
  reach the model, so the view summarises every output by mime type and size
  and emits none of its bytes.  Second, a notebook is a file a human diffs and
  a version control system stores, so it is written back in the exact layout
  Jupyter's own writer produces - one space of indent, sorted keys - and every
  subtree an edit does not name is carried across by reference, so ids,
  execution counts and outputs cannot drift.

  Format knowledge lives here and not in uTools because none of it depends on
  paths, permissions or the console; that is what makes the rules testable
  without a session root or a file on disk. }
unit uNotebook;

{$mode objfpc}{$H+}

interface

uses SysUtils, Classes, uJson;

{ True when Path names a Jupyter notebook.  The rule lives here so uTools
  and the tests cannot disagree about what counts as one. }
function IsNotebookPath(const Path: string): Boolean;

{ Renders a notebook document as numbered cells: type, execution count, the
  source verbatim, and a one-line summary of each output.  Output DATA is
  never emitted - a single display_data can be megabytes of base64, and the
  model needs to know a PNG is there, not what it contains.  False with Err
  set when Text is not a v4 notebook. }
function NotebookView(const Text: string; out View: string;
  out Err: string): Boolean;

{ The document re-emitted unchanged, in the layout NotebookApply writes.
  Used to warn that saving will also reformat a file someone else wrote
  differently. }
function NotebookCanonical(const Text: string; out Canon: string;
  out Err: string): Boolean;

{ Applies one cell change and returns the whole new document text.  Mode is
  'replace', 'insert' or 'delete'; Cell is the 0-based index the view shows,
  and for 'insert' the index the new cell takes.  Source is required by
  replace and insert, CellType ('code'|'markdown'|'raw', default 'code') by
  insert alone.  Every subtree the edit does not name is carried across by
  reference, so ids, execution counts and outputs cannot drift. }
function NotebookApply(const Text: string; Cell: Integer;
  const Mode, Source, CellType: string; out NewText: string;
  out Err: string): Boolean;

implementation

const
  { Per-output limits.  A summary exists to tell the model what is there, not
    to reproduce it: fifteen lines is enough to read a traceback or a small
    table, and everything past that is context spent on data the model can
    re-derive by running the cell. }
  MaxOutputLines = 15;
  MaxOutputChars = 2000;
  { Cells with a hundred outputs happen - a loop printing per iteration - and
    the hundredth says nothing the eighth did not. }
  MaxOutputsPerCell = 8;

function IsNotebookPath(const Path: string): Boolean;
begin
  Result := CompareText(ExtractFileExt(Path), '.ipynb') = 0;
end;

{ ------------------------------------------------------------- helpers -- }

{ nbformat writes a cell's source either as one string or as an array of
  lines, and both forms are in the wild; a reader that only knows one of them
  silently shows an empty cell. }
function SourceText(V: TJson): string;
var
  I: Integer;
begin
  Result := '';
  if V = nil then Exit;
  case V.Kind of
    jkStr: Result := V.AsString;
    jkArr:
      for I := 0 to V.Count - 1 do
        if V.Item(I).Kind = jkStr then
          Result := Result + V.Item(I).AsString;
  end;
end;

{ The array-of-lines form, which is what Jupyter writes and what keeps a
  notebook's diff line-oriented: every line but the last keeps its newline,
  so adding a line changes one array element instead of one enormous string. }
function SourceLines(const S: string): TJson;
var
  I, Start: Integer;
begin
  Result := TJson.NewArr;
  Start := 1;
  for I := 1 to Length(S) do
    if S[I] = #10 then
    begin
      Result.Push(TJson.NewStr(Copy(S, Start, I - Start + 1)));
      Start := I + 1;
    end;
  if Start <= Length(S) then
    Result.Push(TJson.NewStr(Copy(S, Start, MaxInt)));
end;

{ Tracebacks arrive with the colour escapes IPython printed them with.  Left
  in, they are noise the model has to read past in every stack trace. }
function StripAnsi(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = #27) and (I < Length(S)) and (S[I + 1] = '[') then
    begin
      Inc(I, 2);
      while (I <= Length(S)) and not (S[I] in ['@'..'~']) do Inc(I);
      Inc(I);
    end
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
  end;
end;

function Bytes(N: Int64): string;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  if N < 1024 then
    Result := Format('%d bytes', [N])
  else if N < 1024 * 1024 then
    Result := Format('%.1f KB', [N / 1024], FS)
  else
    Result := Format('%.1f MB', [N / (1024 * 1024)], FS);
end;

{ Cuts a value to something a summary can carry.  The caps are per output, so
  a cell with eight of them still cannot dominate the reply. }
function Shorten(const S: string): string;
var
  L: TStringList;
  I: Integer;
begin
  Result := StripAnsi(S);
  L := TStringList.Create;
  try
    L.Text := Result;
    if L.Count > MaxOutputLines then
    begin
      Result := '';
      for I := 0 to MaxOutputLines - 1 do
        Result := Result + L[I] + #10;
      Result := Result + Format('... [%d more lines]', [L.Count - MaxOutputLines]);
    end;
  finally
    L.Free;
  end;
  { Utf8Cut, not Copy: the cap is a byte count and an output is as likely to
    be a pandas repr full of em dashes as it is to be ASCII.  A sequence cut
    in half here reaches the model through read_file and the API rejects the
    request whole - the truncation would cost the turn, not the output. }
  if Length(Result) > MaxOutputChars then
    Result := Utf8Cut(Result, MaxOutputChars) +
      Format('... [%d chars total]', [Length(S)]);
end;

{ A cell id that is unique within Doc and the same every run.  Derived from
  the source rather than drawn at random so a test can assert on it; FNV-1a
  because it is four lines and collisions only cost a bump. }
function NewId(Cells: TJson; const Source: string; Index: Integer): string;
var
  H: LongWord;
  I, Bump: Integer;
  Cand: string;
  Taken: Boolean;
begin
  H := $811C9DC5;
  for I := 1 to Length(Source) do
  begin
    H := H xor LongWord(Byte(Source[I]));
    H := H * 16777619;
  end;
  H := H xor LongWord(Index);
  H := H * 16777619;
  Bump := 0;
  repeat
    Cand := LowerCase(IntToHex(H + LongWord(Bump), 8));
    Taken := False;
    for I := 0 to Cells.Count - 1 do
      if Cells.Item(I).Str('id') = Cand then
      begin
        Taken := True;
        Break;
      end;
    Inc(Bump);
  until (not Taken) or (Bump > 1000);
  Result := Cand;
end;

{ Parses Text and checks it is a notebook this unit understands.  On failure
  nothing is owned by the caller: a half-open document would be a leak under
  -gh and a trap for every call site. }
function OpenDoc(const Text: string; out Doc, Cells: TJson;
  out Err: string): Boolean;
var
  Ver: Double;
begin
  Doc := nil;
  Cells := nil;
  Doc := JsonParse(Text, Err);
  if Doc = nil then
  begin
    if Err = '' then Err := 'not JSON';
    Err := 'not a valid notebook: ' + Err;
    Exit(False);
  end;
  Result := False;
  try
    if Doc.Kind <> jkObj then
    begin
      Err := 'not a notebook: the document is not a JSON object';
      Exit;
    end;
    Ver := Doc.Num('nbformat', 0);
    { v3 kept cells inside worksheets and named half the fields differently.
      Rewriting one as v4 would silently discard structure, so it is refused
      by name rather than half-understood. }
    if Ver <> 4 then
    begin
      Err := Format('unsupported nbformat %d: only version 4 notebooks can be ' +
        'read or edited here', [Round(Ver)]);
      Exit;
    end;
    Cells := Doc.Find('cells');
    if (Cells = nil) or (Cells.Kind <> jkArr) then
    begin
      Err := 'not a notebook: no cells array';
      Exit;
    end;
    Result := True;
  finally
    if not Result then
    begin
      Doc.Free;
      Doc := nil;
      Cells := nil;
    end;
  end;
end;

{ ---------------------------------------------------------------- view -- }

{ One output, summarised.  The mime keys are named and their payloads are
  measured, never emitted: naming the type is what lets the model decide
  whether the cell did what it was meant to, and that is the whole of what
  the payload would have told it. }
function OutputSummary(O: TJson): string;
var
  Data, V: TJson;
  I: Integer;
  Kind, Key, Line: string;
begin
  Result := '';
  if (O = nil) or (O.Kind <> jkObj) then Exit('  [output]');
  Kind := O.Str('output_type', 'output');

  if Kind = 'stream' then
  begin
    Result := Format('  [%s %s] ', [Kind, O.Str('name', 'stdout')]) +
      Shorten(SourceText(O.Find('text')));
    Exit;
  end;

  if Kind = 'error' then
  begin
    Result := Format('  [error] %s: %s', [O.Str('ename'), O.Str('evalue')]);
    V := O.Find('traceback');
    if (V <> nil) and (V.Kind = jkArr) then
    begin
      Line := '';
      for I := 0 to V.Count - 1 do
        Line := Line + V.Item(I).AsString + #10;
      if Trim(Line) <> '' then
        Result := Result + #10 + Shorten(Line);
    end;
    Exit;
  end;

  { execute_result and display_data, plus anything a future kernel invents:
    the data bundle is the part that can be enormous. }
  Result := Format('  [%s]', [Kind]);
  Data := O.Find('data');
  if (Data = nil) or (Data.Kind <> jkObj) then Exit;
  for I := 0 to Data.Count - 1 do
  begin
    Key := Data.Key(I);
    V := Data.Item(I);
    if Key = 'text/plain' then
      Result := Result + #10 + '    text/plain: ' + Shorten(SourceText(V))
    else
      { Every other mime type is described, not shown.  image/png alone is
        commonly a megabyte of base64, and there is no length at which a
        prefix of it becomes useful. }
      Result := Result + #10 +
        Format('    %s (%s)', [Key, Bytes(Length(SourceText(V)))]);
  end;
end;

function NotebookView(const Text: string; out View: string;
  out Err: string): Boolean;
var
  Doc, Cells, C, Outs: TJson;
  I, K, Shown: Integer;
  Src, Head: string;
begin
  View := '';
  if not OpenDoc(Text, Doc, Cells, Err) then Exit(False);
  try
    View := Format('notebook: %d cells, nbformat %d.%d'#10,
      [Cells.Count, Round(Doc.Num('nbformat', 4)),
       Round(Doc.Num('nbformat_minor', 0))]);
    for I := 0 to Cells.Count - 1 do
    begin
      C := Cells.Item(I);
      if (C = nil) or (C.Kind <> jkObj) then
      begin
        View := View + Format(#10'== cell %d (malformed) =='#10, [I]);
        Continue;
      end;
      Head := Format('== cell %d (%s', [I, C.Str('cell_type', '?')]);
      if (C.Find('execution_count') <> nil) and
         (C.Find('execution_count').Kind = jkNum) then
        Head := Head + Format(', execution_count %d',
          [Round(C.Num('execution_count', 0))]);
      View := View + #10 + Head + ') =='#10;
      Src := SourceText(C.Find('source'));
      { Verbatim and unprefixed.  The model has to hand this source back to
        replace it, and any decoration - line numbers, a margin - is something
        it will faithfully copy into the file. }
      if Src <> '' then
      begin
        View := View + Src;
        if Src[Length(Src)] <> #10 then View := View + #10;
      end;
      Outs := C.Find('outputs');
      if (Outs = nil) or (Outs.Kind <> jkArr) or (Outs.Count = 0) then Continue;
      Shown := Outs.Count;
      if Shown > MaxOutputsPerCell then Shown := MaxOutputsPerCell;
      for K := 0 to Shown - 1 do
        View := View + OutputSummary(Outs.Item(K)) + #10;
      if Outs.Count > Shown then
        View := View + Format('  ... [%d more outputs]'#10,
          [Outs.Count - Shown]);
    end;
    Result := True;
  finally
    Doc.Free;
  end;
end;

{ ---------------------------------------------------------------- write -- }

{ The one place a document becomes text, so the layout cannot diverge between
  the canonical check and a real edit.  A trailing newline because that is
  what nbformat writes and what every text tool expects. }
function Emit(Doc: TJson): string;
begin
  Result := Doc.ToJsonPretty(True) + #10;
end;

function NotebookCanonical(const Text: string; out Canon: string;
  out Err: string): Boolean;
var
  Doc, Cells: TJson;
begin
  Canon := '';
  if not OpenDoc(Text, Doc, Cells, Err) then Exit(False);
  try
    Canon := Emit(Doc);
    Result := True;
  finally
    Doc.Free;
  end;
end;

function NotebookApply(const Text: string; Cell: Integer;
  const Mode, Source, CellType: string; out NewText: string;
  out Err: string): Boolean;
var
  Doc, Cells, C, New: TJson;
  Minor: Integer;
  CT: string;
begin
  NewText := '';
  if not OpenDoc(Text, Doc, Cells, Err) then Exit(False);
  Result := False;
  try
    if Mode = 'delete' then
    begin
      if (Cell < 0) or (Cell >= Cells.Count) then
      begin
        Err := Format('cell %d is out of range: the notebook has %d cells (0..%d)',
          [Cell, Cells.Count, Cells.Count - 1]);
        Exit;
      end;
      Cells.Drop(Cell);
    end

    else if Mode = 'replace' then
    begin
      if (Cell < 0) or (Cell >= Cells.Count) then
      begin
        Err := Format('cell %d is out of range: the notebook has %d cells (0..%d)',
          [Cell, Cells.Count, Cells.Count - 1]);
        Exit;
      end;
      C := Cells.Item(Cell);
      if (C = nil) or (C.Kind <> jkObj) or (C.IndexOf('source') < 0) then
      begin
        Err := Format('cell %d has no source field', [Cell]);
        Exit;
      end;
      { Only the source slot is replaced.  Outputs and execution_count are
        deliberately kept: the user approved "change this cell's code", not
        "throw away the plot it produced".  The view labels the outputs, so a
        later read shows the model that they are now stale. }
      C.SetAt(C.IndexOf('source'), SourceLines(Source));
    end

    else if Mode = 'insert' then
    begin
      { Appending at Count is legal - that is how a cell is added at the end -
        so the range is one wider than for replace and delete. }
      if (Cell < 0) or (Cell > Cells.Count) then
      begin
        Err := Format('cell %d is out of range: insert takes 0..%d',
          [Cell, Cells.Count]);
        Exit;
      end;
      CT := CellType;
      if CT = '' then CT := 'code';
      if (CT <> 'code') and (CT <> 'markdown') and (CT <> 'raw') then
      begin
        Err := 'cell_type must be code, markdown or raw: ' + CT;
        Exit;
      end;
      New := TJson.NewObj;
      New.AddStr('cell_type', CT);
      { nbformat 4.5 requires a cell id and 4.0-4.4 forbid the field, so it is
        emitted on the minor version and not on taste. }
      Minor := Round(Doc.Num('nbformat_minor', 0));
      if Minor >= 5 then
        New.AddStr('id', NewId(Cells, Source, Cell));
      New.Add('metadata', TJson.NewObj);
      if CT = 'code' then
      begin
        { The v4 schema makes both mandatory on a code cell; a cell without
          them is one Jupyter's validator rejects on open. }
        New.Add('execution_count', TJson.NewNull);
        New.Add('outputs', TJson.NewArr);
      end;
      New.Add('source', SourceLines(Source));
      Cells.InsertAt(Cell, New);
    end

    else
    begin
      Err := 'edit_mode must be replace, insert or delete: ' + Mode;
      Exit;
    end;

    NewText := Emit(Doc);
    Result := True;
  finally
    Doc.Free;
  end;
end;

end.
