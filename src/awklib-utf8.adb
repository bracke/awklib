package body Awklib.Utf8 is

   function Sequence_Length (S : String; From : Positive) return Positive is
      Lead : constant Natural := Character'Pos (S (From));
      Len  : Positive;
   begin
      if Lead < 16#80# then
         return 1;                       --  ASCII
      elsif Lead < 16#C0# then
         return 1;                       --  stray continuation byte
      elsif Lead < 16#E0# then
         Len := 2;
      elsif Lead < 16#F0# then
         Len := 3;
      elsif Lead < 16#F8# then
         Len := 4;
      else
         return 1;                       --  invalid lead byte
      end if;

      if From + Len - 1 > S'Last then
         return 1;                       --  truncated at end of string
      end if;
      for K in 1 .. Len - 1 loop
         declare
            B : constant Natural := Character'Pos (S (From + K));
         begin
            if B < 16#80# or else B >= 16#C0# then
               return 1;                 --  not a continuation byte
            end if;
         end;
      end loop;
      return Len;
   end Sequence_Length;

   function Count (S : String) return Natural is
      N   : Natural := 0;
      Rel : Positive := 1;
   begin
      while Rel <= S'Length loop
         Rel := Rel + Sequence_Length (S, S'First + Rel - 1);
         N := N + 1;
      end loop;
      return N;
   end Count;

   function Char_To_Byte (S : String; Char_Pos : Positive) return Positive is
      Rel : Positive := 1;
      C   : Positive := 1;
   begin
      while C < Char_Pos and then Rel <= S'Length loop
         Rel := Rel + Sequence_Length (S, S'First + Rel - 1);
         C := C + 1;
      end loop;
      return Rel;
   end Char_To_Byte;

   function Byte_To_Char (S : String; Byte_Off : Positive) return Positive is
      Rel : Positive := 1;
      C   : Positive := 1;
   begin
      while Rel <= S'Length loop
         declare
            Len : constant Positive := Sequence_Length (S, S'First + Rel - 1);
         begin
            exit when Rel + Len > Byte_Off;   --  Byte_Off falls inside this char
            Rel := Rel + Len;
            C := C + 1;
         end;
      end loop;
      return C;
   end Byte_To_Char;

   function Encode (Code : Natural) return String is
   begin
      if Code < 16#80# then
         return [1 => Character'Val (Code)];
      elsif Code < 16#800# then
         return [Character'Val (16#C0# + Code / 16#40#),
                 Character'Val (16#80# + Code mod 16#40#)];
      elsif Code < 16#1_0000# then
         return [Character'Val (16#E0# + Code / 16#1000#),
                 Character'Val (16#80# + (Code / 16#40#) mod 16#40#),
                 Character'Val (16#80# + Code mod 16#40#)];
      else
         return [Character'Val (16#F0# + (Code / 16#4_0000#) mod 16#08#),
                 Character'Val (16#80# + (Code / 16#1000#) mod 16#40#),
                 Character'Val (16#80# + (Code / 16#40#) mod 16#40#),
                 Character'Val (16#80# + Code mod 16#40#)];
      end if;
   end Encode;

end Awklib.Utf8;
