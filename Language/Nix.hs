{- |
   Module      :  Language.Nix
   Copyright   :  (c) 2013 Peter Simons
   License     :  BSD3
   Maintainer  :  simons@cryp.to
 -}

module Language.Nix
  ( -- * Running the Parser
    parseNixFile, parse, parse', ParseError,

    -- * Nix Language AST
    Expr(..), ScopedIdent(..), Attr(..), genIdentifier,

    -- * Nix Language Parsers
    expr, listExpr, term, operatorTable, listOperatorTable, identifier, literal,
    nixString, literalURI, attrSet, scopedIdentifier, attribute, list, letExpr,
    letAssignment, attrSetPattern,

    -- * Parsec Language Specification
    TokenParser, LanguageDef, NixParser, NixOperator, nixLanguage, nixLexer,
    symbol, reserved, reservedOp, lexeme, parens, braces, brackets, natural,
    assign, semi, dot, commaSep1, whitespace,
  )
  where

import Data.Functor.Identity
import Control.Applicative ( (<$>), (<*>), (<$), (<*), (*>) )
import Text.Parsec hiding ( parse )
import qualified Text.Parsec as Parsec
import qualified Text.Parsec.Language as Parsec
import qualified Text.Parsec.Token as Parsec
import Text.Parsec.Expr
import Text.PrettyPrint.Leijen ( Pretty(..) )
import qualified Text.PrettyPrint.Leijen as Pretty
import Test.QuickCheck

----- Nix Language Definition for Parsec --------------------------------------

type TokenParser = Parsec.GenTokenParser String () Identity
type LanguageDef = Parsec.GenLanguageDef String () Identity
type NixParser a = ParsecT String () Identity a
type NixOperator = Operator String () Identity Expr

nixLanguage :: LanguageDef
nixLanguage = Parsec.emptyDef
  { Parsec.commentStart    = "/*"
  , Parsec.commentEnd      = "*/"
  , Parsec.commentLine     = "#"
  , Parsec.nestedComments  = False
  , Parsec.identStart      = letter <|> oneOf "_"
  , Parsec.identLetter     = alphaNum <|> oneOf "-_"
  , Parsec.opStart         = Parsec.opLetter nixLanguage
  , Parsec.opLetter        = oneOf ".!{}[]+=?&|/:"
  , Parsec.reservedOpNames = [".","!","+","++","&&","||","?","=","//","==","!=",":"]
  , Parsec.reservedNames   = ["rec","let","in","import","with","inherit","assert","or","if","then","else"]
  , Parsec.caseSensitive   = True
  }

nixLexer :: TokenParser
nixLexer = Parsec.makeTokenParser nixLanguage

symbol :: String -> NixParser String
symbol = Parsec.symbol nixLexer

reserved :: String -> NixParser ()
reserved = Parsec.reserved nixLexer

reservedOp :: String -> NixParser ()
reservedOp = Parsec.reservedOp nixLexer

lexeme :: NixParser a -> NixParser a
lexeme = Parsec.lexeme nixLexer

parens :: NixParser a -> NixParser a
parens = Parsec.parens nixLexer

braces :: NixParser a -> NixParser a
braces = Parsec.braces nixLexer

brackets :: NixParser a -> NixParser a
brackets = Parsec.brackets nixLexer

natural :: NixParser String
natural = show <$> Parsec.natural nixLexer

assign :: NixParser String
assign = symbol "="

semi :: NixParser String
semi = Parsec.semi nixLexer

dot :: NixParser String
dot = Parsec.dot nixLexer

commaSep1 :: NixParser a -> NixParser [a]
commaSep1 = Parsec.commaSep1 nixLexer

whitespace :: NixParser ()
whitespace = Parsec.whiteSpace nixLexer

----- Nix Expressions ---------------------------------------------------------

newtype ScopedIdent = SIdent [String]
  deriving (Read, Show, Eq)

data Attr = Assign ScopedIdent Expr
          | Inherit ScopedIdent [String]
  deriving (Read, Show, Eq)

genIdentifier :: Gen String
genIdentifier = ((:) <$> elements firstChar <*> listOf (elements identChar)) `suchThat` (`notElem` Parsec.reservedNames nixLanguage)
  where firstChar = ['a'..'z'] ++ ['A'..'Z'] ++ "_"
        identChar = firstChar ++ ['0'..'9'] ++ "-"

