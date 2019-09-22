{-# LANGUAGE LambdaCase #-}

module Blob.Interpreter.Eval where

import Blob.Language.Desugaring.Types (Expr(..), Literal(..), Pattern(..))
import qualified Data.Map as Map
import Blob.Interpreter.Types
import Control.Monad.Reader
import Control.Monad.Except
import Control.Applicative
import Text.PrettyPrint.Leijen hiding ((<$>), empty)
import Data.Maybe
import Data.List.Extra (snoc)
import Blob.Language.Parsing.Annotation

evaluate :: Annotated Expr -> EvalEnv Value
evaluate (ELit (LInt v) :- _)    = pure $ VInt v
evaluate (ELit (LDec v) :- _)    = pure $ VDec v
evaluate (ELit (LChr v) :- _)    = pure $ VChr v
evaluate (EId id' :- _)          = do
                                    isNotCtor <- isJust . Map.lookup id' <$> asks vals

                                    if isNotCtor
                                    then fromJust . Map.lookup id' <$> asks vals
                                    else pure $ VCon id' []
evaluate (ETuple es :- _)        = VTuple <$> mapM evaluate es
evaluate (ELam x e :- _)         = VLam x e <$> asks vals
evaluate (EApp f x :- _)         = do
    x' <- evaluate x
    f' <- evaluate f
    case f' of
        VLam x e c -> foldr ((<|>) . uncurry (evalBranch x')) makeMatchError [(x, e)]
        HLam f''   -> f'' x'
        VCon id' e -> pure $ VCon id' (snoc e x')
        v          -> throwError . text $ "Developer error: type checking failed ; expecting `VLam`, `HLam` or `VCon` ; got `" <> show v <> "`.\nPlease report the issue."
-- evaluate (EList es)         = VList <$> mapM evaluate es
evaluate (EMatch expr pats :- _) = evaluate expr >>= \e -> foldr ((<|>) . uncurry (evalBranch e)) makeMatchError pats
evaluate (EHole :- _) = throwError . text $ "Developer error: type checking failed ; unexpected type hole while executing.\nPlease report the issue."
evaluate (EAnn e _ :- _) = evaluate e

evalBranch :: Value -> Annotated Pattern -> Annotated Expr -> EvalEnv Value
evalBranch e pat branch = do
    s <- unpackPattern e pat
    local (\env -> env { vals = s <> vals env }) (evaluate branch)

unpackPattern :: Value -> Annotated Pattern -> EvalEnv (Scope Value)
unpackPattern = curry $ \case
    (_, Wildcard :- _)               -> pure mempty
    (VInt n, PInt n' :- _) | n == n' -> pure mempty
    (VDec d, PDec d' :- _) | d == d' -> pure mempty
    (v, PId id' :- _)                -> pure $ Map.singleton id' v
    (VCon id' v, PCtor id'' v' :- _)
        | id' == id''                -> mconcat <$> zipWithM unpackPattern v v'
    (val, PAnn p _ :- _)             -> unpackPattern val p
    _                                -> empty

makeMatchError :: EvalEnv Value
makeMatchError = throwError $ text "Non-exhaustive patterns in pattern matching" <> dot