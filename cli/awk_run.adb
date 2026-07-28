with Ada.Command_Line;        use Ada.Command_Line;
with Ada.Text_IO;
with Ada.Text_IO.Text_Streams;
with Ada.Strings.Unbounded;    use Ada.Strings.Unbounded;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Awklib.Interpreter;

--  Minimal `awk`-style CLI over awklib, for testing and as a usage example:
--    awk_run [-f progfile]... [-v name=value]... ['program'] [file...]
procedure Awk_Run is
   package I renames Awklib.Interpreter;
   use type I.Run_Status;

   Program     : Unbounded_String;
   Have_Prog_F : Boolean := False;
   Assignments : I.Assignment_Vectors.Vector;
   Environment : I.Assignment_Vectors.Vector;
   Input       : Unbounded_String;
   First_File  : Unbounded_String;
   Input_Files : I.Assignment_Vectors.Vector;
   Arguments   : I.String_Vectors.Vector;
   Have_Input  : Boolean := False;

   function Read_File (Path : String) return String is
      use Ada.Streams.Stream_IO;
      F    : File_Type;
      Buf  : Unbounded_String;
      Data : Ada.Streams.Stream_Element_Array (1 .. 65536);
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      Open (F, In_File, Path);
      while not End_Of_File (F) loop
         Read (F, Data, Last);
         for K in 1 .. Last loop
            Append (Buf, Character'Val (Data (K)));
         end loop;
      end loop;
      Close (F);
      return To_String (Buf);
   end Read_File;

   --  Read all of standard input. Opening "/dev/stdin" as a Stream_IO file fails
   --  on a pipe (there is no file to open), so read the standard-input stream
   --  directly, which works for both a redirect and a pipe.
   function Read_Standard_Input return String is
      use Ada.Streams;
      S    : constant Ada.Text_IO.Text_Streams.Stream_Access :=
        Ada.Text_IO.Text_Streams.Stream (Ada.Text_IO.Standard_Input);
      Buf  : Unbounded_String;
      Data : Stream_Element_Array (1 .. 65536);
      Last : Stream_Element_Offset;
   begin
      loop
         Read (S.all, Data, Last);
         for K in 1 .. Last loop
            Append (Buf, Character'Val (Data (K)));
         end loop;
         exit when Last < Data'First;
      end loop;
      return To_String (Buf);
   end Read_Standard_Input;

   procedure Add_Assignment (Spec : String) is
      Eq : constant Natural := Ada.Strings.Fixed.Index (Spec, "=");
   begin
      if Eq > 0 then
         Assignments.Append
           (I.Var_Assignment'
              (Name  => To_Unbounded_String (Spec (Spec'First .. Eq - 1)),
               Value => To_Unbounded_String (Spec (Eq + 1 .. Spec'Last))));
      end if;
   end Add_Assignment;

   Idx : Positive := 1;
begin
   --  Options
   while Idx <= Argument_Count loop
      declare
         Arg : constant String := Argument (Idx);
      begin
         if Arg = "-f" and then Idx < Argument_Count then
            Append (Program, Read_File (Argument (Idx + 1)));
            Append (Program, ASCII.LF);
            Have_Prog_F := True;
            Idx := Idx + 2;
         elsif Arg = "-v" and then Idx < Argument_Count then
            Add_Assignment (Argument (Idx + 1));
            Idx := Idx + 2;
         else
            exit;
         end if;
      end;
   end loop;

   if not Have_Prog_F and then Idx <= Argument_Count then
      Program := To_Unbounded_String (Argument (Idx));
      Idx := Idx + 1;
   end if;

   --  Remaining args: input files, each a separate (FILENAME, content) entry.
   --  The same file names also form ARGV (ARGV[1 .. n]); the library adds ARGV[0].
   while Idx <= Argument_Count loop
      Input_Files.Append
        (I.Var_Assignment'(Name  => To_Unbounded_String (Argument (Idx)),
                           Value => To_Unbounded_String (Read_File (Argument (Idx)))));
      Arguments.Append (To_Unbounded_String (Argument (Idx)));
      Have_Input := True;
      Idx := Idx + 1;
   end loop;

   if not Have_Input then
      Input := To_Unbounded_String (Read_Standard_Input);
   end if;

   declare
      Output       : Unbounded_String;
      Output_Files : I.Assignment_Vectors.Vector;
      Exit_Code    : Integer;
      Status       : I.Run_Status;
      Message      : Unbounded_String;

      --  awklib captures `print > file` in memory; the CLI is the front end that
      --  legitimately owns the filesystem, so it writes those captures to disk.
      procedure Write_File (Path, Content : String) is
         use Ada.Streams.Stream_IO;
         F   : File_Type;
         Buf : Ada.Streams.Stream_Element_Array (1 .. Content'Length);
      begin
         Create (F, Out_File, Path);
         for K in Content'Range loop
            Buf (Ada.Streams.Stream_Element_Offset (K - Content'First + 1)) :=
              Ada.Streams.Stream_Element (Character'Pos (Content (K)));
         end loop;
         Write (F, Buf);
         Close (F);
      end Write_File;
   begin
      I.Run
        (Program_Source => To_String (Program),
         Input          => To_String (Input),
         Assignments    => Assignments,
         Environment    => Environment,
         Filename       => To_String (First_File),
         Output         => Output,
         Exit_Code      => Exit_Code,
         Status         => Status,
         Message        => Message,
         Output_Files   => Output_Files,
         Input_Files    => Input_Files,
         Arguments      => Arguments);

      String'Write (Ada.Text_IO.Text_Streams.Stream (Ada.Text_IO.Standard_Output),
                    To_String (Output));
      for Redir of Output_Files loop
         Write_File (To_String (Redir.Name), To_String (Redir.Value));
      end loop;
      if Status = I.Run_Error then
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "awk_run: " & To_String (Message));
         Set_Exit_Status (2);
      else
         Set_Exit_Status (Exit_Status (Exit_Code));
      end if;
   end;
end Awk_Run;
