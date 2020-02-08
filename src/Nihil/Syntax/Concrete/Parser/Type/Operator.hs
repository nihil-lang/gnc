module Nihil.Syntax.Concrete.Parser.Type.Operator where

import Nihil.Syntax.Common (Parser)
import Nihil.Syntax.Concrete.Core
import Nihil.Syntax.Concrete.Parser
import Nihil.Syntax.Concrete.Parser.Identifier
import Nihil.Syntax.Concrete.Debug
import Nihil.Utils.Source

pOperator :: Parser AType
pOperator = debug "p[Type]Operator" $ withPosition (TOperator . annotated <$> pAnySymbolᵗ)