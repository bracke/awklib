with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;   use Ada.Strings.Unbounded;
with Ada.Characters.Handling;
with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Numerics.Float_Random;
with Ada.Exceptions;
with Ada.Text_IO;
with Awklib.Ast;
with Awklib.Values;
with Awklib.Format;
with Awklib.Regex;
with Awklib.Parser;
with Awklib.Utf8;

package body Awklib.Interpreter is

   package V renames Awklib.Values;
   package A renames Awklib.Ast;
   use type V.Number;
   use type V.Value_Kind;
   use type A.Expr_Access;
   use type A.Stmt_Access;
   use type A.Expr_Kind;
   use type A.Builtin_Id;
   use type A.Assign_Op;
   use type A.Bin_Op;
   use type A.Redirect_Kind;
   use type A.Pattern_Kind;
   use type A.Getline_Source;
   use type Awklib.Parser.Result_Status;

   procedure Run_Core
     (Program_Source : String;
      Input          : String;
      Assignments    : Assignment_Vectors.Vector;
      Environment    : Assignment_Vectors.Vector;
      Filename       : String;
      Output         : out U.Unbounded_String;
      Exit_Code      : out Integer;
      Status         : out Run_Status;
      Message        : out U.Unbounded_String;
      Output_Files   : out Assignment_Vectors.Vector;
      Files          : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Input_Files    : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Arguments      : String_Vectors.Vector := String_Vectors.Empty_Vector;
      Commands       : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Read_Command   : Command_Reader := null;
      Read_Record    : Record_Reader := null;
      Read_Text      : Text_Reader := null;
      Runtime_Operands : Runtime_Operand_Vectors.Vector := Runtime_Operand_Vectors.Empty_Vector;
      Read_Operand_Text : Operand_Text_Reader := null;
      Write_Output   : Output_Writer := null;
      Write_Redirection : Redirection_Writer := null;
      User_Data      : System.Address := System.Null_Address)
   is
      package LF_Math is new Ada.Numerics.Generic_Elementary_Functions (Long_Float);

      package Float_Rng renames Ada.Numerics.Float_Random;
      Rand_Gen  : Float_Rng.Generator;
      Rand_Seed : Integer := 0;

      --  AWK's '%' is C fmod (truncated remainder), not IEEE round-to-nearest.
      function Fmod (L, R : V.Number) return V.Number is
         X : constant Long_Float := Long_Float (L);
         Y : constant Long_Float := Long_Float (R);
      begin
         if Y = 0.0 then
            return 0.0;
         end if;
         return V.Number (X - Y * Long_Float'Truncation (X / Y));
      end Fmod;

      HT : constant Character := Character'Val (9);

      type Flow is (Flow_Normal, Flow_Break, Flow_Continue, Flow_Next,
                    Flow_Nextfile, Flow_Return, Flow_Exit);

      --  Containers -------------------------------------------------------------
      package Cell_Maps is new Ada.Containers.Indefinite_Hashed_Maps
        (Key_Type        => String,
         Element_Type    => V.Value,
         Hash            => Ada.Strings.Hash,
         Equivalent_Keys => "=",
         "="             => V."=");

      type Array_Ref is access Cell_Maps.Map;

      package Array_Maps is new Ada.Containers.Indefinite_Hashed_Maps
        (Key_Type        => String,
         Element_Type    => Array_Ref,
         Hash            => Ada.Strings.Hash,
         Equivalent_Keys => "=");

      type Frame is record
         Params  : A.String_Vectors.Vector;
         Scalars : Cell_Maps.Map;
         Arrays  : Array_Maps.Map;
      end record;
      type Frame_Access is access Frame;
      package Frame_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Frame_Access);

      package Ustr_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Unbounded_String, "=" => "=");

      package Str_Sets is new Ada.Containers.Indefinite_Hashed_Maps
        (Key_Type => String, Element_Type => Boolean,
         Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

      --  State ------------------------------------------------------------------
      Prog           : A.Program;
      Globals_Scalar : Cell_Maps.Map;
      Globals_Array  : Array_Maps.Map;
      Frames         : Frame_Vectors.Vector;

      Field0 : Unbounded_String;
      Fields : Ustr_Vectors.Vector;
      NF_Val : Natural := 0;

      --  The main input record stream and its cursor. Global so getline from the
      --  main input advances the same cursor the record loop reads, and NR/FNR stay
      --  consistent whichever advances a record.
      Records    : Ustr_Vectors.Vector;
      Main_Index : Natural := 0;
      NR_Count   : Natural := 0;
      FNR_Count  : Natural := 0;
      Stream_File : Unbounded_String := To_Unbounded_String (Filename);
      Stream_Has_File : Boolean := False;
      Pending_Stream_Record : Boolean := False;
      Pending_File : Unbounded_String;
      Pending_Record : Unbounded_String;
      Text_Buffer : Unbounded_String;
      Text_Buffer_File : Unbounded_String;
      Text_Has_File : Boolean := False;
      Text_End_Of_Input : Boolean := False;
      Text_Pending_Chunk : Boolean := False;
      Text_Pending_File : Unbounded_String;
      Text_Pending_Text : Unbounded_String;
      Current_Runtime_Operand : Natural := 0;
      Preloaded_Input_Initialized : Boolean := False;
      Preloaded_Input_Index : Natural := 0;
      Preloaded_Input_Name : Unbounded_String := To_Unbounded_String (Filename);

      --  getline < file: caller-provided file contents and per-file read cursors.
      package Content_Maps is new Ada.Containers.Indefinite_Hashed_Maps
        (Key_Type => String, Element_Type => Unbounded_String,
         Hash => Ada.Strings.Hash, Equivalent_Keys => "=");
      type File_Cursor is record
         Lines  : Ustr_Vectors.Vector;
         Index  : Natural := 0;
         Loaded : Boolean := False;
      end record;
      type Cursor_Access is access File_Cursor;
      package Cursor_Maps is new Ada.Containers.Indefinite_Hashed_Maps
        (Key_Type => String, Element_Type => Cursor_Access,
         Hash => Ada.Strings.Hash, Equivalent_Keys => "=");
      Getline_Content : Content_Maps.Map;
      Getline_Cursors : Cursor_Maps.Map;
      Command_Content : Content_Maps.Map;
      Command_Cursors : Cursor_Maps.Map;

      Out_Buf        : Unbounded_String;
      Truncated      : Str_Sets.Map;
      --  Redirected output captured in memory (see Output_Files): content per
      --  target, plus the first-write order so the result is deterministic.
      Redirect_Buf   : Content_Maps.Map;
      Redirect_Order : Ustr_Vectors.Vector;
      Return_Value   : V.Value := V.Uninitialized_Value;
      Exit_Code_V    : Integer := 0;
      Exiting        : Boolean := False;
      Runtime_Failed : Boolean := False;
      Runtime_Msg    : Unbounded_String;

      procedure Runtime_Error (Msg : String) is
      begin
         if not Runtime_Failed then
            Runtime_Failed := True;
            Runtime_Msg := To_Unbounded_String (Msg);
         end if;
      end Runtime_Error;

      --  Forward declarations ----------------------------------------------------
      function Eval (E : A.Expr_Access) return V.Value;
      function Exec (S : A.Stmt_Access) return Flow;
      function Call_Function (Name : String; Args : A.Expr_Vectors.Vector) return V.Value;
      procedure Set_Lvalue (Target : A.Expr_Access; Val : V.Value);
      function Get_Lvalue (Target : A.Expr_Access) return V.Value;

      function Eval_Str (E : A.Expr_Access) return String is (V.As_String (Eval (E)));
      function Eval_Num (E : A.Expr_Access) return V.Number is (V.As_Number (Eval (E)));
      function To_Int (X : V.Number) return Integer is (Integer (V.Number'Truncation (X)));

      --  Scalar access -----------------------------------------------------------
      function In_Frame return Boolean is (not Frames.Is_Empty);

      function Is_Local (Name : String) return Boolean is
      begin
         if not In_Frame then
            return False;
         end if;
         for P of Frames.Last_Element.Params loop
            if To_String (P) = Name then
               return True;
            end if;
         end loop;
         return False;
      end Is_Local;

      procedure Set_Record (S : String);   --  forward (used by Set_Scalar for $0 via NF)

      function Get_Scalar (Name : String) return V.Value is
      begin
         if Name = "NF" then
            return V.To_Value (V.Number (NF_Val));
         end if;
         if Is_Local (Name) then
            declare
               M : Cell_Maps.Map renames Frames.Last_Element.Scalars;
            begin
               if M.Contains (Name) then
                  return M.Element (Name);
               end if;
               return V.Uninitialized_Value;
            end;
         end if;
         if Globals_Scalar.Contains (Name) then
            return Globals_Scalar.Element (Name);
         end if;
         return V.Uninitialized_Value;
      end Get_Scalar;

      procedure Set_NF (K : Integer);   --  forward

      procedure Set_Scalar (Name : String; Val : V.Value) is
      begin
         if Name = "NF" then
            Set_NF (To_Int (V.As_Number (Val)));
            return;
         end if;
         if Is_Local (Name) then
            Frames.Last_Element.Scalars.Include (Name, Val);
         else
            Globals_Scalar.Include (Name, Val);
         end if;
      end Set_Scalar;

      function Get_Array (Name : String) return Array_Ref is
         procedure Ensure (M : in out Array_Maps.Map) is
         begin
            if not M.Contains (Name) then
               M.Insert (Name, new Cell_Maps.Map);
            end if;
         end Ensure;
      begin
         if Is_Local (Name) then
            Ensure (Frames.Last_Element.Arrays);
            return Frames.Last_Element.Arrays.Element (Name);
         else
            Ensure (Globals_Array);
            return Globals_Array.Element (Name);
         end if;
      end Get_Array;

      function Is_Array (Name : String) return Boolean is
      begin
         if Is_Local (Name) then
            return Frames.Last_Element.Arrays.Contains (Name);
         end if;
         return Globals_Array.Contains (Name);
      end Is_Array;

      function Get_Str (Name, Default : String) return String is
         Val : constant V.Value := Get_Scalar (Name);
      begin
         if Val.Kind = V.Uninitialized then
            return Default;
         end if;
         return V.As_String (Val);
      end Get_Str;

      --  Render a value as a string through a printf format: a genuine, non-integral
      --  number goes through Fmt; integers print plainly and a string is itself.
      --  This is how AWK stringifies numbers -- with CONVFMT in implicit contexts
      --  (concatenation, array subscripts), OFMT when printed.
      function Num_To_Str (Val : V.Value; Fmt : String) return String is
         X : Long_Float;
      begin
         if Val.Kind = V.Num then
            X := Long_Float (Val.N);
            if X = Long_Float'Truncation (X) and then abs X < 1.0E18 then
               return V.As_String (Val);
            else
               return Awklib.Format.Sprintf (Fmt, [1 => Val]);
            end if;
         else
            return V.As_String (Val);
         end if;
      end Num_To_Str;

      function Conv_Str (Val : V.Value) return String is
        (Num_To_Str (Val, Get_Str ("CONVFMT", "%.6g")));

      --  Field / record model ----------------------------------------------------
      function Is_Space (C : Character) return Boolean is
        (C = ' ' or else C = HT or else C = ASCII.LF);

      --  Split S into fields per separator Sep. Is_Regex forces regex splitting;
      --  otherwise Sep " " is the default whitespace split, a single character is
      --  a literal separator, an empty separator splits into characters, and any
      --  longer separator is treated as a regex.
      function Split_With
        (S : String; Sep : String; Is_Regex : Boolean) return Ustr_Vectors.Vector
      is
         Result : Ustr_Vectors.Vector;
      begin
         if not Is_Regex and then Sep = " " then
            declare
               I : Integer := S'First;
            begin
               while I <= S'Last loop
                  while I <= S'Last and then Is_Space (S (I)) loop
                     I := I + 1;
                  end loop;
                  exit when I > S'Last;
                  declare
                     Start : constant Integer := I;
                  begin
                     while I <= S'Last and then not Is_Space (S (I)) loop
                        I := I + 1;
                     end loop;
                     Result.Append (To_Unbounded_String (S (Start .. I - 1)));
                  end;
               end loop;
            end;
         elsif not Is_Regex and then Sep'Length = 0 then
            --  Empty separator: one element per codepoint, not per byte.
            declare
               Rel : Positive := 1;
            begin
               while Rel <= S'Length loop
                  declare
                     Len : constant Positive := Awklib.Utf8.Sequence_Length (S, S'First + Rel - 1);
                  begin
                     Result.Append (To_Unbounded_String (S (S'First + Rel - 1 .. S'First + Rel + Len - 2)));
                     Rel := Rel + Len;
                  end;
               end loop;
            end;
         elsif not Is_Regex and then Sep'Length = 1 then
            declare
               Start : Integer := S'First;
            begin
               for I in S'Range loop
                  if S (I) = Sep (Sep'First) then
                     Result.Append (To_Unbounded_String (S (Start .. I - 1)));
                     Start := I + 1;
                  end if;
               end loop;
               Result.Append (To_Unbounded_String (S (Start .. S'Last)));
            end;
         else
            --  Regex separator.
            declare
               Pos : Integer := S'First;
            begin
               if S'Length = 0 then
                  return Result;
               end if;
               loop
                  declare
                     From : constant Positive := Pos - S'First + 1;
                     M    : constant Awklib.Regex.Match := Awklib.Regex.Search (Sep, S, From);
                  begin
                     exit when not M.Matched or else M.Last < M.First;   --  none / empty
                     declare
                        Match_First : constant Integer := S'First + M.First - 1;
                        Match_Last  : constant Integer := S'First + M.Last - 1;
                     begin
                        Result.Append (To_Unbounded_String (S (Pos .. Match_First - 1)));
                        Pos := Match_Last + 1;
                     end;
                     exit when Pos > S'Last;
                  end;
               end loop;
               Result.Append (To_Unbounded_String (S (Pos .. S'Last)));
            end;
         end if;
         return Result;
      end Split_With;

      procedure Resplit is
         New_Fields : constant Ustr_Vectors.Vector :=
           Split_With (To_String (Field0), Get_Str ("FS", " "), False);
      begin
         Fields := New_Fields;
         NF_Val := Natural (Fields.Length);
      end Resplit;

      procedure Set_Record (S : String) is
      begin
         Field0 := To_Unbounded_String (S);
         Resplit;
      end Set_Record;

      procedure Rebuild_Record is
         OFS : constant String := Get_Str ("OFS", " ");
         Buf : Unbounded_String;
      begin
         for I in 1 .. NF_Val loop
            if I > 1 then
               Append (Buf, OFS);
            end if;
            if I <= Natural (Fields.Length) then
               Append (Buf, Fields.Element (I));
            end if;
         end loop;
         Field0 := Buf;
      end Rebuild_Record;

      function Get_Field (N : Integer) return String is
      begin
         if N = 0 then
            return To_String (Field0);
         elsif N >= 1 and then N <= NF_Val and then N <= Natural (Fields.Length) then
            return To_String (Fields.Element (N));
         else
            return "";
         end if;
      end Get_Field;

      procedure Set_Field (N : Integer; S : String) is
      begin
         if N = 0 then
            Set_Record (S);
            return;
         end if;
         if N < 1 then
            return;
         end if;
         while Natural (Fields.Length) < N loop
            Fields.Append (Null_Unbounded_String);
         end loop;
         Fields.Replace_Element (N, To_Unbounded_String (S));
         if N > NF_Val then
            NF_Val := N;
         end if;
         Rebuild_Record;
      end Set_Field;

      procedure Set_NF (K : Integer) is
         Kk : constant Natural := (if K < 0 then 0 else K);
      begin
         if Kk < Natural (Fields.Length) then
            while Natural (Fields.Length) > Kk loop
               Fields.Delete_Last;
            end loop;
         else
            while Natural (Fields.Length) < Kk loop
               Fields.Append (Null_Unbounded_String);
            end loop;
         end if;
         NF_Val := Kk;
         Rebuild_Record;
      end Set_NF;

      --  Subscript key ----------------------------------------------------------
      function Subscript_Key (Subs : A.Expr_Vectors.Vector) return String is
         Subsep : constant String := Get_Str ("SUBSEP", "" & Character'Val (28));
         Buf    : Unbounded_String;
         First  : Boolean := True;
      begin
         for E of Subs loop
            if not First then
               Append (Buf, Subsep);
            end if;
            Append (Buf, Conv_Str (Eval (E)));
            First := False;
         end loop;
         return To_String (Buf);
      end Subscript_Key;

      --  Regex text of an expression (regex constant or dynamic string).
      function Regex_Text (E : A.Expr_Access) return String is
      begin
         if E.Kind = A.E_Regex then
            return To_String (E.Rx);
         else
            return Eval_Str (E);
         end if;
      end Regex_Text;

      --  Split content into records on LF, dropping the trailing empty record a
      --  terminating newline would otherwise produce (default RS behaviour).
      function Split_Lines (S : String) return Ustr_Vectors.Vector is
         Result : Ustr_Vectors.Vector;
         Start  : Integer := S'First;
      begin
         if S'Length = 0 then
            return Result;
         end if;
         for I in S'Range loop
            if S (I) = ASCII.LF then
               Result.Append (To_Unbounded_String (S (Start .. I - 1)));
               Start := I + 1;
            end if;
         end loop;
         if Start <= S'Last then
            Result.Append (To_Unbounded_String (S (Start .. S'Last)));
         end if;
         return Result;
      end Split_Lines;

      --  Split input into records using the current RS. A single-character RS
      --  (the default ASCII.LF included) splits on that character; RS = "" is
      --  paragraph mode, where records are separated by runs of blank lines.
      function Split_By_RS (S : String) return Ustr_Vectors.Vector is
         RS_Str : constant String := Get_Str ("RS", "" & ASCII.LF);
         Result : Ustr_Vectors.Vector;
      begin
         if S'Length = 0 then
            return Result;
         end if;

         if RS_Str'Length = 0 then
            --  Paragraph mode: a record is a maximal run of non-empty lines.
            declare
               Lines : constant Ustr_Vectors.Vector := Split_Lines (S);
               Para  : Unbounded_String;
               Open  : Boolean := False;
            begin
               for L of Lines loop
                  if Length (L) = 0 then
                     if Open then
                        Result.Append (Para);
                        Para := Null_Unbounded_String;
                        Open := False;
                     end if;
                  else
                     if Open then
                        Append (Para, ASCII.LF);
                     end if;
                     Append (Para, L);
                     Open := True;
                  end if;
               end loop;
               if Open then
                  Result.Append (Para);
               end if;
            end;
         else
            declare
               Sep   : constant Character := RS_Str (RS_Str'First);
               Start : Integer := S'First;
            begin
               for I in S'Range loop
                  if S (I) = Sep then
                     Result.Append (To_Unbounded_String (S (Start .. I - 1)));
                     Start := I + 1;
                  end if;
               end loop;
               if Start <= S'Last then
                  Result.Append (To_Unbounded_String (S (Start .. S'Last)));
               end if;
            end;
         end if;
         return Result;
      end Split_By_RS;

      procedure Reset_Text_Input is
      begin
         Stream_Has_File := False;
         Pending_Stream_Record := False;
         Pending_File := Null_Unbounded_String;
         Pending_Record := Null_Unbounded_String;
         Text_Buffer := Null_Unbounded_String;
         Text_Buffer_File := Null_Unbounded_String;
         Text_Has_File := False;
         Text_End_Of_Input := False;
         Text_Pending_Chunk := False;
         Text_Pending_File := Null_Unbounded_String;
         Text_Pending_Text := Null_Unbounded_String;
      end Reset_Text_Input;

      function First_Input_Operand return Natural is
      begin
         for Index in 1 .. Natural (Runtime_Operands.Length) loop
            if Runtime_Operands.Element (Index).Kind = Input_Operand then
               return Index;
            end if;
         end loop;
         return 0;
      end First_Input_Operand;

      procedure Start_Operand_Text_Input (Index : Positive) is
         Operand : constant Runtime_Operand := Runtime_Operands.Element (Index);
      begin
         if Current_Runtime_Operand /= Index then
            Current_Runtime_Operand := Index;
            Reset_Text_Input;
            FNR_Count := 0;
            Stream_File := Operand.Text;
         end if;
      end Start_Operand_Text_Input;

      procedure Initialize_First_Preloaded_Input is
      begin
         if Preloaded_Input_Initialized
           or else Read_Record /= null
           or else Read_Text /= null
           or else Read_Operand_Text /= null
         then
            return;
         end if;

         if Input_Files.Is_Empty then
            Preloaded_Input_Name := To_Unbounded_String (Filename);
            Records := Split_By_RS (Input);
            Preloaded_Input_Index := 0;
         else
            declare
               F : constant Var_Assignment := Input_Files.Element (1);
            begin
               Preloaded_Input_Name := F.Name;
               Records := Split_By_RS (To_String (F.Value));
               Preloaded_Input_Index := 1;
            end;
         end if;

         Main_Index := 0;
         FNR_Count := 0;
         Preloaded_Input_Initialized := True;
      end Initialize_First_Preloaded_Input;

      procedure Initialize_Main_Input_For_Begin is
         First_Operand : constant Natural := First_Input_Operand;
      begin
         if Read_Operand_Text /= null then
            if First_Operand > 0 then
               Start_Operand_Text_Input (First_Operand);
            end if;
         end if;
      end Initialize_Main_Input_For_Begin;

      function Extract_Text_Record
        (Name : out Unbounded_String;
         Line : out Unbounded_String) return Boolean
      is
         RS_Str : constant String := Get_Str ("RS", "" & ASCII.LF);
      begin
         if Length (Text_Buffer) = 0 then
            return False;
         end if;

         if RS_Str'Length = 0 then
            declare
               S : constant String := To_String (Text_Buffer);
            begin
               if S'Length >= 2 then
                  for I in S'First .. S'Last - 1 loop
                     if S (I) = ASCII.LF and then S (I + 1) = ASCII.LF then
                        Name := Text_Buffer_File;
                        if I > S'First then
                           Line := To_Unbounded_String (S (S'First .. I - 1));
                        else
                           Line := Null_Unbounded_String;
                        end if;
                        Delete (Text_Buffer, 1, I - S'First + 2);
                        return True;
                     end if;
                  end loop;
               end if;
            end;
         else
            declare
               S   : constant String := To_String (Text_Buffer);
               Sep : constant Character := RS_Str (RS_Str'First);
            begin
               for I in S'Range loop
                  if S (I) = Sep then
                     Name := Text_Buffer_File;
                     if I > S'First then
                        Line := To_Unbounded_String (S (S'First .. I - 1));
                     else
                        Line := Null_Unbounded_String;
                     end if;
                     Delete (Text_Buffer, 1, I - S'First + 1);
                     return True;
                  end if;
               end loop;
            end;
         end if;

         return False;
      end Extract_Text_Record;

      function Advance_Text_Record
        (Name : out Unbounded_String;
         Line : out Unbounded_String) return Boolean
      is
         Done       : Boolean;
         Chunk_Name : Unbounded_String;
         Chunk_Text : Unbounded_String;
      begin
         loop
            if Extract_Text_Record (Name, Line) then
               return True;
            end if;

            if Text_End_Of_Input then
               if Length (Text_Buffer) > 0 then
                  Name := Text_Buffer_File;
                  Line := Text_Buffer;
                  Text_Buffer := Null_Unbounded_String;
                  return True;
               end if;
               return False;
            end if;

            if Text_Pending_Chunk then
               Chunk_Name := Text_Pending_File;
               Chunk_Text := Text_Pending_Text;
               Text_Pending_Chunk := False;
            else
               if Read_Operand_Text /= null then
                  Read_Operand_Text.all
                    (User_Data, Positive (Current_Runtime_Operand),
                     Chunk_Name, Chunk_Text, Done);
               else
                  Read_Text.all (User_Data, Chunk_Name, Chunk_Text, Done);
               end if;
               if Done then
                  Text_End_Of_Input := True;
                  Chunk_Name := Null_Unbounded_String;
                  Chunk_Text := Null_Unbounded_String;
               end if;
            end if;

            if not Text_End_Of_Input then
               if not Text_Has_File then
                  Text_Buffer_File := Chunk_Name;
                  Text_Has_File := True;
                  Append (Text_Buffer, Chunk_Text);
               elsif Chunk_Name = Text_Buffer_File then
                  Append (Text_Buffer, Chunk_Text);
               elsif Length (Text_Buffer) > 0 then
                  Name := Text_Buffer_File;
                  Line := Text_Buffer;
                  Text_Buffer := Null_Unbounded_String;
                  Text_Pending_File := Chunk_Name;
                  Text_Pending_Text := Chunk_Text;
                  Text_Pending_Chunk := True;
                  return True;
               else
                  Text_Buffer_File := Chunk_Name;
                  Append (Text_Buffer, Chunk_Text);
               end if;
            end if;
         end loop;
      end Advance_Text_Record;

      --  Advance the main input cursor by one record -- shared by the record loop
      --  and getline from the main stream, so NR/FNR stay consistent. Bumps NR/FNR
      --  and sets either $0 (Into_Field0) or a target variable. Returns False at
      --  the end of the current input.
      function Advance_Main_Record (Into_Field0 : Boolean; Var : A.Expr_Access) return Boolean is
      begin
         if Read_Text /= null or else Read_Operand_Text /= null then
            declare
               Name : Unbounded_String;
               Line : Unbounded_String;
            begin
               if Pending_Stream_Record then
                  Name := Pending_File;
                  Line := Pending_Record;
                  Pending_Stream_Record := False;
               elsif not Advance_Text_Record (Name, Line) then
                  return False;
               end if;

               if not Stream_Has_File or else Name /= Stream_File then
                  Stream_File := Name;
                  Stream_Has_File := True;
                  FNR_Count := 0;
                  Set_Scalar ("FILENAME", V.To_Value (To_String (Stream_File)));
               end if;

               Pending_Record := Line;
            end;
         elsif Read_Record = null then
            if not Preloaded_Input_Initialized then
               Initialize_First_Preloaded_Input;
            end if;
            if Main_Index >= Natural (Records.Length) then
               return False;
            end if;
            Main_Index := Main_Index + 1;
            if FNR_Count = 0 then
               Set_Scalar ("FILENAME", V.To_Value (To_String (Preloaded_Input_Name)));
            end if;
         else
            declare
               Done : Boolean;
               Name : Unbounded_String;
               Line : Unbounded_String;
            begin
               if Pending_Stream_Record then
                  Name := Pending_File;
                  Line := Pending_Record;
                  Pending_Stream_Record := False;
               else
                  Read_Record.all (User_Data, Name, Line, Done);
                  if Done then
                     return False;
                  end if;
               end if;

               if not Stream_Has_File or else Name /= Stream_File then
                  Stream_File := Name;
                  Stream_Has_File := True;
                  FNR_Count := 0;
                  Set_Scalar ("FILENAME", V.To_Value (To_String (Stream_File)));
               end if;

               Pending_Record := Line;
            end;
         end if;

         NR_Count   := NR_Count + 1;
         FNR_Count  := FNR_Count + 1;
         Set_Scalar ("NR", V.To_Value (V.Number (NR_Count)));
         Set_Scalar ("FNR", V.To_Value (V.Number (FNR_Count)));
         declare
            Line : constant String :=
              (if Read_Record = null and then Read_Text = null and then Read_Operand_Text = null
               then To_String (Records.Element (Main_Index))
               else To_String (Pending_Record));
         begin
            if Into_Field0 then
               Set_Record (Line);
            elsif Var /= null then
               Set_Lvalue (Var, V.Make_Strnum (Line));
            end if;
         end;
         return True;
      end Advance_Main_Record;

      --  Best-effort read of a real file's whole content (line-reconstructed).
      function Try_Read_File (Path : String; Content : out Unbounded_String) return Boolean is
         F : Ada.Text_IO.File_Type;
      begin
         Content := Null_Unbounded_String;
         Ada.Text_IO.Open (F, Ada.Text_IO.In_File, Path);
         while not Ada.Text_IO.End_Of_File (F) loop
            Append (Content, Ada.Text_IO.Get_Line (F));
            Append (Content, ASCII.LF);
         end loop;
         Ada.Text_IO.Close (F);
         return True;
      exception
         when others => return False;
      end Try_Read_File;

      --  getline < File. Returns 1 on a record, 0 at EOF, -1 if the file is absent.
      --  Caller-provided content wins; otherwise the real filesystem is tried.
      function Getline_From_File (Name : String) return Integer is
         C : Cursor_Access;
      begin
         if not Getline_Content.Contains (Name) then
            declare
               Content : Unbounded_String;
            begin
               if Try_Read_File (Name, Content) then
                  Getline_Content.Include (Name, Content);
               else
                  return -1;
               end if;
            end;
         end if;
         if Getline_Cursors.Contains (Name) then
            C := Getline_Cursors.Element (Name);
         else
            C := new File_Cursor;
            C.Lines := Split_Lines (To_String (Getline_Content.Element (Name)));
            C.Loaded := True;
            Getline_Cursors.Insert (Name, C);
         end if;
         if C.Index >= Natural (C.Lines.Length) then
            return 0;
         end if;
         C.Index := C.Index + 1;
         return 1;   --  caller reads C at the new Index
      end Getline_From_File;

      --  command | getline. Returns 1 on a record, 0 at EOF, -1 if the caller
      --  did not provide output for this command.
      function Getline_From_Command (Name : String) return Integer is
         C : Cursor_Access;
      begin
         if not Command_Content.Contains (Name) then
            if Read_Command /= null then
               declare
                  Content   : Unbounded_String;
                  Available : Boolean;
               begin
                  Read_Command.all (User_Data, Name, Content, Available);
                  if Available then
                     Command_Content.Include (Name, Content);
                  else
                     return -1;
                  end if;
               end;
            else
               return -1;
            end if;
         end if;
         if Command_Cursors.Contains (Name) then
            C := Command_Cursors.Element (Name);
         else
            C := new File_Cursor;
            C.Lines := Split_Lines (To_String (Command_Content.Element (Name)));
            C.Loaded := True;
            Command_Cursors.Insert (Name, C);
         end if;
         if C.Index >= Natural (C.Lines.Length) then
            return 0;
         end if;
         C.Index := C.Index + 1;
         return 1;
      end Getline_From_Command;

      --  Lvalue get/set ----------------------------------------------------------
      function Get_Lvalue (Target : A.Expr_Access) return V.Value is
      begin
         case Target.Kind is
            when A.E_Var =>
               return Get_Scalar (To_String (Target.Var_Name));
            when A.E_Field =>
               return V.Make_Strnum (Get_Field (To_Int (Eval_Num (Target.Fld))));
            when A.E_Subscript =>
               declare
                  Arr : constant Array_Ref := Get_Array (To_String (Target.Arr_Name));
                  Key : constant String := Subscript_Key (Target.Subs);
               begin
                  if not Arr.Contains (Key) then
                     Arr.Include (Key, V.Uninitialized_Value);   --  reference vivifies
                  end if;
                  return Arr.Element (Key);
               end;
            when others =>
               return V.Uninitialized_Value;
         end case;
      end Get_Lvalue;

      procedure Set_Lvalue (Target : A.Expr_Access; Val : V.Value) is
      begin
         case Target.Kind is
            when A.E_Var =>
               Set_Scalar (To_String (Target.Var_Name), Val);
            when A.E_Field =>
               Set_Field (To_Int (Eval_Num (Target.Fld)), V.As_String (Val));
            when A.E_Subscript =>
               declare
                  Arr : constant Array_Ref := Get_Array (To_String (Target.Arr_Name));
               begin
                  Arr.Include (Subscript_Key (Target.Subs), Val);
               end;
            when others =>
               null;
         end case;
      end Set_Lvalue;

      --  Replacement string for sub/gsub: '&' is the match, '\&' a literal '&'.
      function Build_Replacement (Repl, Matched : String) return String is
         Buf : Unbounded_String;
         I   : Integer := Repl'First;
      begin
         while I <= Repl'Last loop
            if Repl (I) = '\' and then I < Repl'Last then
               if Repl (I + 1) = '&' then
                  Append (Buf, '&'); I := I + 2;
               elsif Repl (I + 1) = '\' then
                  Append (Buf, '\'); I := I + 2;
               else
                  Append (Buf, Repl (I)); I := I + 1;
               end if;
            elsif Repl (I) = '&' then
               Append (Buf, Matched); I := I + 1;
            else
               Append (Buf, Repl (I)); I := I + 1;
            end if;
         end loop;
         return To_String (Buf);
      end Build_Replacement;

      --  sub/gsub over a target string. Returns count and the new string.
      procedure Do_Sub
        (Pattern, Repl : String;
         Global        : Boolean;
         Subject       : String;
         New_Text      : out Unbounded_String;
         Count         : out Natural)
      is
         Out_S : Unbounded_String;
         Pos   : Integer := Subject'First;
      begin
         Count := 0;
         loop
            declare
               From : constant Positive := Pos - Subject'First + 1;
               M    : constant Awklib.Regex.Match := Awklib.Regex.Search (Pattern, Subject, From);
            begin
               exit when not M.Matched;
               declare
                  MFirst : constant Integer := Subject'First + M.First - 1;
                  MLast  : constant Integer := Subject'First + M.Last - 1;   --  < MFirst if empty
                  Matched_Text : constant String :=
                    (if MLast >= MFirst then Subject (MFirst .. MLast) else "");
               begin
                  Append (Out_S, Subject (Pos .. MFirst - 1));
                  Append (Out_S, Build_Replacement (Repl, Matched_Text));
                  Count := Count + 1;
                  if MLast >= MFirst then
                     Pos := MLast + 1;
                  else
                     --  Zero-length match: emit one char and advance to avoid a loop.
                     if MFirst <= Subject'Last then
                        Append (Out_S, Subject (MFirst));
                     end if;
                     Pos := MFirst + 1;
                  end if;
               end;
            end;
            exit when not Global or else Pos > Subject'Last;
         end loop;
         if Pos <= Subject'Last then
            Append (Out_S, Subject (Pos .. Subject'Last));
         end if;
         New_Text := Out_S;
      end Do_Sub;

      --  Builtins ----------------------------------------------------------------
      function Eval_Builtin (B : A.Builtin_Id; Args : A.Expr_Vectors.Vector) return V.Value is
         NArgs : constant Natural := Natural (Args.Length);
         function Arg (I : Positive) return A.Expr_Access is (Args.Element (I));
      begin
         case B is
            when A.B_Length =>
               if NArgs = 0 then
                  return V.To_Value (V.Number (Awklib.Utf8.Count (To_String (Field0))));
               elsif Arg (1).Kind = A.E_Var and then Is_Array (To_String (Arg (1).Var_Name)) then
                  return V.To_Value (V.Number (Natural (Get_Array (To_String (Arg (1).Var_Name)).Length)));
               else
                  return V.To_Value (V.Number (Awklib.Utf8.Count (Eval_Str (Arg (1)))));
               end if;

            when A.B_Substr =>
               declare
                  S     : constant String := Eval_Str (Arg (1));
                  Chars : constant Integer := Awklib.Utf8.Count (S);
                  M     : constant Integer := To_Int (Eval_Num (Arg (2)));
                  N     : Integer := (if NArgs >= 3 then To_Int (Eval_Num (Arg (3))) else Integer'Last);
                  First_Idx, Last_Idx : Integer;
                  B0, B1 : Positive;
               begin
                  --  AWK 1-based; positions and length count codepoints, not bytes.
                  if NArgs < 3 then
                     N := Chars;   --  to end
                  end if;
                  First_Idx := M;
                  Last_Idx := (if N = Integer'Last then Chars else M + N - 1);
                  if First_Idx < 1 then First_Idx := 1; end if;
                  if Last_Idx > Chars then Last_Idx := Chars; end if;
                  if First_Idx > Last_Idx then
                     return V.To_Value ("");
                  end if;
                  --  Map the clamped codepoint range to byte offsets and slice.
                  B0 := Awklib.Utf8.Char_To_Byte (S, First_Idx);
                  B1 := Awklib.Utf8.Char_To_Byte (S, Last_Idx + 1) - 1;
                  return V.To_Value (S (S'First + B0 - 1 .. S'First + B1 - 1));
               end;

            when A.B_Index =>
               declare
                  S : constant String := Eval_Str (Arg (1));
                  T : constant String := Eval_Str (Arg (2));
               begin
                  if T'Length = 0 then
                     return V.To_Value (V.Number (0));
                  end if;
                  --  Search by bytes (UTF-8 is self-synchronising, so a match can
                  --  only start on a codepoint boundary) and report the 1-based
                  --  codepoint position of the match.
                  for I in S'First .. S'Last - T'Length + 1 loop
                     if S (I .. I + T'Length - 1) = T then
                        return V.To_Value (V.Number (Awklib.Utf8.Byte_To_Char (S, I - S'First + 1)));
                     end if;
                  end loop;
                  return V.To_Value (V.Number (0));
               end;

            when A.B_Split =>
               declare
                  S      : constant String := Eval_Str (Arg (1));
                  Arr    : constant Array_Ref := Get_Array (To_String (Arg (2).Var_Name));
                  Is_Rx  : constant Boolean := NArgs >= 3 and then Arg (3).Kind = A.E_Regex;
                  Sep    : constant String :=
                    (if NArgs >= 3 then Regex_Text (Arg (3)) else Get_Str ("FS", " "));
                  Parts  : constant Ustr_Vectors.Vector :=
                    Split_With (S, Sep, Is_Rx or else (NArgs >= 3 and then Sep'Length > 1));
               begin
                  Arr.Clear;
                  for I in 1 .. Natural (Parts.Length) loop
                     Arr.Include (V.Number_Image (V.Number (I)), V.Make_Strnum (To_String (Parts.Element (I))));
                  end loop;
                  return V.To_Value (V.Number (Natural (Parts.Length)));
               end;

            when A.B_Sub | A.B_Gsub =>
               declare
                  Pattern : constant String := Regex_Text (Arg (1));
                  Repl    : constant String := Eval_Str (Arg (2));
                  Target  : constant A.Expr_Access := (if NArgs >= 3 then Arg (3) else null);
                  Subject : constant String :=
                    (if Target = null then Get_Field (0) else V.As_String (Get_Lvalue (Target)));
                  New_Text : Unbounded_String;
                  Count    : Natural;
               begin
                  Do_Sub (Pattern, Repl, B = A.B_Gsub, Subject, New_Text, Count);
                  if Count > 0 then
                     if Target = null then
                        Set_Record (To_String (New_Text));
                     else
                        Set_Lvalue (Target, V.To_Value (New_Text));
                     end if;
                  end if;
                  return V.To_Value (V.Number (Count));
               end;

            when A.B_Match =>
               declare
                  S : constant String := Eval_Str (Arg (1));
                  P : constant String := Regex_Text (Arg (2));
                  M : constant Awklib.Regex.Match := Awklib.Regex.Search (P, S, 1);
               begin
                  if M.Matched then
                     declare
                        R_Start : constant Natural := Awklib.Utf8.Byte_To_Char (S, M.First);
                        R_Len   : constant Natural :=
                          Awklib.Utf8.Count (S (S'First + M.First - 1 .. S'First + M.Last - 1));
                     begin
                        Set_Scalar ("RSTART", V.To_Value (V.Number (R_Start)));
                        Set_Scalar ("RLENGTH", V.To_Value (V.Number (R_Len)));
                        return V.To_Value (V.Number (R_Start));
                     end;
                  else
                     Set_Scalar ("RSTART", V.To_Value (V.Number (0)));
                     Set_Scalar ("RLENGTH", V.To_Value (V.Number (-1)));
                     return V.To_Value (V.Number (0));
                  end if;
               end;

            when A.B_Sprintf =>
               declare
                  Fmt  : constant String := Eval_Str (Arg (1));
                  VArr : Awklib.Format.Value_Array (1 .. Natural'Max (0, NArgs - 1));
               begin
                  for I in 2 .. NArgs loop
                     VArr (I - 1) := Eval (Arg (I));
                  end loop;
                  return V.To_Value (Awklib.Format.Sprintf (Fmt, VArr));
               end;

            when A.B_Int =>
               return V.To_Value (V.Number'Truncation (Eval_Num (Arg (1))));

            when A.B_Tolower =>
               return V.To_Value (Ada.Characters.Handling.To_Lower (Eval_Str (Arg (1))));
            when A.B_Toupper =>
               return V.To_Value (Ada.Characters.Handling.To_Upper (Eval_Str (Arg (1))));

            when A.B_Sin =>
               return V.To_Value (V.Number (LF_Math.Sin (Long_Float (Eval_Num (Arg (1))))));
            when A.B_Cos =>
               return V.To_Value (V.Number (LF_Math.Cos (Long_Float (Eval_Num (Arg (1))))));
            when A.B_Exp =>
               begin
                  return V.To_Value (V.Number (LF_Math.Exp (Long_Float (Eval_Num (Arg (1))))));
               exception
                  when others => return V.To_Value (V.Number (0));
               end;
            when A.B_Log =>
               begin
                  return V.To_Value (V.Number (LF_Math.Log (Long_Float (Eval_Num (Arg (1))))));
               exception
                  when others => return V.To_Value (V.Number (0));
               end;
            when A.B_Sqrt =>
               begin
                  return V.To_Value (V.Number (LF_Math.Sqrt (Long_Float (Eval_Num (Arg (1))))));
               exception
                  when others => return V.To_Value (V.Number (0));
               end;
            when A.B_Atan2 =>
               begin
                  return V.To_Value
                    (V.Number (LF_Math.Arctan (Long_Float (Eval_Num (Arg (1))),
                                               Long_Float (Eval_Num (Arg (2))))));
               exception
                  when others => return V.To_Value (V.Number (0));
               end;
            when A.B_Rand =>
               return V.To_Value (V.Number (Long_Float (Float_Rng.Random (Rand_Gen))));
            when A.B_Srand =>
               declare
                  Prev : constant Integer := Rand_Seed;
               begin
                  if Args.Is_Empty then
                     Rand_Seed := Rand_Seed + 1;
                  else
                     Rand_Seed := Integer (V.Number'Truncation (Eval_Num (Arg (1))));
                  end if;
                  Float_Rng.Reset (Rand_Gen, Rand_Seed);
                  return V.To_Value (V.Number (Prev));
               end;

            when A.B_System =>
               return V.To_Value (V.Number (-1));   --  command execution unsupported

            when A.B_Close =>
               if not Args.Is_Empty then
                  declare
                     Name : constant String := Eval_Str (Arg (1));
                  begin
                     if Getline_Cursors.Contains (Name) then
                        Getline_Cursors.Delete (Name);
                     end if;
                     if Command_Cursors.Contains (Name) then
                        Command_Cursors.Delete (Name);
                     end if;
                  end;
               end if;
               return V.To_Value (V.Number (0));

            when A.B_Fflush =>
               return V.To_Value (V.Number (0));
         end case;
      end Eval_Builtin;

      --  Function calls ----------------------------------------------------------
      function Find_Func (Name : String; Found : out Boolean) return A.Func_Def is
      begin
         for F of Prog.Funcs loop
            if To_String (F.Name) = Name then
               Found := True;
               return F;
            end if;
         end loop;
         Found := False;
         return (others => <>);
      end Find_Func;

      function Call_Function (Name : String; Args : A.Expr_Vectors.Vector) return V.Value is
         Found : Boolean;
         Def   : constant A.Func_Def := Find_Func (Name, Found);
         New_Frame : Frame_Access;
         NArgs : constant Natural := Natural (Args.Length);
         Result : V.Value := V.Uninitialized_Value;
         Ignore : Flow;
      begin
         if not Found then
            Runtime_Error ("call to undefined function " & Name);
            return V.Uninitialized_Value;
         end if;
         New_Frame := new Frame;
         New_Frame.Params := Def.Params;
         --  Bind arguments (arrays by reference, scalars by value) BEFORE pushing
         --  the frame, so argument expressions see the caller's scope.
         for I in 1 .. Natural (Def.Params.Length) loop
            declare
               PName : constant String := To_String (Def.Params.Element (I));
            begin
               if I <= NArgs then
                  declare
                     Ae : constant A.Expr_Access := Args.Element (I);
                  begin
                     if Ae.Kind = A.E_Var and then Is_Array (To_String (Ae.Var_Name)) then
                        New_Frame.Arrays.Include (PName, Get_Array (To_String (Ae.Var_Name)));
                     else
                        New_Frame.Scalars.Include (PName, Eval (Ae));
                     end if;
                  end;
               end if;
            end;
         end loop;
         Frames.Append (New_Frame);
         Return_Value := V.Uninitialized_Value;
         Ignore := Exec (Def.Body_S);
         Result := Return_Value;
         Return_Value := V.Uninitialized_Value;
         Frames.Delete_Last;
         return Result;
      end Call_Function;

      --  Expression evaluation ---------------------------------------------------
      function Bool_Num (B : Boolean) return V.Value is
        (V.To_Value (V.Number (if B then 1 else 0)));

      function Eval (E : A.Expr_Access) return V.Value is
      begin
         if E = null then
            return V.Uninitialized_Value;
         end if;
         case E.Kind is
            when A.E_Num => return V.To_Value (E.Num);
            when A.E_Str => return V.To_Value (E.Str);

            when A.E_Regex =>
               return Bool_Num (Awklib.Regex.Is_Match (To_String (E.Rx), To_String (Field0)));

            when A.E_Var =>
               return Get_Scalar (To_String (E.Var_Name));

            when A.E_Field =>
               return V.Make_Strnum (Get_Field (To_Int (Eval_Num (E.Fld))));

            when A.E_Subscript =>
               return Get_Lvalue (E);

            when A.E_Group =>
               return Eval (E.Inner);

            when A.E_Concat =>
               return V.To_Value (Conv_Str (Eval (E.C_L)) & Conv_Str (Eval (E.C_R)));

            when A.E_Assign =>
               declare
                  New_Val : V.Value;
               begin
                  if E.A_Op = A.As_Set then
                     New_Val := Eval (E.Rhs);
                  else
                     declare
                        Cur : constant V.Number := V.As_Number (Get_Lvalue (E.Target));
                        Rhs : constant V.Number := Eval_Num (E.Rhs);
                        Res : V.Number;
                     begin
                        case E.A_Op is
                           when A.As_Add => Res := Cur + Rhs;
                           when A.As_Sub => Res := Cur - Rhs;
                           when A.As_Mul => Res := Cur * Rhs;
                           when A.As_Div | A.As_Mod =>
                              if Rhs = 0.0 then
                                 Runtime_Error
                                   ((if E.A_Op = A.As_Mod then "division by zero in %="
                                     else "division by zero"));
                                 Res := 0.0;
                              elsif E.A_Op = A.As_Mod then
                                 Res := Fmod (Cur, Rhs);
                              else
                                 Res := Cur / Rhs;
                              end if;
                           when A.As_Pow => Res := V.Number (LF_Math."**" (Long_Float (Cur), Long_Float (Rhs)));
                           when A.As_Set => Res := Rhs;
                        end case;
                        New_Val := V.To_Value (Res);
                     end;
                  end if;
                  Set_Lvalue (E.Target, New_Val);
                  return New_Val;
               end;

            when A.E_Binary =>
               case E.B_Op is
                  when A.Op_Add => return V.To_Value (Eval_Num (E.L) + Eval_Num (E.R));
                  when A.Op_Sub => return V.To_Value (Eval_Num (E.L) - Eval_Num (E.R));
                  when A.Op_Mul => return V.To_Value (Eval_Num (E.L) * Eval_Num (E.R));
                  when A.Op_Div | A.Op_Mod =>
                     declare
                        Numer : constant V.Number := Eval_Num (E.L);
                        Denom : constant V.Number := Eval_Num (E.R);
                     begin
                        if Denom = 0.0 then
                           Runtime_Error
                             ((if E.B_Op = A.Op_Mod then "division by zero in %"
                               else "division by zero"));
                           return V.To_Value (V.Number (0));
                        end if;
                        return V.To_Value
                          ((if E.B_Op = A.Op_Mod then Fmod (Numer, Denom)
                            else Numer / Denom));
                     end;
                  when A.Op_Pow =>
                     return V.To_Value
                        (V.Number
                           (LF_Math."**"
                              (Long_Float (Eval_Num (E.L)),
                               Long_Float (Eval_Num (E.R)))));
                  when A.Op_Lt => return Bool_Num (V.Compare (Eval (E.L), Eval (E.R)) < 0);
                  when A.Op_Le => return Bool_Num (V.Compare (Eval (E.L), Eval (E.R)) <= 0);
                  when A.Op_Gt => return Bool_Num (V.Compare (Eval (E.L), Eval (E.R)) > 0);
                  when A.Op_Ge => return Bool_Num (V.Compare (Eval (E.L), Eval (E.R)) >= 0);
                  when A.Op_Eq => return Bool_Num (V.Compare (Eval (E.L), Eval (E.R)) = 0);
                  when A.Op_Ne => return Bool_Num (V.Compare (Eval (E.L), Eval (E.R)) /= 0);
               end case;

            when A.E_Unary =>
               case E.U_Op is
                  when A.Un_Neg => return V.To_Value (-Eval_Num (E.Operand));
                  when A.Un_Pos => return V.To_Value (Eval_Num (E.Operand));
                  when A.Un_Not => return Bool_Num (not V.Is_True (Eval (E.Operand)));
               end case;

            when A.E_Incr_Decr =>
               declare
                  Old_N : constant V.Number := V.As_Number (Get_Lvalue (E.Lvalue));
                  New_N : constant V.Number := (if E.Is_Incr then Old_N + 1.0 else Old_N - 1.0);
               begin
                  Set_Lvalue (E.Lvalue, V.To_Value (New_N));
                  return V.To_Value (if E.Is_Pre then New_N else Old_N);
               end;

            when A.E_Ternary =>
               if V.Is_True (Eval (E.Cond)) then
                  return Eval (E.T_Expr);
               else
                  return Eval (E.F_Expr);
               end if;

            when A.E_Match =>
               declare
                  Matched : constant Boolean :=
                    Awklib.Regex.Is_Match (Regex_Text (E.M_R), Eval_Str (E.M_L));
               begin
                  return Bool_Num (Matched xor E.M_Neg);
               end;

            when A.E_In =>
               declare
                  Arr : constant Array_Ref := Get_Array (To_String (E.In_Arr));
               begin
                  return Bool_Num (Arr.Contains (Subscript_Key (E.In_Subs)));
               end;

            when A.E_And =>
               if not V.Is_True (Eval (E.Lg_L)) then
                  return Bool_Num (False);
               end if;
               return Bool_Num (V.Is_True (Eval (E.Lg_R)));

            when A.E_Or =>
               if V.Is_True (Eval (E.Lg_L)) then
                  return Bool_Num (True);
               end if;
               return Bool_Num (V.Is_True (Eval (E.Lg_R)));

            when A.E_Call =>
               return Call_Function (To_String (E.Fn_Name), E.Args);

            when A.E_Builtin =>
               return Eval_Builtin (E.B_Id, E.B_Args);

            when A.E_Getline =>
               if E.GL_Source = A.G_File then
                  declare
                     Name    : constant String := Eval_Str (E.GL_Arg);
                     Outcome : constant Integer := Getline_From_File (Name);
                  begin
                     if Outcome = 1 then
                        declare
                           C    : constant Cursor_Access := Getline_Cursors.Element (Name);
                           Line : constant String := To_String (C.Lines.Element (C.Index));
                        begin
                           if E.GL_Var /= null then
                              Set_Lvalue (E.GL_Var, V.Make_Strnum (Line));
                           else
                              Set_Record (Line);
                           end if;
                        end;
                     end if;
                     return V.To_Value (V.Number (Outcome));
                  end;
               elsif E.GL_Source = A.G_Main then
                  --  `getline` / `getline var` from the main input stream: advance
                  --  the shared cursor. Plain getline sets $0 and re-splits fields;
                  --  `getline var` sets only the variable (and NR/FNR).
                  if Advance_Main_Record
                       (Into_Field0 => E.GL_Var = null, Var => E.GL_Var)
                  then
                     return V.To_Value (V.Number (1));
                  else
                     return V.To_Value (V.Number (0));
                  end if;
               else
                  declare
                     Name    : constant String := Eval_Str (E.GL_Arg);
                     Outcome : constant Integer := Getline_From_Command (Name);
                  begin
                     if Outcome = 1 then
                        declare
                           C    : constant Cursor_Access := Command_Cursors.Element (Name);
                           Line : constant String := To_String (C.Lines.Element (C.Index));
                        begin
                           if E.GL_Var /= null then
                              Set_Lvalue (E.GL_Var, V.Make_Strnum (Line));
                           else
                              Set_Record (Line);
                           end if;
                        end;
                     end if;
                     return V.To_Value (V.Number (Outcome));
                  end;
               end if;
         end case;
      end Eval;

      --  Output ------------------------------------------------------------------
      procedure Emit (Text : String; Dest : A.Expr_Access; Redir : A.Redirect_Kind) is
      begin
         case Redir is
            when A.R_None =>
               if Write_Output = null then
                  Append (Out_Buf, Text);
               else
                  Write_Output.all (User_Data, Text);
               end if;
            when A.R_File | A.R_Append =>
               declare
                  Name        : constant String := Eval_Str (Dest);
                  Append_Mode : constant Boolean :=
                    Redir = A.R_Append or else Truncated.Contains (Name);
               begin
                  if Write_Redirection = null then
                     --  Capture in memory rather than opening the real file:
                     --  the first `>` to a name truncates, `>>` and later `>`
                     --  append, exactly as a filesystem stream would within
                     --  one run.
                     if not Redirect_Buf.Contains (Name) then
                        Redirect_Buf.Insert (Name, Null_Unbounded_String);
                        Redirect_Order.Append (To_Unbounded_String (Name));
                     end if;
                     if not Append_Mode then
                        Truncated.Include (Name, True);
                        Redirect_Buf.Replace (Name, To_Unbounded_String (Text));
                     else
                        Redirect_Buf.Replace
                          (Name, Redirect_Buf.Element (Name) & Text);
                     end if;
                  else
                     if not Append_Mode then
                        Truncated.Include (Name, True);
                     end if;
                     Write_Redirection.all
                       (User_Data, Name, Text, Append_Mode, not Append_Mode);
                  end if;
               end;
            when A.R_Pipe =>
               --  Output pipes (`print | "cmd"`) would spawn a process, which
               --  this hermetic library does not do. Degrade quietly by dropping
               --  the piped output, consistent with the other process constructs
               --  (`system` returns -1, `"cmd" | getline` returns 0/EOF) rather
               --  than failing the whole run.
               null;
         end case;
      end Emit;

      --  How `print` renders a value: a number through OFMT (default "%.6g"),
      --  integers plain.
      function Output_Str (Val : V.Value) return String is
        (Num_To_Str (Val, Get_Str ("OFMT", "%.6g")));

      procedure Do_Print (S : A.Stmt_Access) is
         OFS : constant String := Get_Str ("OFS", " ");
         ORS : constant String := Get_Str ("ORS", "" & ASCII.LF);
         Buf : Unbounded_String;
      begin
         if S.P_Args.Is_Empty then
            Append (Buf, Field0);
         else
            for I in 1 .. Natural (S.P_Args.Length) loop
               if I > 1 then
                  Append (Buf, OFS);
               end if;
               Append (Buf, Output_Str (Eval (S.P_Args.Element (I))));
            end loop;
         end if;
         Append (Buf, ORS);
         Emit (To_String (Buf), S.Dest, S.Redir);
      end Do_Print;

      procedure Do_Printf (S : A.Stmt_Access) is
         NArgs : constant Natural := Natural (S.P_Args.Length);
      begin
         if NArgs = 0 then
            return;
         end if;
         declare
            Fmt  : constant String := Eval_Str (S.P_Args.Element (1));
            VArr : Awklib.Format.Value_Array (1 .. Natural'Max (0, NArgs - 1));
         begin
            for I in 2 .. NArgs loop
               VArr (I - 1) := Eval (S.P_Args.Element (I));
            end loop;
            Emit (Awklib.Format.Sprintf (Fmt, VArr), S.Dest, S.Redir);
         end;
      end Do_Printf;

      --  Statement execution -----------------------------------------------------
      function Exec_Loop_Body (Body_S : A.Stmt_Access; Broke : out Boolean) return Flow is
         F : constant Flow := Exec (Body_S);
      begin
         Broke := False;
         case F is
            when Flow_Break    => Broke := True; return Flow_Normal;
            when Flow_Continue => return Flow_Normal;
            when Flow_Normal   => return Flow_Normal;
            when others        => return F;   --  next/nextfile/return/exit propagate
         end case;
      end Exec_Loop_Body;

      function Exec (S : A.Stmt_Access) return Flow is
      begin
         if S = null or else Runtime_Failed then
            return Flow_Normal;
         end if;
         case S.Kind is
            when A.S_Nop => return Flow_Normal;

            when A.S_Block =>
               for St of S.Stmts loop
                  declare
                     F : constant Flow := Exec (St);
                  begin
                     if F /= Flow_Normal then
                        return F;
                     end if;
                  end;
                  exit when Runtime_Failed;
               end loop;
               return Flow_Normal;

            when A.S_Expr =>
               declare
                  Ignore : constant V.Value := Eval (S.E);
                  pragma Unreferenced (Ignore);
               begin
                  return Flow_Normal;
               end;

            when A.S_Print  => Do_Print (S);  return Flow_Normal;
            when A.S_Printf => Do_Printf (S); return Flow_Normal;

            when A.S_If =>
               if V.Is_True (Eval (S.If_Cond)) then
                  return Exec (S.Then_S);
               elsif S.Else_S /= null then
                  return Exec (S.Else_S);
               end if;
               return Flow_Normal;

            when A.S_While =>
               while V.Is_True (Eval (S.W_Cond)) and then not Runtime_Failed loop
                  declare
                     Broke : Boolean;
                     F     : constant Flow := Exec_Loop_Body (S.W_Body, Broke);
                  begin
                     if F /= Flow_Normal then
                        return F;
                     end if;
                     exit when Broke;
                  end;
               end loop;
               return Flow_Normal;

            when A.S_Do =>
               loop
                  declare
                     Broke : Boolean;
                     F     : constant Flow := Exec_Loop_Body (S.D_Body, Broke);
                  begin
                     if F /= Flow_Normal then
                        return F;
                     end if;
                     exit when Broke;
                  end;
                  exit when Runtime_Failed or else not V.Is_True (Eval (S.D_Cond));
               end loop;
               return Flow_Normal;

            when A.S_For =>
               declare
                  Ignore : Flow;
               begin
                  if S.Init /= null then
                     Ignore := Exec (S.Init);
                  end if;
                  while (S.F_Cond = null or else V.Is_True (Eval (S.F_Cond)))
                    and then not Runtime_Failed
                  loop
                     declare
                        Broke : Boolean;
                        F     : constant Flow := Exec_Loop_Body (S.F_Body, Broke);
                     begin
                        if F /= Flow_Normal then
                           return F;
                        end if;
                        exit when Broke;
                     end;
                     if S.Post /= null then
                        Ignore := Exec (S.Post);
                     end if;
                  end loop;
               end;
               return Flow_Normal;

            when A.S_For_In =>
               declare
                  Arr  : constant Array_Ref := Get_Array (To_String (S.FI_Arr));
                  Keys : Ustr_Vectors.Vector;
               begin
                  for C in Arr.Iterate loop
                     Keys.Append (To_Unbounded_String (Cell_Maps.Key (C)));
                  end loop;
                  for K of Keys loop
                     Set_Scalar (To_String (S.FI_Var), V.Make_Strnum (To_String (K)));
                     declare
                        Broke : Boolean;
                        F     : constant Flow := Exec_Loop_Body (S.FI_Body, Broke);
                     begin
                        if F /= Flow_Normal then
                           return F;
                        end if;
                        exit when Broke or else Runtime_Failed;
                     end;
                  end loop;
               end;
               return Flow_Normal;

            when A.S_Break    => return Flow_Break;
            when A.S_Continue => return Flow_Continue;
            when A.S_Next     => return Flow_Next;
            when A.S_Nextfile => return Flow_Nextfile;

            when A.S_Exit =>
               if S.Val /= null then
                  Exit_Code_V := To_Int (Eval_Num (S.Val));
               end if;
               Exiting := True;
               return Flow_Exit;

            when A.S_Return =>
               if S.Val /= null then
                  Return_Value := Eval (S.Val);
               else
                  Return_Value := V.Uninitialized_Value;
               end if;
               return Flow_Return;

            when A.S_Delete =>
               declare
                  Arr : constant Array_Ref := Get_Array (To_String (S.Del_Arr));
               begin
                  Arr.Exclude (Subscript_Key (S.Del_Subs));
               end;
               return Flow_Normal;

            when A.S_Delete_All =>
               Get_Array (To_String (S.All_Arr)).Clear;
               return Flow_Normal;
         end case;
      end Exec;

      procedure Run_Action (R : A.Rule; Result : out Flow) is
      begin
         if R.Action = null then
            Do_Print (new A.Stmt'(Kind => A.S_Print, Line => 1,
                                  P_Args => A.Expr_Vectors.Empty_Vector,
                                  Redir => A.R_None, Dest => null));
            Result := Flow_Normal;
         else
            Result := Exec (R.Action);
         end if;
      end Run_Action;

      Parse_Status : Awklib.Parser.Result_Status;
      Parse_Msg    : Unbounded_String;
      Has_Main_Or_End : Boolean := False;
      Range_Active : array (1 .. 4096) of Boolean := [others => False];
   begin
      --  Reset global state.
      Globals_Scalar.Clear;
      Globals_Array.Clear;
      Frames.Clear;
      Fields.Clear;
      Records.Clear;
      Truncated.Clear;
      Getline_Content.Clear;
      Getline_Cursors.Clear;
      Command_Content.Clear;
      Command_Cursors.Clear;
      for F of Files loop
         Getline_Content.Include (To_String (F.Name), F.Value);
      end loop;
      for C of Commands loop
         Command_Content.Include (To_String (C.Name), C.Value);
      end loop;
      Field0 := Null_Unbounded_String;
      NF_Val := 0;
      Records.Clear;
      Main_Index := 0;
      NR_Count := 0;
      FNR_Count := 0;
      Stream_File := To_Unbounded_String (Filename);
      Stream_Has_File := False;
      Pending_Stream_Record := False;
      Pending_File := Null_Unbounded_String;
      Pending_Record := Null_Unbounded_String;
      Text_Buffer := Null_Unbounded_String;
      Text_Buffer_File := Null_Unbounded_String;
      Text_Has_File := False;
      Text_End_Of_Input := False;
      Text_Pending_Chunk := False;
      Text_Pending_File := Null_Unbounded_String;
      Text_Pending_Text := Null_Unbounded_String;
      Out_Buf := Null_Unbounded_String;
      Return_Value := V.Uninitialized_Value;
      Exit_Code_V := 0;
      Exiting := False;
      Runtime_Failed := False;
      Runtime_Msg := Null_Unbounded_String;

      Awklib.Parser.Parse (Program_Source, Prog, Parse_Status, Parse_Msg);
      if Parse_Status /= Awklib.Parser.Ok then
         Output := Null_Unbounded_String;
         Exit_Code := 2;
         Status := Run_Error;
         Message := Parse_Msg;
         return;
      end if;

      --  Default special variables.
      Set_Scalar ("FS", V.To_Value (" "));
      Set_Scalar ("OFS", V.To_Value (" "));
      Set_Scalar ("ORS", V.To_Value ("" & ASCII.LF));
      Set_Scalar ("RS", V.To_Value ("" & ASCII.LF));
      Set_Scalar ("SUBSEP", V.To_Value ("" & Character'Val (28)));
      Set_Scalar ("CONVFMT", V.To_Value ("%.6g"));
      Set_Scalar ("OFMT", V.To_Value ("%.6g"));
      Set_Scalar ("RSTART", V.To_Value (V.Number (0)));
      Set_Scalar ("RLENGTH", V.To_Value (V.Number (-1)));
      Set_Scalar ("NR", V.To_Value (V.Number (0)));
      Set_Scalar ("FNR", V.To_Value (V.Number (0)));
      Set_Scalar ("FILENAME", V.To_Value (Filename));

      for Asn of Assignments loop
         Set_Scalar (To_String (Asn.Name), V.Make_Strnum (To_String (Asn.Value)));
      end loop;

      declare
         Env : constant Array_Ref := Get_Array ("ENVIRON");
      begin
         for E of Environment loop
            Env.Include (To_String (E.Name), V.Make_Strnum (To_String (E.Value)));
         end loop;
      end;

      --  ARGV/ARGC: ARGV[0] is "awk", then the supplied arguments, or -- when the
      --  caller gives none -- the input-file names, as awk's own ARGV would hold.
      declare
         Argv  : constant Array_Ref := Get_Array ("ARGV");
         Count : Natural := 0;

         function Key (N : Natural) return String is
            S : constant String := Natural'Image (N);
         begin
            return S (S'First + 1 .. S'Last);   --  drop Natural'Image's leading space
         end Key;
      begin
         Argv.Include ("0", V.Make_Strnum ("awk"));
         if not Runtime_Operands.Is_Empty then
            for Operand of Runtime_Operands loop
               if Length (Operand.Text) > 0 then
                  Count := Count + 1;
                  Argv.Include (Key (Count), V.Make_Strnum (To_String (Operand.Text)));
               end if;
            end loop;
         elsif not Arguments.Is_Empty then
            for Arg of Arguments loop
               Count := Count + 1;
               Argv.Include (Key (Count), V.Make_Strnum (To_String (Arg)));
            end loop;
         else
            for F of Input_Files loop
               Count := Count + 1;
               Argv.Include (Key (Count), V.Make_Strnum (To_String (F.Name)));
            end loop;
         end if;
         Set_Scalar ("ARGC", V.To_Value (V.Number (Count + 1)));
      end;

      for R of Prog.Rules loop
         if R.Pat /= A.P_Begin then
            Has_Main_Or_End := True;
         end if;
      end loop;

      Initialize_Main_Input_For_Begin;

      --  BEGIN rules.
      for R of Prog.Rules loop
         exit when Exiting or else Runtime_Failed;
         if R.Pat = A.P_Begin then
            declare
               F : constant Flow := Exec (R.Action);
               pragma Unreferenced (F);
            begin
               null;
            end;
         end if;
      end loop;

      --  Main record loop -- multi-file: FILENAME and FNR reset per file, NR
      --  runs continuously, range-pattern state (Range_Active) spans the run.
      if Has_Main_Or_End and then not Exiting and then not Runtime_Failed then
         declare
            procedure Process_Current_Record (Do_Nextfile : out Boolean) is
               Idx : Natural := 0;
            begin
               Do_Nextfile := False;
               for R of Prog.Rules loop
                  exit when Exiting or else Runtime_Failed;
                  if R.Pat /= A.P_Begin and then R.Pat /= A.P_End then
                     Idx := Idx + 1;
                     declare
                        Fire : Boolean := False;
                     begin
                        case R.Pat is
                           when A.P_Always =>
                              Fire := True;
                           when A.P_Expr =>
                              Fire := V.Is_True (Eval (R.Expr1));
                           when A.P_Range =>
                              if Idx <= Range_Active'Last then
                                 if not Range_Active (Idx) then
                                    if V.Is_True (Eval (R.Expr1)) then
                                       Range_Active (Idx) := True;
                                       Fire := True;
                                       if V.Is_True (Eval (R.Expr2)) then
                                          Range_Active (Idx) := False;
                                       end if;
                                    end if;
                                 else
                                    Fire := True;
                                    if V.Is_True (Eval (R.Expr2)) then
                                       Range_Active (Idx) := False;
                                    end if;
                                 end if;
                              end if;
                           when others => null;
                        end case;

                        if Fire then
                           declare
                              F : Flow;
                           begin
                              Run_Action (R, F);
                              if F = Flow_Nextfile then
                                 Do_Nextfile := True;
                                 exit;
                              elsif F = Flow_Next then
                                 exit;
                              end if;
                           end;
                        end if;
                     end;
                  end if;
               end loop;
            end Process_Current_Record;

            procedure Process_File
              (FName : String;
               Content : String;
               Reuse_Current : Boolean := False)
            is
               Do_Nextfile : Boolean := False;
            begin
               if not Reuse_Current then
                  Set_Scalar ("FILENAME", V.To_Value (FName));
                  Preloaded_Input_Name := To_Unbounded_String (FName);
                  --  Load this file as the main record stream; FNR restarts
                  --  here, NR_Count continues across files. Advance_Main_Record
                  --  (shared with getline) reads each record and bumps NR/FNR.
                  Records := Split_By_RS (Content);
                  Main_Index := 0;
                  FNR_Count := 0;
               end if;
               while not (Exiting or else Runtime_Failed or else Do_Nextfile)
                 and then Advance_Main_Record (Into_Field0 => True, Var => null)
               loop
                  Process_Current_Record (Do_Nextfile);
               end loop;
            end Process_File;

            procedure Skip_Current_Stream_File is
               Old_Name : constant String := To_String (Stream_File);
               Done     : Boolean := False;
               Name     : Unbounded_String;
               Line     : Unbounded_String;
            begin
               while not Done loop
                  if Read_Text /= null or else Read_Operand_Text /= null then
                     Done := not Advance_Text_Record (Name, Line);
                  else
                     Read_Record.all (User_Data, Name, Line, Done);
                  end if;

                  if not Done and then To_String (Name) /= Old_Name then
                     Pending_File := Name;
                     Pending_Record := Line;
                     Pending_Stream_Record := True;
                     return;
                  end if;
               end loop;
            end Skip_Current_Stream_File;

            procedure Process_Stream is
               Do_Nextfile : Boolean := False;
            begin
               if NR_Count = 0 then
                  Set_Scalar ("FILENAME", V.To_Value (Filename));
                  FNR_Count := 0;
                  Stream_File := To_Unbounded_String (Filename);
                  Stream_Has_File := False;
               end if;
               while not (Exiting or else Runtime_Failed)
                 and then Advance_Main_Record (Into_Field0 => True, Var => null)
               loop
                  Process_Current_Record (Do_Nextfile);
                  if Do_Nextfile then
                     Skip_Current_Stream_File;
                     Do_Nextfile := False;
                  end if;
               end loop;
            end Process_Stream;

            procedure Process_Operand_Stream is
               Do_Nextfile : Boolean := False;
            begin
               for Index in 1 .. Natural (Runtime_Operands.Length) loop
                  exit when Exiting or else Runtime_Failed;
                  declare
                     Operand : constant Runtime_Operand :=
                       Runtime_Operands.Element (Index);
                  begin
                     case Operand.Kind is
                        when Assignment_Operand =>
                           Set_Scalar
                             (To_String (Operand.Name),
                              V.Make_Strnum (To_String (Operand.Value)));
                        when Input_Operand =>
                           Start_Operand_Text_Input (Index);
                           Do_Nextfile := False;
                           while not (Exiting or else Runtime_Failed or else Do_Nextfile)
                             and then Advance_Main_Record (Into_Field0 => True, Var => null)
                           loop
                              Process_Current_Record (Do_Nextfile);
                           end loop;
                     end case;
                  end;
               end loop;
               Current_Runtime_Operand := 0;
            end Process_Operand_Stream;
         begin
            if not Runtime_Operands.Is_Empty then
               Process_Operand_Stream;
            elsif Read_Record /= null or else Read_Text /= null then
               Process_Stream;
            elsif Input_Files.Is_Empty then
               Process_File
                 (Filename, Input,
                  Reuse_Current =>
                    Preloaded_Input_Initialized
                    and then Preloaded_Input_Index = 0);
            else
               for Index in 1 .. Natural (Input_Files.Length) loop
                  exit when Exiting or else Runtime_Failed;
                  declare
                     F : constant Var_Assignment := Input_Files.Element (Index);
                  begin
                     Process_File
                       (To_String (F.Name), To_String (F.Value),
                        Reuse_Current =>
                          Preloaded_Input_Initialized
                          and then Preloaded_Input_Index = Index);
                  end;
               end loop;
            end if;
         end;
      end if;

      --  END rules (run once, even after exit, unless a runtime error).
      Exiting := False;
      for R of Prog.Rules loop
         exit when Exiting or else Runtime_Failed;
         if R.Pat = A.P_End then
            declare
               F : constant Flow := Exec (R.Action);
               pragma Unreferenced (F);
            begin
               null;
            end;
         end if;
      end loop;

      Output := Out_Buf;
      Output_Files.Clear;
      for Name of Redirect_Order loop
         Output_Files.Append
           (Var_Assignment'(Name  => Name,
                            Value => Redirect_Buf.Element (To_String (Name))));
      end loop;
      Exit_Code := Exit_Code_V;
      if Runtime_Failed then
         Status := Run_Error;
         Message := Runtime_Msg;
      else
         Status := Run_Ok;
         Message := Null_Unbounded_String;
      end if;
   exception
      when Err : others =>
         --  A library must never abort its host. Should any operation raise an
         --  unexpected exception -- e.g. a non-finite result overflowing the
         --  number formatter -- turn it into a clean Run_Error instead of letting
         --  it propagate out of Run and crash the caller.
         Output := Out_Buf;
         Output_Files.Clear;
         Exit_Code := 2;
         Status := Run_Error;
         Message := To_Unbounded_String
           ("awklib internal error: " & Ada.Exceptions.Exception_Message (Err));
   end Run_Core;

   procedure Run
     (Program_Source : String;
      Input          : String;
      Assignments    : Assignment_Vectors.Vector;
      Environment    : Assignment_Vectors.Vector;
      Filename       : String;
      Output         : out U.Unbounded_String;
      Exit_Code      : out Integer;
      Status         : out Run_Status;
      Message        : out U.Unbounded_String;
      Output_Files   : out Assignment_Vectors.Vector;
      Files          : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Input_Files    : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Arguments      : String_Vectors.Vector := String_Vectors.Empty_Vector;
      Commands       : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Read_Command   : Command_Reader := null)
   is
   begin
      Run_Core
        (Program_Source => Program_Source,
         Input => Input,
         Assignments => Assignments,
         Environment => Environment,
         Filename => Filename,
         Output => Output,
         Exit_Code => Exit_Code,
         Status => Status,
         Message => Message,
         Output_Files => Output_Files,
         Files => Files,
         Input_Files => Input_Files,
         Arguments => Arguments,
         Commands => Commands,
         Read_Command => Read_Command,
         Read_Record => null,
         Read_Text => null,
         Write_Output => null,
         Write_Redirection => null,
         User_Data => System.Null_Address);
   end Run;

   procedure Run_Streaming
     (Program_Source : String;
      Assignments    : Assignment_Vectors.Vector;
      Environment    : Assignment_Vectors.Vector;
      Initial_Filename : String;
      Read_Record    : not null Record_Reader;
      Write_Output   : not null Output_Writer;
      Write_Redirection : Redirection_Writer;
      User_Data      : System.Address := System.Null_Address;
      Exit_Code      : out Integer;
      Status         : out Run_Status;
      Message        : out U.Unbounded_String;
      Files          : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Arguments      : String_Vectors.Vector := String_Vectors.Empty_Vector;
      Commands       : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Read_Command   : Command_Reader := null)
   is
      Output       : U.Unbounded_String;
      Output_Files : Assignment_Vectors.Vector;
      Empty_Inputs : Assignment_Vectors.Vector;
   begin
      Run_Core
        (Program_Source => Program_Source,
         Input => "",
         Assignments => Assignments,
         Environment => Environment,
         Filename => Initial_Filename,
         Output => Output,
         Exit_Code => Exit_Code,
         Status => Status,
         Message => Message,
         Output_Files => Output_Files,
         Files => Files,
         Input_Files => Empty_Inputs,
         Arguments => Arguments,
         Commands => Commands,
         Read_Command => Read_Command,
         Read_Record => Read_Record,
         Read_Text => null,
         Write_Output => Write_Output,
         Write_Redirection => Write_Redirection,
         User_Data => User_Data);
   end Run_Streaming;

   procedure Run_Text_Streaming
     (Program_Source : String;
      Assignments    : Assignment_Vectors.Vector;
      Environment    : Assignment_Vectors.Vector;
      Initial_Filename : String;
      Read_Text      : not null Text_Reader;
      Write_Output   : not null Output_Writer;
      Write_Redirection : Redirection_Writer;
      User_Data      : System.Address := System.Null_Address;
      Exit_Code      : out Integer;
      Status         : out Run_Status;
      Message        : out U.Unbounded_String;
      Files          : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Arguments      : String_Vectors.Vector := String_Vectors.Empty_Vector;
      Commands       : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Read_Command   : Command_Reader := null)
   is
      Output       : U.Unbounded_String;
      Output_Files : Assignment_Vectors.Vector;
      Empty_Inputs : Assignment_Vectors.Vector;
   begin
      Run_Core
        (Program_Source => Program_Source,
         Input => "",
         Assignments => Assignments,
         Environment => Environment,
         Filename => Initial_Filename,
         Output => Output,
         Exit_Code => Exit_Code,
         Status => Status,
         Message => Message,
         Output_Files => Output_Files,
         Files => Files,
         Input_Files => Empty_Inputs,
         Arguments => Arguments,
         Commands => Commands,
         Read_Command => Read_Command,
         Read_Record => null,
         Read_Text => Read_Text,
         Write_Output => Write_Output,
         Write_Redirection => Write_Redirection,
         User_Data => User_Data);
   end Run_Text_Streaming;

   procedure Run_Text_Streaming_With_Operands
     (Program_Source : String;
      Assignments    : Assignment_Vectors.Vector;
      Environment    : Assignment_Vectors.Vector;
      Initial_Filename : String;
      Operands       : Runtime_Operand_Vectors.Vector;
      Read_Text      : not null Operand_Text_Reader;
      Write_Output   : not null Output_Writer;
      Write_Redirection : Redirection_Writer;
      User_Data      : System.Address := System.Null_Address;
      Exit_Code      : out Integer;
      Status         : out Run_Status;
      Message        : out U.Unbounded_String;
      Files          : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Commands       : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Read_Command   : Command_Reader := null)
   is
      Output       : U.Unbounded_String;
      Output_Files : Assignment_Vectors.Vector;
      Empty_Inputs : Assignment_Vectors.Vector;
      Empty_Args   : String_Vectors.Vector;
   begin
      Run_Core
        (Program_Source => Program_Source,
         Input => "",
         Assignments => Assignments,
         Environment => Environment,
         Filename => Initial_Filename,
         Output => Output,
         Exit_Code => Exit_Code,
         Status => Status,
         Message => Message,
         Output_Files => Output_Files,
         Files => Files,
         Input_Files => Empty_Inputs,
         Arguments => Empty_Args,
         Commands => Commands,
         Read_Command => Read_Command,
         Read_Record => null,
         Read_Text => null,
         Runtime_Operands => Operands,
         Read_Operand_Text => Read_Text,
         Write_Output => Write_Output,
         Write_Redirection => Write_Redirection,
         User_Data => User_Data);
   end Run_Text_Streaming_With_Operands;

end Awklib.Interpreter;
