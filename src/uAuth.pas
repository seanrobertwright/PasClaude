unit uAuth;

{ Credentials: whose they are, where they rest, and which one answers.

  pasclaude is a credential MANAGER and never a credential ISSUER, and that
  is a finding rather than a preference.  Anthropic documents exactly three
  ways to authenticate: a static sk-ant-api key on x-api-key, Workload
  Identity Federation (an org-configured OIDC JWT exchanged for a token,
  which needs a federation rule and a service account created in the Console
  and an IdP-issued assertion - a CI mechanism, not a human at a terminal),
  and App Attest on Apple platforms.  There is no published authorization
  endpoint, no device-code grant, no PKCE flow and no public client id a
  third-party program may use.  Claude Code's client identity is Claude
  Code's; minting tokens with it would be this program claiming to be one it
  is not.  So there is no /login that logs in - only a /login that decides
  which of the credentials this machine already holds should answer, and
  stores one of its own if the user pastes it.

  THE HARD BOUNDARY, and the reason this unit's writers take no path
  argument.  Three of the six sources belong to other programs:
  %USERPROFILE%\.claude\.credentials.json (Claude Code),
  %USERPROFILE%\.jcode\auth.json (Jcode), and
  %APPDATA%\Anthropic\credentials\<profile>.json (the ant CLI).  They are
  read-only forever - refreshing them is their owner's job, and deleting or
  rewriting one would break a program the user did not ask us to touch.
  AuthStore and AuthClear therefore compute CredentialStorePath internally
  and can name no other file: the boundary is enforced by the signatures, not
  by remembering.

  WHAT A PROJECT DIRECTORY DECIDES HERE: nothing whatsoever.  No file under
  any root - session root or --add-dir root - is read by any code path in
  this unit.  The store and the source preference live under %LOCALAPPDATA%,
  the three foreign sources under %USERPROFILE% and %APPDATA%, and
  uTools.SafePath refuses every path outside the roots, so the model's own
  read_file and bash cannot reach any of them.  A repository cannot ship a
  credential, cannot choose which one is used, and cannot cause /login to
  run.

  This unit does no network and no console: pure file, JSON and Win32.  It
  uses uJson and nothing else of ours, so every suite can drive it. }

{$mode objfpc}{$H+}

interface

uses SysUtils, uJson;

