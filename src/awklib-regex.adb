with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;   use Ada.Strings.Unbounded;
with Regexp;

package body Awklib.Regex is

   --  Translate the C-style whitespace escapes AWK recognizes inside a regex
   --  (\t \n \r \f \v \a \b) into their literal control characters. Every other
   --  backslash sequence -- including \\ and metacharacter escapes like \. \* --
   --  is left intact for the regexp engine to interpret.
   function Translate_Escapes (Pattern : String) return String is
      Buf : Unbounded_String;
      I   : Integer := Pattern'First;
   begin
      while I <= Pattern'Last loop
         if Pattern (I) = '\' and then I < Pattern'Last then
            case Pattern (I + 1) is
               when 't' => Append (Buf, Character'Val (9));
               when 'n' => Append (Buf, Character'Val (10));
               when 'r' => Append (Buf, Character'Val (13));
               when 'f' => Append (Buf, Character'Val (12));
               when 'v' => Append (Buf, Character'Val (11));
               when 'a' => Append (Buf, Character'Val (7));
               when 'b' => Append (Buf, Character'Val (8));
               when others =>
                  Append (Buf, '\');
                  Append (Buf, Pattern (I + 1));
            end case;
            I := I + 2;
         else
            Append (Buf, Pattern (I));
            I := I + 1;
         end if;
      end loop;
      return To_String (Buf);
   end Translate_Escapes;

   use type Regexp.Compile_Status;
   use type Regexp.Match_Status;

   type Compiled_Pattern is record
      Search   : Regexp.Compile_Result;
      Anchored : Regexp.Compile_Result;
   end record;

   type Comp_Access is access Compiled_Pattern;

   package Cache_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Comp_Access,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   --  The compiled-regex cache is shared across all interpreter runs (a compiled
   --  Regexp is immutable, so it is safe to share), so guard the map itself with a
   --  protected object -- otherwise concurrent runs would race on insert.
   protected Cache_Store is
      procedure Find (Pattern : String; Comp : out Comp_Access; Found : out Boolean);
      procedure Store (Pattern : String; Comp : Comp_Access);
   private
      Cache : Cache_Maps.Map;
   end Cache_Store;

   protected body Cache_Store is
      procedure Find (Pattern : String; Comp : out Comp_Access; Found : out Boolean) is
         C : constant Cache_Maps.Cursor := Cache.Find (Pattern);
      begin
         Found := Cache_Maps.Has_Element (C);
         Comp  := (if Found then Cache_Maps.Element (C) else null);
      end Find;

      procedure Store (Pattern : String; Comp : Comp_Access) is
      begin
         --  A concurrent run may have compiled the same pattern first; keep whatever
         --  is already there rather than raising on a duplicate key.
         if not Cache.Contains (Pattern) then
            Cache.Insert (Pattern, Comp);
         end if;
      end Store;
   end Cache_Store;

   Awk_Options : constant Regexp.Match_Options :=
     (Case_Sensitive => True, others => <>);

   --  Return the compiled expression for Pattern, compiling and caching on the
   --  first request. Ok is False when the pattern does not compile.
   procedure Get_Compiled
     (Pattern : String;
      Comp    : out Comp_Access;
      Ok      : out Boolean)
   is
      Found : Boolean;
   begin
      Cache_Store.Find (Pattern, Comp, Found);
      if not Found then
         --  Compile in UTF-8 mode so ".", classes, and quantifiers match whole
         --  code points. Matching stays lenient (the match options below are not
         --  UTF_8_Mode, so no input-validation rejection); the engine's decoder
         --  tolerates malformed bytes, which an awk program may legitimately see.
         declare
            Translated : constant String := Translate_Escapes (Pattern);
         begin
            Comp := new Compiled_Pattern'
              (Search   => Regexp.Compile (Translated, Character_Mode => Regexp.UTF_8_Mode),
               Anchored => Regexp.Compile ("^(?:" & Translated & ")$", Character_Mode => Regexp.UTF_8_Mode));
         end;
         Cache_Store.Store (Pattern, Comp);
      end if;
      Ok := Comp.Search.Status = Regexp.Compile_Ok
        and then Comp.Anchored.Status = Regexp.Compile_Ok;
   end Get_Compiled;

   function Is_Match (Pattern, Text : String) return Boolean is
      Comp : Comp_Access;
      Ok   : Boolean;
   begin
      Get_Compiled (Pattern, Comp, Ok);
      if not Ok then
         return False;
      end if;
      return Search (Pattern, Text).Matched;
   end Is_Match;

   function Search (Pattern, Text : String; From : Positive := 1) return Match is
      Comp : Comp_Access;
      Ok   : Boolean;
   begin
      Get_Compiled (Pattern, Comp, Ok);
      if not Ok then
         return (Matched => False, others => 0);
      end if;
      declare
         M : constant Regexp.Match_Result :=
           Regexp.Find_From (Comp.Search.Expression, Text, From, Awk_Options);
      begin
         if M.Status = Regexp.Match_Ok then
            declare
               Absolute_First : constant Positive := Text'First + M.First - 1;
               Best_Last      : Natural := M.Last;

               function Prefix_Matches (Last : Natural) return Boolean is
                  R : Regexp.Match_Result;
               begin
                  if Last < Absolute_First then
                     R := Regexp.Matches_Entire (Comp.Anchored.Expression, "", Awk_Options);
                  else
                     R :=
                       Regexp.Matches_Entire
                         (Comp.Anchored.Expression,
                          Text (Absolute_First .. Positive (Last)),
                          Awk_Options);
                  end if;
                  return R.Status = Regexp.Match_Ok;
               end Prefix_Matches;
            begin
               if Text'Length > 0 then
                  for Last in reverse Absolute_First .. Text'Last loop
                     if Prefix_Matches (Last) then
                        Best_Last := Last - Text'First + 1;
                        return (Matched => True, First => M.First, Last => Best_Last);
                     end if;
                  end loop;
               end if;

               if Prefix_Matches (Absolute_First - 1) then
                  return (Matched => True, First => M.First, Last => M.First - 1);
               end if;

               return (Matched => True, First => M.First, Last => Best_Last);
            end;
         else
            return (Matched => False, others => 0);
         end if;
      end;
   end Search;

end Awklib.Regex;
