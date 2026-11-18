unit SyntaxLfm;

{ Lazarus and Delphi form files (.lfm, .dfm in text form) for fcl-syntax,
  which has no highlighter of its own for them:

    object Form1: TForm1          object, inherited, inline, end, item
      Left = 395                  the property's name, then its value
      Caption = 'Main' + #13      strings and #13 character codes
      Anchors = [akTop, akLeft]   sets, collections in < >, lists in ( )
      Picture.Data = (hex in braces)   binary data, shown quietly
    end

  Keywords, property names, component and class names, strings, numbers
  and symbols each get their own kind, so the page's colors apply. }

{$mode objfpc}{$H+}

interface

uses
  Types, SysUtils, syntax.highlighter;

type
  TLfmSyntaxHighlighter = class(TSyntaxHighlighter)
  private
    FSource: string;
    FPos: integer;
    function Ch(Offset: integer = 0): char;
    function TakeWhile(const Allowed: TSysCharSet): string;
  protected
    class procedure CheckCategories;
    class procedure RegisterDefaultCategories; override;
    class function GetLanguages: TStringDynArray; override;
  public
  class var
    CategoryLfm: integer;
    constructor Create; override;
    function Execute(const Source: string): TSyntaxTokenArray; override;
  end;

implementation

const
  NAME_START = ['A'..'Z', 'a'..'z', '_'];
  NAME_CHARS = ['A'..'Z', 'a'..'z', '_', '0'..'9'];
  DIGITS = ['0'..'9'];

function TLfmSyntaxHighlighter.Ch(Offset: integer): char;
begin
  if FPos + Offset <= Length(FSource) then
    Result := FSource[FPos + Offset]
  else
    Result := #0;
end;

function TLfmSyntaxHighlighter.TakeWhile(const Allowed: TSysCharSet): string;
var
  Start: integer;
begin
  Start := FPos;
  while (FPos <= Length(FSource)) and (FSource[FPos] in Allowed) do
    Inc(FPos);
  Result := Copy(FSource, Start, FPos - Start);
end;

class procedure TLfmSyntaxHighlighter.CheckCategories;
begin
  if CategoryLfm = 0 then
    RegisterDefaultCategories;
end;

class procedure TLfmSyntaxHighlighter.RegisterDefaultCategories;
begin
  CategoryLfm := RegisterCategory('LFM');
end;

class function TLfmSyntaxHighlighter.GetLanguages: TStringDynArray;
begin
  Result := ['lfm', 'dfm', 'xfm', 'fmx'];
end;

constructor TLfmSyntaxHighlighter.Create;
begin
  inherited Create;
  CheckCategories;
  DefaultCategory := CategoryLfm;
end;

function TLfmSyntaxHighlighter.Execute(const Source: string): TSyntaxTokenArray;
var
  word, Lower: string;
  LineStart, AfterObject, InValue: boolean;
  Start, Depth: integer;
begin
  Result := nil;
  CheckCategories;
  if Source = '' then
    Exit;
  FSource := Source;
  FTokens.Reset;
  FPos := 1;
  LineStart := True;      // only spaces so far on this line
  AfterObject := False;   // after object/inherited/inline: the name, then the class
  InValue := False;       // after the property's =
  Depth := 0;             // inside ( ), a list of values; < > holds items with properties
  while FPos <= Length(FSource) do
    case Ch of
      #10, #13:
      begin
        AddToken(TakeWhile([#10, #13]), shDefault);
        LineStart := True;
        AfterObject := False;
        if Depth = 0 then
          InValue := False;
      end;
      ' ', #9:
        AddToken(TakeWhile([' ', #9]), shDefault);
      '''':
      begin
        // 'it''s': a doubled quote stays inside
        Start := FPos;
        Inc(FPos);
        while FPos <= Length(FSource) do
        begin
          if FSource[FPos] in [#10, #13] then
            Break;
          if FSource[FPos] = '''' then
          begin
            if Ch(1) = '''' then
              Inc(FPos, 2)
            else
            begin
              Inc(FPos);
              Break;
            end;
          end
          else
            Inc(FPos);
        end;
        AddToken(Copy(FSource, Start, FPos - Start), shStrings);
        LineStart := False;
      end;
      '#':
      begin
        // #13 and #$0A: characters by their code, part of a string
        Start := FPos;
        Inc(FPos);
        if Ch = '$' then
        begin
          Inc(FPos);
          TakeWhile(['0'..'9', 'A'..'F', 'a'..'f']);
        end
        else
          TakeWhile(DIGITS);
        AddToken(Copy(FSource, Start, FPos - Start), shCharacters);
        LineStart := False;
      end;
      '{':
      begin
        // binary data, often many lines of hex
        Start := FPos;
        while (FPos <= Length(FSource)) and (FSource[FPos] <> '}') do
          Inc(FPos);
        if FPos <= Length(FSource) then
          Inc(FPos);
        AddToken(Copy(FSource, Start, FPos - Start), shComment);
        LineStart := False;
      end;
      '0'..'9', '$', '-', '+':
        if (Ch in ['-', '+']) and not (Ch(1) in DIGITS + ['.', '$']) then
        begin
          AddToken(Ch, shOperator);
          Inc(FPos);
          LineStart := False;
        end
        else
        begin
          Start := FPos;
          if Ch in ['-', '+'] then
            Inc(FPos);
          if Ch = '$' then
          begin
            Inc(FPos);
            TakeWhile(['0'..'9', 'A'..'F', 'a'..'f']);
          end
          else
          begin
            TakeWhile(DIGITS);
            if (Ch = '.') and (Ch(1) in DIGITS) then
            begin
              Inc(FPos);
              TakeWhile(DIGITS);
            end;
            if (Ch in ['e', 'E']) and (Ch(1) in DIGITS + ['-', '+']) then
            begin
              Inc(FPos, 2);
              TakeWhile(DIGITS);
            end;
          end;
          AddToken(Copy(FSource, Start, FPos - Start), shNumbers);
          LineStart := False;
        end;
      'A'..'Z', 'a'..'z', '_':
      begin
        word := TakeWhile(NAME_CHARS + ['.']);
        Lower := LowerCase(word);
        if LineStart and ((Lower = 'object') or (Lower = 'inherited') or (Lower = 'inline')) then
        begin
          AddToken(word, shKeyword);
          AfterObject := True;
        end
        else if LineStart and ((Lower = 'end') or (Lower = 'item')) then
          AddToken(word, shKeyword)
        else if AfterObject then
          // the component's name, then after the colon its class
          AddToken(word, shAttribute)
        else if LineStart and (Depth = 0) and not InValue then
          AddToken(word, shKey)
        else if (Lower = 'true') or (Lower = 'false') or (Lower = 'nil') then
          AddToken(word, shKeyword)
        else
          AddToken(word, shDefault);
        LineStart := False;
      end;
      '=':
      begin
        AddToken('=', shOperator);
        Inc(FPos);
        InValue := True;
        LineStart := False;
      end;
      '(', '<', '[':
      begin
        AddToken(Ch, shSymbol);
        if Ch = '(' then
          Inc(Depth);
        Inc(FPos);
        LineStart := False;
      end;
      ')', '>', ']':
      begin
        AddToken(Ch, shSymbol);
        if (Ch = ')') and (Depth > 0) then
          Dec(Depth);
        Inc(FPos);
        LineStart := False;
      end;
      else
      begin
        AddToken(Ch, shSymbol);
        Inc(FPos);
        LineStart := False;
      end;
    end;
  Result := FTokens.GetTokens;
end;

initialization
  TLfmSyntaxHighlighter.Register;
end.
