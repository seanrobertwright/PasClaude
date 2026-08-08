{ uImage - image bytes for the request body, with no decoder and no package.

  The API accepts png, jpeg, gif and webp.  A file the user mentions already
  is one of those, so for files this unit only has to recognise the format and
  read its dimensions; the bytes go up untouched.  The clipboard is the hard
  case: Windows hands over CF_DIB, raw pixels, which the API will not take, so
  something here has to produce a real PNG.

  A PNG needs a zlib stream, and FPC's paszlib is a package rather than part
  of the RTL, which this project may not use.  The way out is that a zlib
  stream may legally consist of STORED deflate blocks - uncompressed runs with
  a four-byte header - which need only CRC-32 and Adler-32, both a few lines.
  The cost is that the file is roughly the size of the raw pixels, and that
  cost is why EncodePngIndexed exists: a terminal or IDE screenshot has very
  few distinct colours, and a palette makes it three times smaller for exactly
  the images people paste.

  Everything here is a pure function over byte strings: no Win32, no console,
  no JSON.  That is deliberate - the clipboard handle work stays in the host,
  so the awkward parts (a bottom-up DIB, a truncated header) are testable
  without a clipboard.  Every parser bounds-checks the sizes its input claims
  against the buffer it actually got: a DIB comes from any process on the
  machine, and a header saying 40000x40000 must be refused rather than
  believed. }
unit uImage;

{$mode objfpc}{$H+}

interface

const
  { The API's hard ceiling on either dimension.  Anything larger is refused
    rather than resized, because a caller that hands over a 20000px image has
    misunderstood what it is sending. }
  MaxImageDim = 8000;
  { The high-resolution tier's long edge and visual-token cap.  Beyond this
    the API downscales for us, so paying to upload the extra pixels buys
    nothing. }
  TierMaxEdge = 2576;
  TierMaxTokens = 4784;

{ Base64 with no line breaks - the API wants none, and the result is pure
  ASCII, so it is trivially valid UTF-8 wherever it lands. }
function Base64Encode(const S: RawByteString): string;

{ Recognises the four media types the API accepts and reads the dimensions.
  True with W and H set on success; True with W = H = 0 when the type is
  certain but the header was too short or too odd to measure, since a legal
  image whose size we cannot state is still worth sending.  False for
  anything else, BMP included - the API rejects image/bmp outright, so
  guessing there would turn a local problem into a 400. }
function SniffImage(const B: RawByteString; out Media: string;
  out W, H: Integer): Boolean;

{ What the image will cost, in visual tokens: the documented patch formula
  ceil(w/28) * ceil(h/28), applied after the tier's own downscale.  This is
  the number the user is shown before the image is attached, so it has to be
  the number that gets billed rather than a rule of thumb. }
function VisualTokens(W, H: Integer): Integer;

{ 8-bit truecolour PNG over stored deflate blocks. }
function EncodePng(const Rgb: RawByteString; W, H: Integer): RawByteString;

{ The same, palettised, when the image has 256 distinct colours or fewer.
  False (with Png untouched) when it has more, so the caller falls back. }
function EncodePngIndexed(const Rgb: RawByteString; W, H: Integer;
  out Png: RawByteString): Boolean;

{ Encodes, halving the dimensions and retrying while the result is over
  MaxBytes.  At most two halvings: a quarter-scale screenshot is still
  readable, a sixteenth is not, and an honest refusal beats an image the user
  cannot check.  False when it still does not fit. }
function EncodePngAuto(const Rgb: RawByteString; W, H: Integer;
  MaxBytes: Integer; out Png: RawByteString;
  out OutW, OutH: Integer): Boolean;

{ Integer box filter.  Good enough for a screenshot and free of the ringing a
  sharper kernel would add to text. }
function Downscale(const Rgb: RawByteString; W, H, NewW, NewH: Integer)
  : RawByteString;

