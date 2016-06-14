implementation module TypeUnify

import TypeDef, TypeUtil

//import StdDebug //FIXME
trace a b :== b

from StdFunc import o, flip
from StdMisc import abort
import StdBool
import StdList
import StdString
import StdTuple
import StdArray
from Data.Func import $
import Data.Functor
import Data.List
import Data.Maybe
import Control.Applicative
import Control.Monad

derive gEq ClassOrGeneric, Type

:: Equation :== (Type, Type)

// This is an example of why you should give your functions a meaningful name.
// This is an instance of 'Algorithm 1', described by Martelli, Montanari in
// An Efficient Unification Algorithm, 1982, section 2. This implementation
// selects the first from the list of equations, applies the appropriate step
// (a through d) or proceeds to the next equation.
// It has been modified a bit to be able to deal with constructor variables.
alg1 :: ![Equation] -> Maybe [TVAssignment]
alg1 [] = Just []
alg1 [eq=:(t1,t2):es]
	| t1 == t2 = alg1 es
alg1 [eq=:(Var v1,t2):es]
	| isMember v1 (allVars t2) = Nothing
	| isMember v1 (flatten $ map allVars $ types es)
		= eliminate eq es >>= \es` -> alg1 [eq:es`]
	= (\tvas -> [(v1,t2):tvas]) <$> alg1 es
alg1 [(t1,Var v2):es] = alg1 [(Var v2,t1):es]
alg1 [eq=:(Cons _ _,Cons _ _):es]
	= reduct eq >>= \es` -> alg1 $ es ++ es`
alg1 [(t1=:(Cons v1 ts1),t2):es]
	| not (isType t2) || arity t2 < arity t1 = Nothing
	| isMember v1 (allVars t2) = Nothing
	= alg1 $ es ++ makeConsReduction t1 t2
alg1 [(t1,t2=:(Cons _ _)):es] = alg1 [(t2,t1):es]
alg1 [eq:es]
	= reduct eq >>= \es` -> alg1 $ es ++ es`

makeConsReduction :: Type Type -> [Equation]
makeConsReduction (Cons cv ts1) (Type t ts2)
# (ass_vars, uni_vars) = splitAt (length ts2 - length ts1) ts2
= [(Var cv, Type t ass_vars) : [(t1,t2) \\ t1 <- ts1 & t2 <- uni_vars]]

types :: ([Equation] -> [Type])
types = foldr (\(t1,t2) ts -> [t1,t2:ts]) []

reduct :: !Equation -> Maybe [Equation]
reduct (Func [] r _, t) = reduct (r, t) //Can do this because we don't care about CC
reduct (t, Func [] r _) = reduct (t, r)
reduct (Type t1 tvs1, Type t2 tvs2)
	| t1 <> t2 = trace "unequal types\n" Nothing
	| length tvs1 <> length tvs2 = trace "unequal type arg lengths\n" Nothing
	= Just $ zip2 tvs1 tvs2
reduct (Func is1 r1 cc1, Func is2 r2 cc2)        //TODO class context
	| length is1 <> length is2 = trace "unequal func arg lengths\n" Nothing
	= Just $ zip2 [r1:is1] [r2:is2]
reduct (Cons v1 ts1, Cons v2 ts2)
	// In this case, we apply term reduction on variable root function
	// symbols. We need to check that these symbols don't occur elsewhere
	// with different arity (as Cons *or* Var); otherwise we're good.
	| badArity v1 ts1 || badArity v2 ts2 = trace "bad arity\n" Nothing
	#! (len1,len2) = (length ts1, length ts2)
	| len2 > len1 = reduct (Cons v2 ts2, Cons v1 ts1)
	| len1 > len2
		# (takeargs, dropargs) = splitAt (len1 - len2) ts1
		= Just $ zip2 [Cons v1 takeargs:dropargs] [Var v2:ts2]
	= Just $ zip2 [Var v1:ts1] [Var v2:ts2]
	where
		badArity v ts
		# subts = flatten $ map subtypes $ ts1 ++ ts2
		#! arities = map arity $ filter (\t -> isCons` v t || t == Var v) subts
		| isEmpty arities = False
		| length (removeDup arities) > 1 = True
		= hd arities <> length ts
reduct (Uniq t1, Uniq t2) = Just [(t1,t2)]
reduct (Var v1, Var v2) = abort "Cannot reduct variables\n"
reduct _ = trace "bad reduction\n" Nothing

