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

{-# LANGUAGE LambdaCase, TupleSections, TypeApplications #-}

module Blob.Language.TypeChecking.Rules.Types.Infer where

import Blob.Language.TypeChecking.TypeChecker (TI, count, TIError, TypeState(..))
import Blob.Language.TypeChecking.Internal.Constraint (TypeConstraint(..))
import Blob.Language.TypeChecking.Internal.Type
import Blob.Language.Syntax.Internal.Parsing.Located
import Blob.Language.Syntax.Internal.Desugaring.CoreAST hiding (Type(..), Scheme(..), CustomType(..))
import qualified Blob.Language.Syntax.Internal.Desugaring.CoreAST as TP (Type(..), CustomType(..), Scheme(..))
import Blob.Language.TypeChecking.Internal.Environment
import Blob.Language.TypeChecking.Internal.Errors.BindLack
import Blob.Language.TypeChecking.Internal.Errors.UnboundVariable
import Blob.Language.TypeChecking.Internal.Substitution.Types
import Blob.Language.TypeChecking.Internal.Substitution
import Blob.Language.TypeChecking.Internal.Errors.MissingConstructorArguments
import qualified Data.Map as Map
import Data.These
import Control.Monad.Except (throwError, runExceptT)
import Control.Monad.Reader (local, ask)
import Control.Monad.RWS (evalRWST)
import Control.Monad.Identity (runIdentity)
import Control.Lens ((^.), (.~), views, (%~), use, (+=))
import Control.Monad (guard, forM)
import Control.Applicative ((<|>))
import Data.Function ((&))
import Data.Composition ((.:))
import Data.Bifunctor (first, second, bimap)
import Data.Align.Key (alignWithKey)
import Prelude hiding (lookup)

-- | Extends the type environment with a single entry.
inEnv :: (String, Scheme) -> TI a -> TI a
inEnv (x, sc) m =
    flip local m $ do
        env <- ask
        let ctx = env ^. defCtx
        pure $ env & defCtx .~ (remove ctx x `extend` (x, sc) `union` ctx)

-- | Extends the type environment with multiple entries.
inEnvMany :: [(String, Scheme)] -> TI a -> TI a
inEnvMany list m = do
    let env = TypeEnv $ Map.fromList list
    local (defCtx %~ (env `union`)) m

-- | Lookup into a 'TypeEnv'.
lookup :: String -> TypeEnv -> Maybe Scheme
lookup k t1 = Map.lookup k (t1 ^. _TypeEnv)

-- | Returns the type of a constant/function from the environment.
lookupEnv :: String -> TI Type
lookupEnv x = do
    env <- defCtx `views` lookup x
    env' <- ctorCtx `views` lookup x
    maybe (throwError $ makeUnboundVarError x) instantiate (env <|> env')

-- | Creates a new type variable with a given prefix.
fresh :: String -> TI Type
fresh v = do
    s <- use count
    count += 1

    env <- defCtx `views` \t -> concat (fst . (^. _Scheme) <$> Map.elems (t ^. _TypeEnv))
    let newTVar = TV (v <> show s)

    if newTVar `notElem` env
    then pure (TVar newTVar)
    else fresh (newTVar ^. _TV)

-- | Instantiate a 'Scheme' to produce a fresh 'Type'.
instantiate :: Scheme -> TI Type
instantiate (Scheme as t) = do
    as' <- mapM (const $ fresh "a") as
    let s = Subst . Map.fromList $ zip as as'
    pure $ apply s (relax t)

-- | Transforms all the rigid type variables into free type variables in a given 'Type'.
relax :: Type -> Type
relax (TRigid n  ) = TVar n
relax (TFun t1 t2) = TFun (first relax t1) (relax t2)
relax (TTuple ts ) = TTuple (map relax ts)
relax (TApp t1 t2) = TApp (relax t1) (relax t2)
relax t            = t

-- | Infers the 'Type' and 'TypeConstraint's for a given 'Expr'ession.
infer :: Located Expr -> TI (Type, [TypeConstraint])
infer (e :@ _) = case e of
    ELit (LInt _) -> pure (TInt, [])
    ELit (LDec _) -> pure (TFloat, [])
    ELit (LChr _) -> pure (TChar, [])
    EHole -> do
        tv <- fresh "_"
        tv' <- fresh "h"
        pure (tv, [tv :^~: tv'])
    EId x ->
        (, []) <$> lookupEnv x
    ELam x e' -> do
        (pat, cs, env) <- inferPattern x

        (t, c) <- inEnvMany (Map.toList env) (infer e')

        pure ((pat, 0) `TFun` t, cs <> c)
    EApp e1 e2 -> do
        (t1, c1) <- infer e1
        (t2, c2) <- infer e2
        tv <- fresh "a"
        pure (tv, c1 <> c2 <> [t1 :^~: TFun (t2, 1) tv])
    ETuple es -> do
        ts <- mapM infer es
        pure (TTuple $ map fst ts, foldMap snd ts)
    EAnn e t -> do
        (t', c) <- infer e
        pure (t', (t' :^~: tiType t) : c)
    ELet stts e -> do
        let inferStatement name = \case
                This def ->
                    do  var <- fresh "d"
                        (t, c) <- inEnv (name, Scheme [] var) $ infer def
                        pure (Scheme [] t, c <> [t :^~: var])
                That _ -> throwError $ makeBindLackError name
                These def decl ->
                    do  var <- fresh "d"
                        (t, c) <- inEnv (name, Scheme [] var) $ infer def
                        (s, cs) <- pure (Scheme [] t, c <> [t :^~: var])
                        pure (s, (t :^~: tiType decl) : cs)

            sepStatements' [] = ([], [])
            sepStatements' ((Definition name def :@ _):xs) = first ((name, def) :) $ sepStatements' xs
            sepStatements' ((Declaration name decl :@ _):xs) = second ((name, decl) :) $ sepStatements' xs
            sepStatements' (_:xs) = sepStatements' xs
        map' <- sequence $ uncurry (alignWithKey inferStatement)
                    (bimap Map.fromList Map.fromList $ sepStatements' stts)

        let env = Map.map fst map'
            cs = concat . Map.elems $ Map.map snd map'

        (t3, c3) <- inEnvMany (Map.toList env) (infer e)
        pure (t3, cs <> c3)
    EMatch e cases -> do
        (tExp, tCon) <- infer e

        res <- (unzip3 <$>) . forM cases $ \(pat, expr) -> do
            (patTy, patsCons, env) <- inferPattern pat

            (exprTy, exprCons) <- inEnvMany (Map.toList env) (infer expr)
            pure (exprTy, patTy, exprCons <> patsCons)

        let (ret:xs, patsTy, pCons) = res
            types = uncurry (:^~:) <$> zipFrom ret xs <> zipFrom tExp patsTy
            cons = mconcat pCons

        pure (ret, types <> cons <> tCon)
      where
        zipFrom :: a -> [b] -> [(a, b)]
        zipFrom = zip . repeat

-- | Infers the 'Type', the 'TypeConstraint's and a mapping for the types of each pattern variale from a 'Pattern'.
inferPattern :: Located Pattern -> TI (Type, [TypeConstraint], Map.Map String Scheme)
inferPattern (p :@ _) = case p of
    Wildcard -> do
        t <- fresh "p"
        pure (t, [], mempty)
    PInt _ -> pure (TInt, [], mempty)
    PDec _ -> pure (TFloat, [], mempty)
    PChr _ -> pure (TChar, [], mempty)
    PId id' -> do
        t <- fresh "p"
        pure (t, [], Map.singleton id' (Scheme [] t))
    PTuple exp -> do
        pats <- mapM inferPattern exp
        let (ts, cs, envs) = unzip3 pats
        pure (TTuple ts, mconcat cs, mconcat envs)
    PAnn p t -> do
        (t', cs, env) <- inferPattern p
        let t'' = tiType t
        pure (t'', (t'' :^~: t') : cs, env)
    PCtor id' args -> do
        ctor <- instantiate =<< lookupCtor id'
        let (ts, r) = unfoldParams ctor

        guard (length args == length ts)
            <|> throwError (makeMissingConstructorPatternArgumentError id' (length ts) (length args))

        (ts', cons, env) <- fmap mconcat <$> mapAndUnzip3M inferPattern args

        let cons' = uncurry (:^~:) <$> zip (fst <$> ts) ts'

        pure (r, cons' <> mconcat cons, env)
  where
    -- | Returns the 'Scheme' of a constructor.
    lookupCtor :: String -> TI Scheme
    lookupCtor id' = do
        env <- ctorCtx `views` (Map.lookup id' . (^. _TypeEnv))
        case env of
            Nothing -> throwError $ makeUnboundVarError id'
            Just x  -> pure x

    -- | mapAndUnzipM for triples
    mapAndUnzip3M :: Monad m => (a -> m (b, c, d)) -> [a] -> m ([b], [c], [d])
    mapAndUnzip3M _ []     = return ([],[],[])
    mapAndUnzip3M f (x:xs) = do
        (r1,  r2,  r3)  <- f x
        (rs1, rs2, rs3) <- mapAndUnzip3M f xs
        return (r1:rs1, r2:rs2, r3:rs3)

-- | Unfold the parameters and the return type from a type.
unfoldParams :: Type -> ([(Type, Integer)], Type)
unfoldParams (TFun a b) = first (a :) (unfoldParams b)
unfoldParams t          = ([], t)

-- | Transforms a 'TP.Type' into a 'Type', for data type compatibility.
tiType :: Located TP.Type -> Type
tiType (TP.TId id'    :@ _) = TId id'
tiType (TP.TFun t1 t2 :@ _) = TFun (first tiType t1) (tiType t2)
tiType (TP.TTuple ts  :@ _) = TTuple (map tiType ts)
tiType (TP.TApp t1 t2 :@ _) = TApp (tiType t1) (tiType t2)
tiType (TP.TVar id'   :@ _) = TVar (TV id')

-- | Transforms a 'TP.CustomType' into a 'CustomType', also for compatibility reasons.
tiCustomType :: Located TP.CustomType -> CustomType
tiCustomType (TP.TSum   cs :@ _) = TSum (fmap tiScheme cs)
tiCustomType (TP.TAlias t  :@ _) = TAlias (tiType t)

-- | Transforms a 'TP.Scheme' into a 'Scheme', also for compatibility reasons.
tiScheme :: TP.Scheme -> Scheme
tiScheme (TP.Scheme tvs t) = Scheme (map TV tvs) (tiType t)



instance Functor ((,,) a b) where
    fmap f (a, b, c) = (a, b, f c)

-- | Removes an entry from the 'TypeEnv' given.
remove :: TypeEnv -> String -> TypeEnv
remove = TypeEnv .: flip Map.delete . (^. _TypeEnv)

-- | Merges two 'TypeEnv's together.
union :: TypeEnv -> TypeEnv -> TypeEnv
union t1 t2 = TypeEnv ((t1 ^. _TypeEnv) `Map.union` (t2 ^. _TypeEnv))

-- | Extends a given 'TypeEnv' with a new function.
extend :: TypeEnv -> (String, Scheme) -> TypeEnv
extend = TypeEnv .: flip (uncurry Map.insert) . (^. _TypeEnv)




-- | Runs the inference monad given as argument.
runTI :: GlobalEnv -> TI (Type, [TypeConstraint]) -> Either TIError ((Type, [TypeConstraint]), [TypeConstraint])
runTI env m = runIdentity . runExceptT $ evalRWST m env initInfer
  where initInfer = TIState 0