{ CF_DIB to packed RGB, top-down.  Handles the two layouts a screenshot
  actually arrives in - 24bpp BI_RGB and 32bpp BI_BITFIELDS with the standard
  BGRA masks - and refuses anything else by name rather than guessing. }
function DibToRgb(const Dib: RawByteString; out Rgb: RawByteString;
  out W, H: Integer; out Err: string): Boolean;

{ Public only as test seams: a suite can check the checksums against known
  values without owning a PNG decoder, which is the house rule about exposing
  logic that would otherwise need something external to exercise. }
function Crc32Str(const S: RawByteString): LongWord;
function Adler32Str(const S: RawByteString): LongWord;

implementation

uses SysUtils;

{ ------------------------------------------------------------- checksums -- }

var
  CrcTable: array[0..255] of LongWord;
  CrcReady: Boolean = False;

procedure MakeCrcTable;
var
  N, K: Integer;
  C: LongWord;
begin
  for N := 0 to 255 do
  begin
    C := LongWord(N);
    for K := 0 to 7 do
      if (C and 1) <> 0 then
        C := $EDB88320 xor (C shr 1)
      else
        C := C shr 1;
    CrcTable[N] := C;
  end;
  CrcReady := True;
end;

function Crc32Str(const S: RawByteString): LongWord;
var
  I: Integer;
  C: LongWord;
begin
  if not CrcReady then MakeCrcTable;
  C := $FFFFFFFF;
  for I := 1 to Length(S) do
    C := CrcTable[(C xor LongWord(Byte(S[I]))) and $FF] xor (C shr 8);
  Result := C xor $FFFFFFFF;
end;

{ Adler-32 is two running sums modulo 65521.  Reducing every 4096 bytes keeps
  the accumulators inside 32 bits without a division per byte. }
function Adler32Str(const S: RawByteString): LongWord;
const
  Base = 65521;
var
  A, B: LongWord;
  I: Integer;
begin
  A := 1;
  B := 0;
  for I := 1 to Length(S) do
  begin
    Inc(A, Byte(S[I]));
    Inc(B, A);
    if (I mod 4096) = 0 then
    begin
      A := A mod Base;
      B := B mod Base;
    end;
  end;
  A := A mod Base;
  B := B mod Base;
  Result := (B shl 16) or A;
end;

{ ----------------------------------------------------------------- base64 -- }

function Base64Encode(const S: RawByteString): string;
const
  Alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var
  I, N, Outp: Integer;
  V: LongWord;
begin
  N := Length(S);
  SetLength(Result, ((N + 2) div 3) * 4);
  Outp := 1;
  I := 1;
  while I + 2 <= N do
  begin
    V := (LongWord(Byte(S[I])) shl 16) or (LongWord(Byte(S[I + 1])) shl 8) or
         LongWord(Byte(S[I + 2]));
    Result[Outp]     := Alpha[((V shr 18) and 63) + 1];
    Result[Outp + 1] := Alpha[((V shr 12) and 63) + 1];
    Result[Outp + 2] := Alpha[((V shr 6) and 63) + 1];
    Result[Outp + 3] := Alpha[(V and 63) + 1];
    Inc(Outp, 4);
    Inc(I, 3);
  end;
  if I <= N then
  begin
    if I + 1 <= N then
      V := (LongWord(Byte(S[I])) shl 16) or (LongWord(Byte(S[I + 1])) shl 8)
    else
      V := LongWord(Byte(S[I])) shl 16;
    Result[Outp]     := Alpha[((V shr 18) and 63) + 1];
    Result[Outp + 1] := Alpha[((V shr 12) and 63) + 1];
    if I + 1 <= N then
      Result[Outp + 2] := Alpha[((V shr 6) and 63) + 1]
    else
      Result[Outp + 2] := '=';
    Result[Outp + 3] := '=';
  end;
end;

{ ------------------------------------------------------------------ sniff -- }

function Be16(const B: RawByteString; P: Integer): Integer;
begin
  Result := (Byte(B[P]) shl 8) or Byte(B[P + 1]);
