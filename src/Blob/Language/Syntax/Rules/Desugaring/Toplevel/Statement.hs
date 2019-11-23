-- Blobc, a compiler for compiling Blob source code
-- Copyright (c) 2019 Mesabloo

-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.

-- You should have received a copy of the GNU General Public License
-- along with this program. If not, see <http://www.gnu.org/licenses/>.

{-# LANGUAGE LambdaCase #-}

module Blob.Language.Syntax.Rules.Desugaring.Toplevel.Statement where

import Blob.Language.Syntax.Internal.Parsing.Located
import qualified Blob.Language.Syntax.Internal.Parsing.AST as P
import qualified Blob.Language.Syntax.Internal.Desugaring.CoreAST as D
import Blob.Language.Syntax.Desugarer (Desugarer)
import Blob.Language.Syntax.Rules.Desugaring.Types.Type
import Blob.Language.Syntax.Rules.Desugaring.Expression
import Blob.Language.Syntax.Rules.Desugaring.Pattern
import Blob.Language.Syntax.Rules.Desugaring.Toplevel.CustomType
import Control.Monad (forM)

desugarStatement :: String -> Located P.Statement -> Desugarer (Maybe (Located D.Statement))
desugarStatement fileName (P.Declaration name pType :@ p) = do
    t <- desugarType fileName pType
    pure $ Just (D.Declaration name t :@ p)
desugarStatement fileName (P.Definition name args pExpr :@ p) = do
    e <- desugarExpression fileName pExpr
    a <- forM args $ desugarPattern fileName . (: [])
    let val = foldr (\a acc -> D.ELam a acc :@ Nothing) e a
    pure $ Just (D.Definition name val :@ p)
desugarStatement fileName (P.TypeDeclaration name tvs cType :@ p) = do
    ct <- desugarCustomType fileName (name, tvs, cType)
    pure $ Just (D.TypeDeclaration name tvs ct :@ p)
desugarStatement _ _ = pure Nothing