eliminate :: !Equation ![Equation] -> Maybe [Equation]
eliminate _ [] = Just []
eliminate (Var v, t) [(lft,rgt):es]
	# (mbLft, mbRgt) = (assign (v,t) lft, assign (v,t) rgt)
	# mbEqs = eliminate (Var v, t) es
	| isNothing mbEqs || isNothing mbLft || isNothing mbRgt = Nothing
	= Just [(fromJust mbLft, fromJust mbRgt) : fromJust mbEqs]


prepare_unification :: !Bool !Type -> Type
prepare_unification isleft t
# t = propagate_uniqueness t
# t = reduceArities t
# t = appendToVars (if isleft "_l" "_r") t
= t
where
	appendToVars :: String Type -> Type
	appendToVars s t = fromJust $ assignAll (map rename $ allVars t) t
	where rename v = (v, Var (v+++s))

finish_unification :: ![TVAssignment] -> Unifier
finish_unification tvs
# (tvs1, tvs2) = (filter (endsWith "_l") tvs, filter (endsWith "_r") tvs)
# (tvs1, tvs2) = (map removeEnds tvs1, map removeEnds tvs2)
= (tvs1, tvs2)
where
	endsWith :: String TVAssignment -> Bool
	endsWith n (h,_) = h % (size h - size n, size h - 1) == n

	removeEnds :: TVAssignment -> TVAssignment
	removeEnds (v,t) = let rm s = s % (0, size s - 3) in (rm v, fromJust $
	                   assignAll (map (\v->(v,Var (rm v))) $ allVars t) t)

// This is basically a wrapper for alg1 above. However, here, type variables
// with the same name in the first and second type should not be considered
// equal (which is what happens in alg1). Therefore, we first rename all type
// (constructor) variables to *_1 and *_2, call alg1, and rename them back.
unify :: ![Instance] !Type !Type -> Maybe [TVAssignment]
unify is t1 t2 //TODO instances ignored; class context not considered
	= alg1 [(t1, t2)]

//-----------------------//
// Unification utilities //
//-----------------------//

// Apply a TVAssignment to a Type
assign :: !TVAssignment !Type -> Maybe Type
assign va (Type s ts) = Type s <$^> map (assign va) ts
assign va (Func ts r cc) = Func <$^> map (assign va) ts 
		>>= (\f->f <$> assign va r) >>= (\f->pure $ f cc)
assign (v,a) (Var v`) = pure $ if (v == v`) a (Var v`)
assign va=:(v,Type s ts) (Cons v` ts`)
	| v == v`   = Type s <$^> map (assign va) (ts ++ ts`)
	| otherwise = Cons v` <$^> map (assign va) ts`
assign va=:(v,Cons c ts) (Cons v` ts`)
	| v == v`   = Cons c <$^> map (assign va) (ts ++ ts`)
	| otherwise = Cons v` <$^> map (assign va) ts`
assign va=:(v,Var v`) (Cons v`` ts)
	| v == v``  = Cons v` <$^> map (assign va) ts
	| otherwise = Cons v`` <$^> map (assign va) ts
assign _ (Cons _ _) = empty
assign va (Uniq t) = Uniq <$> (assign va t)

(<$^>) infixl 4 //:: ([a] -> b) [Maybe a] -> Maybe b
(<$^>) f mbs :== ifM (all isJust mbs) $ f $ map fromJust mbs

//ifM :: Bool a -> m a | Alternative m
ifM b x :== if b (pure x) empty

// Apply a list of TVAssignments in the same manner as assign to a Type
//assignAll :: ([TVAssignment] Type -> Maybe Type)
assignAll :== flip $ foldM (flip assign)

// Make all functions arity 1 by transforming a b -> c to a -> b -> c
reduceArities :: !Type -> Type
reduceArities (Func ts r cc)
	| length ts > 1 = Func [hd ts] (reduceArities $ Func (tl ts) r cc) cc
	| otherwise = Func (map reduceArities ts) (reduceArities r) cc
reduceArities (Type s ts) = Type s $ map reduceArities ts
reduceArities (Cons v ts) = Cons v $ map reduceArities ts
reduceArities (Uniq t) = Uniq $ reduceArities t
reduceArities (Var v) = Var v