end;

function Le16(const B: RawByteString; P: Integer): Integer;
begin
  Result := Byte(B[P]) or (Byte(B[P + 1]) shl 8);
end;

function Be32(const B: RawByteString; P: Integer): LongWord;
begin
  Result := (LongWord(Byte(B[P])) shl 24) or (LongWord(Byte(B[P + 1])) shl 16) or
            (LongWord(Byte(B[P + 2])) shl 8) or LongWord(Byte(B[P + 3]));
end;

function Le32(const B: RawByteString; P: Integer): LongWord;
begin
  Result := LongWord(Byte(B[P])) or (LongWord(Byte(B[P + 1])) shl 8) or
            (LongWord(Byte(B[P + 2])) shl 16) or (LongWord(Byte(B[P + 3])) shl 24);
end;

{ A dimension only counts if it is sane.  Anything else reports 0, which the
  callers read as "unknown" rather than as a measurement. }
function SaneDim(V: LongWord): Integer;
begin
  if (V = 0) or (V > 200000) then Result := 0 else Result := Integer(V);
end;

{ JPEG carries its size in a start-of-frame segment, which sits an unknown
  distance in behind any number of other segments, so the only way to find it
  is to walk the chain.  Height comes before width, which is the reverse of
  every other format here and the classic way to get this wrong. }
function SniffJpeg(const B: RawByteString; out W, H: Integer): Boolean;
var
  P, N, SegLen: Integer;
  Mk: Byte;
begin
  W := 0;
  H := 0;
  Result := True;
  N := Length(B);
  P := 3;
  while P + 1 <= N do
  begin
    if Byte(B[P]) <> $FF then Exit;
    Mk := Byte(B[P + 1]);
    { Standalone markers carry no length. }
    if (Mk = $D8) or (Mk = $01) or ((Mk >= $D0) and (Mk <= $D7)) then
    begin
      Inc(P, 2);
      Continue;
    end;
    if Mk = $FF then begin Inc(P); Continue; end;   { fill byte }
    if P + 3 > N then Exit;
    SegLen := Be16(B, P + 2);
    if SegLen < 2 then Exit;
    { The SOF family, minus DHT ($C4), JPG ($C8) and DAC ($CC), which share
      the range but are not frame headers. }
    if ((Mk >= $C0) and (Mk <= $CF)) and (Mk <> $C4) and (Mk <> $C8) and
       (Mk <> $CC) then
    begin
      if P + 9 > N then Exit;
      H := SaneDim(Be16(B, P + 5));
      W := SaneDim(Be16(B, P + 7));
      Exit;
    end;
    { Entropy-coded data follows the scan header and cannot be walked. }
    if Mk = $DA then Exit;
    Inc(P, 2 + SegLen);
  end;
end;

{ WebP puts its dimensions in one of three chunk layouts.  When the chunk is
  one we cannot read, the type is still certainly image/webp, so this reports
  True with zeroes rather than refusing a legal file. }
function SniffWebp(const B: RawByteString; out W, H: Integer): Boolean;
var
  N: Integer;
  Tag: string;
  V: LongWord;
begin
  W := 0;
  H := 0;
  Result := True;
  N := Length(B);
  if N < 16 then Exit;
  Tag := Copy(B, 13, 4);
  if Tag = 'VP8 ' then
  begin
    { Lossy: a three-byte frame tag, the 9D 01 2A start code, then two
      little-endian 14-bit fields. }
    if N < 30 then Exit;
    if (Byte(B[24]) <> $9D) or (Byte(B[25]) <> $01) or (Byte(B[26]) <> $2A) then
      Exit;
    W := SaneDim(Le16(B, 27) and $3FFF);
    H := SaneDim(Le16(B, 29) and $3FFF);
  end
  else if Tag = 'VP8L' then
  begin
    if N < 25 then Exit;
    if Byte(B[21]) <> $2F then Exit;
    V := Le32(B, 22);
    W := SaneDim((V and $3FFF) + 1);
    H := SaneDim(((V shr 14) and $3FFF) + 1);
  end
  else if Tag = 'VP8X' then
  begin
    { Extended: canvas size as two three-byte little-endian minus-one fields. }
    if N < 30 then Exit;
    W := SaneDim(LongWord(Byte(B[25])) or (LongWord(Byte(B[26])) shl 8) or
                 (LongWord(Byte(B[27])) shl 16) + 1);
    H := SaneDim(LongWord(Byte(B[28])) or (LongWord(Byte(B[29])) shl 8) or
                 (LongWord(Byte(B[30])) shl 16) + 1);
  end;
