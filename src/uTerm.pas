{ uTerm - console output with colour, plus a line editor for the prompt.

  Output is UTF-8: the console output codepage is switched at startup so that
  non-ASCII in model replies renders instead of turning into mojibake.  Colour
  goes through SetConsoleTextAttribute rather than ANSI escapes, which keeps
  the program working on hosts where virtual-terminal processing is off. }
unit uTerm;

{$mode objfpc}{$H+}

interface

uses SysUtils;

type
  TColor = (clGrey, clWhite, clBright, clCyan, clGreen, clYellow, clRed,
            clMagenta, clBlue);

procedure TermInit;
procedure TermDone;

procedure Emit(const S: string);                      { no newline }
procedure EmitLn(const S: string = '');
procedure EmitC(C: TColor; const S: string);
procedure EmitCLn(C: TColor; const S: string = '');

{ ------------------------------------------------------- markdown streaming --

  The reply arrives in fragments that can split anywhere - mid-line, mid-**,
  mid-fence.  A full parser wants the whole document; a terminal wants the
  text as it arrives.  This renderer holds back only the current incomplete
  line, styles complete lines as they close, and treats inline marks with a
  simple state machine.  It covers what models actually emit - headings,
  fenced code, inline code, bold - and passes anything else through
  unstyled, which is always safe. }

