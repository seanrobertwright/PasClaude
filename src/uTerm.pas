{ uTerm - console output with colour, plus a line editor for the prompt.

  Output is UTF-8: the console output codepage is switched at startup so that
  non-ASCII in model replies renders instead of turning into mojibake.  Colour
  goes through SetConsoleTextAttribute rather than ANSI escapes, which keeps
  the program working on hosts where virtual-terminal processing is off. }
unit uTerm;

{$mode objfpc}{$H+}

interface

type
  TColor = (clGrey, clWhite, clBright, clCyan, clGreen, clYellow, clRed,
            clMagenta, clBlue);

procedure TermInit;
procedure TermDone;

procedure Emit(const S: string);                      { no newline }
procedure EmitLn(const S: string = '');
procedure EmitC(C: TColor; const S: string);
procedure EmitCLn(C: TColor; const S: string = '');

{ Reads one line with basic editing (backspace, Ctrl+U, Ctrl+C).
  Returns False when the user asks to quit (Ctrl+C on an empty line, or EOF). }
function ReadLineEdit(const Prompt: string; out Line: string): Boolean;

{ True when a key is waiting; used to let the user interrupt a stream. }
function EscPressed: Boolean;

function TermWidth: Integer;

implementation

uses Windows, SysUtils;

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

{ Redraws the edited line in place.  The whole line is rewritten rather than
  patched, because working out the minimal update is far more code than the
  redraw costs at terminal speeds - and it is what keeps a mid-line insert or
  a history recall from leaving debris behind. }
procedure Redraw(const Prompt: string; const W: WideString; Caret: Integer;
  var PrevLen: Integer);
var
  I: Integer;
begin
  { Back to column zero, then over the prompt. }
  Emit(#13);
  EmitC(clCyan, Prompt);
  Emit(UTF8Encode(W));
  { Erase whatever the previous, longer line left on screen. }
  for I := Length(W) to PrevLen - 1 do
    Emit(' ');
  Emit(#13);
  EmitC(clCyan, Prompt);
  if Caret > 0 then
    Emit(UTF8Encode(Copy(W, 1, Caret)));
  PrevLen := Length(W);
end;

function ReadLineEdit(const Prompt: string; out Line: string): Boolean;
var
  W: WideString;
  Rec: INPUT_RECORD;
  NRead: DWORD = 0;
  Ch: WideChar;
  Mode: DWORD = 0;
  Caret: Integer;
  PrevLen: Integer;
  HistPos: Integer;
  Pending: WideString;

  procedure Recall(Delta: Integer);
  var
    Target: Integer;
  begin
    if Length(History) = 0 then Exit;
    { HistPos = Length(History) means "the line being typed", which is stashed
      in Pending so browsing away and back does not destroy it. }
    if HistPos = Length(History) then Pending := W;
    Target := HistPos + Delta;
    if Target < 0 then Target := 0;
    if Target > Length(History) then Target := Length(History);
    if Target = HistPos then Exit;
    HistPos := Target;
    if HistPos = Length(History) then
      W := Pending
    else
      W := UTF8Decode(History[HistPos]);
    Caret := Length(W);
    Redraw(Prompt, W, Caret, PrevLen);
  end;

begin
  Line := '';
  W := '';
  Pending := '';
  Caret := 0;
  PrevLen := 0;
  HistPos := Length(History);
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
            EmitLn;
            Line := UTF8Encode(W);
            HistoryAdd(Line);
            Exit(True);
          end;
        VK_BACK:
          begin
            if Caret > 0 then
            begin
              Delete(W, Caret, 1);
              Dec(Caret);
              Redraw(Prompt, W, Caret, PrevLen);
            end;
            Continue;
          end;
        VK_DELETE:
          begin
            if Caret < Length(W) then
            begin
              Delete(W, Caret + 1, 1);
              Redraw(Prompt, W, Caret, PrevLen);
            end;
            Continue;
          end;
        VK_LEFT:
          begin
            if Caret > 0 then
            begin
              Dec(Caret);
              Redraw(Prompt, W, Caret, PrevLen);
            end;
            Continue;
          end;
        VK_RIGHT:
          begin
            if Caret < Length(W) then
            begin
              Inc(Caret);
              Redraw(Prompt, W, Caret, PrevLen);
            end;
            Continue;
          end;
        VK_HOME:
          begin
            Caret := 0;
            Redraw(Prompt, W, Caret, PrevLen);
            Continue;
          end;
        VK_END:
          begin
            Caret := Length(W);
            Redraw(Prompt, W, Caret, PrevLen);
            Continue;
          end;
        VK_UP:
          begin
            Recall(-1);
            Continue;
          end;
        VK_DOWN:
          begin
            Recall(1);
            Continue;
          end;
        VK_ESCAPE:
          begin
            W := '';
            Caret := 0;
            Redraw(Prompt, W, Caret, PrevLen);
            Continue;
          end;
      end;

      if Ch = #3 then          { Ctrl+C }
      begin
        EmitLn;
        Exit(False);
      end;
      if Ch = #21 then         { Ctrl+U clears the line }
      begin
        W := '';
        Caret := 0;
        Redraw(Prompt, W, Caret, PrevLen);
        Continue;
      end;
      if Ch = #1 then          { Ctrl+A to the start }
      begin
        Caret := 0;
        Redraw(Prompt, W, Caret, PrevLen);
        Continue;
      end;
      if Ch = #5 then          { Ctrl+E to the end }
      begin
        Caret := Length(W);
        Redraw(Prompt, W, Caret, PrevLen);
        Continue;
      end;
      if Ch >= #32 then
      begin
        Insert(Ch, W, Caret + 1);
        Inc(Caret);
        { Appending at the end is the common case and needs no redraw, which
          keeps ordinary typing free of flicker. }
        if Caret = Length(W) then
        begin
          Emit(UTF8Encode(WideString(Ch)));
          PrevLen := Length(W);
        end
        else
          Redraw(Prompt, W, Caret, PrevLen);
      end;
    until False;
  finally
    if HIn <> 0 then SetConsoleMode(HIn, Mode);
  end;
end;

end.