end;

function SniffImage(const B: RawByteString; out Media: string;
  out W, H: Integer): Boolean;
var
  N: Integer;
begin
  Media := '';
  W := 0;
  H := 0;
  Result := False;
  N := Length(B);
  if N < 4 then Exit;

  if (N >= 8) and (Byte(B[1]) = $89) and (Copy(B, 2, 3) = 'PNG') and
     (Byte(B[5]) = $0D) and (Byte(B[6]) = $0A) and (Byte(B[7]) = $1A) and
     (Byte(B[8]) = $0A) then
  begin
    Media := 'image/png';
    { IHDR must be the first chunk, so the sizes sit at fixed offsets - but a
      file truncated to the signature has neither, hence the length test. }
    if (N >= 24) and (Copy(B, 13, 4) = 'IHDR') then
    begin
      W := SaneDim(Be32(B, 17));
      H := SaneDim(Be32(B, 21));
    end;
    Exit(True);
  end;

  if (N >= 6) and ((Copy(B, 1, 6) = 'GIF87a') or (Copy(B, 1, 6) = 'GIF89a')) then
  begin
    Media := 'image/gif';
    if N >= 10 then
    begin
      W := SaneDim(Le16(B, 7));
      H := SaneDim(Le16(B, 9));
    end;
    Exit(True);
  end;

  if (Byte(B[1]) = $FF) and (Byte(B[2]) = $D8) and (Byte(B[3]) = $FF) then
  begin
    Media := 'image/jpeg';
    SniffJpeg(B, W, H);
    Exit(True);
  end;

  if (N >= 12) and (Copy(B, 1, 4) = 'RIFF') and (Copy(B, 9, 4) = 'WEBP') then
  begin
    Media := 'image/webp';
    SniffWebp(B, W, H);
    Exit(True);
  end;
end;

{ ------------------------------------------------------------------ tokens -- }

function CeilDiv(A, B: Integer): Integer;
begin
  if B <= 0 then Exit(0);
  Result := (A + B - 1) div B;
end;

function VisualTokens(W, H: Integer): Integer;
var
  LongEdge, ShortEdge, NW, NH: Integer;
begin
  Result := 0;
  if (W <= 0) or (H <= 0) then Exit;
  NW := W;
  NH := H;
  { The tier downscales anything over its long edge before charging for it,
    preserving aspect, so the estimate has to do the same or it overstates a
    4K screenshot by a factor of three. }
  if W >= H then
  begin
    LongEdge := W;
    ShortEdge := H;
  end
  else
  begin
    LongEdge := H;
    ShortEdge := W;
  end;
  if LongEdge > TierMaxEdge then
  begin
    ShortEdge := (ShortEdge * TierMaxEdge) div LongEdge;
    if ShortEdge < 1 then ShortEdge := 1;
    if W >= H then
    begin
      NW := TierMaxEdge;
      NH := ShortEdge;
    end
    else
    begin
      NH := TierMaxEdge;
      NW := ShortEdge;
    end;
  end;
  Result := CeilDiv(NW, 28) * CeilDiv(NH, 28);
  { An extreme aspect ratio survives the long-edge clamp with more patches
    than the tier will bill, so the documented ceiling is applied outright. }
  if Result > TierMaxTokens then Result := TierMaxTokens;
end;

