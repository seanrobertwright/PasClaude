{ embed - the smallest program that hosts pasclaude's agent.

  It exists to be compiled.  build.cmd builds it after the main executable and
  fails the build if it does not link, which is the only thing that stops
  uSdk from quietly growing a dependency on uTerm: the facade's whole claim is
  that an embedder needs no console, and a claim nobody checks is a comment.

  Note what is absent.  No uTerm, no banner, no permission prompt - Ask is nil,
  so every gated tool refuses in band and says so in its own result.  An
  embedder that wants otherwise assigns Session.Agent.Ask itself, which is a
  deliberate act rather than a default.

      fpc -Fusrc -FUbuild\units -obin\embed.exe examples\embed.lpr }
program embed;

{$mode objfpc}{$H+}

uses SysUtils, uSdk;

var
  Session: TSdkSession;
  Key, Reply, Err: string;
begin
  Key := GetEnvironmentVariable('ANTHROPIC_API_KEY');
  if Trim(Key) = '' then
  begin
    WriteLn('set ANTHROPIC_API_KEY first');
    Halt(2);
  end;

  { Before Create, because the prompt is fixed there and a flag set afterwards
    would be a flag set too late.  Saying yes is the embedder's deliberate act
    and not the unit's default, exactly as assigning Ask is: this program is
    pointed at the directory it was started in, and the tree it finds there
    gets to write part of the system prompt through AGENTS.md, CLAUDE.md or
    .pasclaude.md.  An embedder that clones a stranger's repository into
    GetCurrentDir leaves this line out and gets the guidelines only. }
  SdkProjectContextAllowed := True;

  { Root, key, model - the model empty means the default.  The constructor
    performs the ordering that used to be spread through pasclaude.lpr: the
    root, the ignore rules, then the system prompt that names the root. }
  Session := TSdkSession.Create(GetCurrentDir, Key, '');
  try
    if Session.Ask('list the units in this project', Reply, Err) then
      WriteLn(Reply)
    else
    begin
      WriteLn('failed: ', Err);
      ExitCode := 1;
    end;
  finally
    Session.Free;
  end;
end.
