{-# LANGUAGE LambdaCase, TupleSections #-}

module Blob.Language.Parsing.Parser where

import Blob.Language.Lexing.Types hiding (Parser)
import Blob.Language.Parsing.Types
import Blob.Language.Parsing.Annotation
import Text.PrettyPrint.Leijen (Doc, text, linebreak)
import qualified Data.Map as Map
import Control.Monad
import Data.Functor
import Control.Monad.Except
import Data.Maybe
import Control.Monad.State
import qualified Data.Text as Text
import qualified Data.Char as Ch
import Text.Megaparsec hiding (Token, match)
import Control.Applicative (empty, liftA2)
import Data.Void
import Debug.Trace

program :: Parser Program
program = "statements" <??> many statement <* (eof <?> "EOF")

statement :: Parser (Annotated Statement)
statement = nonIndented (choice [ customOp <?> "custom operator definition"
                                , customDataType <?> "custom data type declaration"
                                , typeAlias <?> "type alias declaration"
                                , try declaration <?> "function declaration"
                                , definition <?> "function definition" ]) <* many (symbol ";")

customOp :: Parser (Annotated Statement)
customOp = do
    (pInit, pEnd, op) <- getPositionInSource $ do
        iPos <- getPositionAndIndent
        f <- fixity
        prec <- sameLineOrIndented iPos integer <?> "operator precedence"
        guard (prec <= 9) <|> fail "Operator precedence should be < 10 and > 0"
        op <- sameLineOrIndented iPos (opSymbol <|> parens opSymbol) <?> "operator"

        pure $ OpFixity op (f prec op :- Nothing)

    pure (op :- Just (SourceSpan pInit pEnd))
  where
    fixity = Infix <$> choice [ keyword "infix"  $> N
                              , keyword "infixl" $> L
                              , keyword "infixr" $> R ]

customDataType :: Parser (Annotated Statement)
customDataType = do
    (pInit, pEnd, dataType) <- getPositionInSource $ do
        keyword "data"
        iPos <- getPositionAndIndent
        name <- sameLineOrIndented iPos typeIdentifier
        tvs <- many $ sameLineOrIndented iPos identifier

        TypeDeclaration name tvs <$> choice [ sameLineOrIndented iPos (symbol "=") *> adtDeclaration iPos
                                            , sameLineOrIndented iPos (keyword "where") *> gadtDeclaration iPos ]

    pure (dataType :- Just (SourceSpan pInit pEnd))
  where
    adtDeclaration iPos = do
        (pInit, pEnd, cType) <- getPositionInSource $ do
            let ctor = (,) <$> typeIdentifier <*> many (sameLineOrIndented iPos atype)
            ctor1 <- sameLineOrIndented iPos ctor
            ctors <- many (sameLineOrIndented iPos (symbol "|") *> sameLineOrIndented iPos ctor)
            pure (TSum $ Map.fromList (ctor1:ctors))
        pure (cType :- Just (SourceSpan pInit pEnd))

    gadtDeclaration iPos = do
        (pInit, pEnd, cType) <- getPositionInSource $ do
            let ctor =
                    (,) <$> typeIdentifier
                        <*> (sameLineOrIndented iPos (symbol "::" <|> symbol "∷") *> sameLineOrIndented iPos type')
            ctor1 <- sameLineOrIndented iPos ctor
            ctors <- many (sameLineOrIndented iPos (symbol "|") *> sameLineOrIndented iPos ctor)
            pure (TGADT $ Map.fromList (ctor1:ctors))
        pure (cType :- Just (SourceSpan pInit pEnd))

typeAlias :: Parser (Annotated Statement)
typeAlias = do
    (pInit, pEnd, alias) <- getPositionInSource $ do
        iPos <- getPositionAndIndent
        keyword "type"
        name <- sameLineOrIndented iPos typeIdentifier
        tvs <- many $ sameLineOrIndented iPos identifier
        sameLineOrIndented iPos (symbol "=")
        (pInit, pEnd, alias) <- getPositionInSource $ sameLineOrIndented iPos type'

        pure (TypeDeclaration name tvs (TAlias alias :- Just (SourceSpan pInit pEnd)))
    
    pure (alias :- Just (SourceSpan pInit pEnd))

declaration :: Parser (Annotated Statement)
declaration = do
    (pInit, pEnd, decl) <- getPositionInSource $ do
        iPos <- getPositionAndIndent
        name <- identifier <|> parens opSymbol
        sameLineOrIndented iPos (symbol "::" <|> symbol "∷")
        t <- sameLineOrIndented iPos type'

        pure (Declaration name t)
    pure (decl :- Just (SourceSpan pInit pEnd))

definition :: Parser (Annotated Statement)
definition = do
    (pInit, pEnd, def) <- getPositionInSource $ do
        iPos <- getPositionAndIndent
        name <- identifier <|> parens opSymbol
        args <- many $ sameLineOrIndented iPos identifier
        sameLineOrIndented iPos (symbol "=")
        v <- sameLineOrIndented iPos expression

        pure (Definition name args v)
    pure (def :- Just (SourceSpan pInit pEnd))

------------------------------------------------------------------------------------------

getPositionInSource :: Parser a -> Parser (SourcePos, SourcePos, a)
getPositionInSource p = do
    (_, SourceSpan pInit _) <- getPositionAndIndent
    stream <- stateInput <$> getParserState
    res <- p
    let f (i, pos, _) = (i, pos)
    (_, SourceSpan _ pEnd) <- (eof $> f (last stream)) <|> getPositionAndIndent

    pure (pInit, pEnd, res)

sameLineOrIndented :: (Int, SourceSpan) -> Parser a -> Parser a
sameLineOrIndented (indent, SourceSpan beg end) p = do
    (i, SourceSpan b _) <- try getPositionAndIndent
    if sourceLine beg == sourceLine b
    then p
    else do
        guard (i > indent)
            <|> fail ("Possible incorrect indentation (should be greater than " <> show indent <> ")")
        p

sameIndented :: (Int, SourceSpan) -> Parser a -> Parser a
sameIndented (indent, _) p = do
    (i, _) <- try getPositionAndIndent
    guard (i > indent)
        <|> fail ("Possible incorrect indentation (should equal " <> show indent <> ")")
    p

nonIndented :: Parser a -> Parser a
nonIndented p = do
    (i, _) <- try getPositionAndIndent
    guard (i == 0)
        <|> fail "Possible incorrect indentation (should equal 0)"
    p

getPositionAndIndent :: Parser (Int, SourceSpan)
getPositionAndIndent =
    "any token" <??> try (lookAhead anySingle)
        >>= \(i, p, t) -> pure (i, p)

keyword :: String -> Parser TokenL
keyword s = ("keyword \"" <> s <> "\"") <??> satisfy (\(_, _, t) -> case t of
    LKeyword kw | s == Text.unpack kw -> True
    _ -> False)

symbol :: String -> Parser TokenL
symbol s = ("symbol \"" <> s <> "\"") <??> satisfy (\(_, _, t) -> case t of
    LSymbol sb | s == Text.unpack sb -> True
    _ -> False)

identifier :: Parser String
identifier = "identifier" <??> sat >>= \(_, _, LLowIdentifier i) -> pure (Text.unpack i)
  where sat = satisfy $ \(_, _, t) -> case t of
            LLowIdentifier i -> True 
            _ -> False

typeIdentifier :: Parser String
typeIdentifier = "type identifier" <??> sat >>= \(_, _, LUpIdentifier i) -> pure (Text.unpack i)
  where sat = satisfy $ \(_, _, t) -> case t of
            LUpIdentifier i -> True
            _ -> False

opSymbol :: Parser String
opSymbol = "operator" <??> sat >>= \(_, _, LSymbol s) -> pure (Text.unpack s) >>= check
  where sat = satisfy $ \(_, _, t) -> case t of
            LSymbol s | isOperator s -> True
            _ -> False
  
        isOperator :: Text.Text -> Bool
        isOperator = Text.all (liftA2 (||) Ch.isSymbol (`elem` "!#$%&.<=>?^~|@*/-:"))

        check :: String -> Parser String
        check x | x `elem` rOps = fail ("Reserved operator \"" <> x <> "\"")
                | otherwise = pure x

parens :: Parser a -> Parser a
parens p = symbol "(" *> p <* symbol ")"

brackets :: Parser a -> Parser a
brackets p = symbol "[" *> p <* symbol "]"

integer :: Parser Integer
integer = "integer" <??> sat >>= \(_, _, LInteger i) -> pure i
  where sat = satisfy $ \(_, _, t) -> case t of
            LInteger lit -> True
            _ -> False

float :: Parser Double
float = "floaing point number" <??> sat >>= \(_, _, LFloat f) -> pure f
  where sat = satisfy $ \(_, _, t) -> case t of
            LFloat lit -> True
            _ -> False

char :: Parser Char
char = "character" <??> sat >>= \(_, _, LChar c) -> pure c
  where sat = satisfy $ \(_, _, t) -> case t of
            LChar lit -> True
            _ -> False

string :: Parser String
string = "string" <??> sat >>= \(_, _, LString s) -> pure (Text.unpack s)
  where sat = satisfy $ \(_, _, t) -> case t of
            LString lit -> True
            _ -> False

------------------------------------------------------------------------------------------

nothing :: Parser ()
nothing = pure ()

(<??>) :: String -> Parser a -> Parser a
(<??>) = flip (<?>)
infix 0 <??>

-------------------------------------------------------------------------------------------

type' :: Parser (Annotated Type)
type' = do
    iPos <- getPositionAndIndent
    (pInit, pEnd, (ty, optTy)) <- getPositionInSource $ do
        ft <- btype
        ot <- optional $ do
            usage <- sameLineOrIndented iPos $
                choice [ Just ([ALit (LInt 1) :- Nothing] :- Nothing) <$ (symbol "-o" <|> symbol "⊸")
                       , Nothing <$ (symbol "->" <|> symbol "→") ]
            (usage,) <$> sameLineOrIndented iPos type'
        pure (ft, ot)

    case optTy of
        Nothing -> pure ty
        Just (Nothing, ty') -> pure (TFun ty ty' :- Just (SourceSpan pInit pEnd))
        Just (Just count, ty') -> pure (TArrow count ty ty' :- Just (SourceSpan pInit pEnd))

btype :: Parser (Annotated Type)
btype = do
    iPos <- getPositionAndIndent
    (pInit, pEnd, ts) <- getPositionInSource $ 
        some (sameLineOrIndented iPos atype)
    pure (TApp ts :- Just (SourceSpan pInit pEnd))

atype :: Parser (Annotated Type)
atype = do
    (pInit, pEnd, at) <- getPositionInSource $
        choice [ gtycon, try tTuple, tList, TVar <$> identifier, getAnnotated <$> parens type' ]
    pure (at :- Just (SourceSpan pInit pEnd))
  where
    tTuple = do
        iPos <- getPositionAndIndent
        parens $ do
            t1 <- sameLineOrIndented iPos type'
            ts <- some $ sameLineOrIndented iPos (symbol ",") *> sameLineOrIndented iPos type'
            pure $ TTuple (t1:ts)

    tList = do
        iPos <- getPositionAndIndent
        brackets $ choice [ do { e1 <- sameLineOrIndented iPos type'
                               ; es <- many $ sameLineOrIndented iPos (symbol ",") *> sameLineOrIndented iPos type'
                               ; pure $ TList (e1:es) }
                          , nothing $> TList [] ]

gtycon :: Parser Type
gtycon = choice [ conid
                , try (parens nothing) $> TTuple [] ]

conid :: Parser Type
conid = TId <$> typeIdentifier

-------------------------------------------------------------------------------------------

expression :: Parser (Annotated Expr)
expression = do
    iPos <- getPositionAndIndent
    (pInit, pEnd, (a, ty)) <- getPositionInSource $ do
        as <- some (sameLineOrIndented iPos atom)
        optional (sameLineOrIndented iPos (symbol "::" <|> symbol "∷") *> sameLineOrIndented iPos type') <&> (as,)

    case ty of
        Nothing -> pure (a :- Just (SourceSpan pInit pEnd))
        Just t  -> pure $ [AAnn (a :- Just (SourceSpan pInit pEnd)) t :- Just (SourceSpan pInit pEnd)] :- Just (SourceSpan pInit pEnd)

atom :: Parser (Annotated Atom)
atom = try operator <|> expr
  where expr = try app <|> exprNoApp

exprNoApp :: Parser (Annotated Atom)
exprNoApp = do
    (pInit, pEnd, a) <- getPositionInSource $
        choice [ hole <?> "type hole", lambda <?> "lambda", match <?> "match", try tuple <?> "tuple", list <?> "list"
               , AId <$> choice [ identifier, try (parens opSymbol), try (parens nothing) $> "()", typeIdentifier ] <?> "identifier"
               , ALit . LDec <$> try float <?> "floating point number"
               , ALit . LInt <$> integer <?> "integer"
               , ALit . LChr <$> char <?> "character"
               , ALit . LStr <$> string <?> "string"
               , AParens <$> parens expression <?> "parenthesized expression" ]
    pure (a :- Just (SourceSpan pInit pEnd))

app :: Parser (Annotated Atom)
app = do
    (_, _, a) <- getPositionInSource $ do
        iPos <- getPositionAndIndent
        (:) <$> exprNoApp <*> some (sameLineOrIndented iPos exprNoApp)
    pure $ foldl1 f a
  where
    f a1 a2 = let begin' = begin <$> getSpan a1
                  end'   = end <$> getSpan a2
              in if isNothing begin' || isNothing end'
                 then AApp a1 a2 :- Nothing
                 else AApp a1 a2 :- Just (SourceSpan (fromJust begin') (fromJust end'))

operator :: Parser (Annotated Atom)
operator = do
    (pInit, pEnd, op) <- getPositionInSource
        opSymbol
    pure (AOperator op :- Just (SourceSpan pInit pEnd))

hole :: Parser Atom
hole = AHole <$ satisfy (\(_, _, l) -> l == LWildcard)

lambda :: Parser Atom
lambda = do
    iPos <- getPositionAndIndent
    symbol "\\" <|> symbol "λ"
    params <- some (sameLineOrIndented iPos identifier)
    sameLineOrIndented iPos (symbol "->" <|> symbol "→")
    ALambda params <$> sameLineOrIndented iPos expression

tuple :: Parser Atom
tuple = do
    iPos <- getPositionAndIndent
    parens $ do
        e1 <- sameLineOrIndented iPos expression
        es <- some (sameLineOrIndented iPos (symbol ",") *> sameLineOrIndented iPos expression)
        pure $ ATuple (e1:es)
    
list :: Parser Atom
list = do
    iPos <- getPositionAndIndent
    brackets $ choice [ do { e1 <- sameLineOrIndented iPos expression
                           ; es <- many (sameLineOrIndented iPos (symbol ",") *> sameLineOrIndented iPos expression)
                           ; pure (AList (e1:es)) }
                      , nothing $> AList [] ]

match :: Parser Atom
match = do
    iPos <- getPositionAndIndent
    keyword "match"
    expr <- sameLineOrIndented iPos expression
    sameLineOrIndented iPos (keyword "with")
    pats <- parseCases iPos

    pure (AMatch expr pats)
  where
    parseCases iPos = some $ sameLineOrIndented iPos parseCase <* many (symbol ";")
    parseCase = do
        iPos <- getPositionAndIndent
        p <- pattern'
        sameLineOrIndented iPos (symbol "->" <|> symbol "→")
        (p,) <$> sameLineOrIndented iPos expression

pattern' :: Parser [Annotated Pattern]
pattern' = some (try patOperator <|> patTerm)
    
patOperator :: Parser (Annotated Pattern)
patOperator = do
    (pInit, pEnd, op) <- getPositionInSource $
        POperator <$> opSymbol
    pure (op :- Just (SourceSpan pInit pEnd))

patTerm :: Parser (Annotated Pattern)
patTerm = do
    iPos <- getPositionAndIndent
    (pInit, pEnd, (term, ty)) <- getPositionInSource $ do
        p <- choice [ PHole       <$ hole
                    , PLit . LDec <$> try float
                    , PLit . LInt <$> integer
                    , PLit . LChr <$> char
                    , PId         <$> identifier
                    , PCtor       <$> typeIdentifier <*> (fmap (: []) <$> many (sameLineOrIndented iPos patTerm))
                    ,                 try patTuple
                    ,                 patList
                    , PLit . LStr <$> string
                    , PParens     <$> parens pattern' ]
        optional (sameLineOrIndented iPos (symbol "::" <|> symbol "∷") *> sameLineOrIndented iPos type') <&> (p,)

    case ty of
        Nothing -> pure (term :- Just (SourceSpan pInit pEnd))
        Just t  -> pure (PAnn [term :- Just (SourceSpan pInit pEnd)] t :- Just (SourceSpan pInit pEnd))
  where
    patList :: Parser Pattern
    patList = 
        getPositionAndIndent
        >>= \iPos -> brackets $ choice [ do { e1 <- sameLineOrIndented iPos pattern'
                                            ; es <- many (sameLineOrIndented iPos (symbol ",") *> sameLineOrIndented iPos pattern')
                                            ; pure $ PList (e1:es) }
                                       , nothing $> PList [] ]

    patTuple :: Parser Pattern
    patTuple =
        getPositionAndIndent
        >>= \iPos -> parens $ do
            e1 <- sameLineOrIndented iPos pattern'
            es <- some (sameLineOrIndented iPos (symbol ",") *> sameLineOrIndented iPos pattern')
            pure $ PTuple (e1:es)

--------------------------------------------------------------------------------------------------------------

runParser :: [Token] -> String -> Either (ParseErrorBundle [TokenL] Void) Program
runParser tks fileName = Text.Megaparsec.runParser program fileName (mapMaybe f tks)
  where f (_, _, Nothing) = Nothing
        f (indent, spos, Just x) = Just (indent, spos, x)

runParser' :: Parser a -> [Token] -> String -> Either (ParseErrorBundle [TokenL] Void) a
runParser' p tks fileName = Text.Megaparsec.runParser p fileName (mapMaybe f tks)
  where f (_, _, Nothing) = Nothing
        f (indent, spos, Just x) = Just (indent, spos, x)

-------------------------------------------------------------------------------------------------------------

rOps :: [String]
rOps = [ "=", "::", "\\", "->", "-o", "=>", ",", "∷", "→", "⊸", "⇒" ]