{ -------------------------------------------------------------------- PNG -- }

{ A growable byte buffer.  Appending to a RawByteString directly reallocates
  per call, and a truecolour PNG is built from millions of small appends. }
type
  TBuf = record
    Data: RawByteString;
    Len: Integer;
  end;

procedure BufInit(out B: TBuf; Cap: Integer);
begin
  if Cap < 64 then Cap := 64;
  SetLength(B.Data, Cap);
  B.Len := 0;
end;

procedure BufNeed(var B: TBuf; N: Integer);
var
  Cap: Integer;
begin
  if B.Len + N <= Length(B.Data) then Exit;
  Cap := Length(B.Data) * 2;
  if Cap < B.Len + N then Cap := B.Len + N + 1024;
  SetLength(B.Data, Cap);
end;

procedure BufByte(var B: TBuf; V: Byte);
begin
  BufNeed(B, 1);
  Inc(B.Len);
  B.Data[B.Len] := Chr(V);
end;

procedure BufStr(var B: TBuf; const S: RawByteString);
begin
  if S = '' then Exit;
  BufNeed(B, Length(S));
  Move(S[1], B.Data[B.Len + 1], Length(S));
  Inc(B.Len, Length(S));
end;

function BufDone(const B: TBuf): RawByteString;
begin
  Result := Copy(B.Data, 1, B.Len);
end;

function Be32Str(V: LongWord): RawByteString;
begin
  SetLength(Result, 4);
  Result[1] := Chr((V shr 24) and $FF);
  Result[2] := Chr((V shr 16) and $FF);
  Result[3] := Chr((V shr 8) and $FF);
  Result[4] := Chr(V and $FF);
end;

{ length, type, data, CRC over type+data - the CRC deliberately excludes the
  length field, which is the classic off-by-one-field in a hand-written PNG. }
procedure PutChunk(var B: TBuf; const Tag: RawByteString;
  const Data: RawByteString);
begin
  BufStr(B, Be32Str(LongWord(Length(Data))));
  BufStr(B, Tag);
  BufStr(B, Data);
  BufStr(B, Be32Str(Crc32Str(Tag + Data)));
end;

{ Wraps raw bytes as a zlib stream of stored deflate blocks.  0x78 0x01 is
  the only header FCHECK admits for CM=8/CINFO=7 with no preset dictionary.
  Each block is BFINAL+BTYPE=00 in one byte, then LEN and its ones-complement
  NLEN little-endian, then the bytes verbatim.  NLEN is what a decoder checks
  to know it has not lost sync, so writing it as a copy of LEN produces a
  file that looks right and that nothing will open. }
function ZlibStored(const Raw: RawByteString): RawByteString;
const
  MaxBlock = 65535;
var
  B: TBuf;
  P, N, Chunk: Integer;
  Final: Boolean;
begin
  N := Length(Raw);
  BufInit(B, N + (N div MaxBlock + 1) * 5 + 16);
  BufByte(B, $78);
  BufByte(B, $01);
  P := 1;
  repeat
    Chunk := N - P + 1;
    if Chunk > MaxBlock then Chunk := MaxBlock;
    Final := (P + Chunk) > N;
    if Final then BufByte(B, 1) else BufByte(B, 0);
    BufByte(B, Chunk and $FF);
    BufByte(B, (Chunk shr 8) and $FF);
    BufByte(B, (not Chunk) and $FF);
    BufByte(B, ((not Chunk) shr 8) and $FF);
    if Chunk > 0 then
    begin
      BufNeed(B, Chunk);
      Move(Raw[P], B.Data[B.Len + 1], Chunk);
      Inc(B.Len, Chunk);
    end;
    Inc(P, Chunk);
  until Final;
  { Adler-32 covers the UNCOMPRESSED data, and is big-endian - the one
    big-endian field in a structure that is otherwise little-endian. }
  BufStr(B, Be32Str(Adler32Str(Raw)));
  Result := BufDone(B);
end;

