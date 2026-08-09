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
  { The first nine are the original palette and map to the bright ANSI
    foregrounds, which is all a legacy console can render.  The four after
    them are the amber theme, and they are the reason this enum grew: a
    16-colour palette has exactly one amber - clYellow - and a UI built from
    one amber is a UI with no shading.  These four go out as 24-bit
    sequences on a VT console and collapse onto clYellow and clGrey where
    they cannot, which is a duller banner and never a broken one.

    New entries go at the END.  Attr and VtSeq both close with an else, so
    an unmapped colour is the saved attribute rather than a compile error -
    an ordering mistake here would be silent. }
  TColor = (clGrey, clWhite, clBright, clCyan, clGreen, clYellow, clRed,
            clMagenta, clBlue,
            { the amber ramp, lightest first }
            clAmberLt, clAmber, clAmberDim, clAmberDk);

procedure TermInit;
procedure TermDone;

{ True when the console accepted virtual-terminal processing, in which case
  colour goes out as ANSI escapes instead of attribute calls.  Exposed for
  the tests and for anyone wondering which path their terminal is on. }
function TermVtActive: Boolean;

{ The escape sequence for a colour, '' when VT is off.  Pure, so the mapping
  is testable without a console. }
function VtSeq(C: TColor): string;
function VtReset: string;

procedure Emit(const S: string);                      { no newline }
procedure EmitLn(const S: string = '');
procedure EmitC(C: TColor; const S: string);
procedure EmitCLn(C: TColor; const S: string = '');
{ Bright white text on a blue field, for the logo.  One write on the VT
  path; attribute round trip on legacy consoles. }
procedure EmitLogo(const S: string);

{ ------------------------------------------------------------- the chrome --

  The banner and the prompt block are laid out in columns, and a column is a
  width.  Everything below exists because Length() is not a width: this
  program's strings are UTF-8, so '─' is three bytes and one column, and a
  banner padded by Length() is a banner with a ragged right edge.

  Rows are written as ONE string with inline colour marks rather than as a
  run of EmitC calls, because a row that is six calls long cannot be measured
  or padded before it is painted - and measuring is the whole job.  A mark is
  #1 followed by one letter; #1 cannot occur in text the user or the model
  produced, so no escaping rule is needed and none is enforced. }

const
  MkOff      = #1'0';    { back to the terminal's own colour }
  MkGrey     = #1'g';
  MkWhite    = #1'w';
  MkBright   = #1'B';
  MkCyan     = #1'c';
  MkGreen    = #1'G';
  MkYellow   = #1'y';
  MkRed      = #1'r';
  MkAmberLt  = #1'L';
  MkAmber    = #1'A';
  MkAmberDim = #1'D';
  MkAmberDk  = #1'K';

{ Columns the string occupies once the marks are removed.  Counts UTF-8
  characters, not bytes.  Every glyph this program draws is single-width;
  a wide CJK character would be counted as one and pad short, which is a
  cosmetic bug in a banner and not worth a character-width table. }
function UiWidth(const S: string): Integer;
{ The string with the marks stripped - what a log or a test sees. }
function UiPlain(const S: string): string;
{ Padded on the right to exactly W columns (never truncated: use UiFit). }
function UiPad(const S: string; W: Integer): string;
{ Truncated to at most W columns, with a trailing ellipsis when it had to
  cut.  Marks are preserved and never counted, and a cut never lands inside
  a mark or inside a UTF-8 sequence. }
function UiFit(const S: string; W: Integer): string;
{ Centred within W columns. }
function UiCentre(const S: string; W: Integer): string;
{ Paints a marked-up string.  Colour marks turn into EmitC runs. }
procedure UiPaint(const S: string);
procedure UiPaintLn(const S: string = '');
{ The same string with the marks turned into VT escapes, for a caller that
  must paint in ONE write - the prompt block repaints six rows on every
  keystroke, and six rows of per-run console calls is a prompt that feels
  like it is thinking.  '' when VT is off, because there is nothing useful
  to return: the attribute path cannot be expressed as text. }
function UiVt(const S: string): string;

{ True when the console can be trusted with box-drawing and block glyphs.
  Tied to VT by default, which every console that has the fonts also has and
  which the raster-font conhost that would render them as blanks does not. }
function UiFancy: Boolean;

type
  { ugAuto follows VT.  The other two override it, which the tests need -
    a suite that can only ever reach the ASCII branch is a suite that tests
    half of this - and which a user on a terminal that renders box-drawing
    badly can be given later without another decision being made here. }
  TUiGlyphs = (ugAuto, ugAscii, ugUnicode);

procedure UiSetGlyphs(G: TUiGlyphs);
function UiGlyphs: TUiGlyphs;
{ Glyph repeated N times.  N below 1 is the empty string, so a caller doing
  arithmetic on a terminal width cannot produce a negative-length loop. }
function UiRepeat(const Glyph: string; N: Integer): string;
{ A horizontal rule of Cells columns. }
function UiRule(Cells: Integer): string;
{ A proportional bar: Pct of Cells columns in Fill, the rest in Trough.
  Pct is clamped to 0..100, and a non-zero percentage always lights at least
  one cell - a meter that reads 0 at 1% is a meter that lies about the
  direction things are moving. }
function UiMeter(Pct, Cells: Integer; Fill, Trough: TColor): string;
{ 1234 as '1.2k', 1500000 as '1.5M'.  For the status line, where the number
  is a sense of scale and four significant figures are noise. }
function UiCount(N: Int64): string;

{ A rounded frame, exactly Width columns wide in every part, so the three
  pieces line up without the caller doing arithmetic.  The title is set into
  the top edge, where it reads as a label rather than as a first row.

  UiBoxRow takes one string per column and the width of each; a column is
  fitted and padded to its width, so a long path shortens instead of pushing
  the right border off the screen.  For N columns the frame costs
  3*N + 1 columns of chrome, which is what UiBoxInner works out for the
  caller. }
function UiBoxTop(const Title: string; Width: Integer): string;
function UiBoxBottom(Width: Integer): string;
function UiBoxRow(const Cells: array of string;
  const Widths: array of Integer): string;
{ Columns left for content in a Width-wide box of Columns columns. }
function UiBoxInner(Width, Columns: Integer): Integer;

{ ---------------------------------------------------------- the statusline --

  What the block under the prompt says.  uTerm is at the bottom of the unit
  ladder and cannot ask uAgent for a token count or uTools for the permission
  mode, so the facts are PUSHED here by the REPL before each read rather than
  pulled from here.  That inversion is not a workaround: it is what keeps the
  console unit free of the program's state, and it means the composer below
  is a pure function of a record and can be tested without a console.

  Every field has a "say nothing" value - '' or a negative number - and a
  field that says nothing takes no space in the output.  A status line is
  read at a glance or not at all, so a run with no git, no MCP servers and no
  memory file gets a shorter line, not a line of zeroes and dashes. }
type
  TStatusInfo = record
    Model: string;         { the model or alias in force }
    Dir: string;           { the working directory, already shortened }
    Branch: string;        { git branch; '' when the tree is not a repo }
    CtxTokens: Int64;      { the last measured prompt size }
    CtxLimit: Int64;       { what it is measured against; 0 hides the meter }
    TokensIn: Int64;       { the session totals, cache included }
    TokensOut: Int64;
    Memories: Integer;     { CLAUDE.md files loaded; -1 hides }
    Mcps: Integer;         { live MCP servers; -1 hides }
    Hooks: Integer;        { configured hook entries; -1 hides }
    Mode: string;          { permission mode word; '' hides the whole line }
    ModeHot: Boolean;      { paint the mode as a warning, not as a label }
    Note: string;          { one free line, already marked up; '' hides }
  end;

{ Clears every field to its "say nothing" value.  Callers build on top of
  this rather than declaring a record and filling what they remember, so a
  field added later defaults to hidden instead of to garbage. }
procedure StatusClear(out S: TStatusInfo);
{ Installs what the block paints.  Read only while a prompt is on screen. }
procedure SetStatus(const S: TStatusInfo);
{ The rows the record renders to, marked up and already fitted to Width.
  Pure: no console, no module state beyond the palette. }
function StatusLines(const S: TStatusInfo; Width: Integer): TStringArray;

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
  Returns False when the user asks to quit (Ctrl+C on an empty line, or EOF).

  This is the PLAIN reader, and it is the one every prompt in the program uses
  except the REPL: the permission answer, the model picker, the session picker
  and the rewind picker all read through here.  It consults no binding table
  and has no modal editor - see the line-editing section below for why that
  is a safety property and not an oversight. }
function ReadLineEdit(const Prompt: string; out Line: string): Boolean;

{ Reads one line WITHOUT echoing anything at all - not the characters, not
  asterisks.  A mask is not free: it publishes the secret's length to anyone
  looking at the screen or at a terminal recording, and length is most of
  what an attacker wants to know about a key.  The prompt therefore has to
  say that typing is not shown, because a terminal that prints nothing looks
  like a terminal that has hung, and a user who thinks it hung pastes twice.

  False on Esc, on Ctrl+C, and immediately when stdin is not a console - a
  scripted run has nobody to type, and a reader that blocked there would hang
  the run forever.  Nothing read here reaches the history: this reader does
  not call HistoryAdd and does not go through the prompt profile, so no
  binding table can be pointed at it. }
function ReadSecretLine(const Prompt: string; out Secret: string): Boolean;

{ True when a key is waiting; used to let the user interrupt a stream. }
function EscPressed: Boolean;

{ True when stdin is a real console rather than a pipe or a file, which is
  how print mode decides whether there is piped input to read. }
function StdinIsConsole: Boolean;

{ True once per Ctrl+C received while no prompt is being read (that is,
  while a reply streams).  Reading it consumes it.  The prompt itself sees
  Ctrl+C as a key and quits; this flag exists for the stretches where nothing
  is reading the keyboard and the default handler would kill the process -
  skipping every finally block, console restoration included. }
function CtrlCPressed: Boolean;

{ The console control handler, exposed so a test can deliver a synthetic
  event without a keyboard.  Returns True when the event was consumed. }
function HandleConsoleBreak(CtrlType: LongWord): LongBool; stdcall;

function TermWidth: Integer;

