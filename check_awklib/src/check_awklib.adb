with Ada.Command_Line;
with Ada.Directories;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with Project_Tools.Files;
with Project_Tools.Processes;
with Project_Tools.Text;
with Project_Tools.Tree_Checks;

procedure Check_Awklib is
   use Ada.Text_IO;

   Build_Command : constant String := "alr --non-interactive build";
   GNAT_Version_Check_Command : constant String := "alr exec -- gnatls --version";
   Tests_Run_Command : constant String := "./bin/awklib_tests";

   function Root_Directory return String is
      Current : constant String := Ada.Directories.Current_Directory;
   begin
      if Ada.Directories.Exists (Current & "/awklib.gpr") then
         return Current;
      elsif Ada.Directories.Exists (Current & "/../awklib.gpr") then
         return Ada.Directories.Full_Name (Current & "/..");
      else
         Put_Line (Standard_Error, "awklib root not found from " & Current);
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         raise Program_Error;
      end if;
   end Root_Directory;

   Root   : constant String := Root_Directory;
   Errors : Natural := 0;

   procedure Error (Message : String) is
   begin
      Errors := Errors + 1;
      Put_Line (Standard_Error, "error: " & Message);
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end Error;

   procedure Require_Alire_GNAT_15 is
      Output : constant String :=
        Project_Tools.Processes.Shell_Output
          ("cd " & Project_Tools.Processes.Shell_Quote (Root) & " && " & GNAT_Version_Check_Command);
   begin
      Put_Line ("");
      Put_Line ("==> verify Alire-selected GNAT 15 toolchain");

      if Output = "" then
         Error ("alr exec -- gnatls --version failed");
      elsif Project_Tools.Text.Contains (Output, "GNATLS 15.") = False then
         Error ("awklib must build with Alire-selected GNAT 15, got: " & Output);
      end if;
   end Require_Alire_GNAT_15;

   procedure Require_Text (Relative_Path : String; Pattern : String; Message : String) is
   begin
      Project_Tools.Files.Require_Contains (Root & "/" & Relative_Path, Pattern, Message);
   end Require_Text;

   procedure Require_GNAT_15_Manifest (Relative_Path : String) is
   begin
      Require_Text
        (Relative_Path,
         "gnat_native = ""=15.2.1""",
         Relative_Path & " must pin gnat_native = ""=15.2.1""");
   end Require_GNAT_15_Manifest;

   procedure Run_Command (Label : String; Dir : String; Command : String) is
      Status : Integer;
   begin
      Put_Line ("");
      Put_Line ("==> " & Label);

      Status := Project_Tools.Processes.Run_Shell_In_Directory (Dir, Command);
      if Status /= 0 then
         Error (Label & " failed with status" & Integer'Image (Status));
      end if;
   end Run_Command;

   procedure Check_Generated_Artifacts is
      Hygiene_Errors : Natural := 0;
   begin
      Project_Tools.Tree_Checks.Check_No_Generated_Python (Hygiene_Errors, Root & "/src");
      Project_Tools.Tree_Checks.Check_No_Generated_Python (Hygiene_Errors, Root & "/tests/src");
      Errors := Errors + Hygiene_Errors;
   end Check_Generated_Artifacts;

begin
   Project_Tools.Processes.Require_Command ("alr", "alr executable not found on PATH");
   Require_Alire_GNAT_15;

   Require_GNAT_15_Manifest ("alire.toml");
   Require_GNAT_15_Manifest ("tests/alire.toml");
   Require_GNAT_15_Manifest ("tools/alire.toml");
   Require_GNAT_15_Manifest ("check_awklib/alire.toml");

   Project_Tools.Files.Require_Files
     ([To_Unbounded_String (Root & "/README.md"),
       To_Unbounded_String (Root & "/CLAUDE.md"),
       To_Unbounded_String (Root & "/AGENTS.md"),
       To_Unbounded_String (Root & "/awklib.gpr"),
       To_Unbounded_String (Root & "/src/awklib.ads"),
       To_Unbounded_String (Root & "/src/awklib-interpreter.ads"),
       To_Unbounded_String (Root & "/tests/alire.toml"),
       To_Unbounded_String (Root & "/tests/awklib_tests.gpr")],
      "required awklib release file missing");

   --  The on-ramp docs must carry the API entry point, how to work the crate, and the
   --  one deliberate divergence a consumer needs to know about.
   Require_Text
     ("README.md", "Awklib.Interpreter",
      "README must document the Awklib.Interpreter.Run entry point");
   Require_Text
     ("README.md", "alr test",
      "README must document how to build and run the suite");
   Require_Text
     ("README.md", "leftmost-first",
      "README must document the leftmost-first regex boundary");
   Require_Text
     ("CLAUDE.md", "not reentrant",
      "CLAUDE.md must warn that the interpreter is not reentrant");
   Require_Text
     ("CLAUDE.md", "strnum",
      "CLAUDE.md must describe the strnum value model");

   Check_Generated_Artifacts;

   Run_Command ("build awklib library", Root, Build_Command);
   Run_Command ("build awklib tests", Root & "/tests", Build_Command);
   Run_Command ("run awklib tests", Root & "/tests", Tests_Run_Command);

   if Errors = 0 then
      Put_Line ("awklib release check passed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   else
      Put_Line
        (Standard_Error,
         "awklib release check failed:" & Natural'Image (Errors) & " error(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
exception
   when Program_Error =>
      null;
end Check_Awklib;