const
  PngSig: array[0..7] of Byte = ($89, $50, $4E, $47, $0D, $0A, $1A, $0A);

function SigStr: RawByteString;
var
  I: Integer;
begin
  SetLength(Result, 8);
  for I := 0 to 7 do Result[I + 1] := Chr(PngSig[I]);
end;

function IhdrStr(W, H: Integer; ColorType: Byte): RawByteString;
begin
  Result := Be32Str(LongWord(W)) + Be32Str(LongWord(H)) +
    Chr(8) + Chr(ColorType) + Chr(0) + Chr(0) + Chr(0);
end;

function EncodePng(const Rgb: RawByteString; W, H: Integer): RawByteString;
var
  Raw: TBuf;
  Out_: TBuf;
  Y, RowBytes: Integer;
begin
  Result := '';
  if (W <= 0) or (H <= 0) then Exit;
  RowBytes := W * 3;
  if Length(Rgb) < RowBytes * H then Exit;

  { Every scanline is preceded by its filter byte; 0 means no filtering,
    which is what makes the pixel bytes copyable verbatim. }
  BufInit(Raw, H * (RowBytes + 1));
  for Y := 0 to H - 1 do
  begin
    BufByte(Raw, 0);
    BufNeed(Raw, RowBytes);
    Move(Rgb[Y * RowBytes + 1], Raw.Data[Raw.Len + 1], RowBytes);
    Inc(Raw.Len, RowBytes);
  end;

  BufInit(Out_, Raw.Len + Raw.Len div 1000 + 1024);
  BufStr(Out_, SigStr);
  PutChunk(Out_, 'IHDR', IhdrStr(W, H, 2));
  PutChunk(Out_, 'IDAT', ZlibStored(BufDone(Raw)));
  PutChunk(Out_, 'IEND', '');
  Result := BufDone(Out_);
end;

function EncodePngIndexed(const Rgb: RawByteString; W, H: Integer;
  out Png: RawByteString): Boolean;
const
  Slots = 2048;      { power of two, comfortably over the 257 we bail at }
var
  KeyTab: array[0..Slots - 1] of LongWord;
  IdxTab: array[0..Slots - 1] of Integer;
  Pal: array[0..255] of LongWord;
  NPal, I, X, Y, RowBytes, Slot: Integer;
  Key: LongWord;
  Raw, Out_: TBuf;
  Plte: RawByteString;

  { Open addressing with linear probing: returns the palette index for a
    colour, adding it when new, or -1 once the palette is full. }
  function Intern(C: LongWord): Integer;
  var
    S: Integer;
  begin
    S := Integer((C * 2654435761) mod Slots);
    while True do
    begin
      if IdxTab[S] < 0 then
      begin
        if NPal >= 256 then Exit(-1);
        KeyTab[S] := C;
        IdxTab[S] := NPal;
        Pal[NPal] := C;
        Inc(NPal);
        Exit(IdxTab[S]);
      end;
      if KeyTab[S] = C then Exit(IdxTab[S]);
      S := (S + 1) and (Slots - 1);
    end;
  end;

