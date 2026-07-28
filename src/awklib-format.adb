with Ada.Strings.Unbounded;    use Ada.Strings.Unbounded;
with Ada.Long_Float_Text_IO;
with Interfaces;               use Interfaces;

package body Awklib.Format is

   package V renames Awklib.Values;
   use type V.Number;
   use type V.Value_Kind;

   function Digits_Of
     (Mag : Unsigned_64; Base : Unsigned_64; Upper : Boolean) return String
   is
      Lower_Set : constant String := "0123456789abcdef";
      Upper_Set : constant String := "0123456789ABCDEF";
      Set  : constant String := (if Upper then Upper_Set else Lower_Set);
      Work : Unsigned_64 := Mag;
      Buf  : String (1 .. 64);
      Last : Natural := Buf'Last;
   begin
      if Work = 0 then
         return "0";
      end if;
      while Work > 0 loop
         Buf (Last) := Set (Natural (Work mod Base) + 1);
         Work := Work / Base;
         Last := Last - 1;
      end loop;
      return Buf (Last + 1 .. Buf'Last);
   end Digits_Of;

   function Repeat (C : Character; N : Integer) return String is
   begin
      if N <= 0 then
         return "";
      end if;
      return [1 .. N => C];
   end Repeat;

   --  C-printf rendering of a non-negative magnitude ---------------------------

   function Trim_Spaces (S : String) return String is
      First : Integer := S'First;
   begin
      while First <= S'Last and then S (First) = ' ' loop
         First := First + 1;
      end loop;
      return S (First .. S'Last);
   end Trim_Spaces;

   --  "%f": Mag with Prec fraction digits.
   function Format_Fixed (Mag : Long_Float; Prec : Natural) return String is
      Buf : String (1 .. 512);
   begin
      --  Ada's Put does not honour Aft => 0 (it leaves a fraction), so render a
      --  zero-precision value as the nearest integer (round half to even, as C
      --  printf does). Guard the range that Long_Long_Integer can hold.
      if Prec = 0 and then abs Mag < 1.0E18 then
         return Trim_Spaces
           (Long_Long_Integer'Image (Long_Long_Integer (Long_Float'Unbiased_Rounding (Mag))));
      end if;
      Ada.Long_Float_Text_IO.Put (Buf, Mag, Aft => Prec, Exp => 0);
      return Trim_Spaces (Buf);
   end Format_Fixed;

   --  The mantissa (in [1, 10) unless Mag = 0), rendered with Prec fraction
   --  digits, and the decimal exponent -- the shared core of %e and %g.
   procedure Sci_Parts
     (Mag : Long_Float; Prec : Natural; Mantissa : out Unbounded_String; Exp : out Integer)
   is
      M     : Long_Float := Mag;
      E     : Integer := 0;
      Scale : constant Long_Float := 10.0 ** Prec;
   begin
      if Mag = 0.0 then
         Mantissa := To_Unbounded_String (Format_Fixed (0.0, Prec));
         Exp := 0;
         return;
      end if;
      while M >= 10.0 loop
         M := M / 10.0;
         E := E + 1;
      end loop;
      while M < 1.0 loop
         M := M * 10.0;
         E := E - 1;
      end loop;
      --  Round to Prec fraction digits; a carry to two integer digits bumps E.
      M := Long_Float'Rounding (M * Scale) / Scale;
      if M >= 10.0 then
         M := M / 10.0;
         E := E + 1;
      end if;
      Mantissa := To_Unbounded_String (Format_Fixed (M, Prec));
      Exp := E;
   end Sci_Parts;

   --  "e+NN" / "E-NN": signed, at least two exponent digits.
   function Exp_Suffix (Exp : Integer; Upper : Boolean) return String is
      Body_S : constant String := Trim_Spaces (Integer'Image (abs Exp));
      Padded : constant String := (if Body_S'Length < 2 then "0" & Body_S else Body_S);
   begin
      return (if Upper then "E" else "e") & (if Exp < 0 then "-" else "+") & Padded;
   end Exp_Suffix;

   --  "%e"/"%E".
   function Format_Sci (Mag : Long_Float; Prec : Natural; Upper : Boolean) return String is
      Mant : Unbounded_String;
      Exp  : Integer;
   begin
      Sci_Parts (Mag, Prec, Mant, Exp);
      return To_String (Mant) & Exp_Suffix (Exp, Upper);
   end Format_Sci;

   --  Drop trailing fraction zeros (and a bare trailing point) from an
   --  exponent-free numeric string -- %g's shortest form.
   function Strip_Zeros (S : String) return String is
      Last    : Integer := S'Last;
      Has_Dot : Boolean := False;
   begin
      for C of S loop
         Has_Dot := Has_Dot or else C = '.';
      end loop;
      if not Has_Dot then
         return S;
      end if;
      while Last > S'First and then S (Last) = '0' loop
         Last := Last - 1;
      end loop;
      if Last >= S'First and then S (Last) = '.' then
         Last := Last - 1;
      end if;
      return S (S'First .. Last);
   end Strip_Zeros;

   --  "%g"/"%G": %e when the exponent is < -4 or >= precision, else %f, with
   --  trailing zeros stripped unless the alternate ('#') form is asked for.
   function Format_Gen (Mag : Long_Float; Prec : Natural; Upper, Alt : Boolean) return String is
      P    : constant Natural := (if Prec = 0 then 1 else Prec);
      Mant : Unbounded_String;
      Exp  : Integer;
   begin
      Sci_Parts (Mag, P - 1, Mant, Exp);
      if Exp < -4 or else Exp >= P then
         return
           (if Alt then To_String (Mant) else Strip_Zeros (To_String (Mant)))
           & Exp_Suffix (Exp, Upper);
      else
         declare
            F : constant String := Format_Fixed (Mag, P - 1 - Exp);
         begin
            return (if Alt then F else Strip_Zeros (F));
         end;
      end if;
   end Format_Gen;

   function Sprintf (Fmt : String; Args : Value_Array) return String is
      Out_Buf : Unbounded_String;
      Arg_Idx : Integer := Args'First;
      I       : Integer := Fmt'First;

      function Next_Arg return V.Value is
      begin
         if Arg_Idx <= Args'Last then
            return R : constant V.Value := Args (Arg_Idx) do
               Arg_Idx := Arg_Idx + 1;
            end return;
         else
            return V.Uninitialized_Value;
         end if;
      end Next_Arg;

      --  Emit S into the field of the given width, honouring left-justify.
      procedure Emit_Field (S : String; Width : Integer; Left : Boolean) is
         Pad : constant Integer := Width - S'Length;
      begin
         if Left then
            Append (Out_Buf, S);
            Append (Out_Buf, Repeat (' ', Pad));
         else
            Append (Out_Buf, Repeat (' ', Pad));
            Append (Out_Buf, S);
         end if;
      end Emit_Field;

      --  Emit a signed integer conversion (d/i) or unsigned (o/u/x/X).
      procedure Emit_Integer
        (Val        : V.Value;
         Base       : Unsigned_64;
         Upper      : Boolean;
         Signed     : Boolean;
         Flag_Minus : Boolean;
         Flag_Plus  : Boolean;
         Flag_Space : Boolean;
         Flag_Zero  : Boolean;
         Width      : Integer;
         Prec       : Integer;   --  -1 => unspecified
         Alt        : Boolean;
         Alt_Prefix : String)
      is
         Num  : constant V.Number := V.As_Number (Val);
         Neg  : constant Boolean := Signed and then Num < 0.0;
         Mag  : Unsigned_64;
         Sign : constant String :=
           (if Neg then "-" elsif Flag_Plus then "+" elsif Flag_Space then " " else "");
      begin
         --  Magnitude only; sign display is handled separately. For unsigned
         --  conversions of a negative value (never produced by AWK's own
         --  numeric operations here) this takes the absolute value.
         Mag := Unsigned_64 (Long_Long_Integer (V.Number'Truncation (abs Num)));

         declare
            Raw    : constant String := Digits_Of (Mag, Base, Upper);
            Zeros  : constant Integer :=
              (if Prec >= 0 and then Prec > Raw'Length then Prec - Raw'Length else 0);
            Prefix : constant String :=
              (if Alt and then Mag /= 0 then Alt_Prefix else "");
            --  A precision of 0 with a zero value yields no digits.
            Body_Digits : constant String :=
              (if Prec = 0 and then Mag = 0 then "" else Repeat ('0', Zeros) & Raw);
         begin
            declare
               Core : constant String := Sign & Prefix & Body_Digits;
            begin
               if Flag_Zero and then not Flag_Minus and then Prec < 0
                 and then Width > Core'Length
               then
                  --  Zero-pad after the sign/prefix.
                  Append (Out_Buf,
                          Sign & Prefix
                          & Repeat ('0', Width - Core'Length) & Body_Digits);
               else
                  Emit_Field (Core, Width, Flag_Minus);
               end if;
            end;
         end;
      end Emit_Integer;

      procedure Emit_Float
        (Val        : V.Value;
         Conv       : Character;
         Flag_Minus : Boolean;
         Flag_Plus  : Boolean;
         Flag_Space : Boolean;
         Flag_Zero  : Boolean;
         Width      : Integer;
         Prec       : Integer)
      is
         X    : constant Long_Float := Long_Float (V.As_Number (Val));
         P    : constant Natural := (if Prec < 0 then 6 else Prec);
         Core : Unbounded_String;
      begin
         case Conv is
            when 'f' | 'F' =>
               Core := To_Unbounded_String (Format_Fixed (abs X, P));
            when 'e' | 'E' =>
               Core := To_Unbounded_String (Format_Sci (abs X, P, Conv = 'E'));
            when others =>   --  'g','G'
               Core := To_Unbounded_String (Format_Gen (abs X, P, Conv = 'G', Alt => False));
         end case;
         declare
            Sign : constant String :=
              (if X < 0.0 then "-" elsif Flag_Plus then "+"
               elsif Flag_Space then " " else "");
            Full : constant String := Sign & To_String (Core);
         begin
            if Flag_Zero and then not Flag_Minus and then Width > Full'Length then
               Append (Out_Buf, Sign & Repeat ('0', Width - Full'Length) & To_String (Core));
            else
               Emit_Field (Full, Width, Flag_Minus);
            end if;
         end;
      end Emit_Float;

   begin
      while I <= Fmt'Last loop
         if Fmt (I) /= '%' then
            Append (Out_Buf, Fmt (I));
            I := I + 1;
         else
            I := I + 1;
            if I > Fmt'Last then
               Append (Out_Buf, '%');
               exit;
            elsif Fmt (I) = '%' then
               Append (Out_Buf, '%');
               I := I + 1;
            else
               declare
                  Flag_Minus, Flag_Plus, Flag_Space, Flag_Zero, Alt : Boolean := False;
                  Width : Integer := 0;
                  Prec  : Integer := -1;
               begin
                  --  Flags
                  loop
                     exit when I > Fmt'Last;
                     case Fmt (I) is
                        when '-' => Flag_Minus := True;
                        when '+' => Flag_Plus := True;
                        when ' ' => Flag_Space := True;
                        when '0' => Flag_Zero := True;
                        when '#' => Alt := True;
                        when others => exit;
                     end case;
                     I := I + 1;
                  end loop;
                  --  Width
                  if I <= Fmt'Last and then Fmt (I) = '*' then
                     Width := Integer (V.As_Number (Next_Arg));
                     if Width < 0 then
                        Flag_Minus := True;
                        Width := -Width;
                     end if;
                     I := I + 1;
                  else
                     while I <= Fmt'Last and then Fmt (I) in '0' .. '9' loop
                        Width := Width * 10 + (Character'Pos (Fmt (I)) - Character'Pos ('0'));
                        I := I + 1;
                     end loop;
                  end if;
                  --  Precision
                  if I <= Fmt'Last and then Fmt (I) = '.' then
                     I := I + 1;
                     Prec := 0;
                     if I <= Fmt'Last and then Fmt (I) = '*' then
                        Prec := Integer (V.As_Number (Next_Arg));
                        if Prec < 0 then
                           Prec := -1;
                        end if;
                        I := I + 1;
                     else
                        while I <= Fmt'Last and then Fmt (I) in '0' .. '9' loop
                           Prec := Prec * 10 + (Character'Pos (Fmt (I)) - Character'Pos ('0'));
                           I := I + 1;
                        end loop;
                     end if;
                  end if;
                  --  Conversion
                  if I > Fmt'Last then
                     exit;
                  end if;
                  declare
                     Conv : constant Character := Fmt (I);
                  begin
                     I := I + 1;
                     case Conv is
                        when 'd' | 'i' =>
                           Emit_Integer (Next_Arg, 10, False, True,
                                         Flag_Minus, Flag_Plus, Flag_Space, Flag_Zero,
                                         Width, Prec, Alt, "");
                        when 'o' =>
                           Emit_Integer (Next_Arg, 8, False, False,
                                         Flag_Minus, Flag_Plus, Flag_Space, Flag_Zero,
                                         Width, Prec, Alt, "0");
                        when 'u' =>
                           Emit_Integer (Next_Arg, 10, False, False,
                                         Flag_Minus, Flag_Plus, Flag_Space, Flag_Zero,
                                         Width, Prec, False, "");
                        when 'x' =>
                           Emit_Integer (Next_Arg, 16, False, False,
                                         Flag_Minus, Flag_Plus, Flag_Space, Flag_Zero,
                                         Width, Prec, Alt, "0x");
                        when 'X' =>
                           Emit_Integer (Next_Arg, 16, True, False,
                                         Flag_Minus, Flag_Plus, Flag_Space, Flag_Zero,
                                         Width, Prec, Alt, "0X");
                        when 'c' =>
                           declare
                              A : constant V.Value := Next_Arg;
                              S : constant String := V.As_String (A);
                              Ch : String (1 .. 1);
                           begin
                              if A.Kind = V.Num then
                                 Ch (1) := Character'Val (Integer (V.As_Number (A)) mod 256);
                              elsif S'Length > 0 then
                                 Ch (1) := S (S'First);
                              else
                                 Ch (1) := Character'Val (0);
                              end if;
                              Emit_Field (Ch, Width, Flag_Minus);
                           end;
                        when 's' =>
                           declare
                              S : constant String := V.As_String (Next_Arg);
                           begin
                              if Prec >= 0 and then Prec < S'Length then
                                 Emit_Field (S (S'First .. S'First + Prec - 1), Width, Flag_Minus);
                              else
                                 Emit_Field (S, Width, Flag_Minus);
                              end if;
                           end;
                        when 'e' | 'E' | 'f' | 'F' | 'g' | 'G' =>
                           Emit_Float (Next_Arg, Conv,
                                       Flag_Minus, Flag_Plus, Flag_Space, Flag_Zero,
                                       Width, Prec);
                        when others =>
                           Append (Out_Buf, '%');
                           Append (Out_Buf, Conv);
                     end case;
                  end;
               end;
            end if;
         end if;
      end loop;

      return To_String (Out_Buf);
   end Sprintf;

end Awklib.Format;
