with Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Project_Tools.Processes;
with Project_Tools.Release_Checks;
with Project_Tools.Text;
with Project_Tools.Tree_Checks;

procedure Check_All is
   use Ada.Text_IO;

   function Project_Root return String is
      Here : constant String := Ada.Directories.Current_Directory;
   begin
      if Ada.Directories.Exists (Here & "/awklib.gpr") then
         return Here;
      elsif Ada.Directories.Exists (Here & "/../awklib.gpr") then
         return Ada.Directories.Full_Name (Here & "/..");
      else
         return Here;
      end if;
   end Project_Root;

   Root   : constant String := Project_Root;
   Alr    : constant String := Project_Tools.Processes.Locate_Command ("alr");
   Checks : constant Project_Tools.Release_Checks.Checker :=
     Project_Tools.Release_Checks.Create (Root);

   procedure Require_Alire_GNAT_15 is
      Output : Ada.Strings.Unbounded.Unbounded_String;
      Status : Integer;
   begin
      Status :=
        Project_Tools.Processes.Run_Status
          ("verify Alire-selected GNAT 15 toolchain",
           Root,
           Alr,
           [new String'("exec"), new String'("--"), new String'("gnatls"), new String'("--version")],
           Output,
           Quiet => False);

      if Status /= 0 then
         Put_Line (Standard_Error, "alr exec -- gnatls --version failed");
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         raise Program_Error;
      elsif Project_Tools.Text.Contains (Ada.Strings.Unbounded.To_String (Output), "GNATLS 15.") = False then
         Put_Line
           (Standard_Error,
            "awklib must build with Alire-selected GNAT 15, got: "
            & Ada.Strings.Unbounded.To_String (Output));
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         raise Program_Error;
      end if;
   end Require_Alire_GNAT_15;
begin
   if not Ada.Directories.Exists (Root & "/awklib.gpr") then
      Put_Line (Standard_Error, "check_all must be run from the awklib root or tools directory");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Project_Tools.Processes.Require_Command
     ("alr", "alr executable not found on PATH");
   Require_Alire_GNAT_15;

   Project_Tools.Release_Checks.Require_File (Checks, "awklib.gpr");
   Project_Tools.Release_Checks.Require_File (Checks, "check_awklib/check_awklib.gpr");
   Project_Tools.Release_Checks.Require_File (Checks, "tools/awklib_check_all.gpr");

   Project_Tools.Release_Checks.Run
     ("build check_awklib", Root & "/check_awklib", Alr, [1 => new String'("build")]);
   Project_Tools.Release_Checks.Run
     ("awklib release check", Root & "/check_awklib", "./bin/check_awklib", []);

   Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr (Root & "/check_awklib/obj");
   Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr (Root & "/tools/obj");

   Put_Line ("awklib aggregate release checklist passed");
   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
exception
   when Program_Error =>
      null;
   when E : others =>
      Put_Line
        (Standard_Error,
         "awklib aggregate release checklist failed: " & Ada.Exceptions.Exception_Message (E));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Check_All;
