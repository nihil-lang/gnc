{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}

module Nihil.Syntax.Concrete.Parser.Expression.Atom
( pAtom, pAtomNoApp ) where

import Nihil.Syntax.Common (Parser)
import Nihil.Syntax.Concrete.Core
import Nihil.Syntax.Concrete.Parser
import Nihil.Syntax.Concrete.Parser.Expression.Operator
import Nihil.Syntax.Concrete.Parser.Identifier
import Nihil.Syntax.Concrete.Parser.Enclosed
import Nihil.Syntax.Concrete.Parser.Literal
import Nihil.Syntax.Concrete.Parser.Expression.Lambda
import Nihil.Syntax.Concrete.Parser.Expression.Let
import Nihil.Syntax.Concrete.Parser.Expression.Match
import Nihil.Syntax.Concrete.Parser.Expression.Tuple
import Nihil.Syntax.Concrete.Parser.Expression.TypeHole
import Nihil.Syntax.Concrete.Parser.Expression.Record
import {-# SOURCE #-} Nihil.Syntax.Concrete.Parser.Expression
import Nihil.Syntax.Concrete.Debug
import Nihil.Utils.Source
import Control.Applicative ((<|>))
import qualified Text.Megaparsec as MP

pAtom :: Parser () -> Parser AAtom
pAtom s = debug "p[Expression]Atom" $ MP.try pOperator <|> pAtom' s

pAtom' :: Parser () -> Parser AAtom
pAtom' s = MP.try (pApplication s) <|> pAtomNoApp s

pAtomNoApp :: Parser () -> Parser AAtom
pAtomNoApp s = do
    a <- withPosition do
        MP.choice atoms
    access <- MP.optional (MP.try s *> pSymbol' "." *> s *> pIdentifier)
    pure (maybe a ((`locate` location a) . ARecordAccess a) access)
  where atoms =
            [ pTypeHole MP.<?> "type hole"
            , pLambda s MP.<?> "lambda expression"
            , pMatch s MP.<?> "match expression"
            , MP.try (pTuple s) MP.<?> "tuple"
            , pLet s MP.<?> "let expression"
            , pRecord s MP.<?> "record"
            , AId . annotated      <$> MP.choice
                [ pIdentifier
                , pIdentifier'
                , MP.try (pParens pAnySymbolᵉ)
                ] MP.<?> "identifier"
            , ALiteral . annotated <$> MP.try pFloat MP.<?> "float literal"
            , ALiteral . annotated <$> pInteger MP.<?> "integer literal"
            , ALiteral . annotated <$> pCharacter MP.<?> "character literal"
            , ALiteral . annotated <$> pString MP.<?> "string literal"
            , AParens              <$> pParens (pExpression s) MP.<?> "parenthesized expression"
            ]

pApplication :: Parser () -> Parser AAtom
pApplication s = lexeme do
    withPosition (AApplication <$> exprs)
  where exprs = (:) <$> (pAtomNoApp s <* s) <*> (pAtomNoApp s `MP.sepBy1` MP.try s)