type
  { Resolution order is the declaration order below, and that is deliberate:
    the environment always wins because exporting a variable is a deliberate
    act, and reading another program's token is not. }
  TAuthSource = (asNone, asApiKeyEnv, asAuthTokenEnv, asStored,
                 asClaudeCode, asJcode, asAntProfile);

  TAuthInfo = record
    Source: TAuthSource;
    Token: string;      { never printed, never logged, never persisted by us }
    Path: string;       { '' for the two environment sources }
    Hint: string;       { first 7 + ellipsis + last 4 - the display form }
    Why: string;        { why this source is not usable, when it is not }
    ExpiresMs: Int64;   { 0 = no expiry known, which counts as live }
    Present: Boolean;   { a usable token was found here }
    Decryptable: Boolean; { stored only: False = wrong user or machine }
  end;
  TAuthInfoArray = array of TAuthInfo;

const
  CredentialFileName = 'credential.json';
  { Bound into every CryptProtectData call.  Without it any other program on
    this account could decrypt the file with a bare CryptUnprotectData. }
  CredentialEntropy  = 'pasclaude:credential:v1';
  { The one shape this loader accepts.  A file that says anything else -
    including "none" - is refused rather than read, so hand-writing an
    unprotected value into %LOCALAPPDATA% cannot inject a credential. }
  CredentialProtection = 'dpapi';
  CredentialVersion  = 1;
  { A stored blob larger than this is not a credential.  DPAPI adds a few
    hundred bytes of header to a key of about seventy. }
  MaxCredentialBytes = 64 * 1024;

{ Stable label, used as the prefer key and as the SDK's auth_source.  Never a
  token and never a path. }
function AuthSourceName(S: TAuthSource): string;
function AuthSourceFromName(const N: string): TAuthSource;
{ First 7 characters, an ellipsis, last 4 - and never more.  Enough to tell
  two keys apart, not enough to use one. }
function AuthHint(const Token: string): string;
{ %LOCALAPPDATA%\pasclaude\credential.json, falling back to %USERPROFILE%.
  '' when neither exists, and '' means STORE NOTHING - never a path inside a
  root.  That is ApprovalsPath's rule, for ApprovalsPath's reason: a file the
  project tree could carry must never be able to answer a trust question.

  Deliberately NOT keyed by uTools.SessionKey the way approvals are.
  Approvals answer "what may this project do", which is per-project; a
  credential answers "who am I", which is per-user.  Keying it by root would
  make the user re-paste the same key in every repository. }
function CredentialStorePath: string;

{ DPAPI, current-user scope, UI forbidden.  False rather than a degraded
  result in both directions: a failed protect means nothing is written (there
  is no plaintext path and no flag that talks one into existing), and a
  failed unprotect means the stored credential is treated as ABSENT. }
function AuthProtect(const Plain: string; out Blob: string): Boolean;
function AuthUnprotect(const Blob: string; out Plain: string): Boolean;

{ Writes pasclaude's own credential, and only that file.  Refuses when the
  protect fails or there is nowhere out-of-tree to put it. }
function AuthStore(const Token: string; out Err: string): Boolean;
{ Deletes pasclaude's own credential file, and only that file. }
function AuthClear(out Err: string): Boolean;
{ The stored source preference: which discovered source should answer.  It
  can only CHOOSE among sources already found on this machine - it can never
  introduce one, and it never outranks the two environment variables. }
function AuthPrefer: string;
function AuthSetPrefer(const SourceName: string; out Err: string): Boolean;

{ Every source, present or not, in resolution order - the /login listing. }
function AuthList: TAuthInfoArray;
{ The credential that will actually be used.  False when there is none. }
function AuthResolve(out Info: TAuthInfo): Boolean;
{ One line naming the source.  No secret, no path. }
function AuthDescribe(const Info: TAuthInfo): string;
{ Why a 401 happened and what to do about it.  Names the source and the file;
  never the value. }
function AuthDiagnose401(const Info: TAuthInfo): string;
{ Milliseconds until Info expires, or -1 when it has no known expiry.
  Negative values other than -1 cannot occur: an expired source is not
  Present. }
function AuthExpiresInMs(const Info: TAuthInfo): Int64;

var
  { Test seam, the uHttp.HttpTransport pattern: nil by default and never
    assigned by the shipped program.  A suite installs a synthetic source
    table so resolution order can be asserted without a filesystem. }
  AuthProbeOverride: procedure(out Sources: TAuthInfoArray) = nil;

implementation

uses Windows, Classes, DateUtils;

{ ------------------------------------------------------------------ DPAPI -- }

type
  DATA_BLOB = record
    cbData: DWORD;
    pbData: PByte;
  end;
  PDATA_BLOB = ^DATA_BLOB;

const
  CRYPTPROTECT_UI_FORBIDDEN = $1;

{ Declared directly rather than pulled in from a package.  A Win32 API is not
  a dependency; this is the same call every Windows program that keeps a
  secret at rest makes, and it binds the ciphertext to the user account, so a
  copied file is inert on another machine. }
function CryptProtectData(pDataIn: PDATA_BLOB; szDataDescr: PWideChar;
  pOptionalEntropy: PDATA_BLOB; pvReserved: Pointer; pPromptStruct: Pointer;
  dwFlags: DWORD; pDataOut: PDATA_BLOB): LongBool; stdcall;
  external 'crypt32.dll' name 'CryptProtectData';
function CryptUnprotectData(pDataIn: PDATA_BLOB; ppszDataDescr: PPWideChar;
  pOptionalEntropy: PDATA_BLOB; pvReserved: Pointer; pPromptStruct: Pointer;
  dwFlags: DWORD; pDataOut: PDATA_BLOB): LongBool; stdcall;
  external 'crypt32.dll' name 'CryptUnprotectData';

procedure SetBlob(out B: DATA_BLOB; const S: string);
begin
  B.cbData := Length(S);
  if S = '' then B.pbData := nil else B.pbData := PByte(PChar(S));
end;

function TakeBlob(const B: DATA_BLOB): string;
begin
  SetLength(Result, B.cbData);
  if B.cbData > 0 then Move(B.pbData^, Result[1], B.cbData);
end;

function AuthProtect(const Plain: string; out Blob: string): Boolean;
var
  InB, EntB, OutB: DATA_BLOB;
begin
  Blob := '';
  Result := False;
  if Plain = '' then Exit;
  SetBlob(InB, Plain);
  SetBlob(EntB, CredentialEntropy);
  FillChar(OutB, SizeOf(OutB), 0);
  if not CryptProtectData(@InB, nil, @EntB, nil, nil,
    CRYPTPROTECT_UI_FORBIDDEN, @OutB) then Exit;
  Blob := TakeBlob(OutB);
  if OutB.pbData <> nil then LocalFree(HLOCAL(OutB.pbData));
  Result := Blob <> '';
end;

function AuthUnprotect(const Blob: string; out Plain: string): Boolean;
var
  InB, EntB, OutB: DATA_BLOB;
begin
  Plain := '';
  Result := False;
  if Blob = '' then Exit;
  SetBlob(InB, Blob);
  SetBlob(EntB, CredentialEntropy);
  FillChar(OutB, SizeOf(OutB), 0);
  if not CryptUnprotectData(@InB, nil, @EntB, nil, nil,
    CRYPTPROTECT_UI_FORBIDDEN, @OutB) then Exit;
  Plain := TakeBlob(OutB);
  if OutB.pbData <> nil then LocalFree(HLOCAL(OutB.pbData));
  Result := Plain <> '';
end;

{ ----------------------------------------------------------------- base64 -- }

{ Hand-written, both directions, for the same reason uImage's PNG encoder is:
  the house rule is nothing beyond the RTL, and thirty lines here is cheaper
  than a package. }

const
  B64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function B64Encode(const S: string): string;
var
  I, N: Integer;
  A, B, C: Byte;
begin
  Result := '';
  I := 1;
  N := Length(S);
  while I <= N do
  begin
    A := Byte(S[I]);
    if I + 1 <= N then B := Byte(S[I + 1]) else B := 0;
    if I + 2 <= N then C := Byte(S[I + 2]) else C := 0;
    Result := Result + B64Chars[(A shr 2) + 1] +
      B64Chars[(((A and 3) shl 4) or (B shr 4)) + 1];
    if I + 1 <= N then
      Result := Result + B64Chars[(((B and 15) shl 2) or (C shr 6)) + 1]
    else
      Result := Result + '=';
    if I + 2 <= N then
      Result := Result + B64Chars[(C and 63) + 1]
    else
      Result := Result + '=';
    Inc(I, 3);
  end;
end;

function B64Value(C: Char): Integer;
begin
  case C of
    'A'..'Z': Result := Ord(C) - Ord('A');
    'a'..'z': Result := Ord(C) - Ord('a') + 26;
    '0'..'9': Result := Ord(C) - Ord('0') + 52;
    '+': Result := 62;
    '/': Result := 63;
    '=': Result := -2;
  else
    Result := -1;
  end;
end;

{ False on any character that is not base64.  A value the loader cannot
  decode is a refusal, not a best effort: the bytes are about to be handed to
  DPAPI and half a blob is not a credential. }
function B64Decode(const S: string; out Bytes: string): Boolean;
var
  I, V, Acc, Bits: Integer;
begin
  Bytes := '';
  Acc := 0;
  Bits := 0;
  for I := 1 to Length(S) do
  begin
    if S[I] in [#9, #10, #13, ' '] then Continue;
    V := B64Value(S[I]);
    if V = -2 then Break;
    if V < 0 then Exit(False);
    Acc := (Acc shl 6) or V;
    Inc(Bits, 6);
    if Bits >= 8 then
    begin
      Dec(Bits, 8);
      Bytes := Bytes + Chr((Acc shr Bits) and $FF);
    end;
  end;
  Result := True;
end;

{ -------------------------------------------------------------- utilities -- }

function NowUnixMs: Int64;
begin
  Result := Round((LocalTimeToUniversal(Now) - EncodeDate(1970, 1, 1)) *
    MSecsPerDay);
end;

function ReadFileText(const Path: string; out Text: string): Boolean;
var
  F: TFileStream;
begin
  Result := False;
  Text := '';
  if Path = '' then Exit;
  if not FileExists(Path) then Exit;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      if F.Size > MaxCredentialBytes * 8 then Exit;
      SetLength(Text, F.Size);
      if F.Size > 0 then F.ReadBuffer(Text[1], F.Size);
    finally
      F.Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

function HomeDir: string;
begin
  Result := SysUtils.GetEnvironmentVariable('USERPROFILE');
  if Result <> '' then Result := IncludeTrailingPathDelimiter(Result);
end;

function AuthSourceName(S: TAuthSource): string;
begin
  case S of
    asApiKeyEnv:    Result := 'api_key_env';
    asAuthTokenEnv: Result := 'auth_token_env';
    asStored:       Result := 'stored';
    asClaudeCode:   Result := 'claude_code';
    asJcode:        Result := 'jcode';
    asAntProfile:   Result := 'ant_profile';
  else
    Result := 'none';
  end;
end;

function AuthSourceFromName(const N: string): TAuthSource;
var
  S: TAuthSource;
begin
  for S := asApiKeyEnv to asAntProfile do
    if AuthSourceName(S) = N then Exit(S);
  Result := asNone;
end;

function AuthHint(const Token: string): string;
begin
  { Below twelve characters the two ends would overlap and the hint would be
    most of the secret, so it degrades to nothing rather than to a leak. }
  if Length(Token) < 12 then Exit('(hidden)');
  Result := Copy(Token, 1, 7) + '...' + Copy(Token, Length(Token) - 3, 4);
end;

function CredentialStorePath: string;
var
  Base: string;
begin
  Base := SysUtils.GetEnvironmentVariable('LOCALAPPDATA');
  if Base = '' then Base := SysUtils.GetEnvironmentVariable('USERPROFILE');
  { No home at all: store nothing.  Never a path inside a root - a credential
    that a git clone could carry, or the model's own read_file could open, is
    worse than no stored credential. }
  if Base = '' then Exit('');
  Result := IncludeTrailingPathDelimiter(Base) + 'pasclaude' + PathDelim +
    CredentialFileName;
end;

{ ------------------------------------------------------------- the store -- }

{ Reads our own file into a parsed document, or nil.  Callers free it. }
function LoadStoreDoc: TJson;
var
  Text, Path: string;
begin
  Result := nil;
  Path := CredentialStorePath;
  if Path = '' then Exit;
  if not ReadFileText(Path, Text) then Exit;
  Result := JsonParse(Text);
  { A document that is not an object is not our file.  Refusing it here means
    every reader below can ask for a key without first asking what shape it
    is looking at. }
  if (Result <> nil) and (Result.Kind <> jkObj) then FreeAndNil(Result);
end;

function AuthPrefer: string;
var
  Root: TJson;
begin
  Result := '';
  Root := LoadStoreDoc;
  if Root = nil then Exit;
  try
    Result := Root.Str('prefer');
    { A prefer naming a source this build does not know is no preference at
      all, rather than a source that silently never matches. }
    if AuthSourceFromName(Result) = asNone then Result := '';
  finally
    Root.Free;
  end;
end;

{ The single writer.  Takes no path: the boundary that keeps another
  program's credential file read-only is the absence of a parameter here. }
function WriteStore(const Blob, Hint, Prefer: string; out Err: string): Boolean;
var
  Root: TJson;
  Path, Text: string;
  F: TFileStream;
begin
  Err := '';
  Result := False;
  Path := CredentialStorePath;
  if Path = '' then
  begin
    Err := 'neither LOCALAPPDATA nor USERPROFILE is set, so there is ' +
      'nowhere out of the project tree to keep a credential; nothing was ' +
      'stored';
    Exit;
  end;
  Root := TJson.NewObj;
  try
    Root.AddNum('version', CredentialVersion);
    Root.AddStr('kind', 'api_key');
    if Blob <> '' then
    begin
      Root.AddStr('protected', CredentialProtection);
      Root.AddStr('value', B64Encode(Blob));
      Root.AddStr('hint', Hint);
      Root.AddNum('created', NowUnixMs div 1000);
    end;
    if Prefer <> '' then Root.AddStr('prefer', Prefer);
    Text := Root.ToJson;
  finally
    Root.Free;
  end;
  if not ForceDirectories(ExtractFilePath(Path)) then
  begin
    Err := 'cannot create ' + ExtractFilePath(Path);
    Exit;
  end;
  try
    F := TFileStream.Create(Path, fmCreate);
    try
      if Text <> '' then F.WriteBuffer(Text[1], Length(Text));
    finally
      F.Free;
    end;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Exit;
    end;
  end;
  Result := True;
end;

{ Reads back what is already stored so a write of one field does not throw
  the other away. }
procedure ReadStoreParts(out Blob, Hint, Prefer: string);
var
  Root: TJson;
  Raw: string;
begin
  Blob := '';
  Hint := '';
  Prefer := '';
  Root := LoadStoreDoc;
  if Root = nil then Exit;
  try
    Prefer := Root.Str('prefer');
    if AuthSourceFromName(Prefer) = asNone then Prefer := '';
    if Round(Root.Num('version', 0)) <> CredentialVersion then Exit;
    if Root.Str('protected') <> CredentialProtection then Exit;
    Raw := Root.Str('value');
    if (Raw = '') or (Length(Raw) > MaxCredentialBytes) then Exit;
    if not B64Decode(Raw, Blob) then
    begin
      Blob := '';
      Exit;
    end;
    Hint := Root.Str('hint');
  finally
    Root.Free;
  end;
end;

function AuthStore(const Token: string; out Err: string): Boolean;
var
  Blob, OldBlob, OldHint, Prefer: string;
begin
  Err := '';
  if Trim(Token) = '' then
  begin
    Err := 'nothing to store';
    Exit(False);
  end;
  { Protection first, and nothing is written when it fails.  There is
    deliberately no plaintext path and no flag that produces one: a store
    that quietly falls back to unprotected bytes when encryption fails is
    worse than no store at all, because the user believes the opposite. }
  if not AuthProtect(Token, Blob) then
  begin
    Err := Format('Windows could not protect the credential ' +
      '(CryptProtectData failed, error %d); nothing was stored',
      [GetLastError]);
    Exit(False);
  end;
  ReadStoreParts(OldBlob, OldHint, Prefer);
  Result := WriteStore(Blob, AuthHint(Token), Prefer, Err);
end;

function AuthClear(out Err: string): Boolean;
var
  Path: string;
begin
  Err := '';
  Path := CredentialStorePath;
  if Path = '' then
  begin
    Err := 'there is no credential store on this machine';
    Exit(False);
  end;
  if not FileExists(Path) then
  begin
    Err := 'no stored credential to remove';
    Exit(False);
  end;
  if not SysUtils.DeleteFile(Path) then
  begin
    Err := 'could not delete ' + Path;
    Exit(False);
  end;
  Result := True;
end;

function AuthSetPrefer(const SourceName: string; out Err: string): Boolean;
var
  Blob, Hint, OldPrefer: string;
begin
  Err := '';
  if (SourceName <> '') and (AuthSourceFromName(SourceName) = asNone) then
  begin
    Err := 'not a credential source: ' + SourceName;
    Exit(False);
  end;
  ReadStoreParts(Blob, Hint, OldPrefer);
  Result := WriteStore(Blob, Hint, SourceName, Err);
end;

{ --------------------------------------------------------------- probes --- }

{ An expiry field whose type is not documented.  Number below 1e11 is epoch
  seconds, above it is milliseconds; a string is tried as ISO-8601.  Anything
  else - null, 'soon', a shape nobody anticipated - returns False, and False
  means NO KNOWN EXPIRY, which counts as live.  Wrongly rejecting a working
  token is worse than a 401 we can now explain. }
function ParseExpiry(J: TJson; const Name: string; out Ms: Int64): Boolean;
var
  F: TJson;
  S: string;
  Y, M, D, H, Mi, Sec: Integer;
  Dt: TDateTime;
begin
  Ms := 0;
  Result := False;
  if J = nil then Exit;
  F := J.Find(Name);
  if F = nil then Exit;
  if F.Kind = jkNum then
  begin
    Ms := Round(F.AsNumber);
    if Ms <= 0 then Exit(False);
    if Ms < 100000000000 then Ms := Ms * 1000;
    Exit(True);
  end;
  if F.Kind <> jkStr then Exit;
  S := F.AsString;
  if Length(S) < 19 then Exit;
  Y := StrToIntDef(Copy(S, 1, 4), 0);
  M := StrToIntDef(Copy(S, 6, 2), 0);
  D := StrToIntDef(Copy(S, 9, 2), 0);
  H := StrToIntDef(Copy(S, 12, 2), -1);
  Mi := StrToIntDef(Copy(S, 15, 2), -1);
  Sec := StrToIntDef(Copy(S, 18, 2), -1);
  if (Y < 1970) or (M < 1) or (M > 12) or (D < 1) or (D > 31) or
     (H < 0) or (H > 23) or (Mi < 0) or (Mi > 59) or (Sec < 0) or (Sec > 60) then
    Exit;
  try
    Dt := EncodeDate(Y, M, D) + EncodeTime(H, Mi, Sec, 0);
  except
    Exit(False);
  end;
  Ms := Round((Dt - EncodeDate(1970, 1, 1)) * MSecsPerDay);
  Result := True;
end;

procedure InitInfo(out I: TAuthInfo; S: TAuthSource);
begin
  I.Source := S;
  I.Token := '';
  I.Path := '';
  I.Hint := '';
  I.Why := '';
  I.ExpiresMs := 0;
  I.Present := False;
  I.Decryptable := True;
end;

procedure Accept(var I: TAuthInfo; const Token: string; ExpiresMs: Int64);
begin
  I.Token := Token;
  I.Hint := AuthHint(Token);
  I.ExpiresMs := ExpiresMs;
  I.Present := True;
  I.Why := '';
end;

function ProbeEnv(S: TAuthSource; const Name: string): TAuthInfo;
var
  V: string;
begin
  InitInfo(Result, S);
  V := Trim(SysUtils.GetEnvironmentVariable(Name));
  if V = '' then
  begin
    Result.Why := Name + ' is not set';
    Exit;
  end;
  Accept(Result, V, 0);
end;

function ProbeStored: TAuthInfo;
var
  Blob, Hint, Prefer, Plain: string;
begin
  InitInfo(Result, asStored);
  Result.Path := CredentialStorePath;
  if Result.Path = '' then
  begin
    Result.Why := 'no credential store on this machine';
    Exit;
  end;
  if not FileExists(Result.Path) then
  begin
    Result.Why := 'nothing stored (/login key stores one)';
    Exit;
  end;
  ReadStoreParts(Blob, Hint, Prefer);
  if Blob = '' then
  begin
    Result.Why := 'the stored credential is not readable (/login key ' +
      'replaces it, /logout removes it)';
    Exit;
  end;
  if not AuthUnprotect(Blob, Plain) then
  begin
    { Named, not merely remedied.  A user who logged in once and is now told
      only "run /login again" reads it as a bug; told that the file was
      encrypted by a different Windows account or on a different machine,
      they know exactly what happened and that nothing was lost. }
    Result.Decryptable := False;
    Result.Why := 'the stored credential cannot be decrypted by this ' +
      'Windows user on this machine - it was protected by a different ' +
      'account or on different hardware (/login key replaces it)';
    Exit;
  end;
  Accept(Result, Plain, 0);
  Result.Hint := AuthHint(Plain);
end;

{ Claude Code's file: a claudeAiOauth object carrying accessToken and
  expiresAt.  Read-only forever.  The Why strings below are the ones the user sees when
  no credential works at all, and they are preserved word for word from the
  version that lived in pasclaude.lpr. }
function ProbeClaudeCode: TAuthInfo;
var
  Text, Tok: string;
  Root, OAuth: TJson;
  ExpiresMs: Int64;
begin
  InitInfo(Result, asClaudeCode);
  Result.Path := HomeDir + '.claude' + PathDelim + '.credentials.json';
  Result.Why := 'no Claude Code credentials';
  if HomeDir = '' then Exit;
  if not ReadFileText(Result.Path, Text) then Exit;
  Root := JsonParse(Text);
  if Root = nil then
  begin
    Result.Why := 'Claude Code credentials are not valid JSON';
    Exit;
  end;
  try
    OAuth := Root.Find('claudeAiOauth');
    if (OAuth = nil) or (OAuth.Kind <> jkObj) then
    begin
      Result.Why := 'no OAuth entry in the Claude Code credentials';
      Exit;
    end;
    if not ParseExpiry(OAuth, 'expiresAt', ExpiresMs) then ExpiresMs := 0;
    if (ExpiresMs > 0) and (NowUnixMs > ExpiresMs) then
    begin
      Result.ExpiresMs := ExpiresMs;
      Result.Why := 'the Claude Code token has expired';
      Exit;
    end;
    Tok := OAuth.Str('accessToken');
    if Tok = '' then
    begin
      Result.Why := 'the Claude Code credentials hold no token';
      Exit;
    end;
    Accept(Result, Tok, ExpiresMs);
  finally
    Root.Free;
  end;
end;

{ Jcode's file: an anthropic_accounts array whose entries carry access and
  expires.  Read-only forever. }
function ProbeJcode: TAuthInfo;
var
  Text: string;
  Root, Accts, A: TJson;
  I: Integer;
  ExpiresMs: Int64;
begin
  InitInfo(Result, asJcode);
  Result.Path := HomeDir + '.jcode' + PathDelim + 'auth.json';
  Result.Why := 'no Jcode credentials';
  if HomeDir = '' then Exit;
  if not ReadFileText(Result.Path, Text) then Exit;
  Root := JsonParse(Text);
  if Root = nil then
  begin
    Result.Why := 'Jcode credentials are not valid JSON';
    Exit;
  end;
  try
    Accts := Root.Find('anthropic_accounts');
    if (Accts = nil) or (Accts.Kind <> jkArr) or (Accts.Count = 0) then
    begin
      Result.Why := 'no accounts in the Jcode credentials';
      Exit;
    end;
    { The first account with a live token; expired ones are skipped rather
      than reported, since a later account may still work. }
    for I := 0 to Accts.Count - 1 do
    begin
      A := Accts.Item(I);
      if A = nil then Continue;
      if A.Str('access') = '' then Continue;
      if not ParseExpiry(A, 'expires', ExpiresMs) then ExpiresMs := 0;
      if (ExpiresMs > 0) and (NowUnixMs > ExpiresMs) then Continue;
      Accept(Result, A.Str('access'), ExpiresMs);
      Exit;
    end;
    Result.Why := 'every Jcode token has expired';
  finally
    Root.Free;
  end;
end;

{ The ant CLI / SDK profile store.  Config dir is $ANTHROPIC_CONFIG_DIR else
  %APPDATA%\Anthropic; the profile is $ANTHROPIC_PROFILE, else the one line
  in active_config, else 'default'.  Read-only forever, like the other two.

  The token is sk-ant-oat01-..., which the existing OauthKeyPrefix test in
  uAgent already routes to a Bearer header and the oauth beta flag, so no
  fourth request path appears anywhere for this source. }
function ProbeAntProfile: TAuthInfo;
var
  Dir, Profile, Text, Tok: string;
  L: TStringList;
  Root: TJson;
  ExpiresMs: Int64;
begin
  InitInfo(Result, asAntProfile);
  Result.Why := 'no ant profile credentials';
  Dir := SysUtils.GetEnvironmentVariable('ANTHROPIC_CONFIG_DIR');
  if Dir = '' then
  begin
    Dir := SysUtils.GetEnvironmentVariable('APPDATA');
    if Dir = '' then Exit;
    Dir := IncludeTrailingPathDelimiter(Dir) + 'Anthropic';
  end;
  Dir := IncludeTrailingPathDelimiter(Dir);
  Profile := Trim(SysUtils.GetEnvironmentVariable('ANTHROPIC_PROFILE'));
  if Profile = '' then
  begin
    if FileExists(Dir + 'active_config') then
    begin
      L := TStringList.Create;
      try
        try
          L.LoadFromFile(Dir + 'active_config');
          if L.Count > 0 then Profile := Trim(L[0]);
        except
          Profile := '';
        end;
      finally
        L.Free;
      end;
    end;
  end;
  if Profile = '' then Profile := 'default';
  { Character-filtered rather than SafePath'd, the way uTools filters a bare
    agent name: the value comes from an environment variable, and a profile
    called ..\..\something must not become a path. }
  if (Pos('/', Profile) > 0) or (Pos('\', Profile) > 0) or
     (Pos('..', Profile) > 0) or (Pos(':', Profile) > 0) then
  begin
    Result.Why := 'ANTHROPIC_PROFILE is not a plain profile name';
    Exit;
  end;
  Result.Path := Dir + 'credentials' + PathDelim + Profile + '.json';
  if not ReadFileText(Result.Path, Text) then Exit;
  Root := JsonParse(Text);
  if Root = nil then
  begin
    Result.Why := 'the ant profile credentials are not valid JSON';
    Exit;
  end;
  try
    Tok := Root.Str('access_token');
    if Tok = '' then
    begin
      Result.Why := 'the ant profile holds no access token';
      Exit;
    end;
    { Unparseable expiry means USE THE TOKEN.  expires_at's type is not
      documented, and this is another program's file: a shape we did not
      anticipate must not make pasclaude claim it cannot see a credential
      every other Anthropic client can. }
    if not ParseExpiry(Root, 'expires_at', ExpiresMs) then ExpiresMs := 0;
    if (ExpiresMs > 0) and (NowUnixMs > ExpiresMs) then
    begin
      Result.ExpiresMs := ExpiresMs;
      Result.Why := 'the ant profile token has expired';
      Exit;
    end;
    Accept(Result, Tok, ExpiresMs);
  finally
    Root.Free;
  end;
end;

{ ------------------------------------------------------------ resolution -- }

function AuthList: TAuthInfoArray;
begin
  Result := nil;
  if Assigned(AuthProbeOverride) then
  begin
    AuthProbeOverride(Result);
    Exit;
  end;
  SetLength(Result, 6);
  Result[0] := ProbeEnv(asApiKeyEnv, 'ANTHROPIC_API_KEY');
  Result[1] := ProbeEnv(asAuthTokenEnv, 'ANTHROPIC_AUTH_TOKEN');
  Result[2] := ProbeStored;
  Result[3] := ProbeClaudeCode;
  Result[4] := ProbeJcode;
  Result[5] := ProbeAntProfile;
end;

function AuthResolve(out Info: TAuthInfo): Boolean;
var
  List: TAuthInfoArray;
  I: Integer;
  Pref: string;
begin
  InitInfo(Info, asNone);
  List := AuthList;
  { The environment first and unconditionally.  prefer may only CHOOSE among
    sources already discovered; it can never introduce one and it can never
    outrank a variable the user exported for this invocation. }
  for I := 0 to High(List) do
    if List[I].Present and (List[I].Source in [asApiKeyEnv, asAuthTokenEnv]) then
    begin
      Info := List[I];
      Exit(True);
    end;
  Pref := AuthPrefer;
  if Pref <> '' then
    for I := 0 to High(List) do
      if List[I].Present and (AuthSourceName(List[I].Source) = Pref) then
      begin
        Info := List[I];
        Exit(True);
      end;
  for I := 0 to High(List) do
    if List[I].Present then
    begin
      Info := List[I];
      Exit(True);
    end;
  Result := False;
end;

function AuthDescribe(const Info: TAuthInfo): string;
begin
  case Info.Source of
    asApiKeyEnv:    Result := 'ANTHROPIC_API_KEY';
    asAuthTokenEnv: Result := 'ANTHROPIC_AUTH_TOKEN';
    asStored:       Result := 'stored key';
    asClaudeCode:   Result := 'claude code subscription';
    asJcode:        Result := 'jcode subscription';
    asAntProfile:   Result := 'ant profile';
  else
    Result := 'no credential';
  end;
end;

function AuthExpiresInMs(const Info: TAuthInfo): Int64;
begin
  if Info.ExpiresMs <= 0 then Exit(-1);
  Result := Info.ExpiresMs - NowUnixMs;
end;

function AuthDiagnose401(const Info: TAuthInfo): string;
var
  Left: Int64;
begin
  if Info.Source = asNone then
    Exit('there is no credential in force; /login lists what this machine has');
  Result := 'the credential in use came from ' + AuthDescribe(Info);
  if Info.Path <> '' then Result := Result + ' (' + Info.Path + ')';
  Left := AuthExpiresInMs(Info);
  if Left = -1 then
    Result := Result + '; it carries no expiry, so it was rejected rather ' +
      'than timed out'
  else if Left <= 0 then
    Result := Result + '; it has expired since this session started'
  else
    Result := Result + Format('; it is not expired (%d minutes left), so it ' +
      'was rejected', [Left div 60000]);
  case Info.Source of
    asApiKeyEnv, asAuthTokenEnv:
      Result := Result + '. Check the variable, or /login to use another source.';
    asStored:
      Result := Result + '. /login key stores a new one, /logout removes it.';
    asClaudeCode:
      Result := Result + '. Sign in to Claude Code again; pasclaude only ' +
        'reads that file.';
    asJcode:
      Result := Result + '. Sign in to Jcode again; pasclaude only reads ' +
        'that file.';
    asAntProfile:
      Result := Result + '. Run ant auth login again; pasclaude only reads ' +
        'that file.';
  end;
end;

end.
