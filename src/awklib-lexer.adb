package body Awklib.Lexer is

   HT : constant Character := Character'Val (9);

   function Is_Ident_Start (C : Character) return Boolean is
     (C in 'A' .. 'Z' | 'a' .. 'z' | '_');

   function Is_Ident_Char (C : Character) return Boolean is
     (C in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_');

   function Is_Digit (C : Character) return Boolean is (C in '0' .. '9');

   --  Does a token of this kind end a value, so that a following '/' is the
   --  division operator rather than the start of a regex constant?
   function Value_Ending (K : Token_Kind) return Boolean is
     (K in Tok_Number | Tok_String | Tok_Ere | Tok_Name
         | Tok_Rparen | Tok_Rbracket | Tok_Incr | Tok_Decr | Tok_Dollar);

   procedure Tokenize
     (Source  : String;
      Tokens  : out Token_Vectors.Vector;
      Status  : out Result_Status;
      Message : out U.Unbounded_String)
   is
      I    : Integer := Source'First;
      Last : constant Integer := Source'Last;
      Line : Positive := 1;
      Prev : Token_Kind := Tok_Newline;   --  regex context at start of file

      procedure Emit (K : Token_Kind; Text : String := ""; N : Values.Number := 0.0) is
      begin
         Tokens.Append (Token'(Kind => K,
                               Text => U.To_Unbounded_String (Text),
                               Num  => N,
                               Line => Line));
         Prev := K;
      end Emit;

      procedure Fail (Msg : String) is
      begin
         Status := Lex_Error;
         Message := U.To_Unbounded_String
           ("line" & Positive'Image (Line) & ": " & Msg);
      end Fail;

      function Keyword (Name : String) return Token_Kind is
      begin
         if Name = "BEGIN" then return Tok_Begin;
         elsif Name = "END" then return Tok_End;
         elsif Name = "function" or else Name = "func" then return Tok_Function;
         elsif Name = "if" then return Tok_If;
         elsif Name = "else" then return Tok_Else;
         elsif Name = "while" then return Tok_While;
         elsif Name = "for" then return Tok_For;
         elsif Name = "do" then return Tok_Do;
         elsif Name = "break" then return Tok_Break;
         elsif Name = "continue" then return Tok_Continue;
         elsif Name = "next" then return Tok_Next;
         elsif Name = "nextfile" then return Tok_Nextfile;
         elsif Name = "exit" then return Tok_Exit;
         elsif Name = "return" then return Tok_Return;
         elsif Name = "delete" then return Tok_Delete;
         elsif Name = "in" then return Tok_In;
         elsif Name = "getline" then return Tok_Getline;
         elsif Name = "print" then return Tok_Print;
         elsif Name = "printf" then return Tok_Printf;
         else return Tok_Name;
         end if;
      end Keyword;

   begin
      Status := Ok;
      Message := U.Null_Unbounded_String;
      Tokens.Clear;

      while I <= Last loop
         declare
            C : constant Character := Source (I);
         begin
            if C = ' ' or else C = HT then
               I := I + 1;

            elsif C = '\' and then I < Last and then Source (I + 1) = ASCII.LF then
               --  Line continuation.
               Line := Line + 1;
               I := I + 2;

            elsif C = ASCII.CR then
               I := I + 1;   --  ignore, handle LF separately

            elsif C = ASCII.LF then
               Emit (Tok_Newline);
               Line := Line + 1;
               I := I + 1;

            elsif C = '#' then
               while I <= Last and then Source (I) /= ASCII.LF loop
                  I := I + 1;
               end loop;

            elsif Is_Ident_Start (C) then
               declare
                  Start : constant Integer := I;
               begin
                  while I <= Last and then Is_Ident_Char (Source (I)) loop
                     I := I + 1;
                  end loop;
                  declare
                     Name : constant String := Source (Start .. I - 1);
                     K    : constant Token_Kind := Keyword (Name);
                  begin
                     if K /= Tok_Name then
                        Emit (K, Name);
                     elsif I <= Last and then Source (I) = '(' then
                        Emit (Tok_Func_Name, Name);
                     else
                        Emit (Tok_Name, Name);
                     end if;
                  end;
               end;

            elsif Is_Digit (C)
              or else (C = '.' and then I < Last and then Is_Digit (Source (I + 1)))
            then
               declare
                  Start : constant Integer := I;
               begin
                  while I <= Last and then Is_Digit (Source (I)) loop
                     I := I + 1;
                  end loop;
                  if I <= Last and then Source (I) = '.' then
                     I := I + 1;
                     while I <= Last and then Is_Digit (Source (I)) loop
                        I := I + 1;
                     end loop;
                  end if;
                  if I <= Last and then (Source (I) = 'e' or else Source (I) = 'E') then
                     declare
                        J : Integer := I + 1;
                     begin
                        if J <= Last and then (Source (J) = '+' or else Source (J) = '-') then
                           J := J + 1;
                        end if;
                        if J <= Last and then Is_Digit (Source (J)) then
                           while J <= Last and then Is_Digit (Source (J)) loop
                              J := J + 1;
                           end loop;
                           I := J;
                        end if;
                     end;
                  end if;
                  Emit (Tok_Number,
                        Source (Start .. I - 1),
                        Values.Parse_Leading_Number (Source (Start .. I - 1)));
               end;

            elsif C = '"' then
               declare
                  Buf : U.Unbounded_String;
               begin
                  I := I + 1;
                  loop
                     if I > Last then
                        Fail ("unterminated string literal");
                        return;
                     end if;
                     exit when Source (I) = '"';
                     if Source (I) = '\' and then I < Last then
                        I := I + 1;
                        case Source (I) is
                           when 'n' => U.Append (Buf, ASCII.LF);
                           when 't' => U.Append (Buf, HT);
                           when 'r' => U.Append (Buf, ASCII.CR);
                           when '\' => U.Append (Buf, '\');
                           when '"' => U.Append (Buf, '"');
                           when '/' => U.Append (Buf, '/');
                           when 'a' => U.Append (Buf, Character'Val (7));
                           when 'b' => U.Append (Buf, Character'Val (8));
                           when 'f' => U.Append (Buf, Character'Val (12));
                           when 'v' => U.Append (Buf, Character'Val (11));
                           when '0' .. '7' =>
                              declare
                                 Val   : Natural := 0;
                                 Count : Natural := 0;
                              begin
                                 while Count < 3 and then I <= Last
                                   and then Source (I) in '0' .. '7'
                                 loop
                                    Val := Val * 8 + (Character'Pos (Source (I)) - Character'Pos ('0'));
                                    I := I + 1;
                                    Count := Count + 1;
                                 end loop;
                                 I := I - 1;
                                 U.Append (Buf, Character'Val (Val mod 256));
                              end;
                           when others =>
                              U.Append (Buf, Source (I));
                        end case;
                        I := I + 1;
                     else
                        U.Append (Buf, Source (I));
                        I := I + 1;
                     end if;
                  end loop;
                  I := I + 1;   --  closing quote
                  Emit (Tok_String, U.To_String (Buf));
               end;

            elsif C = '/' and then not Value_Ending (Prev) then
               --  Regex constant.
               declare
                  Buf     : U.Unbounded_String;
                  In_Class : Boolean := False;
               begin
                  I := I + 1;
                  loop
                     if I > Last then
                        Fail ("unterminated regex constant");
                        return;
                     end if;
                     exit when Source (I) = '/' and then not In_Class;
                     if Source (I) = '\' and then I < Last then
                        if Source (I + 1) = '/' then
                           U.Append (Buf, '/');
                        else
                           U.Append (Buf, '\');
                           U.Append (Buf, Source (I + 1));
                        end if;
                        I := I + 2;
                     else
                        if Source (I) = '[' then
                           In_Class := True;
                        elsif Source (I) = ']' then
                           In_Class := False;
                        end if;
                        U.Append (Buf, Source (I));
                        I := I + 1;
                     end if;
                  end loop;
                  I := I + 1;   --  closing slash
                  Emit (Tok_Ere, U.To_String (Buf));
               end;

            else
               --  Operators and punctuation. Longest match first.
               declare
                  C2 : constant Character := (if I < Last then Source (I + 1) else ASCII.NUL);
               begin
                  if C = '+' and then C2 = '+' then Emit (Tok_Incr); I := I + 2;
                  elsif C = '-' and then C2 = '-' then Emit (Tok_Decr); I := I + 2;
                  elsif C = '+' and then C2 = '=' then Emit (Tok_Add_Assign); I := I + 2;
                  elsif C = '-' and then C2 = '=' then Emit (Tok_Sub_Assign); I := I + 2;
                  elsif C = '*' and then C2 = '=' then Emit (Tok_Mul_Assign); I := I + 2;
                  elsif C = '/' and then C2 = '=' then Emit (Tok_Div_Assign); I := I + 2;
                  elsif C = '%' and then C2 = '=' then Emit (Tok_Mod_Assign); I := I + 2;
                  elsif C = '^' and then C2 = '=' then Emit (Tok_Pow_Assign); I := I + 2;
                  elsif C = '=' and then C2 = '=' then Emit (Tok_Eq); I := I + 2;
                  elsif C = '!' and then C2 = '=' then Emit (Tok_Ne); I := I + 2;
                  elsif C = '<' and then C2 = '=' then Emit (Tok_Le); I := I + 2;
                  elsif C = '>' and then C2 = '=' then Emit (Tok_Ge); I := I + 2;
                  elsif C = '>' and then C2 = '>' then Emit (Tok_Append); I := I + 2;
                  elsif C = '&' and then C2 = '&' then Emit (Tok_And); I := I + 2;
                  elsif C = '|' and then C2 = '|' then Emit (Tok_Or); I := I + 2;
                  elsif C = '!' and then C2 = '~' then Emit (Tok_No_Match); I := I + 2;
                  else
                     case C is
                        when '=' => Emit (Tok_Assign);
                        when '<' => Emit (Tok_Lt);
                        when '>' => Emit (Tok_Gt);
                        when '!' => Emit (Tok_Not);
                        when '~' => Emit (Tok_Match);
                        when '+' => Emit (Tok_Plus);
                        when '-' => Emit (Tok_Minus);
                        when '*' => Emit (Tok_Star);
                        when '/' => Emit (Tok_Slash);
                        when '%' => Emit (Tok_Percent);
                        when '^' => Emit (Tok_Caret);
                        when '?' => Emit (Tok_Question);
                        when ':' => Emit (Tok_Colon);
                        when '$' => Emit (Tok_Dollar);
                        when '(' => Emit (Tok_Lparen);
                        when ')' => Emit (Tok_Rparen);
                        when '{' => Emit (Tok_Lbrace);
                        when '}' => Emit (Tok_Rbrace);
                        when '[' => Emit (Tok_Lbracket);
                        when ']' => Emit (Tok_Rbracket);
                        when ';' => Emit (Tok_Semicolon);
                        when ',' => Emit (Tok_Comma);
                        when '|' => Emit (Tok_Pipe);
                        when others =>
                           Fail ("unexpected character '" & C & "'");
                           return;
                     end case;
                     I := I + 1;
                  end if;
               end;
            end if;
         end;
      end loop;

      Tokens.Append (Token'(Kind => Tok_Eof, Line => Line, others => <>));
   end Tokenize;

end Awklib.Lexer;