instance Arbitrary ScopedIdent where
  arbitrary = SIdent <$> listOf1 genIdentifier

instance Pretty ScopedIdent where
  pretty (SIdent xs) = Pretty.hcat $ Pretty.punctuate Pretty.dot (map Pretty.text xs)

data Expr = Lit String
          | Ident String
          | AttrSet Bool [Attr]
          | AttrSetP (Maybe String) [(String, Maybe Expr)]
          | List [Expr]
          | Deref Expr Expr
          | HasAttr Expr Expr
          | DefAttr Expr Expr
          | Concat Expr Expr
          | Append Expr Expr
          | Not Expr
          | Union Expr Expr
          | Equal Expr Expr
          | Inequal Expr Expr
          | And Expr Expr
          | Or Expr Expr
          | Implies Expr Expr
          | Fun Expr Expr
          | Let [(String,Expr)] Expr
          | Apply Expr Expr
          | Import Expr
          | With Expr
          | Assert Expr
          | IfThenElse Expr Expr Expr
  deriving (Read, Show, Eq)

expr :: NixParser Expr
expr = whitespace >> buildExpressionParser operatorTable term

listExpr :: NixParser Expr
listExpr = buildExpressionParser listOperatorTable term

term :: NixParser Expr
term = choice [ parens expr
              , list
              , try attrSetPattern
              , attrSet
              , letExpr
              , reserved "import" >> Import <$> expr
              , reserved "with" >> With <$> expr <* semi
              , reserved "assert" >> Assert <$> expr <* semi
              , IfThenElse <$> (reserved "if" *> expr) <*> (reserved "then" *> expr) <*> (reserved "else" *> expr)
              , try literal
              , identifier
              ]

operatorTable :: [[NixOperator]]
operatorTable = x1 : x2 : x3 : [ Infix (Apply <$ whitespace) AssocRight ] : xs
  where (x1:x2:x3:xs) = listOperatorTable

listOperatorTable :: [[NixOperator]]
listOperatorTable = [ [ binary ":" Fun AssocRight ]
                    , [ binary "." Deref AssocLeft ]
                    , [ binary "or" DefAttr AssocNone ]
                {-  , [ Infix (Apply <$ whitespace) AssocRight ] -}
                    , [ binary "?" HasAttr AssocNone ]
                    , [ binary "++" Concat AssocRight ]
                    , [ binary "+" Append AssocLeft ]
                    , [ prefix "!" Not ]
                    , [ binary "//" Union AssocRight ]
                    , [ binary "==" Equal AssocNone ]
                    , [ binary "!=" Inequal AssocNone ]
                    , [ binary "&&" And AssocLeft ]
                    , [ binary "||" Or AssocLeft ]
                    , [ binary "->" Implies AssocNone ]
                    ]
  where
    binary :: String -> (Expr -> Expr -> Expr) -> Assoc -> NixOperator
    binary op fun = Infix (fun <$ reservedOp op)

    prefix :: String -> (Expr -> Expr) -> NixOperator
    prefix op fun = Prefix (fun <$ reservedOp op)

identifier :: NixParser Expr
identifier = Ident <$> Parsec.identifier nixLexer

literal :: NixParser Expr
literal = Lit <$> (Parsec.stringLiteral nixLexer <|> nixString <|> natural <|> literalURI)

nixString :: NixParser String
nixString = lexeme $ between (string "''") (string "''") (many (noneOf "'" <|> try (char '\'' <* notFollowedBy (char '\''))))

literalURI :: NixParser String
literalURI = lexeme $ try absoluteURI <|> relativeURI

absoluteURI :: NixParser String
absoluteURI = (++) <$> scheme <*> ((:) <$> char ':' <*> (hierPart <|> opaquePart))

relativeURI :: NixParser String
relativeURI = (++) <$> (absPath <|> relPath) <*> option "" (char '?' >> query)

absPath :: NixParser String
absPath = (:) <$> char '/' <*> pathSegments

authority :: NixParser String
authority = server <|> regName

domainlabel :: NixParser String
domainlabel = (:) <$> alphaNum <*> option "" ((++) <$> many (char '-') <*> domainlabel)

escapedChars :: NixParser Char
escapedChars = char '%' >> hexDigit >> hexDigit

hierPart :: NixParser String
hierPart = (++) <$> (try netPath <|> absPath) <*> option "" (char '?' >> query)

