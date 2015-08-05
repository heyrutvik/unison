{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}

module Unison.Type where

import Data.Aeson (ToJSON(..), FromJSON(..))
import Data.Aeson.TH
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Text (Text)
import GHC.Generics
import Prelude.Extras (Eq1(..),Show1(..))
import Unison.Doc (Doc)
import Unison.Note (Noted)
import Unison.Reference (Reference)
import Unison.Symbol (Symbol(..))
import Unison.Var (Var)
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Unison.ABT as ABT
import qualified Unison.Doc as D
import qualified Unison.JSON as J
import qualified Unison.Kind as K
import qualified Unison.Symbol as Symbol
import qualified Unison.Var as Var
import qualified Unison.View as View

-- | Type literals
data Literal
  = Number
  | Text
  | Vector
  | Distance
  | Ref Reference -- ^ A type literal uniquely defined by some nameless Hash
  deriving (Eq,Ord,Generic)

deriveJSON defaultOptions ''Literal

-- | Base functor for types in the Unison language
data F a
  = Lit Literal
  | Arrow a a
  | Ann a K.Kind
  | App a a
  | Constrain a () -- todo: constraint language
  | Forall a
  | Existential a
  | Universal a
  deriving (Eq,Foldable,Functor,Generic1,Traversable)

deriveJSON defaultOptions ''F
instance Eq1 F where (==#) = (==)
instance Show1 F where showsPrec1 = showsPrec

-- | Types are represented as ABTs over the base functor F, with variables in `v`
type Type v = AnnotatedType v ()

-- | Like `Type v`, but with an annotation of type `a` at every level in the tree
type AnnotatedType v a = ABT.Term F v a

-- An environment for looking up type references
type Env f v = Reference -> Noted f (Type v)

freeVars :: Type v -> Set v
freeVars = ABT.freeVars

data Monotype v = Monotype { getPolytype :: Type v } deriving (Eq)

instance Var v => Show (Monotype v) where
  show = show . getPolytype

-- Smart constructor which checks if a `Type` has no `Forall` quantifiers.
monotype :: Ord v => Type v -> Maybe (Monotype v)
monotype t = Monotype <$> ABT.visit isMono t where
  isMono (Forall' _ _) = Just Nothing
  isMono _ = Nothing

-- some smart patterns
pattern Lit' l <- ABT.Tm' (Lit l)
pattern Arrow' i o <- ABT.Tm' (Arrow i o)
pattern Arrows' spine <- (unArrows -> Just spine)
pattern ArrowsP' spine <- (unArrows' -> Just spine)
pattern Ann' t k <- ABT.Tm' (Ann t k)
pattern App' f x <- ABT.Tm' (App f x)
pattern Apps' f args <- (unApps -> Just (f, args))
pattern AppsP' f args <- (unApps' -> Just (f, args))
pattern Constrain' t u <- ABT.Tm' (Constrain t u)
pattern Forall' v body <- ABT.Tm' (Forall (ABT.Abs' v body))
pattern ForallsP' vs body <- (unForalls' -> Just (vs, body))
pattern Existential' v <- ABT.Tm' (Existential (ABT.Var' v))
pattern Universal' v <- ABT.Tm' (Universal (ABT.Var' v))

unArrows :: Type v -> Maybe [Type v]
unArrows t =
  case go t of [] -> Nothing; l -> Just l
  where
    go (Arrow' i o) = i : go o
    go _ = []

unArrows' :: Type v -> Maybe [(Type v,Path)]
unArrows' t = addPaths <$> unArrows t
  where addPaths ts = ts `zip` arrowPaths (length ts)

unForalls' :: Type v -> Maybe ([(v, Path)], (Type v, Path))
unForalls' (Forall' v body) = case unForalls' body of
  Nothing -> Just ([(v, [])], (body, [Body])) -- todo, need a path for forall vars
  Just (vs, (body,bodyp)) -> Just ((v, []) : vs, (body, Body:bodyp))
unForalls' _ = Nothing

unApps :: Type v -> Maybe (Type v, [Type v])
unApps t = case go t [] of [] -> Nothing; f:args -> Just (f,args)
  where
  go (App' i o) acc = go i (o:acc)
  go fn args = fn:args

unApps' :: Type v -> Maybe ((Type v,Path), [(Type v,Path)])
unApps' t = addPaths <$> unApps t
  where
  addPaths (f,args) = case appPaths (length args) of
    (fp,ap) -> ((f,fp), args `zip` ap)

appPaths :: Int -> (Path, [Path])
appPaths numArgs = (fnp, argsp)
  where
  fnp = replicate numArgs Fn
  argsp = take numArgs . drop 1 $ iterate (Fn:) [Arg]

arrowPaths :: Int -> [Path]
arrowPaths spineLength =
  (take (spineLength-1) $ iterate (Output:) [Input]) ++
  [replicate spineLength Output]

matchExistential :: Eq v => v -> Type v -> Bool
matchExistential v (Existential' x) = x == v
matchExistential _ _ = False

matchUniversal :: Eq v => v -> Type v -> Bool
matchUniversal v (Universal' x) = x == v
matchUniversal _ _ = False

-- some smart constructors

lit :: Ord v => Literal -> Type v
lit l = ABT.tm (Lit l)

ref :: Ord v => Reference -> Type v
ref = lit . Ref

app :: Ord v => Type v -> Type v -> Type v
app f arg = ABT.tm (App f arg)

arrow :: Ord v => Type v -> Type v -> Type v
arrow i o = ABT.tm (Arrow i o)

ann :: Ord v => Type v -> K.Kind -> Type v
ann e t = ABT.tm (Ann e t)

forall :: Ord v => v -> Type v -> Type v
forall v body = ABT.tm (Forall (ABT.abs v body))

existential :: Ord v => v -> Type v
existential v = ABT.tm (Existential (ABT.var v))

universal :: Ord v => v -> Type v
universal v = ABT.tm (Universal (ABT.var v))

v' :: Var v => Text -> Type v
v' s = universal (ABT.v' s)

forall' :: Var v => [Text] -> Type v -> Type v
forall' vs body = foldr forall body (map ABT.v' vs)

constrain :: Ord v => Type v -> () -> Type v
constrain t u = ABT.tm (Constrain t u)

-- | Bind all free variables with an outer `forall`.
generalize :: Ord v => Type v -> Type v
generalize t = foldr forall t $ Set.toList (ABT.freeVars t)

data PathElement
  = Fn -- ^ Points at type in a type application
  | Arg -- ^ Points at the argument in a type application
  | Input -- ^ Points at the left of an `Arrow`
  | Output -- ^ Points at the right of an `Arrow`
  | Body -- ^ Points at the body of a forall
  deriving (Eq,Ord)

type Path = [PathElement]

type ViewableType = Type (Symbol View.Rich)

view :: (Reference -> Symbol View.Rich) -> ViewableType -> Doc Text Path
view ref t = go no View.low t
  where
  no = const False
  (<>) = D.append
  paren b d =
    let r = D.root d
    in if b then D.embed' r "(" <> d <> D.embed' r ")" else d
  arr = D.breakable " " <> D.embed "→ "
  sp = D.breakable " "
  sym v = D.embed (Var.name v)
  op :: ViewableType -> Symbol View.Rich
  op t = case t of
    Lit' (Ref r) -> ref r
    Lit' l -> Symbol.annotate View.prefix . Symbol.prefix . Text.pack . show $ l
    Universal' v -> v
    Existential' v -> v
    _ -> Symbol.annotate View.prefix (Symbol.prefix "")
  go :: (ViewableType -> Bool) -> View.Precedence -> ViewableType -> Doc Text Path
  go inChain p t = case t of
    ArrowsP' spine ->
      paren (p > View.low) . D.group . D.delimit arr $
        [ D.sub' p (go no (View.increase View.low) s) | (s,p) <- spine ]
    AppsP' (fn,fnP) args ->
      let
        Symbol _ name view = op fn
        (taken, remaining) = splitAt (View.arity view) args
        fmt (child,path) = (\p -> D.sub' path (go (fn ==) p child), path)
        applied = fromMaybe unsaturated (View.instantiate view fnP name (map fmt taken))
        unsaturated = D.sub' fnP $ go no View.high fn
      in
        (if inChain fn then id else D.group) $ case remaining of
          [] -> applied
          args -> paren (p > View.high) . D.group . D.docs $
            [ applied, sp
            , D.nest "  " . D.group . D.delimit sp $
              [ D.sub' p (go no (View.increase View.high) s) | (s,p) <- args ] ]
    ForallsP' vs (body,bodyp) ->
      if p == View.low then D.sub' bodyp (go no p body)
      else paren True . D.group $
           D.embed "∀ " <>
           D.delimit (D.embed " ") (map (sym . fst) vs) <>
           D.docs [D.embed ".", sp, D.nest "  " $ D.sub' bodyp (go no View.low body)]
    Constrain' t _ -> go inChain p t
    Ann' t _ -> go inChain p t -- ignoring kind annotations for now
    Universal' v -> sym v
    Existential' v -> D.embed ("'" `mappend` Var.name v)
    Lit' _ -> D.embed (Var.name $ op t)
    _ -> error $ "layout match failure"

instance J.ToJSON1 F where
  toJSON1 f = toJSON f

instance J.FromJSON1 F where
  parseJSON1 j = parseJSON j

instance Show Literal where
  show Number = "Number"
  show Text = "Text"
  show Vector = "Vector"
  show Distance = "Distance"
  show (Ref r) = show r

instance Show a => Show (F a) where
  showsPrec p fa = go p fa where
    go _ (Lit l) = showsPrec 0 l
    go p (Arrow i o) =
      showParen (p > 0) $ showsPrec (p+1) i <> s" -> " <> showsPrec p o
    go p (Ann t k) =
      showParen (p > 1) $ showsPrec 0 t <> s":" <> showsPrec 0 k
    go p (App f x) =
      showParen (p > 9) $ showsPrec 9 f <> s" " <> showsPrec 10 x
    go p (Constrain t _) = showsPrec p t
    go _ (Universal v) = showsPrec 0 v
    go _ (Existential v) = s"'" <> showsPrec 0 v
    go p (Forall body) = case p of
      0 -> showsPrec p body
      _ -> showParen True $ s"∀ " <> showsPrec 0 body
    (<>) = (.)
    s = showString
