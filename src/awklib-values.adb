with Ada.Long_Float_Text_IO;

package body Awklib.Values is

   HT : constant Character := Character'Val (9);

   function Is_Blank (C : Character) return Boolean is (C = ' ' or else C = HT);

   ----------------------------------------------------------------------------
   --  Numeric scanning
   ----------------------------------------------------------------------------

   --  Scan an AWK numeric token starting at From (already past leading blanks).
   --  Returns in Stop the index of the last consumed character (From - 1 if no
   --  digit was seen). Value holds the parsed magnitude with sign.
   procedure Scan_Number
     (Text  : String;
      From  : Integer;
      Stop  : out Integer;
      Value : out Number)
   is
      I         : Integer := From;
      Last      : constant Integer := Text'Last;
      Neg       : Boolean := False;
      Acc       : Long_Float := 0.0;
      Scale     : Long_Float := 1.0;
      Has_Digit : Boolean := False;
      Exp_Val   : Integer := 0;
   begin
      Stop := From - 1;
      Value := 0.0;

      if I <= Last and then (Text (I) = '+' or else Text (I) = '-') then
         Neg := Text (I) = '-';
         I := I + 1;
      end if;

      while I <= Last and then Text (I) in '0' .. '9' loop
         Acc := Acc * 10.0 + Long_Float (Character'Pos (Text (I)) - Character'Pos ('0'));
         Has_Digit := True;
         I := I + 1;
      end loop;

      if I <= Last and then Text (I) = '.' then
         I := I + 1;
         while I <= Last and then Text (I) in '0' .. '9' loop
            Scale := Scale / 10.0;
            Acc := Acc + Long_Float (Character'Pos (Text (I)) - Character'Pos ('0')) * Scale;
            Has_Digit := True;
            I := I + 1;
         end loop;
      end if;

      if not Has_Digit then
         return;
      end if;

      --  Optional exponent -- only accepted when it carries at least one digit.
      if I <= Last and then (Text (I) = 'e' or else Text (I) = 'E') then
         declare
            J             : Integer := I + 1;
            Exp_Neg       : Boolean := False;
            Exp_Has_Digit : Boolean := False;
            EV            : Integer := 0;
         begin
            if J <= Last and then (Text (J) = '+' or else Text (J) = '-') then
               Exp_Neg := Text (J) = '-';
               J := J + 1;
            end if;
            while J <= Last and then Text (J) in '0' .. '9' loop
               EV := EV * 10 + (Character'Pos (Text (J)) - Character'Pos ('0'));
               Exp_Has_Digit := True;
               J := J + 1;
            end loop;
            if Exp_Has_Digit then
               Exp_Val := (if Exp_Neg then -EV else EV);
               I := J;
            end if;
         end;
      end if;

      if Exp_Val /= 0 then
         Acc := Acc * (10.0 ** Exp_Val);
      end if;
      if Neg then
         Acc := -Acc;
      end if;

      Stop := I - 1;
      Value := Number (Acc);
   end Scan_Number;

   function Parse_Leading_Number (Text : String) return Number is
      I     : Integer := Text'First;
      Stop  : Integer;
      Value : Number;
   begin
      while I <= Text'Last and then Is_Blank (Text (I)) loop
         I := I + 1;
      end loop;
      Scan_Number (Text, I, Stop, Value);
      return Value;
   end Parse_Leading_Number;

   function Looks_Numeric (Text : String) return Boolean is
      I     : Integer := Text'First;
      Last  : Integer := Text'Last;
      Stop  : Integer;
      Value : Number;
   begin
      while I <= Last and then Is_Blank (Text (I)) loop
         I := I + 1;
      end loop;
      while Last >= I and then Is_Blank (Text (Last)) loop
         Last := Last - 1;
      end loop;
      if I > Last then
         return False;
      end if;
      Scan_Number (Text (I .. Last), I, Stop, Value);
      return Stop = Last;
   end Looks_Numeric;

   ----------------------------------------------------------------------------
   --  Number formatting
   ----------------------------------------------------------------------------

   function Integer_Image (V : Long_Long_Integer) return String is
      S : constant String := Long_Long_Integer'Image (V);
   begin
      if S (S'First) = ' ' then
         return S (S'First + 1 .. S'Last);
      else
         return S;
      end if;
   end Integer_Image;

   function Format_G6 (X : Long_Float) return String is
      Buf   : String (1 .. 128);
      First : Integer;
      Last  : Integer;
   begin
      Ada.Long_Float_Text_IO.Put (Buf, X, Aft => 6, Exp => 0);
      First := Buf'First;
      while First <= Buf'Last and then Buf (First) = ' ' loop
         First := First + 1;
      end loop;
      Last := Buf'Last;
      --  Strip trailing zeros and a dangling decimal point.
      if (for some K in First .. Last => Buf (K) = '.') then
         while Last > First and then Buf (Last) = '0' loop
            Last := Last - 1;
         end loop;
         if Last > First and then Buf (Last) = '.' then
            Last := Last - 1;
         end if;
      end if;
      return Buf (First .. Last);
   end Format_G6;

   function Number_Image (Item : Number) return String is
      X : constant Long_Float := Long_Float (Item);
   begin
      if X = Long_Float'Truncation (X) and then abs X < 1.0E18 then
         return Integer_Image (Long_Long_Integer (X));
      else
         return Format_G6 (X);
      end if;
   end Number_Image;

   ----------------------------------------------------------------------------
   --  Constructors
   ----------------------------------------------------------------------------

   function To_Value (Item : Number) return Value is
     ((Kind => Num, N => Item, S => U.Null_Unbounded_String));

   function To_Value (Item : String) return Value is
     ((Kind => Str, N => 0.0, S => U.To_Unbounded_String (Item)));

   function To_Value (Item : U.Unbounded_String) return Value is
     ((Kind => Str, N => 0.0, S => Item));

   function Make_Strnum (Item : String) return Value is
     ((Kind => Strnum, N => 0.0, S => U.To_Unbounded_String (Item)));

   ----------------------------------------------------------------------------
   --  Coercions
   ----------------------------------------------------------------------------

   function As_Number (Item : Value) return Number is
   begin
      case Item.Kind is
         when Uninitialized => return 0.0;
         when Num           => return Item.N;
         when Str | Strnum  => return Parse_Leading_Number (U.To_String (Item.S));
      end case;
   end As_Number;

   function As_String (Item : Value) return String is
   begin
      case Item.Kind is
         when Uninitialized => return "";
         when Num           => return Number_Image (Item.N);
         when Str | Strnum  => return U.To_String (Item.S);
      end case;
   end As_String;

   function As_Unbounded (Item : Value) return U.Unbounded_String is
   begin
      case Item.Kind is
         when Uninitialized => return U.Null_Unbounded_String;
         when Num           => return U.To_Unbounded_String (Number_Image (Item.N));
         when Str | Strnum  => return Item.S;
      end case;
   end As_Unbounded;

   ----------------------------------------------------------------------------
   --  Truthiness and comparison
   ----------------------------------------------------------------------------

   function Is_True (Item : Value) return Boolean is
   begin
      case Item.Kind is
         when Uninitialized => return False;
         when Num           => return Item.N /= 0.0;
         when Str           => return U.Length (Item.S) > 0;
         when Strnum        =>
            declare
               Text : constant String := U.To_String (Item.S);
            begin
               if Looks_Numeric (Text) then
                  return Parse_Leading_Number (Text) /= 0.0;
               else
                  return Text'Length > 0;
               end if;
            end;
      end case;
   end Is_True;

   function Numeric_For_Compare (Item : Value) return Boolean is
   begin
      case Item.Kind is
         when Num | Uninitialized => return True;
         when Strnum              => return Looks_Numeric (U.To_String (Item.S));
         when Str                 => return False;
      end case;
   end Numeric_For_Compare;

   function "=" (Left, Right : Value) return Boolean is
   begin
      if Left.Kind /= Right.Kind then
         return False;
      end if;
      case Left.Kind is
         when Uninitialized => return True;
         when Num           => return Left.N = Right.N;
         when Str | Strnum  => return U."=" (Left.S, Right.S);
      end case;
   end "=";

   function Compare (Left, Right : Value) return Integer is
   begin
      if Numeric_For_Compare (Left) and then Numeric_For_Compare (Right) then
         declare
            L : constant Number := As_Number (Left);
            R : constant Number := As_Number (Right);
         begin
            return (if L < R then -1 elsif L > R then 1 else 0);
         end;
      else
         declare
            L : constant String := As_String (Left);
            R : constant String := As_String (Right);
         begin
            return (if L < R then -1 elsif L > R then 1 else 0);
         end;
      end if;
   end Compare;

end Awklib.Values;