begin
  Result := False;
  Png := '';
  if (W <= 0) or (H <= 0) then Exit;
  RowBytes := W * 3;
  if Length(Rgb) < RowBytes * H then Exit;

  for I := 0 to Slots - 1 do IdxTab[I] := -1;
  NPal := 0;

  BufInit(Raw, H * (W + 1));
  for Y := 0 to H - 1 do
  begin
    BufByte(Raw, 0);
    BufNeed(Raw, W);
    for X := 0 to W - 1 do
    begin
      I := Y * RowBytes + X * 3 + 1;
      Key := (LongWord(Byte(Rgb[I])) shl 16) or
             (LongWord(Byte(Rgb[I + 1])) shl 8) or LongWord(Byte(Rgb[I + 2]));
      Slot := Intern(Key);
      if Slot < 0 then Exit;      { more than 256 colours: caller falls back }
      Inc(Raw.Len);
      Raw.Data[Raw.Len] := Chr(Byte(Slot));
    end;
  end;

  SetLength(Plte, NPal * 3);
  for I := 0 to NPal - 1 do
  begin
    Plte[I * 3 + 1] := Chr((Pal[I] shr 16) and $FF);
    Plte[I * 3 + 2] := Chr((Pal[I] shr 8) and $FF);
    Plte[I * 3 + 3] := Chr(Pal[I] and $FF);
  end;

  BufInit(Out_, Raw.Len + 1024);
  BufStr(Out_, SigStr);
  PutChunk(Out_, 'IHDR', IhdrStr(W, H, 3));
  PutChunk(Out_, 'PLTE', Plte);
  PutChunk(Out_, 'IDAT', ZlibStored(BufDone(Raw)));
  PutChunk(Out_, 'IEND', '');
  Png := BufDone(Out_);
  Result := True;
end;

function Downscale(const Rgb: RawByteString; W, H, NewW, NewH: Integer)
  : RawByteString;
var
  X, Y, SX0, SX1, SY0, SY1, SX, SY, N, I: Integer;
  R, G, B: Cardinal;
begin
  Result := '';
  if (W <= 0) or (H <= 0) or (NewW <= 0) or (NewH <= 0) then Exit;
  if Length(Rgb) < W * H * 3 then Exit;
  SetLength(Result, NewW * NewH * 3);
  for Y := 0 to NewH - 1 do
  begin
    SY0 := (Y * H) div NewH;
    SY1 := ((Y + 1) * H) div NewH;
    if SY1 <= SY0 then SY1 := SY0 + 1;
    if SY1 > H then SY1 := H;
    for X := 0 to NewW - 1 do
    begin
      SX0 := (X * W) div NewW;
      SX1 := ((X + 1) * W) div NewW;
      if SX1 <= SX0 then SX1 := SX0 + 1;
      if SX1 > W then SX1 := W;
      R := 0; G := 0; B := 0; N := 0;
      for SY := SY0 to SY1 - 1 do
        for SX := SX0 to SX1 - 1 do
        begin
          I := (SY * W + SX) * 3 + 1;
          Inc(R, Byte(Rgb[I]));
          Inc(G, Byte(Rgb[I + 1]));
          Inc(B, Byte(Rgb[I + 2]));
          Inc(N);
        end;
      if N = 0 then N := 1;
      I := (Y * NewW + X) * 3 + 1;
      Result[I] := Chr(R div Cardinal(N));
      Result[I + 1] := Chr(G div Cardinal(N));
      Result[I + 2] := Chr(B div Cardinal(N));
    end;
  end;
end;

function EncodePngAuto(const Rgb: RawByteString; W, H: Integer;
  MaxBytes: Integer; out Png: RawByteString;
  out OutW, OutH: Integer): Boolean;
var
  Cur: RawByteString;
  Try_: Integer;
  Try2: RawByteString;
begin
  Png := '';
  OutW := W;
  OutH := H;
  Result := False;
  Cur := Rgb;
  for Try_ := 0 to 2 do
  begin
    { Indexed first: a screenshot of a terminal or a dialog is overwhelmingly
      under 256 colours, and the palette makes it a third of the size, which
      with stored deflate is the difference between fitting and not. }
    if not EncodePngIndexed(Cur, OutW, OutH, Png) then
      Png := EncodePng(Cur, OutW, OutH);
    if Png = '' then Exit;
    if Length(Png) <= MaxBytes then Exit(True);
    if Try_ = 2 then Break;
    if (OutW div 2 < 1) or (OutH div 2 < 1) then Break;
    Try2 := Downscale(Cur, OutW, OutH, OutW div 2, OutH div 2);
    if Try2 = '' then Break;
    Cur := Try2;
    OutW := OutW div 2;
    OutH := OutH div 2;
  end;
  Png := '';
end;

{ -------------------------------------------------------------------- DIB -- }