{ Resets the renderer for a fresh reply. }
procedure MdReset;
{ Feeds one streamed fragment; complete lines are styled and printed. }
procedure MdFeed(const S: string);
{ Flushes whatever is buffered, closing the reply. }
procedure MdFinish;
{ True when the renderer is mid-line (for the caller's cursor tracking). }
function MdMidLine: Boolean;

{ Reads one line with basic editing (backspace, Ctrl+U, Ctrl+C).
  Returns False when the user asks to quit (Ctrl+C on an empty line, or EOF). }
function ReadLineEdit(const Prompt: string; out Line: string): Boolean;

{ True when a key is waiting; used to let the user interrupt a stream. }
function EscPressed: Boolean;

function TermWidth: Integer;

{ ------------------------------------------------------------ line editing --

  The editor's decisions - where the caret goes, what a key removes, which
  history entry is recalled - are separated from the console so they can be
  tested.  ReadLineEdit is then a loop that turns real key events into these
  calls and redraws; everything that could be wrong about the editing itself
  lives here. }
type
  TEditKey = (ekChar, ekBackspace, ekDelete, ekLeft, ekRight, ekHome, ekEnd,
              ekHistPrev, ekHistNext, ekClear, ekNewline);

  TEditState = record
    Text: WideString;
    Caret: Integer;        { 0..Length(Text); characters before the cursor }
    HistPos: Integer;      { Length(History) means "the line being typed" }
    Pending: WideString;   { the typed line, stashed while browsing history }
  end;

  { Supplies completion candidates for the token under the caret.  The host
    wires this to slash commands and the file system; uTerm itself stays free
    of both. }
  TCompleteProc = function(const Token: string; AtLineStart: Boolean): TStringArray;

var
  CompleteProvider: TCompleteProc = nil;

{ Starts an edit with an empty line. }
procedure EditInit(out E: TEditState);
{ Applies one key.  Ch matters only for ekChar. }
procedure EditApply(var E: TEditState; Key: TEditKey; Ch: WideChar);
{ Completes the token ending at the caret using Candidates.  A single match
  replaces the token outright; several extend it to their common prefix.
  Returns True when the text changed.  Pure, so the whole behaviour is
  testable without a console or a file system. }
function CompleteToken(var E: TEditState;
  const Candidates: array of string): Boolean;
{ The token the completion would act on: from after the last space to the
  caret.  Exposed for the provider and the tests. }
function TokenAtCaret(const E: TEditState; out AtLineStart: Boolean): string;
{ Records a finished line in the history. }
procedure HistoryAdd(const S: string);
{ Test seam: forget every recorded command. }
procedure HistoryClear;
{ Test seam: how many commands are remembered. }
function HistoryCount: Integer;

implementation

uses Windows;

var
  HOut: HANDLE = 0;
  HIn: HANDLE = 0;
  SavedAttr: Word = 7;
  SavedCP: UINT = 0;
  SavedInCP: UINT = 0;

function Attr(C: TColor): Word;
begin
  case C of
    clGrey:    Result := FOREGROUND_INTENSITY;
    clWhite:   Result := FOREGROUND_RED or FOREGROUND_GREEN or FOREGROUND_BLUE;
    clBright:  Result := FOREGROUND_RED or FOREGROUND_GREEN or FOREGROUND_BLUE or FOREGROUND_INTENSITY;
    clCyan:    Result := FOREGROUND_GREEN or FOREGROUND_BLUE or FOREGROUND_INTENSITY;
    clGreen:   Result := FOREGROUND_GREEN or FOREGROUND_INTENSITY;
    clYellow:  Result := FOREGROUND_RED or FOREGROUND_GREEN or FOREGROUND_INTENSITY;
    clRed:     Result := FOREGROUND_RED or FOREGROUND_INTENSITY;
    clMagenta: Result := FOREGROUND_RED or FOREGROUND_BLUE or FOREGROUND_INTENSITY;
    clBlue:    Result := FOREGROUND_BLUE or FOREGROUND_INTENSITY;
  else
    Result := SavedAttr;
  end;
end;

procedure TermInit;
var
  Info: CONSOLE_SCREEN_BUFFER_INFO;
begin
  HOut := GetStdHandle(STD_OUTPUT_HANDLE);
  HIn := GetStdHandle(STD_INPUT_HANDLE);
  if GetConsoleScreenBufferInfo(HOut, Info) then
    SavedAttr := Info.wAttributes;
  SavedCP := GetConsoleOutputCP;
  SavedInCP := GetConsoleCP;
  SetConsoleOutputCP(CP_UTF8);
  SetConsoleCP(CP_UTF8);
end;

procedure TermDone;
begin
  if HOut <> 0 then
    SetConsoleTextAttribute(HOut, SavedAttr);
  if SavedCP <> 0 then SetConsoleOutputCP(SavedCP);
  if SavedInCP <> 0 then SetConsoleCP(SavedInCP);
end;

function TermWidth: Integer;
var
  Info: CONSOLE_SCREEN_BUFFER_INFO;
begin
  Result := 80;
  if (HOut <> 0) and GetConsoleScreenBufferInfo(HOut, Info) then
    Result := Info.srWindow.Right - Info.srWindow.Left + 1;
  if Result < 20 then Result := 20;
end;

{ WriteConsoleW takes UTF-16, so text is converted rather than written as raw
  bytes; that keeps output correct even if the codepage switch was refused.
  It fails outright on a redirected handle, in which case the UTF-8 bytes go
  straight to the stream so piping still works. }
procedure RawWrite(const S: string);
var
  W: WideString;
  Written: DWORD;
begin
  if S = '' then Exit;
  if HOut <> 0 then
  begin
    W := UTF8Decode(S);
    if (W <> '') and WriteConsoleW(HOut, PWideChar(W), Length(W), Written, nil) then
      Exit;
  end;
  Write(Output, S);
  Flush(Output);
end;

procedure Emit(const S: string);
begin
  RawWrite(S);
end;

procedure EmitLn(const S: string);
begin
  RawWrite(S + sLineBreak);
end;

procedure EmitC(C: TColor; const S: string);
begin
  if HOut <> 0 then SetConsoleTextAttribute(HOut, Attr(C));
  RawWrite(S);
  if HOut <> 0 then SetConsoleTextAttribute(HOut, SavedAttr);
end;

procedure EmitCLn(C: TColor; const S: string);
begin
  EmitC(C, S + sLineBreak);
end;

{ ------------------------------------------------------- markdown streaming -- }

var
  MdBuf: string = '';          { the incomplete final line }
  MdInFence: Boolean = False;

procedure MdReset;
begin
  MdBuf := '';
  MdInFence := False;
end;

function MdMidLine: Boolean;
begin
  Result := MdBuf <> '';
end;

{ Prints one complete line with inline styling.  `code` spans render cyan,
  **bold** renders bright; the marks themselves are eaten.  An unclosed mark
  prints literally, because swallowing text the model wrote is worse than
  showing a stray asterisk. }
procedure MdLine(const S: string);
var
  I, Start: Integer;
  InCode, InBold: Boolean;

  procedure Flush(Upto: Integer);
  begin
    if Upto >= Start then
    begin
      if InCode then
        EmitC(clCyan, Copy(S, Start, Upto - Start + 1))
      else if InBold then
        EmitC(clBright, Copy(S, Start, Upto - Start + 1))
      else
        Emit(Copy(S, Start, Upto - Start + 1));
    end;
  end;

begin
  { Fences toggle code mode and are themselves swallowed - the colour says
    what the block is, and the ``` line is markdown plumbing, not content. }
  if Copy(TrimLeft(S), 1, 3) = '```' then
  begin
    MdInFence := not MdInFence;
    Exit;
  end;
  if MdInFence then
  begin
    EmitCLn(clCyan, S);
    Exit;
  end;
  { A heading colours the whole line and keeps its # marks: they carry the
    level, and models refer back to "## Design" by name. }
  if (S <> '') and (S[1] = '#') then
  begin
    EmitCLn(clBright, S);
    Exit;
  end;

  I := 1;
  Start := 1;
  InCode := False;
  InBold := False;
  while I <= Length(S) do
  begin
    if S[I] = '`' then
    begin
      { The span only styles if it closes on this line. }
      if InCode or (Pos('`', S, I + 1) > 0) then
      begin
        Flush(I - 1);
        InCode := not InCode;
        Start := I + 1;
      end;
      Inc(I);
    end
    else if (not InCode) and (I < Length(S)) and (S[I] = '*') and (S[I + 1] = '*') then
    begin
      if InBold or (Pos('**', S, I + 2) > 0) then
      begin
        Flush(I - 1);
        InBold := not InBold;
        Start := I + 2;
      end;
      Inc(I, 2);
    end
    else
      Inc(I);
  end;
  Flush(Length(S));
  EmitLn;
end;

procedure MdFeed(const S: string);
var
  I: Integer;
  Line: string;
begin
  MdBuf := MdBuf + S;
  repeat
    I := Pos(#10, MdBuf);
    if I = 0 then Exit;
    Line := Copy(MdBuf, 1, I - 1);
    Delete(MdBuf, 1, I);
    if (Line <> '') and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    MdLine(Line);
  until False;
end;

procedure MdFinish;
begin
  if MdBuf <> '' then
  begin
    MdLine(MdBuf);
    MdBuf := '';
  end;
  MdInFence := False;
end;

function EscPressed: Boolean;
var
  N: DWORD;
  Rec: INPUT_RECORD;
  NRead: DWORD = 0;
begin
  Result := False;
  if HIn = 0 then Exit;
  while GetNumberOfConsoleInputEvents(HIn, N) and (N > 0) do
  begin
    if not ReadConsoleInputW(HIn, Rec, 1, NRead) or (NRead = 0) then Exit;
    if (Rec.EventType = KEY_EVENT) and Rec.Event.KeyEvent.bKeyDown and
       (Rec.Event.KeyEvent.wVirtualKeyCode = VK_ESCAPE) then
      Result := True;
  end;
end;

{ Command history.  Kept for the life of the process; a session long enough to
  care about persistence has bigger state than this. }
var
  History: array of string;

procedure HistoryAdd(const S: string);
var
  N: Integer;
begin
  if Trim(S) = '' then Exit;
  N := Length(History);
  { Repeating the last command should not fill the history with copies. }
  if (N > 0) and (History[N - 1] = S) then Exit;
  SetLength(History, N + 1);
  History[N] := S;
end;

procedure HistoryClear;
begin
  SetLength(History, 0);
end;

function HistoryCount: Integer;
begin
  Result := Length(History);
end;

procedure EditInit(out E: TEditState);
begin
  E.Text := '';
  E.Caret := 0;
  E.HistPos := Length(History);
  E.Pending := '';
end;

function TokenAtCaret(const E: TEditState; out AtLineStart: Boolean): string;
var
  I, Start: Integer;
begin
  Start := 1;
  for I := E.Caret downto 1 do
    if (E.Text[I] = ' ') or (E.Text[I] = #10) then
    begin
      Start := I + 1;
      Break;
    end;
  Result := UTF8Encode(Copy(E.Text, Start, E.Caret - Start + 1));
  AtLineStart := Start = 1;
end;

function CompleteToken(var E: TEditState;
  const Candidates: array of string): Boolean;
var
  Token, Prefix, Cand: string;
  I, J, Start: Integer;
  AtStart: Boolean;
  W: WideString;
begin
  Result := False;
  if Length(Candidates) = 0 then Exit;
  Token := TokenAtCaret(E, AtStart);

  { The common prefix of every candidate.  With one candidate that is the
    candidate itself, which is the single-match case. }
  Prefix := Candidates[0];
  for I := 1 to High(Candidates) do
  begin
    Cand := Candidates[I];
    J := 1;
    while (J <= Length(Prefix)) and (J <= Length(Cand)) and
          (LowerCase(Prefix[J]) = LowerCase(Cand[J])) do
      Inc(J);
    SetLength(Prefix, J - 1);
  end;

  { Nothing longer than what is already typed means nothing to do. }
  if Length(Prefix) <= Length(Token) then Exit;

  { Replace the token with the prefix.  Both are re-measured in UTF-16, since
    the caret counts wide characters and the strings are UTF-8. }
  W := UTF8Decode(Token);
  Start := E.Caret - Length(W);
  Delete(E.Text, Start + 1, Length(W));
  W := UTF8Decode(Prefix);
  Insert(W, E.Text, Start + 1);
  E.Caret := Start + Length(W);
  Result := True;
end;

procedure EditApply(var E: TEditState; Key: TEditKey; Ch: WideChar);
var
  Target: Integer;
begin
  case Key of
    ekChar:
      begin
        Insert(Ch, E.Text, E.Caret + 1);
        Inc(E.Caret);
      end;
    ekBackspace:
      if E.Caret > 0 then
      begin
        Delete(E.Text, E.Caret, 1);
        Dec(E.Caret);
      end;
    ekDelete:
      { Delete removes forwards and must leave the caret where it is, which is
        what distinguishes it from backspace. }
      if E.Caret < Length(E.Text) then
        Delete(E.Text, E.Caret + 1, 1);
    ekLeft:
      if E.Caret > 0 then Dec(E.Caret);
    ekRight:
      if E.Caret < Length(E.Text) then Inc(E.Caret);
    ekHome:
      E.Caret := 0;
    ekEnd:
      E.Caret := Length(E.Text);
    ekClear:
      begin
        E.Text := '';
        E.Caret := 0;
      end;
    ekNewline:
      begin
        { A literal newline in the middle of the line, for multi-line input.
          It goes through the same insertion path as any character so the
          caret rules hold. }
        Insert(WideChar(#10), E.Text, E.Caret + 1);
        Inc(E.Caret);
      end;
    ekHistPrev, ekHistNext:
      begin
        if Length(History) = 0 then Exit;
        { The half-typed line is stashed on the way out so that browsing up
          and back down returns it rather than losing it. }
        if E.HistPos = Length(History) then E.Pending := E.Text;
        if Key = ekHistPrev then Target := E.HistPos - 1
                            else Target := E.HistPos + 1;
        if Target < 0 then Target := 0;
        if Target > Length(History) then Target := Length(History);
        if Target = E.HistPos then Exit;
        E.HistPos := Target;
        if E.HistPos = Length(History) then
          E.Text := E.Pending
        else
          E.Text := UTF8Decode(History[E.HistPos]);
        E.Caret := Length(E.Text);
      end;
  end;
end;

{ Redraws the edited line in place.  The whole line is rewritten rather than
  patched, because working out the minimal update is far more code than the
  redraw costs at terminal speeds - and it is what keeps a mid-line insert or
  a history recall from leaving debris behind.

  The buffer may hold newlines (a pasted block, or an inserted break); a
  console cannot re-edit rows it has already scrolled past, so what is drawn
  is the line containing the caret, with a continuation marker instead of the
  prompt when it is not the first. }
procedure Redraw(const Prompt: string; const W: WideString; Caret: Integer;
  var PrevLen: Integer);
var
  I: Integer;
  LineStart, LineEnd: Integer;
  Seg: WideString;
  Lead: string;
  RelCaret: Integer;
begin
  { The segment between the newlines around the caret. }
  LineStart := 1;
  for I := Caret downto 1 do
    if W[I] = #10 then
    begin
      LineStart := I + 1;
      Break;
    end;
  LineEnd := Length(W);
  for I := Caret + 1 to Length(W) do
    if W[I] = #10 then
    begin
      LineEnd := I - 1;
      Break;
    end;
  Seg := Copy(W, LineStart, LineEnd - LineStart + 1);
  RelCaret := Caret - LineStart + 1;
  if LineStart = 1 then Lead := Prompt else Lead := '... ';

  { Back to column zero, then over the prompt. }
  Emit(#13);
  EmitC(clCyan, Lead);
  Emit(UTF8Encode(Seg));
  { Erase whatever the previous, longer line left on screen. }
  for I := Length(Seg) to PrevLen - 1 do
    Emit(' ');
  Emit(#13);
  EmitC(clCyan, Lead);
  if RelCaret > 0 then
    Emit(UTF8Encode(Copy(Seg, 1, RelCaret)));
  PrevLen := Length(Seg);
end;

function ReadLineEdit(const Prompt: string; out Line: string): Boolean;
var
  Rec: INPUT_RECORD;
  NRead: DWORD = 0;
  Ch: WideChar;
  Mode: DWORD = 0;
  PrevLen: Integer;
  E: TEditState;
  NPend: DWORD;
  Token: string;
  AtStart: Boolean;
  Cands: TStringArray;

  { Applies a key and repaints.  Every editing key goes through here, so the
    console and the state cannot drift apart. }
  procedure Apply(Key: TEditKey; C: WideChar);
  begin
    EditApply(E, Key, C);
    Redraw(Prompt, E.Text, E.Caret, PrevLen);
  end;

begin
  Line := '';
  PrevLen := 0;
  EditInit(E);
  EmitC(clCyan, Prompt);

  { Cooked mode would swallow the per-key handling this editor needs. }
  if HIn <> 0 then
  begin
    GetConsoleMode(HIn, Mode);
    SetConsoleMode(HIn, ENABLE_PROCESSED_INPUT);
  end;
  try
    repeat
      if (HIn = 0) or not ReadConsoleInputW(HIn, Rec, 1, NRead) or (NRead = 0) then
      begin
        { Not a console (piped input): fall back to a plain read. }
        if EOF(Input) then Exit(False);
        ReadLn(Line);
        Exit(True);
      end;
      if (Rec.EventType <> KEY_EVENT) or not Rec.Event.KeyEvent.bKeyDown then
        Continue;

      Ch := WideChar(Rec.Event.KeyEvent.UnicodeChar);
      case Rec.Event.KeyEvent.wVirtualKeyCode of
        VK_RETURN:
          begin
            { Enter with Ctrl or Alt held inserts a line break instead of
              submitting, which is how a multi-line prompt is written by
              hand.  A pasted block does the same implicitly below. }
            if (Rec.Event.KeyEvent.dwControlKeyState and
                (LEFT_CTRL_PRESSED or RIGHT_CTRL_PRESSED or
                 LEFT_ALT_PRESSED or RIGHT_ALT_PRESSED)) <> 0 then
            begin
              Apply(ekNewline, #0);
              Continue;
            end;
            { A Return with more input already waiting is a paste: the
              terminal delivered the whole clipboard as one burst of key
              events, and treating each newline as a submit would fire off
              one truncated request per pasted line.  The break is kept and
              the read continues until the queue drains. }
            if (GetNumberOfConsoleInputEvents(HIn, NPend) and (NPend > 0)) then
            begin
              Apply(ekNewline, #0);
              Continue;
            end;
            EmitLn;
            Line := UTF8Encode(E.Text);
            HistoryAdd(Line);
            Exit(True);
          end;
        VK_TAB:
          begin
            if Assigned(CompleteProvider) then
            begin
              Token := TokenAtCaret(E, AtStart);
              Cands := CompleteProvider(Token, AtStart);
              if CompleteToken(E, Cands) then
                Redraw(Prompt, E.Text, E.Caret, PrevLen);
            end;
            Continue;
          end;
        VK_BACK:   begin Apply(ekBackspace, #0); Continue; end;
        VK_DELETE: begin Apply(ekDelete, #0);    Continue; end;
        VK_LEFT:   begin Apply(ekLeft, #0);      Continue; end;
        VK_RIGHT:  begin Apply(ekRight, #0);     Continue; end;
        VK_HOME:   begin Apply(ekHome, #0);      Continue; end;
        VK_END:    begin Apply(ekEnd, #0);       Continue; end;
        VK_UP:     begin Apply(ekHistPrev, #0);  Continue; end;
        VK_DOWN:   begin Apply(ekHistNext, #0);  Continue; end;
        VK_ESCAPE: begin Apply(ekClear, #0);     Continue; end;
      end;

      if Ch = #3 then          { Ctrl+C }
      begin
        EmitLn;
        Exit(False);
      end;
      if Ch = #21 then begin Apply(ekClear, #0); Continue; end;  { Ctrl+U }
      if Ch = #1  then begin Apply(ekHome, #0);  Continue; end;  { Ctrl+A }
      if Ch = #5  then begin Apply(ekEnd, #0);   Continue; end;  { Ctrl+E }
      if Ch >= #32 then
      begin
        EditApply(E, ekChar, Ch);
        { Appending at the end is the common case and needs no redraw, which
          keeps ordinary typing free of flicker. }
        if E.Caret = Length(E.Text) then
        begin
          Emit(UTF8Encode(WideString(Ch)));
          PrevLen := Length(E.Text);
        end
        else
          Redraw(Prompt, E.Text, E.Caret, PrevLen);
      end;
    until False;
  finally
    if HIn <> 0 then SetConsoleMode(HIn, Mode);
  end;
end;

end.
