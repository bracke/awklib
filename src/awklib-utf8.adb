with Ada.Strings.Unbounded;
with Ada.Wide_Wide_Characters.Handling;

package body Awklib.Utf8 is

   package U renames Ada.Strings.Unbounded;
   package WWH renames Ada.Wide_Wide_Characters.Handling;

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

   function Decode (S : String; From : Positive; Len : Positive) return Natural is
      Lead : constant Natural := Character'Pos (S (From));
   begin
      case Len is
         when 1 =>
            return Lead;
         when 2 =>
            return (Lead mod 16#20#) * 16#40#
              + (Character'Pos (S (From + 1)) mod 16#40#);
         when 3 =>
            return (Lead mod 16#10#) * 16#1000#
              + (Character'Pos (S (From + 1)) mod 16#40#) * 16#40#
              + (Character'Pos (S (From + 2)) mod 16#40#);
         when others =>
            return (Lead mod 16#08#) * 16#4_0000#
              + (Character'Pos (S (From + 1)) mod 16#40#) * 16#1000#
              + (Character'Pos (S (From + 2)) mod 16#40#) * 16#40#
              + (Character'Pos (S (From + 3)) mod 16#40#);
      end case;
   end Decode;

   function Is_Unicode_Scalar (Code : Natural) return Boolean is
     (Code <= 16#10_FFFF# and then not (Code in 16#D800# .. 16#DFFF#));

   function Convert_Case (S : String; Upper : Boolean) return String is
      Result : U.Unbounded_String;
      Rel    : Positive := 1;
   begin
      while Rel <= S'Length loop
         declare
            From : constant Positive := S'First + Rel - 1;
            Len  : constant Positive := Sequence_Length (S, From);
            Code : constant Natural := Decode (S, From, Len);
         begin
            if Len = 1 and then Code >= 16#80# then
               U.Append (Result, S (From));
            elsif Is_Unicode_Scalar (Code) then
               declare
                  Ch : constant Wide_Wide_Character := Wide_Wide_Character'Val (Code);
                  Converted : constant Wide_Wide_Character :=
                    (if Upper then WWH.To_Upper (Ch) else WWH.To_Lower (Ch));
               begin
                  U.Append (Result, Encode (Wide_Wide_Character'Pos (Converted)));
               end;
            else
               U.Append (Result, S (From .. From + Len - 1));
            end if;
            Rel := Rel + Len;
         end;
      end loop;
      return U.To_String (Result);
   end Convert_Case;

   function To_Lower (S : String) return String is (Convert_Case (S, Upper => False));

   function To_Upper (S : String) return String is (Convert_Case (S, Upper => True));

end Awklib.Utf8;