host :: NixParser String
host = hostname <|> ipv4address

hostname :: NixParser String
hostname = many (domainlabel >> char '.') >> toplabel >> option "" (string ".")

hostport :: NixParser String
hostport = (++) <$> host <*> option "" ((:) <$> char ':' <*> port)

ipv4address :: NixParser String
ipv4address = many1 digit >> char '.' >> many1 digit >> char '.' >> many1 digit >> char '.' >> many1 digit

markChars :: NixParser Char
markChars = oneOf "-_.!~*'" -- Note that "()" have been removed here!

netPath :: NixParser String
netPath = (++) <$> ((++) <$> string "//" <*> authority) <*> option "" absPath

opaquePart :: NixParser String
opaquePart = uricNoSlash >> many uric

pathSegments :: NixParser String
pathSegments = (++) <$> segment <*> (concat <$> many ((:) <$> char '/' <*> segment))

pchar :: NixParser Char
pchar = unreservedChars <|> escapedChars <|> oneOf ":@&=+$,"

port :: NixParser String
port = many1 digit

query :: NixParser String
query = many uric

regName :: NixParser String
regName = many1 (unreservedChars <|> escapedChars <|> oneOf "$,:@&=+") -- Note that ';' has been removed here!

relPath :: NixParser String
relPath = (++) <$> relSegment <*> absPath

relSegment :: NixParser String
relSegment = many1 (unreservedChars <|> escapedChars <|> oneOf "@&=+$,") -- Note that ';' has been removed here!

reservedChars :: NixParser Char
reservedChars = oneOf "/?:@&=+$," -- Note that ';' has been removed here!

scheme :: NixParser String
scheme = (:) <$> letter <*> many (alphaNum <|> oneOf "+-.")

segment :: NixParser String
segment = {- (++) <$> -} many pchar {- <*> (concat <$> many ((:) <$> char ';' <*> param)) -}

server :: NixParser String
server = option "" (option "" ((++) <$> userinfo <*> string "@") >> hostport)

toplabel :: NixParser Char
toplabel = letter <|> (letter >> many (alphaNum <|> char '-') >> alphaNum)

unreservedChars :: NixParser Char
unreservedChars = alphaNum <|> markChars

uric :: NixParser Char
uric = reservedChars <|> unreservedChars <|> escapedChars

uricNoSlash :: NixParser Char
uricNoSlash = unreservedChars <|> escapedChars <|> oneOf ";?:@&=+$,"

userinfo :: NixParser String
userinfo = many (unreservedChars <|> escapedChars <|> oneOf ";:&=+$,")

attrSet :: NixParser Expr
attrSet = AttrSet <$> option False (True <$ reserved "rec") <*> braces (attribute `endBy` semi)

scopedIdentifier :: NixParser ScopedIdent
scopedIdentifier = SIdent <$> sepBy1 (Parsec.identifier nixLexer) dot

attribute :: NixParser Attr
attribute =  (Assign <$> (SIdent . return <$> Parsec.stringLiteral nixLexer <|> scopedIdentifier) <* assign <*> expr)
         <|> (Inherit <$> (symbol "inherit" *> option (SIdent []) (parens scopedIdentifier)) <*> many1 (Parsec.identifier nixLexer))

list :: NixParser Expr
list = List <$> brackets (many listExpr)

attrSetPattern :: NixParser Expr
attrSetPattern = AttrSetP <$> optionMaybe atPattern <*> setPattern
  where
    atPattern  = Parsec.identifier nixLexer <* reserved "@"
    setPattern = braces $ commaSep1 $ (,) <$> Parsec.identifier nixLexer <*> optionMaybe (reservedOp "?" >> expr) <|> ellipsis
    ellipsis   = ("...",Nothing) <$ reserved "..."

letExpr :: NixParser Expr
letExpr = Let <$> (reserved "let" *> many1 letAssignment) <*> (reserved "in" *> expr)

letAssignment :: NixParser (String, Expr)
letAssignment = (,) <$> Parsec.identifier nixLexer <* assign <*> expr <* semi

parseNixFile :: FilePath -> IO (Either ParseError Expr)
parseNixFile path = Parsec.parse expr path <$> readFile path

parse' :: NixParser a -> SourceName -> String -> Either ParseError a
parse' = Parsec.parse

parse :: NixParser a -> String -> Either ParseError a
parse p input = parse' (p <* eof) (show input) input