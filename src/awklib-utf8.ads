package Awklib.Utf8 is
   --  Minimal UTF-8 codepoint utilities for awk's character-oriented string
   --  functions. Strings stay UTF-8 byte sequences everywhere; these routines
   --  interpret them as sequences of codepoints. Decoding is lenient: a byte
   --  that does not begin a well-formed sequence (a stray continuation byte, an
   --  invalid lead, or a truncated tail) counts as a single one-byte character,
   --  the way gawk tolerates malformed input rather than failing.

   function Sequence_Length (S : String; From : Positive) return Positive
     with Pre => From in S'Range;
   --  Byte length (1 .. 4) of the codepoint beginning at S (From); 1 for a
   --  continuation byte, an invalid lead byte, or a truncated sequence.

   function Count (S : String) return Natural;
   --  Number of codepoints in S.

   function Char_To_Byte (S : String; Char_Pos : Positive) return Positive;
   --  Byte offset (1-based, relative to S'First, so in 1 .. S'Length + 1) at
   --  which codepoint number Char_Pos begins. A Char_Pos past the end yields
   --  S'Length + 1.

   function Byte_To_Char (S : String; Byte_Off : Positive) return Positive;
   --  Codepoint index (1-based) of the character containing the byte at the
   --  1-based relative offset Byte_Off. Byte_Off = S'Length + 1 yields
   --  Count (S) + 1.

   function Encode (Code : Natural) return String;
   --  The UTF-8 encoding of code point Code. Values beyond U+10FFFF are encoded
   --  from their low bits (lenient), never raising.

   function To_Lower (S : String) return String;
   --  Unicode-aware lowercase conversion for well-formed UTF-8 codepoints.
   --  Malformed bytes are preserved unchanged.

   function To_Upper (S : String) return String;
   --  Unicode-aware uppercase conversion for well-formed UTF-8 codepoints.
   --  Malformed bytes are preserved unchanged.

end Awklib.Utf8;