function DibToRgb(const Dib: RawByteString; out Rgb: RawByteString;
  out W, H: Integer; out Err: string): Boolean;
var
  N, HdrSize, Bits, Comp, Stride, PixOff, PalBytes, ClrUsed: Integer;
  SrcH: LongInt;
  Y, X, Src, Dst, RowStart: Integer;
  TopDown: Boolean;
begin
  Rgb := '';
  W := 0;
  H := 0;
  Err := '';
  Result := False;
  N := Length(Dib);
  if N < 40 then
  begin
    Err := 'clipboard image header is truncated';
    Exit;
  end;
  HdrSize := Integer(Le32(Dib, 1));
  if (HdrSize < 40) or (HdrSize > N) then
  begin
    Err := 'clipboard image header size is not usable';
    Exit;
  end;
  W := Integer(Le32(Dib, 5));
  SrcH := LongInt(Le32(Dib, 9));
  Bits := Le16(Dib, 15);
  Comp := Integer(Le32(Dib, 17));
  ClrUsed := Integer(Le32(Dib, 33));

  { A negative height means the rows are already top-down; a positive one -
    which is what a screenshot actually arrives as - means they are stored
    bottom-up and have to be flipped, or every pasted image is upside down. }
  TopDown := SrcH < 0;
  if TopDown then H := Integer(-SrcH) else H := Integer(SrcH);

  if (W <= 0) or (H <= 0) or (W > MaxImageDim) or (H > MaxImageDim) then
  begin
    Err := Format('clipboard image is %dx%d, which is not usable', [W, H]);
    W := 0;
    H := 0;
    Exit;
  end;
  if (Bits <> 24) and (Bits <> 32) then
  begin
    Err := Format('clipboard image is %d-bit; only 24- and 32-bit are ' +
      'supported (save it to a file and use @path)', [Bits]);
    W := 0; H := 0;
    Exit;
  end;
  { BI_RGB is 0, BI_BITFIELDS is 3.  Anything else is a compressed payload
    this unit has no decoder for. }
  if (Comp <> 0) and (Comp <> 3) then
  begin
    Err := Format('clipboard image uses compression %d, which is not ' +
      'supported', [Comp]);
    W := 0; H := 0;
    Exit;
  end;

  { The pixels start after the header, after the three colour masks that only
    a 40-byte BI_BITFIELDS header stores separately (a V4/V5 header has them
    inside), and after any palette the producer wrote. }
  PixOff := HdrSize;
  if (Comp = 3) and (HdrSize = 40) then Inc(PixOff, 12);
  PalBytes := 0;
  if ClrUsed > 0 then PalBytes := ClrUsed * 4;
  Inc(PixOff, PalBytes);

  Stride := ((W * Bits + 31) div 32) * 4;
  { The only defence against a hostile or merely truncated clipboard payload:
    believe the header's dimensions only if the bytes to back them are there. }
  if (PixOff < 0) or (Int64(PixOff) + Int64(Stride) * H > N) then
  begin
    Err := 'clipboard image is smaller than its header claims';
    W := 0; H := 0;
    Exit;
  end;

  SetLength(Rgb, W * H * 3);
  for Y := 0 to H - 1 do
  begin
    if TopDown then
      RowStart := PixOff + Y * Stride
    else
      RowStart := PixOff + (H - 1 - Y) * Stride;
    Dst := Y * W * 3 + 1;
    for X := 0 to W - 1 do
    begin
      Src := RowStart + X * (Bits div 8) + 1;
      { Windows stores BGR(A); the API wants RGB.  32-bit alpha is dropped on
        purpose - screenshot alpha is routinely zero everywhere, and honouring
        it would produce a fully transparent image. }
      Rgb[Dst] := Dib[Src + 2];
      Rgb[Dst + 1] := Dib[Src + 1];
      Rgb[Dst + 2] := Dib[Src];
      Inc(Dst, 3);
    end;
  end;
  Result := True;
end;

end.