{ ------------------------------------------------------------ line editing --

  The editor's decisions - where the caret goes, what a key removes, which
  history entry is recalled - are separated from the console so they can be
  tested.  ReadLineEdit is then a loop that turns real key events into these
  calls and redraws; everything that could be wrong about the editing itself
  lives here.

  The modal editor and the rebindable keys are both built on that seam rather
  than inside the key loop, for the same reason: a suite with no way to
  deliver a keystroke can still drive EditApply, EditNormalKey and DecodeKey
  directly, so every decision either of them makes is asserted.

  TWO WALLS keep a keys.json away from the permission prompt, and either one
  alone is sufficient:

    1. The grammar.  A bindable chord must carry ctrl or alt, or be a named
       non-character key.  The strings 'y', 'a' and 'n' cannot be written in
       the key-name grammar at all, so no configuration file - mistaken or
       hostile - can express a rebinding of a permission answer.  Enter, Tab,
       Escape and Ctrl+C are refused on top of that.
    2. The scope.  ReadLineCore takes its profile as a required parameter and
       reads no module state.  Exactly one expression in the program hands it
       PromptProfile - the argument in ReadPromptLine - and exactly one call
       site reaches ReadPromptLine, the REPL.  Everything else calls
       ReadLineEdit, which passes the constant KeysNone, so the permission
       prompt and the three pickers are structurally unable to see a binding
       or a vim mode.  The audit is one line:

         grep -n "ReadPromptLine\|PromptProfile\|KeysNone" src/*.pas src/*.lpr

       Expected, and nothing else: ReadPromptLine - one declaration, one body,
       ONE CALL.  KeysNone - one declaration, one body, one use (in
       ReadLineEdit) plus KeysDefault building on it.  PromptProfile - one
       declaration, one body, one setter pair, one read INSIDE THIS UNIT
       (ReadPromptLine's argument), and reads in the host only to print the
       table (/keys), to report the mode (/vim) and to save it - none of
       which can route a profile into a reader.  A second call to
       ReadPromptLine, or a read of PromptProfile inside ReadLineCore, is the
       thing this comment exists to make visible in a diff.

  And a third: an action is a TEditKey, so nothing a binding can name
  submits a line, answers a question, or reaches outside the buffer. }
type
  TVimMode = (vmInsert, vmNormal);

  { The eleven original verbs come first and in their original order - a
    saved profile and the tests both name them by identifier, but ekNewline
    being last is asserted elsewhere as a canary, so new verbs are APPENDED
    and never interleaved. }
  TEditKey = (ekChar, ekBackspace, ekDelete, ekLeft, ekRight, ekHome, ekEnd,
              ekHistPrev, ekHistNext, ekClear, ekNewline,
              { motions }
              ekWordRight, ekWordLeft, ekWordEnd, ekFirstNonBlank,
              { deletions }
              ekDelWordRight, ekDelWordLeft, ekDelWordEnd, ekDelToEnd,
              ekDelToStart, ekDelLine,
              { the same six, then insert mode - vim's c operator }
              ekChangeWordRight, ekChangeWordLeft, ekChangeWordEnd,
              ekChangeToEnd, ekChangeToStart, ekChangeLine,
              { mode changes }
              ekNormalMode, ekInsertHere, ekAppendHere, ekInsertStart,
              ekAppendEnd,
              { history of edits, not of commands }
              ekUndo, ekRedo);

  { One point on the edit timeline.  Only the text and the caret: the mode,
    the history position and the pending operator are where the user is, not
    what the line says, and restoring them would be surprising. }
  TEditUndo = record
    Text: WideString;
    Caret: Integer;
  end;

  TEditState = record
    Text: WideString;
    Caret: Integer;        { 0..Length(Text); characters before the cursor }
    HistPos: Integer;      { Length(History) means "the line being typed" }
    Pending: WideString;   { the typed line, stashed while browsing history }
    { Vim is a property of the profile the line was started with, not a
      global, so a line read by ReadLineEdit can never be modal. }
    Vim: Boolean;
    Mode: TVimMode;
    PendOp: WideChar;      { 'd' or 'c' awaiting its target, #0 otherwise }
    Undo: array of TEditUndo;
    UndoN: Integer;        { entries in use }
    UndoAt: Integer;       { index of the entry the current state occupies }
  end;

  { A key event reduced to what a binding may match on: the virtual-key code
    and the modifier flags.  Deliberately NOT the character the console
    synthesises - Ctrl+W arrives as VK $57 with the control flag set and also
    as UnicodeChar #23, and matching on the VK is what makes one rule cover
    both shapes. }
  TKeyChord = record
    VK: Word;
    Ctrl, Alt, Shift: Boolean;
  end;

  TBinding = record
    Chord: TKeyChord;
    Action: TEditKey;
  end;

  TKeyProfile = record
    Vim: Boolean;
    Binds: array of TBinding;
  end;

  { Supplies completion candidates for the token under the caret.  The host
    wires this to slash commands and the file system; uTerm itself stays free
    of both. }
  TCompleteProc = function(const Token: string; AtLineStart: Boolean): TStringArray;

var
  CompleteProvider: TCompleteProc = nil;

{ Starts an edit with an empty line, vim off and an empty undo stack. }
procedure EditInit(out E: TEditState);
{ The same, then takes the profile's vim setting.  Every line starts in
  INSERT mode, so a user who turned vim on and forgot types normally. }
procedure EditInitProfile(out E: TEditState; const P: TKeyProfile);
{ Applies one key.  Ch matters only for ekChar. }
procedure EditApply(var E: TEditState; Key: TEditKey; Ch: WideChar);
{ The vim normal-mode command parser: one printable character in, one verb
  out.  Returns False when the key was absorbed (an operator waiting for its
  target) or meaningless (an unbound command character, which is DISCARDED -
  in normal mode a stray key must never end up in the line).  Pure, so 'd'
  then 'w' is two calls in a test and no console anywhere. }
function EditNormalKey(var E: TEditState; Ch: WideChar;
  out Key: TEditKey): Boolean;
{ The painted lead: the vim indicator when vim is on, then the prompt on the
  first buffer line or the continuation marker on any other.  Pure, so the
  whole composition is asserted without a console - the same reason
  ModePrompt is a function. }
function EditLead(const E: TEditState; const Prompt: string;
  FirstLine: Boolean): string;
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
{ Loads history from Path, replacing what is in memory.  A missing or
  unreadable file is simply an empty history, never an error: history is a
  convenience, and a session must not fail over it. }
procedure HistoryLoad(const Path: string);
{ Writes the history to Path, newest last, capped at HistoryMax entries.
  Failures are swallowed for the same reason. }
procedure HistorySave(const Path: string);

const
  { Entries kept on disk.  Enough that Up-arrow reaches last week's build
    command, few enough that the file stays trivial. }
  HistoryMax = 200;
  { Edit states remembered per line.  A prompt line is not a document; a
    hundred steps is more than anyone unwinds by hand, and the cap is what
    stops a pathological paste-and-delete loop from growing without bound. }
  UndoMax = 100;

{ ------------------------------------------------------------- keybindings --

  Two tables, both closed: chord names and action names.  An unknown entry in
  either is REPORTED, never ignored - a binding that silently did nothing
  would be indistinguishable from one this build does not support. }

{ The empty profile: no bindings, vim off.  This is what ReadLineEdit passes,
  and it is the reason a keys.json cannot reach the permission prompt. }
function KeysNone: TKeyProfile;
{ The built-in bindings, which a file overrides entry by entry.  These are
  the readline verbs the editor has always lacked. }
function KeysDefault: TKeyProfile;
{ Parses a keys.json document.  Takes BYTES, never a path: uTerm reads
  nothing from disk but the history file, and the host is what knows where
  configuration lives.  Returns False for an unusable document, in which case
  P is KeysDefault - a broken file must never widen or narrow anything.
  Notes is every entry that was refused, one line each, for the caller to
  print; the caller owns and frees it. }
function KeysParse(const Text: string; out P: TKeyProfile;
  out Notes: TStringArray): Boolean;
{ Rewrites Existing with P's vim flag, preserving every other field in place.
  Read-modify-write rather than a rebuild, because keys.json is hand-authored
  and /vim save must not reorder or drop what the user wrote. }
function KeysToJson(const P: TKeyProfile; const Existing: string): string;

function KeyActionName(K: TEditKey): string;
function KeyActionOf(const Name: string; out K: TEditKey): Boolean;
function KeyChordName(const C: TKeyChord): string;
{ Parses '[ctrl+][alt+][shift+]base'.  A bare character is REFUSED with Why
  naming the missing modifier: that refusal is the wall that keeps y, a and n
  unbindable no matter what else goes wrong. }
function KeyChordOf(const Name: string; out C: TKeyChord;
  out Why: string): Boolean;
{ Chords the editor owns outright: Ctrl+C, Enter (in every modifier
  combination), Tab and Escape.  Nothing may take them, because each one is
  how a user gets out of something. }
function KeyChordReserved(const C: TKeyChord): Boolean;

{ Pure key-event to verb decision, matched on VK and modifiers alone.  False
  when no binding matches, leaving the caller's fixed handling in charge. }
function DecodeKey(const P: TKeyProfile; const E: TEditState; VK: Word;
  Ctrl, Alt, Shift: Boolean; Ch: WideChar; out Key: TEditKey): Boolean;

{ The one install seam.  PromptProfile is read in exactly one expression in
  the program - ReadPromptLine's argument - and a grep is the audit. }
procedure SetPromptProfile(const P: TKeyProfile);
procedure SetPromptVim(Enabled: Boolean);
function PromptProfile: TKeyProfile;

{ The REPL's reader, and the ONLY caller of the profile.  Everything else in
  the program keeps ReadLineEdit, whose signature and behaviour are unchanged
  by any of this.  This is also the only reader that draws the framed block
  described above; on a console that refused VT it is the plain line, and
  nothing above this comment changes. }
function ReadPromptLine(const Prompt: string; out Line: string): Boolean;

{ The visual rows the framed prompt breaks Text into at InnerW columns, and
  where in them the caret sits.  Rows come back as UTF-8, without the lead
  or the frame - this is the wrapping alone.

  Exposed for the same reason the editor's own decisions are: a wrap that
  loses a character, or a caret that lands one row from where the user's eye
  is, is invisible in review and obvious in use, and neither can be argued
  about against a console.  Row and column are both zero-based. }
function PromptRows(const Text: WideString; InnerW, Caret: Integer;
  out CaretRow, CaretCol: Integer): TStringArray;

implementation

{ uJson is the bottom of the unit ladder and depends on nothing, so using it
  here breaks no rule - but it is the first thing beyond the RTL that uTerm
  has needed, and the reason is narrow: keys.json is JSON, and a second
  parser in this program would be a liability.  KeysParse takes a string, so
  uTerm still opens no file but the history. }
uses Windows, Classes, uJson;

var
  HOut: HANDLE = 0;
  HIn: HANDLE = 0;
  SavedAttr: Word = 7;
  SavedCP: UINT = 0;
  SavedInCP: UINT = 0;
  { Written from the console control thread, read from the main one; a
    Boolean write is atomic on every target this builds for. }
  CtrlCFlag: Boolean = False;
  VtActive: Boolean = False;
  SavedOutMode: DWORD = 0;

const
  ENABLE_VIRTUAL_TERMINAL_PROCESSING = $0004;

function TermVtActive: Boolean;
begin
  Result := VtActive;
end;

{ The 8 bright ANSI foregrounds cover the palette exactly; clWhite is the
  one non-intense entry.  Escape sequences render italic-capable, truecolor
  terminals correctly where legacy attributes flatten them. }
function VtSeq(C: TColor): string;
begin
  if not VtActive then Exit('');
  case C of
    clGrey:    Result := #27'[90m';
    clWhite:   Result := #27'[37m';
    clBright:  Result := #27'[97m';
    clCyan:    Result := #27'[96m';
    clGreen:   Result := #27'[92m';
    clYellow:  Result := #27'[93m';
    clRed:     Result := #27'[91m';
    clMagenta: Result := #27'[95m';
    clBlue:    Result := #27'[94m';
    { The amber ramp.  Truecolor, because the whole point of these four is
      the distance between them and a palette that has one yellow cannot
      express it.  A terminal that advertises VT but only has 256 colours
      quantises these itself, and lands somewhere in the same family. }
    clAmberLt:  Result := #27'[38;2;255;203;139m';   { highlights }
    clAmber:    Result := #27'[38;2;255;169;64m';    { the accent }
    clAmberDim: Result := #27'[38;2;191;122;38m';    { borders }
    clAmberDk:  Result := #27'[38;2;122;80;34m';     { rules, meter troughs }
  else
    Result := '';
  end;
end;

function VtReset: string;
begin
  if VtActive then Result := #27'[0m' else Result := '';
end;

procedure RawWrite(const S: string); forward;

function HandleConsoleBreak(CtrlType: LongWord): LongBool; stdcall;
begin
  { Only Ctrl+C is turned into a cancel; Ctrl+Break and a closing window
    keep their default meaning, because a user reaching for those wants the
    process gone, not the reply stopped. }
  if CtrlType = CTRL_C_EVENT then
  begin
    CtrlCFlag := True;
    Result := True;
  end
  else
    Result := False;
end;

function CtrlCPressed: Boolean;
begin
  Result := CtrlCFlag;
  CtrlCFlag := False;
end;

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
    { Sixteen colours have one amber between them, so the ramp collapses:
      the two bright ends onto intense yellow, the two dark ones onto the
      dim pair that reads as "structure, not text".  The banner loses its
      shading and keeps its shape. }
    clAmberLt, clAmber:
      Result := FOREGROUND_RED or FOREGROUND_GREEN or FOREGROUND_INTENSITY;
    clAmberDim: Result := FOREGROUND_RED or FOREGROUND_GREEN;
    clAmberDk:  Result := FOREGROUND_INTENSITY;
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
  SetConsoleCtrlHandler(@HandleConsoleBreak, True);
  { Ask for VT processing; a console that refuses (an old conhost) simply
    leaves the attribute path in use.  The mode is restored at exit because
    the flag is process-wide on shared consoles. }
  VtActive := False;
  if (HOut <> 0) and GetConsoleMode(HOut, SavedOutMode) then
    if SetConsoleMode(HOut, SavedOutMode or ENABLE_VIRTUAL_TERMINAL_PROCESSING) then
      VtActive := True;
end;

procedure TermDone;
begin
  SetConsoleCtrlHandler(@HandleConsoleBreak, False);
  if VtActive and (HOut <> 0) then
  begin
    RawWrite(VtReset);
    SetConsoleMode(HOut, SavedOutMode);
    VtActive := False;
  end;
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
  if VtActive then
    { One write instead of three round trips; on a VT console the colour
      travels inside the text. }
    RawWrite(VtSeq(C) + S + VtReset)
  else
  begin
    if HOut <> 0 then SetConsoleTextAttribute(HOut, Attr(C));
    RawWrite(S);
    if HOut <> 0 then SetConsoleTextAttribute(HOut, SavedAttr);
  end;
end;

procedure EmitCLn(C: TColor; const S: string);
begin
  EmitC(C, S + sLineBreak);
end;

{ The logo block: bright white on the logo's blue.  On a VT console the
  24-bit background matches the source image (royal blue); legacy consoles
  get the nearest attribute pair. }
procedure EmitLogo(const S: string);
begin
  if VtActive then
    RawWrite(#27'[48;2;41;82;209m'#27'[97m' + S + #27'[0m')
  else
  begin
    if HOut <> 0 then
      SetConsoleTextAttribute(HOut,
        BACKGROUND_BLUE or
        FOREGROUND_RED or FOREGROUND_GREEN or FOREGROUND_BLUE or
        FOREGROUND_INTENSITY);
    RawWrite(S);
    if HOut <> 0 then SetConsoleTextAttribute(HOut, SavedAttr);
  end;
end;

{ ------------------------------------------------------------- the chrome -- }

var
  GlyphMode: TUiGlyphs = ugAuto;

procedure UiSetGlyphs(G: TUiGlyphs);
begin
  GlyphMode := G;
end;

function UiGlyphs: TUiGlyphs;
begin
  Result := GlyphMode;
end;

function UiFancy: Boolean;
begin
  case GlyphMode of
    ugAscii:   Result := False;
    ugUnicode: Result := True;
  else
    Result := VtActive;
  end;
end;

{ A byte starts a character unless it is a UTF-8 continuation byte, which is
  the whole of the width rule for the single-width text this draws. }
function IsLead(B: Byte): Boolean;
begin
  Result := (B and $C0) <> $80;
end;

function UiWidth(const S: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] = #1 then
    begin
      { A mark is two bytes and zero columns.  A trailing #1 with nothing
        after it is a caller's bug; it is skipped rather than counted, so a
        truncated row cannot make the padding negative. }
      Inc(I, 2);
      Continue;
    end;
    if IsLead(Byte(S[I])) then Inc(Result);
    Inc(I);
  end;
end;

function UiPlain(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] = #1 then
    begin
      Inc(I, 2);
      Continue;
    end;
    Result := Result + S[I];
    Inc(I);
  end;
end;

function UiRepeat(const Glyph: string; N: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to N do Result := Result + Glyph;
end;

function UiPad(const S: string; W: Integer): string;
begin
  Result := S + UiRepeat(' ', W - UiWidth(S));
end;

function UiFit(const S: string; W: Integer): string;
var
  I, Col: Integer;
begin
  if W <= 0 then Exit('');
  if UiWidth(S) <= W then Exit(S);
  { One column is given back to the ellipsis, so a fitted string is at most
    W wide including the mark that it was cut. }
  Result := '';
  Col := 0;
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] = #1 then
    begin
      { Marks are copied through without costing a column: a truncated row
        that dropped its colour marks would leak the last colour onto
        everything painted after it. }
      Result := Result + Copy(S, I, 2);
      Inc(I, 2);
      Continue;
    end;
    if IsLead(Byte(S[I])) then
    begin
      if Col >= W - 1 then Break;
      Inc(Col);
    end;
    Result := Result + S[I];
    Inc(I);
  end;
  if UiFancy then Result := Result + #$E2#$80#$A6 else Result := Result + '.';
end;

function UiCentre(const S: string; W: Integer): string;
var
  Left: Integer;
begin
  Left := (W - UiWidth(S)) div 2;
  if Left < 0 then Left := 0;
  Result := UiRepeat(' ', Left) + S;
end;

type
  { What WalkMarks hands each run to. }
  TMarkSink = procedure(const Run: string; Col: TColor; Coloured: Boolean);

function MarkColor(C: Char; out Col: TColor): Boolean;
begin
  Result := True;
  case C of
    'g': Col := clGrey;
    'w': Col := clWhite;
    'B': Col := clBright;
    'c': Col := clCyan;
    'G': Col := clGreen;
    'y': Col := clYellow;
    'r': Col := clRed;
    'L': Col := clAmberLt;
    'A': Col := clAmber;
    'D': Col := clAmberDim;
    'K': Col := clAmberDk;
  else
    Col := clWhite;
    Result := False;    { '0', and anything unknown, means "no colour" }
  end;
end;

{ The one walk over the marks, shared by both painters.  Each run is handed
  to Run with the colour in force, or with Coloured false where the string
  asked for the terminal's own foreground. }
procedure WalkMarks(const S: string; Sink: TMarkSink);
var
  I, Start: Integer;
  Col: TColor;
  Coloured: Boolean;

  procedure FlushRun(Upto: Integer);
  begin
    if Upto < Start then Exit;
    if Upto = Start - 1 then Exit;
    Sink(Copy(S, Start, Upto - Start + 1), Col, Coloured);
  end;

begin
  Coloured := False;
  Col := clWhite;
  Start := 1;
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] = #1 then
    begin
      FlushRun(I - 1);
      if I + 1 <= Length(S) then
        Coloured := MarkColor(S[I + 1], Col)
      else
        Coloured := False;
      Inc(I, 2);
      Start := I;
      Continue;
    end;
    Inc(I);
  end;
  FlushRun(Length(S));
end;

var
  { WalkMarks hands its runs to a closure-free callback, so the two painters
    each keep one module-level accumulator.  Neither is re-entrant, and
    neither needs to be: both are called from the one thread that owns the
    console. }
  VtBuf: string = '';

procedure VtSink(const Run: string; Col: TColor; Coloured: Boolean);
begin
  if Coloured then VtBuf := VtBuf + VtSeq(Col) + Run + VtReset
  else VtBuf := VtBuf + Run;
end;

procedure PaintSink(const Run: string; Col: TColor; Coloured: Boolean);
begin
  if Coloured then EmitC(Col, Run) else Emit(Run);
end;

function UiVt(const S: string): string;
begin
  if not VtActive then Exit('');
  VtBuf := '';
  WalkMarks(S, @VtSink);
  Result := VtBuf;
  VtBuf := '';
end;

procedure UiPaint(const S: string);
begin
  { One write on a VT console, a call per run on a legacy one - where the
    colour IS a call and there is no way around it. }
  if VtActive then
    RawWrite(UiVt(S))
  else
    WalkMarks(S, @PaintSink);
end;

procedure UiPaintLn(const S: string);
begin
  UiPaint(S);
  EmitLn;
end;

function UiRule(Cells: Integer): string;
begin
  if UiFancy then
    Result := UiRepeat(#$E2#$94#$80, Cells)     { U+2500 }
  else
    Result := UiRepeat('-', Cells);
end;

function UiMeter(Pct, Cells: Integer; Fill, Trough: TColor): string;
var
  Lit: Integer;
  Block: string;
  FillMark, TroughMark: string;

  function MarkOf(C: TColor): string;
  begin
    case C of
      clGrey:     Result := MkGrey;
      clWhite:    Result := MkWhite;
      clBright:   Result := MkBright;
      clCyan:     Result := MkCyan;
      clGreen:    Result := MkGreen;
      clYellow:   Result := MkYellow;
      clRed:      Result := MkRed;
      clAmberLt:  Result := MkAmberLt;
      clAmber:    Result := MkAmber;
      clAmberDim: Result := MkAmberDim;
      clAmberDk:  Result := MkAmberDk;
    else
      Result := MkOff;
    end;
  end;

begin
  if Cells < 1 then Exit('');
  if Pct < 0 then Pct := 0;
  if Pct > 100 then Pct := 100;
  Lit := (Pct * Cells) div 100;
  { A percentage that has moved off zero lights a cell.  The rounding this
    breaks is worth less than the signal: the first thing a user wants from
    a context meter is to see it start. }
  if (Lit = 0) and (Pct > 0) then Lit := 1;
  if Lit > Cells then Lit := Cells;
  if UiFancy then Block := #$E2#$96#$88 else Block := '=';   { U+2588 }
  FillMark := MarkOf(Fill);
  TroughMark := MarkOf(Trough);
  Result := FillMark + UiRepeat(Block, Lit) +
            TroughMark + UiRepeat(Block, Cells - Lit) + MkOff;
end;

function UiCount(N: Int64): string;
begin
  if N < 0 then Exit('0');
  if N < 1000 then Exit(IntToStr(N));
  if N < 1000000 then
    Exit(Format('%.1fk', [N / 1000]));
  Result := Format('%.1fM', [N / 1000000]);
end;

{ The four rounded corners and the two bars, or ASCII where the console
  cannot be trusted with them.  Kept together so the fallback set is
  obviously complete rather than six scattered ifs. }
function GlyphTL: string; begin if UiFancy then Result := #$E2#$95#$AD else Result := '.'; end;
function GlyphTR: string; begin if UiFancy then Result := #$E2#$95#$AE else Result := '.'; end;
function GlyphBL: string; begin if UiFancy then Result := #$E2#$95#$B0 else Result := '`'; end;
function GlyphBR: string; begin if UiFancy then Result := #$E2#$95#$AF else Result := #39;  end;
function GlyphV: string;  begin if UiFancy then Result := #$E2#$94#$82 else Result := '|'; end;

function UiBoxInner(Width, Columns: Integer): Integer;
begin
  { Two border bars, one separator per extra column, and a space on each
    side of every column. }
  Result := Width - (3 * Columns + 1);
  if Result < 0 then Result := 0;
end;

function UiBoxTop(const Title: string; Width: Integer): string;
var
  Rest: Integer;
begin
  if Title = '' then
  begin
    Result := MkAmberDim + GlyphTL + UiRule(Width - 2) + GlyphTR + MkOff;
    Exit;
  end;
  Rest := Width - 5 - UiWidth(Title);
  if Rest < 0 then Rest := 0;
  Result := MkAmberDim + GlyphTL + UiRule(1) + ' ' +
            Title + MkAmberDim + ' ' + UiRule(Rest) + GlyphTR + MkOff;
end;

function UiBoxBottom(Width: Integer): string;
begin
  Result := MkAmberDim + GlyphBL + UiRule(Width - 2) + GlyphBR + MkOff;
end;

function UiBoxRow(const Cells: array of string;
  const Widths: array of Integer): string;
var
  I, W: Integer;
begin
  Result := MkAmberDim + GlyphV + MkOff + ' ';
  for I := 0 to High(Cells) do
  begin
    if I > 0 then Result := Result + MkAmberDim + GlyphV + MkOff + ' ';
    if I <= High(Widths) then W := Widths[I] else W := 0;
    Result := Result + UiPad(UiFit(Cells[I], W), W) + ' ';
  end;
  Result := Result + MkAmberDim + GlyphV + MkOff;
end;

{ ---------------------------------------------------------- the statusline -- }

var
  Status: TStatusInfo;

procedure StatusClear(out S: TStatusInfo);
begin
  S.Model := '';
  S.Dir := '';
  S.Branch := '';
  S.CtxTokens := 0;
  S.CtxLimit := 0;
  S.TokensIn := 0;
  S.TokensOut := 0;
  S.Memories := -1;
  S.Mcps := -1;
  S.Hooks := -1;
  S.Mode := '';
  S.ModeHot := False;
  S.Note := '';
end;

procedure SetStatus(const S: TStatusInfo);
begin
  Status := S;
end;

{ 'thing' or 'things', so a line can say "1 hook" without saying "1 hooks". }
function Plural(N: Integer; const One, Many: string): string;
begin
  if N = 1 then Result := IntToStr(N) + ' ' + One
  else Result := IntToStr(N) + ' ' + Many;
end;

function StatusLines(const S: TStatusInfo; Width: Integer): TStringArray;
var
  Row, Sep, Facts: string;
  Pct: Integer;

  procedure Add(const Line: string);
  begin
    if Trim(UiPlain(Line)) = '' then Exit;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := UiFit(Line, Width);
  end;

begin
  Result := nil;
  if Width < 12 then Exit;
  if UiFancy then Sep := MkAmberDk + ' ' + #$E2#$94#$82 + ' ' else Sep := MkAmberDk + ' | ';

  { Line one: who is answering and where.  The two facts a user checks
    before typing, and the two that are wrong most expensively. }
  Row := '';
  if S.Model <> '' then Row := MkCyan + '[' + S.Model + ']';
  if S.Dir <> '' then
  begin
    if Row <> '' then Row := Row + Sep;
    Row := Row + MkAmberLt + S.Dir;
  end;
  if S.Branch <> '' then
    Row := Row + MkGrey + ' git:(' + MkAmber + S.Branch + MkGrey + ')';
  Add(Row + MkOff);

  { Line two: the meters.  Context first, because it is the one that ends
    the session when it fills. }
  Row := '';
  if S.CtxLimit > 0 then
  begin
    Pct := Round((S.CtxTokens * 100) / S.CtxLimit);
    Row := MkGrey + 'Context ' +
           UiMeter(Pct, 12, clAmber, clAmberDk) + ' ' +
           MkAmberLt + IntToStr(Pct) + '%' +
           MkGrey + ' (' + UiCount(S.CtxTokens) + ')';
  end;
  if (S.TokensIn > 0) or (S.TokensOut > 0) then
  begin
    if Row <> '' then Row := Row + Sep;
    Row := Row + MkGrey + 'Session ' + MkAmberLt + UiCount(S.TokensIn) +
           MkGrey + ' in ' + MkAmberLt + UiCount(S.TokensOut) + MkGrey + ' out';
  end;
  Add(Row + MkOff);

  { Line three: what was loaded.  Nothing here changes during a session, so
    it is the line a reader stops noticing - which is why it is last of the
    three and why a zero is omitted rather than shown. }
  Facts := '';
  if S.Memories > 0 then Facts := Plural(S.Memories, 'CLAUDE.md', 'CLAUDE.md');
  if S.Mcps > 0 then
  begin
    if Facts <> '' then Facts := Facts + Sep + MkGrey;
    Facts := Facts + Plural(S.Mcps, 'MCP', 'MCPs');
  end;
  if S.Hooks > 0 then
  begin
    if Facts <> '' then Facts := Facts + Sep + MkGrey;
    Facts := Facts + Plural(S.Hooks, 'hook', 'hooks');
  end;
  if Facts <> '' then Add(MkGrey + Facts + MkOff);

  { The mode, last and loudest.  It is the line that says what will happen
    without being asked, so it is the one that must survive a narrow
    terminal - hence last, where nothing pushes it off.

    The caller sets Mode to '' for the ordinary ask-me state.  An indicator
    that is always on is not an indicator, and the prompt has always taken
    that view; the status line takes it too. }
  if S.Mode <> '' then
  begin
    if S.ModeHot then
    begin
      if UiFancy then Row := MkRed + #$E2#$96#$B8#$E2#$96#$B8 + ' '
      else Row := MkRed + '>> ';
      Row := Row + S.Mode + MkGrey + '  (/mode to change)';
    end
    else
      Row := MkAmberDim + S.Mode + MkGrey + '  (/mode to change)';
    Add(Row + MkOff);
  end;

  if S.Note <> '' then Add(S.Note + MkOff);
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

{ GetConsoleMode succeeds only on a real console handle; a pipe or a file
  refuses it, which is exactly the distinction wanted. }
function StdinIsConsole: Boolean;
var
  M: DWORD;
begin
  Result := (HIn <> 0) and GetConsoleMode(HIn, M);
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

{ One command per line.  A multi-line prompt (pasted block, Ctrl+Enter) is
  stored with backslash escapes - \\ for a backslash, \n for a newline -
  because the file format is line-oriented and a bare newline would split
  one command into several. }

function HistEscape(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    case S[I] of
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
      #13: ;   { CR never re-enters; the editor stores bare newlines }
    else
      Result := Result + S[I];
    end;
end;

function HistUnescape(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '\') and (I < Length(S)) then
    begin
      case S[I + 1] of
        '\': Result := Result + '\';
        'n': Result := Result + #10;
      else
        { An escape this build does not know passes through untouched,
          which errs on the side of showing the user their own text. }
        Result := Result + Copy(S, I, 2);
      end;
      Inc(I, 2);
    end
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
  end;
end;

procedure HistoryLoad(const Path: string);
var
  L: TStringList;
  I, N: Integer;
  S: string;
begin
  SetLength(History, 0);
  if not FileExists(Path) then Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
    except
      Exit;
    end;
    N := 0;
    for I := 0 to L.Count - 1 do
    begin
      S := HistUnescape(L[I]);
      if Trim(S) = '' then Continue;
      SetLength(History, N + 1);
      History[N] := S;
      Inc(N);
    end;
  finally
    L.Free;
  end;
end;

procedure HistorySave(const Path: string);
var
  L: TStringList;
  I, First: Integer;
begin
  L := TStringList.Create;
  try
    First := 0;
    if Length(History) > HistoryMax then
      First := Length(History) - HistoryMax;
    for I := First to High(History) do
      L.Add(HistEscape(History[I]));
    try
      L.SaveToFile(Path);
    except
      { A read-only directory or a full disk is not worth a message: the
        session works identically without persistent history. }
    end;
  finally
    L.Free;
  end;
end;

procedure EditInit(out E: TEditState);
begin
  E.Text := '';
  E.Caret := 0;
  E.HistPos := Length(History);
  E.Pending := '';
  E.Vim := False;
  E.Mode := vmInsert;
  E.PendOp := #0;
  SetLength(E.Undo, 0);
  E.UndoN := 0;
  E.UndoAt := 0;
end;

procedure EditInitProfile(out E: TEditState; const P: TKeyProfile);
begin
  EditInit(E);
  { Insert mode every time, deliberately.  A prompt that came back in normal
    mode would eat the first word of anyone who had forgotten vim was on, and
    unlike a file there is nothing on screen to make the mode obvious before
    the first keystroke. }
  E.Vim := P.Vim;
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

{ ----------------------------------------------------------- word motions --

  One rule, defined once, used by every w/b/e verb and by Ctrl+W.  A word is
  a run of letters, digits and underscore, or a run of punctuation; blanks
  separate them.  Anything above #127 counts as a word character rather than
  punctuation: a path with an accent or a line of CJK would otherwise
  fragment into one "word" per character, which is worse than wrong - it is
  slow to recover from. }
type
  TWordClass = (wcBlank, wcWord, wcPunct);

function ClassOf(C: WideChar): TWordClass;
begin
  if (C = ' ') or (C = #9) or (C = #10) or (C = #13) then
    Result := wcBlank
  else if ((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) or
          ((C >= '0') and (C <= '9')) or (C = '_') or (C > #127) then
    Result := wcWord
  else
    Result := wcPunct;
end;

{ All four take and return 0-based caret positions (the number of characters
  before the cursor), which is what TEditState.Caret holds; the strings
  themselves are 1-based, hence the +1 on every index. }

function WordFwd(const W: WideString; P: Integer): Integer;
var
  C: TWordClass;
begin
  Result := P;
  if Result >= Length(W) then Exit(Length(W));
  C := ClassOf(W[Result + 1]);
  if C <> wcBlank then
    while (Result < Length(W)) and (ClassOf(W[Result + 1]) = C) do Inc(Result);
  while (Result < Length(W)) and (ClassOf(W[Result + 1]) = wcBlank) do Inc(Result);
end;

function WordBack(const W: WideString; P: Integer): Integer;
var
  C: TWordClass;
begin
  Result := P;
  while (Result > 0) and (ClassOf(W[Result]) = wcBlank) do Dec(Result);
  if Result = 0 then Exit(0);
  C := ClassOf(W[Result]);
  while (Result > 0) and (ClassOf(W[Result]) = C) do Dec(Result);
end;

{ The position of the LAST character of the next word, not the one after it -
  that is what makes 'e' distinct from 'w', and getting it wrong by one is
  the first thing a vim user notices. }
function WordEndFwd(const W: WideString; P: Integer): Integer;
begin
  Result := P + 1;
  if Result >= Length(W) then
  begin
    { The last character of an EMPTY line is 0, not -1.  The two clamps at the
      bottom of this function never run on this path, so the arithmetic has to
      be right here: a caret of -1 escapes into VimClamp and Redraw, both of
      which index W[Caret + 1] and so read W[0] - a nil dereference on an empty
      WideString, and a process death that skips TermDone and leaves the
      console in raw mode. }
    Result := Length(W) - 1;
    if Result < 0 then Result := 0;
    Exit;
  end;
  while (Result < Length(W)) and (ClassOf(W[Result + 1]) = wcBlank) do Inc(Result);
  while (Result < Length(W) - 1) and
        (ClassOf(W[Result + 2]) = ClassOf(W[Result + 1])) do Inc(Result);
  if Result > Length(W) - 1 then Result := Length(W) - 1;
  if Result < 0 then Result := 0;
end;

{ The newline-bounded run the caret sits in - the same span Redraw paints, so
  0, ^ and $ mean what the user can see rather than what the whole buffer
  happens to contain after a paste. }
function SegStart(const W: WideString; P: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := P downto 1 do
    if W[I] = #10 then Exit(I);
end;

function SegEnd(const W: WideString; P: Integer): Integer;
var
  I, From: Integer;
begin
  Result := Length(W);
  { The scan starts at P + 1, so a caret of -1 would index W[0] - outside a
    WideString, and a nil dereference when the string is empty.  Callers are
    supposed to hand over a caret in range; this clamp is the belt to that
    braces, because the cost of being wrong here is the whole process. }
  From := P + 1;
  if From < 1 then From := 1;
  for I := From to Length(W) do
    if W[I] = #10 then Exit(I - 1);
end;

function FirstNonBlank(const W: WideString; P: Integer): Integer;
var
  E: Integer;
begin
  Result := SegStart(W, P);
  E := SegEnd(W, P);
  while (Result < E) and (ClassOf(W[Result + 1]) = wcBlank) do Inc(Result);
end;

{ In normal mode the caret sits ON a character, not between two, which is
  what keeps i and a distinct, makes x delete under the cursor, and makes
  Esc's step left correct.  One clamp, applied after every normal-mode verb. }
procedure VimClamp(var E: TEditState);
var
  S, F: Integer;
begin
  if not (E.Vim and (E.Mode = vmNormal)) then Exit;
  S := SegStart(E.Text, E.Caret);
  F := SegEnd(E.Text, E.Caret);
  if E.Caret > F - 1 then E.Caret := F - 1;
  if E.Caret < S then E.Caret := S;
  if E.Caret < 0 then E.Caret := 0;
end;

{ ------------------------------------------------------------------ undo --

  The array is a timeline of states and UndoAt is where the current state
  sits on it.  E itself is the live copy, so it is written back into
  Undo[UndoAt] before anything moves - that resynchronisation is what lets a
  whole insert session (which pushes nothing per character) collapse into the
  single step a vim user expects. }

procedure UndoSync(var E: TEditState);
begin
  if E.UndoN = 0 then
  begin
    if Length(E.Undo) < 1 then SetLength(E.Undo, 8);
    E.UndoAt := 0;
    E.UndoN := 1;
  end;
  E.Undo[E.UndoAt].Text := E.Text;
  E.Undo[E.UndoAt].Caret := E.Caret;
end;

procedure UndoPush(var E: TEditState);
var
  I: Integer;
begin
  UndoSync(E);
  { A fresh edit discards whatever redo tail was there: the timeline forks
    and the abandoned branch is not worth the confusion of keeping. }
  Inc(E.UndoAt);
  E.UndoN := E.UndoAt + 1;
  if Length(E.Undo) < E.UndoN then SetLength(E.Undo, E.UndoN + 8);
  E.Undo[E.UndoAt] := E.Undo[E.UndoAt - 1];
  if E.UndoN > UndoMax then
  begin
    for I := 1 to E.UndoN - 1 do E.Undo[I - 1] := E.Undo[I];
    Dec(E.UndoAt);
    Dec(E.UndoN);
    E.Undo[E.UndoN].Text := '';
  end;
end;

procedure UndoStep(var E: TEditState; Delta: Integer);
var
  T: Integer;
begin
  UndoSync(E);
  T := E.UndoAt + Delta;
  if (T < 0) or (T >= E.UndoN) then Exit;
  E.UndoAt := T;
  E.Text := E.Undo[T].Text;
  E.Caret := E.Undo[T].Caret;
end;

{ Which verbs are worth a step of their own.  Not ekChar: per-character undo
  is the complaint every vim user has about editors that do it.  Single
  deletes earn one only in normal mode, where they are x rather than the
  Delete key held down. }
function UndoWorthy(const E: TEditState; Key: TEditKey): Boolean;
begin
  case Key of
    ekClear, ekDelWordRight, ekDelWordLeft, ekDelWordEnd, ekDelToEnd,
    ekDelToStart, ekDelLine, ekChangeWordRight, ekChangeWordLeft,
    ekChangeWordEnd, ekChangeToEnd, ekChangeToStart, ekChangeLine,
    ekInsertHere, ekAppendHere, ekInsertStart, ekAppendEnd:
      Result := True;
    ekDelete, ekBackspace:
      Result := E.Vim and (E.Mode = vmNormal);
  else
    Result := False;
  end;
end;

{ Removes [A, B) and parks the caret at A.  Every delete and change verb is
  this plus a span, which is why they cannot disagree about the caret. }
procedure CutSpan(var E: TEditState; A, B: Integer);
begin
  if A < 0 then A := 0;
  if B > Length(E.Text) then B := Length(E.Text);
  if B <= A then
  begin
    E.Caret := A;
    Exit;
  end;
  Delete(E.Text, A + 1, B - A);
  E.Caret := A;
end;

procedure EditApply(var E: TEditState; Key: TEditKey; Ch: WideChar);
var
  Target: Integer;
begin
  if UndoWorthy(E, Key) then UndoPush(E);
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
      { With vim on, 0 and Ctrl+A mean the start of the line the user can
        see; without it, the historical whole-buffer behaviour is kept
        exactly, because four other prompts depend on it. }
      if E.Vim then E.Caret := SegStart(E.Text, E.Caret) else E.Caret := 0;
    ekEnd:
      if E.Vim then E.Caret := SegEnd(E.Text, E.Caret)
               else E.Caret := Length(E.Text);
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
      if Length(History) > 0 then
      begin
        { The half-typed line is stashed on the way out so that browsing up
          and back down returns it rather than losing it. }
        if E.HistPos = Length(History) then E.Pending := E.Text;
        if Key = ekHistPrev then Target := E.HistPos - 1
                            else Target := E.HistPos + 1;
        if Target < 0 then Target := 0;
        if Target > Length(History) then Target := Length(History);
        if Target <> E.HistPos then
        begin
          E.HistPos := Target;
          if E.HistPos = Length(History) then
            E.Text := E.Pending
          else
            E.Text := UTF8Decode(History[E.HistPos]);
          E.Caret := Length(E.Text);
        end;
      end;

    { ---- motions.  These move the caret and nothing else. ---- }
    ekWordRight:     E.Caret := WordFwd(E.Text, E.Caret);
    ekWordLeft:      E.Caret := WordBack(E.Text, E.Caret);
    ekWordEnd:       E.Caret := WordEndFwd(E.Text, E.Caret);
    ekFirstNonBlank: E.Caret := FirstNonBlank(E.Text, E.Caret);

    { ---- deletions.  Each is the span its matching motion covers. ---- }
    ekDelWordRight, ekChangeWordRight:
      CutSpan(E, E.Caret, WordFwd(E.Text, E.Caret));
    ekDelWordLeft, ekChangeWordLeft:
      CutSpan(E, WordBack(E.Text, E.Caret), E.Caret);
    ekDelWordEnd, ekChangeWordEnd:
      CutSpan(E, E.Caret, WordEndFwd(E.Text, E.Caret) + 1);
    ekDelToEnd, ekChangeToEnd:
      CutSpan(E, E.Caret, SegEnd(E.Text, E.Caret));
    ekDelToStart, ekChangeToStart:
      CutSpan(E, SegStart(E.Text, E.Caret), E.Caret);
    ekDelLine, ekChangeLine:
      CutSpan(E, SegStart(E.Text, E.Caret), SegEnd(E.Text, E.Caret));

    { ---- mode changes ---- }
    ekNormalMode:
      begin
        E.Mode := vmNormal;
        E.PendOp := #0;
        { Leaving insert steps left, because the caret was after the last
          character typed and normal mode sits on one. }
        if E.Caret > SegStart(E.Text, E.Caret) then Dec(E.Caret);
      end;
    ekInsertHere:
      E.Mode := vmInsert;
    ekAppendHere:
      begin
        E.Mode := vmInsert;
        if E.Caret < Length(E.Text) then Inc(E.Caret);
      end;
    ekInsertStart:
      begin
        E.Mode := vmInsert;
        E.Caret := FirstNonBlank(E.Text, E.Caret);
      end;
    ekAppendEnd:
      begin
        E.Mode := vmInsert;
        E.Caret := SegEnd(E.Text, E.Caret);
      end;

    ekUndo: UndoStep(E, -1);
    ekRedo: UndoStep(E, 1);
  end;

  { The change verbs are their deletion plus insert mode; sharing the arm
    above means the two can never disagree about what was removed. }
  case Key of
    ekChangeWordRight, ekChangeWordLeft, ekChangeWordEnd, ekChangeToEnd,
    ekChangeToStart, ekChangeLine:
      E.Mode := vmInsert;
  end;

  VimClamp(E);
end;

{ ---------------------------------------------------- vim normal mode -----

  What is here: two modes, the motions h l w b e 0 ^ $, j/k as history, the
  entries i a I A, the edits x D C S dd cc dw db de d0 d$ cw cb ce c0 c$, and
  undo/redo.

  What is deliberately NOT here: visual mode, registers, yank and put (dw
  therefore deletes into nothing - there is nowhere to put it), counts (3dw),
  the . repeat, marks, macros, : commands, / and ? search, text objects
  (ciw, di"), r R s, o O, gg G and %.  A prompt is one line: there is no
  buffer to write, no next line for o to open, and j/k are worth far more as
  history than as line motion.  What one line does NOT remove is the need for
  undo, for w/b/e over a long path, and for 0/^/$ - a pasted block puts
  newlines in the buffer, so those three are defined against the segment the
  screen is actually showing. }
function EditNormalKey(var E: TEditState; Ch: WideChar;
  out Key: TEditKey): Boolean;
var
  Op: WideChar;
begin
  Key := ekChar;
  Result := False;

  if E.PendOp <> #0 then
  begin
    Op := E.PendOp;
    { Cleared whatever happens next: an operator that survived an invalid
      target would fire on the following keystroke, which is the kind of bug
      that deletes a word the user was only trying to move over. }
    E.PendOp := #0;
    if Op = 'd' then
      case Ch of
        'w': Key := ekDelWordRight;
        'b': Key := ekDelWordLeft;
        'e': Key := ekDelWordEnd;
        '0': Key := ekDelToStart;
        '$': Key := ekDelToEnd;
        'd': Key := ekDelLine;
      else
        Exit(False);
      end
    else
      case Ch of
        { cw is ce in vim - it changes to the end of the word rather than to
          the start of the next, and every vim user has that in their
          fingers.  Matching the editor rather than the symmetry. }
        'w', 'e': Key := ekChangeWordEnd;
        'b': Key := ekChangeWordLeft;
        '0': Key := ekChangeToStart;
        '$': Key := ekChangeToEnd;
        'c': Key := ekChangeLine;
      else
        Exit(False);
      end;
    Exit(True);
  end;

  case Ch of
    'h': Key := ekLeft;
    'l': Key := ekRight;
    'w': Key := ekWordRight;
    'b': Key := ekWordLeft;
    'e': Key := ekWordEnd;
    '0': Key := ekHome;
    '^': Key := ekFirstNonBlank;
    '$': Key := ekEnd;
    { The one-line adaptation: there is no line below to move to, and
      up/down on a prompt has meant history since the first version. }
    'j': Key := ekHistNext;
    'k': Key := ekHistPrev;
    'x': Key := ekDelete;
    'D': Key := ekDelToEnd;
    'C': Key := ekChangeToEnd;
    'S': Key := ekChangeLine;
    'i': Key := ekInsertHere;
    'a': Key := ekAppendHere;
    'I': Key := ekInsertStart;
    'A': Key := ekAppendEnd;
    'u': Key := ekUndo;
    #18: Key := ekRedo;          { Ctrl+R }
    'd', 'c':
      begin
        E.PendOp := Ch;
        Exit(False);
      end;
  else
    { An unbound command character is thrown away.  Inserting it instead
      would be the worst of both worlds: the user is in normal mode, so the
      character was never meant as text. }
    Exit(False);
  end;
  Result := True;
end;

{ ------------------------------------------------------------ keybindings -- }

{ VK_OEM_4 is the '[' key on a US layout, wanted only so that Ctrl+[ can mean
  Escape the way it does in a terminal.  It is layout-dependent, which is
  also why no other punctuation is nameable: a binding that silently meant a
  different physical key on a German keyboard is worse than no binding. }
const
  VK_OEM_4_ = 219;

type
  TKeyName = record
    Name: string;
    VK: Word;
  end;
  TActionName = record
    Name: string;
    Key: TEditKey;
  end;

const
  KeyNames: array[0..12] of TKeyName = (
    (Name: 'left';      VK: VK_LEFT),
    (Name: 'right';     VK: VK_RIGHT),
    (Name: 'up';        VK: VK_UP),
    (Name: 'down';      VK: VK_DOWN),
    (Name: 'home';      VK: VK_HOME),
    (Name: 'end';       VK: VK_END),
    (Name: 'backspace'; VK: VK_BACK),
    (Name: 'delete';    VK: VK_DELETE),
    (Name: 'pageup';    VK: VK_PRIOR),
    (Name: 'pagedown';  VK: VK_NEXT),
    (Name: '[';         VK: VK_OEM_4_),
    { The last three are nameable only so the parser can recognise them and
      then refuse them by name; none can ever be bound. }
    (Name: 'enter';     VK: VK_RETURN),
    (Name: 'tab';       VK: VK_TAB));

  { The closed action set.  ekChar is absent on purpose: it is the only verb
    that needs a character, and a binding that could produce text is a
    binding that could type an answer to a question. }
  ActionNames: array[0..30] of TActionName = (
    (Name: 'left';              Key: ekLeft),
    (Name: 'right';             Key: ekRight),
    (Name: 'home';              Key: ekHome),
    (Name: 'end';               Key: ekEnd),
    (Name: 'backspace';         Key: ekBackspace),
    (Name: 'delete';            Key: ekDelete),
    (Name: 'history-prev';      Key: ekHistPrev),
    (Name: 'history-next';      Key: ekHistNext),
    (Name: 'clear-line';        Key: ekClear),
    (Name: 'newline';           Key: ekNewline),
    (Name: 'word-right';        Key: ekWordRight),
    (Name: 'word-left';         Key: ekWordLeft),
    (Name: 'word-end';          Key: ekWordEnd),
    (Name: 'first-non-blank';   Key: ekFirstNonBlank),
    (Name: 'delete-word-right'; Key: ekDelWordRight),
    (Name: 'delete-word-left';  Key: ekDelWordLeft),
    (Name: 'delete-word-end';   Key: ekDelWordEnd),
    (Name: 'delete-to-end';     Key: ekDelToEnd),
    (Name: 'delete-to-start';   Key: ekDelToStart),
    (Name: 'delete-line';       Key: ekDelLine),
    (Name: 'change-word-right'; Key: ekChangeWordRight),
    (Name: 'change-word-left';  Key: ekChangeWordLeft),
    (Name: 'change-word-end';   Key: ekChangeWordEnd),
    (Name: 'change-to-end';     Key: ekChangeToEnd),
    (Name: 'change-to-start';   Key: ekChangeToStart),
    (Name: 'change-line';       Key: ekChangeLine),
    (Name: 'normal-mode';       Key: ekNormalMode),
    (Name: 'insert-here';       Key: ekInsertHere),
    (Name: 'append-here';       Key: ekAppendHere),
    (Name: 'insert-start';      Key: ekInsertStart),
    (Name: 'append-end';        Key: ekAppendEnd));

function KeyActionName(K: TEditKey): string;
var
  I: Integer;
begin
  for I := 0 to High(ActionNames) do
    if ActionNames[I].Key = K then Exit(ActionNames[I].Name);
  { Undo and redo are bindable but sit outside the table because they are
    named twice over - once here, once as vim's u and Ctrl+R. }
  case K of
    ekUndo: Result := 'undo';
    ekRedo: Result := 'redo';
  else
    Result := '';
  end;
end;

function KeyActionOf(const Name: string; out K: TEditKey): Boolean;
var
  I: Integer;
  N: string;
begin
  K := ekChar;
  N := LowerCase(Trim(Name));
  if N = 'undo' then begin K := ekUndo; Exit(True); end;
  if N = 'redo' then begin K := ekRedo; Exit(True); end;
  for I := 0 to High(ActionNames) do
    if ActionNames[I].Name = N then
    begin
      K := ActionNames[I].Key;
      Exit(True);
    end;
  Result := False;
end;

function KeyChordName(const C: TKeyChord): string;
var
  I: Integer;
begin
  Result := '';
  if C.Ctrl  then Result := Result + 'ctrl+';
  if C.Alt   then Result := Result + 'alt+';
  if C.Shift then Result := Result + 'shift+';
  if C.VK = VK_ESCAPE then Exit(Result + 'escape');
  for I := 0 to High(KeyNames) do
    if KeyNames[I].VK = C.VK then Exit(Result + KeyNames[I].Name);
  if ((C.VK >= Ord('A')) and (C.VK <= Ord('Z'))) or
     ((C.VK >= Ord('0')) and (C.VK <= Ord('9'))) then
    Result := Result + LowerCase(Chr(C.VK))
  else
    Result := Result + Format('vk%d', [C.VK]);
end;

function KeyChordOf(const Name: string; out C: TKeyChord;
  out Why: string): Boolean;
var
  N: string;
  I: Integer;
begin
  C.VK := 0;
  C.Ctrl := False;
  C.Alt := False;
  C.Shift := False;
  Why := '';
  N := LowerCase(Trim(Name));

  { Modifier prefixes, in any order, each at most once. }
  while True do
  begin
    if Copy(N, 1, 5) = 'ctrl+' then
    begin
      if C.Ctrl then begin Why := 'ctrl given twice'; Exit(False); end;
      C.Ctrl := True;
      Delete(N, 1, 5);
    end
    else if Copy(N, 1, 4) = 'alt+' then
    begin
      if C.Alt then begin Why := 'alt given twice'; Exit(False); end;
      C.Alt := True;
      Delete(N, 1, 4);
    end
    else if Copy(N, 1, 6) = 'shift+' then
    begin
      if C.Shift then begin Why := 'shift given twice'; Exit(False); end;
      C.Shift := True;
      Delete(N, 1, 6);
    end
    else
      Break;
  end;

  if N = '' then
  begin
    Why := 'no key after the modifiers';
    Exit(False);
  end;

  if N = 'escape' then
  begin
    C.VK := VK_ESCAPE;
    Exit(True);
  end;
  for I := 0 to High(KeyNames) do
    if KeyNames[I].Name = N then
    begin
      C.VK := KeyNames[I].VK;
      Exit(True);
    end;

  { A single letter or digit - and THIS is the wall.  Without a modifier it
    is refused outright, which is why no file can name y, a or n, and why a
    keys.json cannot touch the permission prompt even if every other guard
    in this unit were wired away. }
  if (Length(N) = 1) and
     (((N[1] >= 'a') and (N[1] <= 'z')) or ((N[1] >= '0') and (N[1] <= '9'))) then
  begin
    if not (C.Ctrl or C.Alt) then
    begin
      Why := 'a plain key cannot be bound; write ctrl+' + N + ' or alt+' + N;
      Exit(False);
    end;
    C.VK := Ord(UpCase(N[1]));
    Exit(True);
  end;

  Why := 'unknown key name';
  Result := False;
end;

function KeyChordReserved(const C: TKeyChord): Boolean;
begin
  { Enter in every modifier combination (submit, and Ctrl/Alt+Enter for a
    line break), Tab (completion), Escape (clear, or normal mode) and Ctrl+C
    (quit).  Each one is how a user gets out of something, and a rebound exit
    is a trap. }
  Result := (C.VK = VK_RETURN) or (C.VK = VK_TAB) or (C.VK = VK_ESCAPE) or
            ((C.VK = Ord('C')) and C.Ctrl);
end;

function KeysNone: TKeyProfile;
begin
  Result.Vim := False;
  SetLength(Result.Binds, 0);
end;

procedure BindSet(var P: TKeyProfile; const C: TKeyChord; K: TEditKey);
var
  I, N: Integer;
begin
  for I := 0 to High(P.Binds) do
    if (P.Binds[I].Chord.VK = C.VK) and (P.Binds[I].Chord.Ctrl = C.Ctrl) and
       (P.Binds[I].Chord.Alt = C.Alt) and (P.Binds[I].Chord.Shift = C.Shift) then
    begin
      P.Binds[I].Action := K;
      Exit;
    end;
  N := Length(P.Binds);
  SetLength(P.Binds, N + 1);
  P.Binds[N].Chord := C;
  P.Binds[N].Action := K;
end;

procedure BindDrop(var P: TKeyProfile; const C: TKeyChord);
var
  I, J: Integer;
begin
  for I := 0 to High(P.Binds) do
    if (P.Binds[I].Chord.VK = C.VK) and (P.Binds[I].Chord.Ctrl = C.Ctrl) and
       (P.Binds[I].Chord.Alt = C.Alt) and (P.Binds[I].Chord.Shift = C.Shift) then
    begin
      for J := I to High(P.Binds) - 1 do P.Binds[J] := P.Binds[J + 1];
      SetLength(P.Binds, Length(P.Binds) - 1);
      Exit;
    end;
end;

procedure BindName(var P: TKeyProfile; const Chord, Action: string);
var
  C: TKeyChord;
  K: TEditKey;
  Why: string;
begin
  { The defaults go through the same grammar as a file's entries, so a
    default that could not be written in keys.json cannot exist. }
  if not KeyChordOf(Chord, C, Why) then Exit;
  if not KeyActionOf(Action, K) then Exit;
  BindSet(P, C, K);
end;

function KeysDefault: TKeyProfile;
begin
  Result := KeysNone;
  { The readline verbs the editor has always been missing.  Ctrl+W and Ctrl+K
    are what a shell user reaches for; Alt+B and Alt+F are the word motions;
    Ctrl+Z is undo, which now has something to undo. }
  BindName(Result, 'ctrl+w', 'delete-word-left');
  BindName(Result, 'ctrl+k', 'delete-to-end');
  BindName(Result, 'alt+b',  'word-left');
  BindName(Result, 'alt+f',  'word-right');
  BindName(Result, 'ctrl+z', 'undo');
end;

function DecodeKey(const P: TKeyProfile; const E: TEditState; VK: Word;
  Ctrl, Alt, Shift: Boolean; Ch: WideChar; out Key: TEditKey): Boolean;
var
  I: Integer;
begin
  Key := ekChar;
  { E and Ch are not consulted: a binding must mean the same thing whatever
    the console synthesised into UnicodeChar and whatever mode the editor is
    in, or the same physical key would do two things.  They are in the
    signature because the suite drives this exactly as the loop does. }
  for I := 0 to High(P.Binds) do
    if (P.Binds[I].Chord.VK = VK) and (P.Binds[I].Chord.Ctrl = Ctrl) and
       (P.Binds[I].Chord.Alt = Alt) and (P.Binds[I].Chord.Shift = Shift) then
    begin
      Key := P.Binds[I].Action;
      Exit(True);
    end;
  Result := False;
end;

procedure NoteAdd(var Notes: TStringArray; const S: string);
var
  N: Integer;
begin
  N := Length(Notes);
  SetLength(Notes, N + 1);
  Notes[N] := S;
end;

function KeysParse(const Text: string; out P: TKeyProfile;
  out Notes: TStringArray): Boolean;
var
  Root, B, V: TJson;
  I: Integer;
  C: TKeyChord;
  K: TEditKey;
  Name, Act, Why: string;
begin
  P := KeysDefault;
  Notes := nil;
  Result := False;

  if Trim(Text) = '' then
  begin
    NoteAdd(Notes, 'keys.json is empty; using the built-in bindings');
    Exit;
  end;
  Root := JsonParse(Text);
  if Root = nil then
  begin
    NoteAdd(Notes, 'keys.json is not valid JSON; using the built-in bindings');
    Exit;
  end;
  try
    if Root.Kind <> jkObj then
    begin
      NoteAdd(Notes, 'keys.json must be a JSON object; using the built-in bindings');
      Exit;
    end;
    P.Vim := Root.Bool('vim', False);
    B := Root.Find('bindings');
    if (B <> nil) and (B.Kind <> jkObj) then
      NoteAdd(Notes, '"bindings" must be an object; ignored')
    else if B <> nil then
      for I := 0 to B.Count - 1 do
      begin
        Name := B.Key(I);
        V := B.Item(I);
        if V.Kind <> jkStr then
        begin
          NoteAdd(Notes, Name + ': the action must be a string');
          Continue;
        end;
        Act := LowerCase(Trim(V.AsString));
        if not KeyChordOf(Name, C, Why) then
        begin
          NoteAdd(Notes, Name + ': ' + Why);
          Continue;
        end;
        if KeyChordReserved(C) then
        begin
          NoteAdd(Notes, Name + ' cannot be rebound; the editor owns it');
          Continue;
        end;
        { An explicit unbind, so a user can take back a default without
          having to know what else the key might mean. }
        if Act = 'none' then
        begin
          BindDrop(P, C);
          Continue;
        end;
        if not KeyActionOf(Act, K) then
        begin
          NoteAdd(Notes, Name + ': unknown action "' + Act + '"');
          Continue;
        end;
        BindSet(P, C, K);
      end;
    Result := True;
  finally
    Root.Free;
  end;
end;

function KeysToJson(const P: TKeyProfile; const Existing: string): string;
var
  Root: TJson;
  I: Integer;
begin
  Root := nil;
  if Trim(Existing) <> '' then Root := JsonParse(Existing);
  if (Root <> nil) and (Root.Kind <> jkObj) then FreeAndNil(Root);
  if Root = nil then Root := TJson.NewObj;
  try
    { Only the vim field is written.  The bindings in memory came from this
      file and rewriting them would reformat a document the user hand-wrote,
      for no gain; SetAt keeps the key where it already was so a diff of the
      file shows one changed value. }
    I := Root.IndexOf('vim');
    if I >= 0 then
      Root.SetAt(I, TJson.NewBool(P.Vim))
    else
      Root.AddBool('vim', P.Vim);
    Result := Root.ToJsonPretty + sLineBreak;
  finally
    Root.Free;
  end;
end;

{ The install seam.  Written by SetPromptProfile/SetPromptVim, read in
  exactly one expression in the whole program: the argument ReadPromptLine
  passes to ReadLineCore.  If a second read ever appears, the wall described
  at the top of this unit's line-editing section is gone. }
var
  PromptProfileVar: TKeyProfile;

procedure SetPromptProfile(const P: TKeyProfile);
begin
  PromptProfileVar := P;
end;

procedure SetPromptVim(Enabled: Boolean);
begin
  PromptProfileVar.Vim := Enabled;
end;

function PromptProfile: TKeyProfile;
begin
  Result := PromptProfileVar;
end;

{ Redraws the edited line in place.  The whole line is rewritten rather than
  patched, because working out the minimal update is far more code than the
  redraw costs at terminal speeds - and it is what keeps a mid-line insert or
  a history recall from leaving debris behind.

  The buffer may hold newlines (a pasted block, or an inserted break); a
  console cannot re-edit rows it has already scrolled past, so what is drawn
  is the line containing the caret, with a continuation marker instead of the
  prompt when it is not the first. }
{ The mode tag.  Both states are shown, unlike the permission mode where only
  the unusual one is: with vim on there is no safe default state, because
  every printable key means something different in each. }
function EditVimTag(const E: TEditState): string;
begin
  if not E.Vim then Exit('');
  if E.Mode = vmNormal then Result := '[N] ' else Result := '[I] ';
end;

function EditLead(const E: TEditState; const Prompt: string;
  FirstLine: Boolean): string;
begin
  Result := EditVimTag(E);
  if FirstLine then Result := Result + Prompt else Result := Result + '... ';
end;

procedure Redraw(const Prompt: string; const E: TEditState;
  var PrevLen: Integer);
var
  I: Integer;
  LineStart, LineEnd: Integer;
  Seg, W: WideString;
  Lead, Tag: string;
  RelCaret, Painted: Integer;
begin
  W := E.Text;
  { The segment between the newlines around the caret. }
  LineStart := 1;
  for I := E.Caret downto 1 do
    if W[I] = #10 then
    begin
      LineStart := I + 1;
      Break;
    end;
  LineEnd := Length(W);
  for I := E.Caret + 1 to Length(W) do
    if W[I] = #10 then
    begin
      LineEnd := I - 1;
      Break;
    end;
  Seg := Copy(W, LineStart, LineEnd - LineStart + 1);
  RelCaret := E.Caret - LineStart + 1;
  Tag := EditVimTag(E);
  Lead := EditLead(E, Prompt, LineStart = 1);

  { PrevLen is the TOTAL painted width, lead included, not the length of the
    text.  It has to be: the mode tag appears and disappears mid-line, and a
    four-character indicator that vanished while the erase loop measured only
    the text would leave '[N] ' hanging off the end of the line. }
  Painted := Length(Lead) + Length(Seg);

  { Back to column zero, then over the lead. }
  Emit(#13);
  if Tag <> '' then
    if E.Mode = vmNormal then EmitC(clYellow, Tag) else EmitC(clGrey, Tag);
  EmitC(clCyan, Copy(Lead, Length(Tag) + 1, MaxInt));
  Emit(UTF8Encode(Seg));
  { Erase whatever the previous, longer line left on screen. }
  for I := Painted to PrevLen - 1 do
    Emit(' ');
  Emit(#13);
  if Tag <> '' then
    if E.Mode = vmNormal then EmitC(clYellow, Tag) else EmitC(clGrey, Tag);
  EmitC(clCyan, Copy(Lead, Length(Tag) + 1, MaxInt));
  if RelCaret > 0 then
    Emit(UTF8Encode(Copy(Seg, 1, RelCaret)));
  PrevLen := Painted;
end;

{ ------------------------------------------------------- the prompt block --

  Redraw above paints one line and stays on it.  The REPL's prompt is a
  block: a rule, the text, a rule, and the status lines under it.  That means
  painting rows BELOW the caret and then going back up to it, which is a
  thing only VT escapes can do - so this path exists alongside the one above
  rather than replacing it, and a console that refused VT keeps the single
  line it has always had.

  The block is for the REPL and nothing else.  A permission question inside a
  status frame is a permission question nobody reads, so ReadLineEdit - which
  is what every other prompt in the program calls - never takes this path. }

type
  { A visual row of the input text: a span of the wide string, 1-based.
    Spans rather than copies, so the caret can be located by arithmetic
    instead of by re-searching the text. }
  TWrapSpan = record
    Start, Len: Integer;
  end;
  TWrapSpans = array of TWrapSpan;

  TBlockState = record
    Rows: Integer;       { rows painted last time, so a shrink can be erased }
    CaretRow: Integer;   { where the cursor was left, counted from row 0 }
  end;

{ Breaks the text into visual rows of at most InnerW columns.  Hard newlines
  always break; beyond that the break is at the last space that fits, and at
  InnerW itself when a single word is longer than the row.  Always returns at
  least one span, possibly empty, because a block with no rows has nowhere to
  put the caret. }
function WrapText(const W: WideString; InnerW: Integer): TWrapSpans;
var
  LineStart, I, SegEndIx, Look: Integer;

  procedure Emit_(A, L: Integer);
  begin
    if L < 0 then L := 0;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Start := A;
    Result[High(Result)].Len := L;
  end;

begin
  Result := nil;
  if InnerW < 1 then InnerW := 1;
  LineStart := 1;
  I := 1;
  while I <= Length(W) + 1 do
  begin
    if (I = Length(W) + 1) or (W[I] = #10) then
    begin
      { One logical line: LineStart .. I-1.  Wrapped into as many rows as
        it needs, and into one empty row when it is empty - a blank line the
        user typed is a blank line they should see. }
      SegEndIx := I - 1;
      while SegEndIx - LineStart + 1 > InnerW do
      begin
        { The row can hold LineStart .. LineStart+InnerW-1, so the character
          at LineStart+InnerW is the first that does not fit.  Walking back
          from there finds the space to break at - and that space is itself a
          legal break, because it is dropped rather than shown. }
        Look := LineStart + InnerW;
        while (Look > LineStart) and (W[Look] <> ' ') do Dec(Look);
        if Look > LineStart then
        begin
          Emit_(LineStart, Look - LineStart);
          LineStart := Look + 1;
        end
        else
        begin
          { A word longer than the row is cut at the margin.  Refusing to
            break it would either overflow the frame or loop forever, and
            the loop is the worse of the two. }
          Emit_(LineStart, InnerW);
          LineStart := LineStart + InnerW;
        end;
      end;
      Emit_(LineStart, SegEndIx - LineStart + 1);
      LineStart := I + 1;
    end;
    Inc(I);
  end;
  if Length(Result) = 0 then Emit_(1, 0);
end;

{ Which row the caret sits on and how far into it.  The caret is an index
  BETWEEN characters (0 = before the first), so a caret at a row's end and
  one at the next row's start are the same position; the earlier row wins,
  which is what a user who just typed the last character expects to see. }
procedure CaretAt(const Spans: TWrapSpans; Caret: Integer;
  out Row, Col: Integer);
var
  I: Integer;
begin
  for I := 0 to High(Spans) do
    if Caret <= Spans[I].Start + Spans[I].Len - 1 then
    begin
      Row := I;
      Col := Caret - Spans[I].Start + 1;
      if Col < 0 then Col := 0;
      Exit;
    end;
  Row := High(Spans);
  if Row < 0 then Row := 0;
  Col := 0;
  if Length(Spans) > 0 then Col := Spans[Row].Len;
end;

function PromptRows(const Text: WideString; InnerW, Caret: Integer;
  out CaretRow, CaretCol: Integer): TStringArray;
var
  Spans: TWrapSpans;
  I: Integer;
begin
  Result := nil;
  Spans := WrapText(Text, InnerW);
  CaretAt(Spans, Caret, CaretRow, CaretCol);
  SetLength(Result, Length(Spans));
  for I := 0 to High(Spans) do
    Result[I] := UTF8Encode(Copy(Text, Spans[I].Start, Spans[I].Len));
end;

{ The rows the block paints, marked up and fitted.  Pure but for TermWidth
  and the installed status record, which is what makes the layout arguable
  in a test without a console. }
function BlockRows(const E: TEditState; Width: Integer;
  out CaretRow, CaretCol: Integer): TStringArray;
var
  Body: TStringArray;
  Lead, Cont, Tag: string;
  InnerW, I, LeadW: Integer;
  Stat: TStringArray;

  procedure Add(const S: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := S;
  end;

begin
  Result := nil;
  if UiFancy then Lead := MkAmber + #$E2#$9D#$AF + ' ' else Lead := MkAmber + '> ';
  LeadW := 2;
  Cont := '  ';

  { The vim tag, in front of the prompt mark exactly as it is on the single
    line.  It cannot be dropped here and left to the status line: with vim on
    there is no safe default state, because every printable key means
    something different in each mode - which is why this is the one indicator
    shown in BOTH its states rather than only the unusual one.

    It costs nothing in reflow because both tags are four columns wide, so
    the text column does not move when the mode changes.  A tag of some other
    width would shift the whole block sideways on every Esc. }
  if E.Vim then
  begin
    if E.Mode = vmNormal then Tag := MkYellow + '[N] ' else Tag := MkGrey + '[I] ';
    Lead := Tag + Lead;
    Cont := '    ' + Cont;
    LeadW := LeadW + 4;
  end;

  InnerW := Width - LeadW;
  if InnerW < 8 then InnerW := 8;

  Body := PromptRows(E.Text, InnerW, E.Caret, CaretRow, CaretCol);

  { Row 0 is the rule above the text, so the caret row reported to the
    painter is one further down than the text row, and the column is one
    lead further along. }
  Add(MkAmberDk + UiRule(Width) + MkOff);
  Inc(CaretRow);
  CaretCol := CaretCol + LeadW;

  for I := 0 to High(Body) do
    { The text carries no colour mark at all, so it arrives in the terminal's
      own foreground.  Anything else would fight whatever theme the user
      chose for the window they type into. }
    if I = 0 then
      Add(Lead + MkOff + Body[I])
    else
      Add(Cont + Body[I]);

  Add(MkAmberDk + UiRule(Width) + MkOff);
  Stat := StatusLines(Status, Width);
  for I := 0 to High(Stat) do Add(Stat[I]);
end;

{ Where the cursor sits, so the first paint can tell whether the row it is
  about to take over already has something on it.  False when the console
  will not say, which is treated as "not at the start" - one spare blank
  line is a cheaper mistake than an erased line of output. }
function CursorAtLineStart: Boolean;
var
  Info: CONSOLE_SCREEN_BUFFER_INFO;
begin
  Result := False;
  if (HOut <> 0) and GetConsoleScreenBufferInfo(HOut, Info) then
    Result := Info.dwCursorPosition.X = 0;
end;

{ Paints the block, leaving the cursor in the text where the caret is.
  Every move is relative - up N, down N - never absolute, so a paint that
  scrolled the window is still correct: the block scrolled with it. }
procedure BlockDraw(const E: TEditState; var St: TBlockState);
var
  Rows: TStringArray;
  Width, CaretRow, CaretCol, Total, I: Integer;
  Buf: string;
begin
  Width := TermWidth - 1;      { one column spare, or the last cell wraps }
  if Width < 12 then Width := 12;
  Rows := BlockRows(E, Width, CaretRow, CaretCol);

  { The whole repaint is assembled and written ONCE.  Six rows painted run by
    run is thirty console calls per keystroke, which the user experiences as
    a prompt that stutters while they type - and a terminal handed the update
    in pieces has thirty chances to show a half-drawn frame. }
  Buf := '';

  { The first paint claims rows it does not own yet, and it claims them by
    erasing them - so it has to start on a row that is genuinely free.  The
    blank line after that is not decoration: the block is a frame, and a
    frame flush against the last line of a reply reads as part of it. }
  if St.Rows = 0 then
  begin
    if not CursorAtLineStart then Buf := sLineBreak;
    Buf := Buf + sLineBreak;
  end;

  { Back to the top of the block from wherever the caret was left. }
  if St.CaretRow > 0 then Buf := Buf + #27'[' + IntToStr(St.CaretRow) + 'A';
  Buf := Buf + #13;

  { A block that shrank still has the old rows on screen, so the paint runs
    to whichever count is larger and blanks the difference. }
  Total := Length(Rows);
  if St.Rows > Total then Total := St.Rows;
  for I := 0 to Total - 1 do
  begin
    if I > 0 then Buf := Buf + sLineBreak;
    Buf := Buf + #27'[2K';
    if I <= High(Rows) then Buf := Buf + UiVt(UiFit(Rows[I], Width));
  end;

  { Down at the last row now; back up to the caret's row and along to it. }
  if Total - 1 > CaretRow then
    Buf := Buf + #27'[' + IntToStr(Total - 1 - CaretRow) + 'A';
  Buf := Buf + #13;
  if CaretCol > 0 then Buf := Buf + #27'[' + IntToStr(CaretCol) + 'C';

  Emit(Buf);
  St.Rows := Length(Rows);
  St.CaretRow := CaretRow;
end;

{ Takes the block off the screen and leaves the cursor at column zero of the
  row it started on, ready for whatever the REPL prints next. }
procedure BlockErase(var St: TBlockState);
var
  I: Integer;
  Buf: string;
begin
  if St.Rows = 0 then Exit;
  Buf := '';
  if St.CaretRow > 0 then Buf := #27'[' + IntToStr(St.CaretRow) + 'A';
  Buf := Buf + #13;
  for I := 0 to St.Rows - 1 do
  begin
    if I > 0 then Buf := Buf + sLineBreak;
    Buf := Buf + #27'[2K';
  end;
  if St.Rows > 1 then Buf := Buf + #27'[' + IntToStr(St.Rows - 1) + 'A';
  Emit(Buf + #13);
  St.Rows := 0;
  St.CaretRow := 0;
end;

{ The one console key loop, taking its profile as a REQUIRED PARAMETER and
  reading no module state.  That is the structural half of the wall: the two
  wrappers below are the only things that supply a profile, and the one that
  every prompt in the program already calls supplies the empty one.

  Block asks for the framed multi-row prompt.  It is honoured only where it
  can be: a console with no VT, or a redirected stdin, falls back to the
  single line, and the caller cannot tell the difference except by looking. }
function ReadLineCore(const Prompt: string; const P: TKeyProfile;
  Block: Boolean; out Line: string): Boolean;
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
  Ctrl, Alt, Shift: Boolean;
  Bound: TEditKey;
  Blk: TBlockState;
  Framed: Boolean;

  { Applies a key and repaints.  Every editing key goes through here, so the
    console and the state cannot drift apart. }
  procedure Apply(Key: TEditKey; C: WideChar);
  begin
    EditApply(E, Key, C);
    if Framed then BlockDraw(E, Blk) else Redraw(Prompt, E, PrevLen);
  end;

  { A repaint with no state change - after an absorbed vim operator, or a
    completion that changed nothing.  Same split as Apply. }
  procedure Repaint;
  begin
    if Framed then BlockDraw(E, Blk) else Redraw(Prompt, E, PrevLen);
  end;

  { The block comes down and the submitted text goes into the scrollback as
    an ordinary line, which is where the user will look for it three screens
    later.  Without this the frame would scroll away carrying the question
    with it, and the transcript would be a column of answers. }
  procedure CloseBlock;
  var
    Mark: string;
  begin
    BlockErase(Blk);
    if UiFancy then Mark := #$E2#$9D#$AF + ' ' else Mark := '> ';
    EmitC(clAmberDim, Mark);
    EmitCLn(clWhite, UTF8Encode(E.Text));
  end;

begin
  Line := '';
  PrevLen := 0;
  EditInitProfile(E, P);
  { The frame needs VT for the cursor moves and a real console to read from;
    without either, the caller silently gets the line editor this program has
    always had.  Deciding it once here means no key handler has to ask. }
  Framed := Block and VtActive and (HIn <> 0) and StdinIsConsole;
  Blk.Rows := 0;
  Blk.CaretRow := 0;
  if Framed then
    BlockDraw(E, Blk)
  else
  begin
    { The tag is part of the lead from the first keystroke, so the width the
      erase loop measures against is right even before the first Redraw. }
    if E.Vim then
    begin
      EmitC(clGrey, EditVimTag(E));
      PrevLen := Length(EditVimTag(E));
    end;
    EmitC(clCyan, Prompt);
    PrevLen := PrevLen + Length(Prompt);
  end;

  { Raw mode: cooked mode would swallow the per-key handling this editor
    needs, and ENABLE_PROCESSED_INPUT would route Ctrl+C to the control
    handler instead of the input buffer - the editor wants it as a key, so
    that Ctrl+C at the prompt quits rather than merely setting the cancel
    flag nobody is polling. }
  if HIn <> 0 then
  begin
    GetConsoleMode(HIn, Mode);
    SetConsoleMode(HIn, 0);
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
      Ctrl := (Rec.Event.KeyEvent.dwControlKeyState and
               (LEFT_CTRL_PRESSED or RIGHT_CTRL_PRESSED)) <> 0;
      Alt := (Rec.Event.KeyEvent.dwControlKeyState and
              (LEFT_ALT_PRESSED or RIGHT_ALT_PRESSED)) <> 0;
      Shift := (Rec.Event.KeyEvent.dwControlKeyState and SHIFT_PRESSED) <> 0;

      case Rec.Event.KeyEvent.wVirtualKeyCode of
        VK_RETURN:
          begin
            { Enter with Ctrl or Alt held inserts a line break instead of
              submitting, which is how a multi-line prompt is written by
              hand.  A pasted block does the same implicitly below.  Both
              shapes are reserved: Enter submits from either vim mode, so a
              paste arriving in normal mode still cannot fire a request. }
            if Ctrl or Alt then
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
            if Framed then CloseBlock else EmitLn;
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
              if CompleteToken(E, Cands) then Repaint;
            end;
            Continue;
          end;
      end;

      { Ctrl+C before anything a binding could see.  It is in the reserved
        set as well, so this is belt and braces on purpose. }
      if (Ch = #3) or ((Rec.Event.KeyEvent.wVirtualKeyCode = Ord('C')) and Ctrl) then
      begin
        { Erased rather than closed: nothing was submitted, so nothing
          belongs in the scrollback. }
        if Framed then BlockErase(Blk);
        EmitLn;
        Exit(False);
      end;

      { The binding table, consulted here and nowhere else in the program.
        Matching is on the virtual key and the modifier flags, never on the
        control character the console synthesised, so one rule covers both
        shapes Ctrl arrives in. }
      if DecodeKey(P, E, Rec.Event.KeyEvent.wVirtualKeyCode,
                   Ctrl, Alt, Shift, Ch, Bound) then
      begin
        Apply(Bound, #0);
        Continue;
      end;

      case Rec.Event.KeyEvent.wVirtualKeyCode of
        VK_BACK:   begin Apply(ekBackspace, #0); Continue; end;
        VK_DELETE: begin Apply(ekDelete, #0);    Continue; end;
        VK_LEFT:   begin Apply(ekLeft, #0);      Continue; end;
        VK_RIGHT:  begin Apply(ekRight, #0);     Continue; end;
        VK_HOME:   begin Apply(ekHome, #0);      Continue; end;
        VK_END:    begin Apply(ekEnd, #0);       Continue; end;
        VK_UP:     begin Apply(ekHistPrev, #0);  Continue; end;
        VK_DOWN:   begin Apply(ekHistNext, #0);  Continue; end;
        VK_ESCAPE:
          begin
            { With vim on, Escape leaves insert mode - which costs the
              clear-the-line meaning it has always had.  Ctrl+U still clears,
              and /vim says so when it turns the mode on. }
            if E.Vim then Apply(ekNormalMode, #0) else Apply(ekClear, #0);
            Continue;
          end;
        VK_OEM_4_:
          { Ctrl+[ is Escape in a terminal, and a vim user's fingers know it.
            Layout-dependent, so its failure is a missing convenience. }
          if Ctrl and E.Vim then
          begin
            Apply(ekNormalMode, #0);
            Continue;
          end;
      end;

      { Ctrl+R arrives as a control character, below the printable range the
        normal-mode parser sees, so redo is wired here rather than there. }
      if (Ch = #18) and E.Vim then begin Apply(ekRedo, #0); Continue; end;
      if Ch = #21 then begin Apply(ekClear, #0); Continue; end;  { Ctrl+U }
      if Ch = #1  then begin Apply(ekHome, #0);  Continue; end;  { Ctrl+A }
      if Ch = #5  then begin Apply(ekEnd, #0);   Continue; end;  { Ctrl+E }
      if Ch >= #32 then
      begin
        { In normal mode a printable key is a command, never text. }
        if E.Vim and (E.Mode = vmNormal) then
        begin
          if EditNormalKey(E, Ch, Bound) then
            Apply(Bound, #0)
          else
            { An absorbed operator or a discarded key still repaints: the
              caret may have moved nowhere but the tag must stay honest. }
            Repaint;
          Continue;
        end;
        EditApply(E, ekChar, Ch);
        { Appending at the end is the common case and needs no redraw, which
          keeps ordinary typing free of flicker.  PrevLen is total painted
          width, so this is an increment, not the text length - which also
          fixes the multi-line case, where the two were never the same.

          The framed path cannot take that shortcut: a character can push the
          text onto a new row, which moves the rules and the status lines
          under it, so the block is repainted whole every time. }
        if Framed then
          BlockDraw(E, Blk)
        else if E.Caret = Length(E.Text) then
        begin
          Emit(UTF8Encode(WideString(Ch)));
          Inc(PrevLen);
        end
        else
          Redraw(Prompt, E, PrevLen);
      end;
    until False;
  finally
    if HIn <> 0 then SetConsoleMode(HIn, Mode);
  end;
end;

function ReadLineEdit(const Prompt: string; out Line: string): Boolean;
begin
  { KeysNone, always.  This is the reader the permission prompt, the model
    picker, the session picker and the rewind picker use, and it is the
    reader anyone adding a sixth prompt will reach for because it is the one
    that already exists under the obvious name.

    False for the frame, always, and for the same reason: these prompts ask a
    question whose answer matters, and a question wrapped in a status bar is
    a question that gets skimmed. }
  Result := ReadLineCore(Prompt, KeysNone, False, Line);
end;

function ReadPromptLine(const Prompt: string; out Line: string): Boolean;
begin
  { THE one read of PromptProfile in the program, and the one framed prompt. }
  Result := ReadLineCore(Prompt, PromptProfile, True, Line);
end;

function ReadSecretLine(const Prompt: string; out Secret: string): Boolean;
var
  Mode: DWORD;
  Rec: INPUT_RECORD;
  NRead: DWORD = 0;
  Ch: WideChar;
  Ctrl: Boolean;
  W: WideString;
begin
  Secret := '';
  Result := False;
  { Refused rather than attempted off a pipe.  ReadLineCore falls back to
    ReadLn there; this must not, because the fallback would echo the secret
    into whatever is reading the console's output and because a -p run has
    nobody to answer. }
  if not StdinIsConsole then Exit;
  EmitC(clCyan, Prompt);
  GetConsoleMode(HIn, Mode);
  { Raw, for the same reason the editor is: cooked mode would echo. }
  SetConsoleMode(HIn, 0);
  try
    W := '';
    repeat
      if not ReadConsoleInputW(HIn, Rec, 1, NRead) or (NRead = 0) then Exit;
      if (Rec.EventType <> KEY_EVENT) or not Rec.Event.KeyEvent.bKeyDown then
        Continue;
      Ctrl := (Rec.Event.KeyEvent.dwControlKeyState and
               (LEFT_CTRL_PRESSED or RIGHT_CTRL_PRESSED)) <> 0;
      case Rec.Event.KeyEvent.wVirtualKeyCode of
        VK_RETURN:
          begin
            Emit(#10);
            Secret := UTF8Encode(W);
            Exit(True);
          end;
        VK_ESCAPE:
          begin
            Emit(#10);
            Exit(False);
          end;
        VK_BACK:
          begin
            if Length(W) > 0 then SetLength(W, Length(W) - 1);
            Continue;
          end;
      end;
      Ch := WideChar(Rec.Event.KeyEvent.UnicodeChar);
      { Ctrl+C quits, Ctrl+U clears - the two the plain editor also honours,
        so muscle memory does not produce a key with a stray control
        character wedged into it. }
      if Ctrl and ((Ch = #3) or (Ch = 'c') or (Ch = 'C')) then
      begin
        Emit(#10);
        Exit(False);
      end;
      if Ctrl and ((Ch = #21) or (Ch = 'u') or (Ch = 'U')) then
      begin
        W := '';
        Continue;
      end;
      { Everything below space is a control code, and a key never contains
        one; dropping them here is also what keeps a bracketed-paste burst
        from wedging escape sequences into the middle of the value. }
      if Ch < ' ' then Continue;
      W := W + Ch;
      { Deliberately no Emit.  This is the whole point of the reader. }
    until False;
  finally
    { Restored even on Esc, on Ctrl+C and on an exception, or a cancelled
      /login would leave the console in raw mode for the rest of the run. }
    SetConsoleMode(HIn, Mode);
  end;
end;

end.
