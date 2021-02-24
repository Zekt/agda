{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE ViewPatterns               #-}
{-# LANGUAGE TypeOperators              #-}

module Agda.TypeChecking.Monad.Base
  ( module Agda.TypeChecking.Monad.Base
  , HasOptions (..)
  ) where

import Prelude hiding (null)

import Control.Applicative hiding (empty)
import qualified Control.Concurrent as C
import qualified Control.Exception as E

import qualified Control.Monad.Fail as Fail

import Control.Monad.Except
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Writer hiding ((<>))
import Control.Monad.Trans          ( MonadTrans(..), lift )
import Control.Monad.Trans.Control  ( MonadTransControl(..), liftThrough )
import Control.Monad.Trans.Identity
import Control.Monad.Trans.Maybe

import Data.Array (Ix)
import Data.Bifunctor
import Data.Bifoldable
import Data.Coerce (coerce)
import Data.Function
import Data.Foldable (toList)
import Data.Int
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import qualified Data.List as List
import qualified Data.Kind
import Data.Maybe
import Data.Map (Map)
import qualified Data.Map as Map -- hiding (singleton, null, empty)
import Data.Sequence (Seq)
import Data.Set (Set)
import qualified Data.Set as Set -- hiding (singleton, null, empty)
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HMap
import Data.Semigroup ( Semigroup, (<>)) --, Any(..) )
import qualified Data.Sequence as S
import Data.Data (Data, Typeable)
import Data.String
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL

import Data.IORef

import Agda.Benchmarking (Benchmark, Phase)

import Agda.Syntax.Concrete (TopLevelModuleName)
import Agda.Syntax.Common
import qualified Agda.Syntax.Concrete as C
import Agda.Syntax.Concrete.Definitions
  (NiceDeclaration, DeclarationWarning, dwWarning, declarationWarningName)
import qualified Agda.Syntax.Abstract as A
import Agda.Syntax.Internal as I
import Agda.Syntax.Internal.MetaVars
import Agda.Syntax.Internal.Generic (TermLike(..))
import Agda.Syntax.Parser (ParseWarning)
import Agda.Syntax.Parser.Monad (parseWarningName)
import Agda.Syntax.Treeless (Compiled)
import Agda.Syntax.Notation
import Agda.Syntax.Position
import Agda.Syntax.Scope.Base
import qualified Agda.Syntax.Info as Info

import {-# SOURCE #-} Agda.TypeChecking.Monad.Context (MonadAddContext(..), unsafeModifyContext)
import Agda.TypeChecking.CompiledClause
import Agda.TypeChecking.Coverage.SplitTree
import Agda.TypeChecking.Positivity.Occurrence
import Agda.TypeChecking.Free.Lazy (Free(freeVars'), underBinder', underBinder)
import Agda.TypeChecking.Substitute.Class (Apply(..))

-- Args, defined in Agda.Syntax.Treeless and exported from Agda.Compiler.Backend
-- conflicts with Args, defined in Agda.Syntax.Internal and also imported here.
-- This only matters when interpreted in ghci, which sees all of the module's
-- exported symbols, not just the ones defined in the `.hs-boot`. See the
-- comment in ../../Compiler/Backend.hs-boot
import {-# SOURCE #-} Agda.Compiler.Backend hiding (Args)

import Agda.Interaction.Options
import Agda.Interaction.Options.Warnings
import {-# SOURCE #-} Agda.Interaction.Response
  (InteractionOutputCallback, defaultInteractionOutputCallback)
import Agda.Interaction.Highlighting.Precise
  (CompressedFile, HighlightingInfo, NameKind)
import Agda.Interaction.Library

import Agda.Utils.Benchmark (MonadBench(..))
import Agda.Utils.Dependent
import Agda.Utils.CallStack ( CallStack, HasCallStack, withCallerCallStack )
import Agda.Utils.FileName
import Agda.Utils.Functor
import Agda.Utils.Hash
import Agda.Utils.IntSet.Typed (ISet)
import qualified Agda.Utils.IntSet.Typed as ISet
import Agda.Utils.Lens
import Agda.Utils.List
import Agda.Utils.ListT
import Agda.Utils.List1 (List1, pattern (:|))
import Agda.Utils.List2 (List2, pattern List2)
import qualified Agda.Utils.List1 as List1
import qualified Agda.Utils.Maybe.Strict as Strict
import Agda.Utils.Monad
import Agda.Utils.Null
import Agda.Utils.Permutation
import Agda.Utils.Pretty
import Agda.Utils.Singleton
import Agda.Utils.Size
import Agda.Utils.SmallSet (SmallSet)
import qualified Agda.Utils.SmallSet as SmallSet
import Agda.Utils.Update
import Agda.Utils.WithDefault ( collapseDefault )

import Agda.Utils.Impossible

---------------------------------------------------------------------------
-- * Type checking state
---------------------------------------------------------------------------

data TCState = TCSt
  { stPreScopeState   :: !PreScopeState
    -- ^ The state which is frozen after scope checking.
  , stPostScopeState  :: !PostScopeState
    -- ^ The state which is modified after scope checking.
  , stPersistentState :: !PersistentTCState
    -- ^ State which is forever, like a diamond.
  }

class Monad m => ReadTCState m where
  getTCState :: m TCState
  locallyTCState :: Lens' a TCState -> (a -> a) -> m b -> m b

  withTCState :: (TCState -> TCState) -> m a -> m a
  withTCState = locallyTCState id

  default getTCState :: (MonadTrans t, ReadTCState n, t n ~ m) => m TCState
  getTCState = lift getTCState

  default locallyTCState
    :: (MonadTransControl t, ReadTCState n, t n ~ m)
    => Lens' a TCState -> (a -> a) -> m b -> m b
  locallyTCState l = liftThrough . locallyTCState l

instance ReadTCState m => ReadTCState (ListT m) where
  locallyTCState l = mapListT . locallyTCState l

instance ReadTCState m => ReadTCState (ChangeT m)
instance ReadTCState m => ReadTCState (ExceptT err m)
instance ReadTCState m => ReadTCState (IdentityT m)
instance ReadTCState m => ReadTCState (MaybeT m)
instance ReadTCState m => ReadTCState (ReaderT r m)
instance ReadTCState m => ReadTCState (StateT s m)
instance (Monoid w, ReadTCState m) => ReadTCState (WriterT w m)


instance Show TCState where
  show _ = "TCSt{}"

data PreScopeState = PreScopeState
  { stPreTokens             :: !CompressedFile -- from lexer
    -- ^ Highlighting info for tokens (but not those tokens for
    -- which highlighting exists in 'stSyntaxInfo').
  , stPreImports            :: !Signature  -- XX populated by scope checker
    -- ^ Imported declared identifiers.
    --   Those most not be serialized!
  , stPreImportedModules    :: !(Set ModuleName)  -- imports logic
  , stPreModuleToSource     :: !ModuleToSource   -- imports
  , stPreVisitedModules     :: !VisitedModules   -- imports
  , stPreScope              :: !ScopeInfo
    -- generated by scope checker, current file:
    -- which modules you have, public definitions, current file, maps concrete names to abstract names.
  , stPrePatternSyns        :: !A.PatternSynDefns
    -- ^ Pattern synonyms of the current file.  Serialized.
  , stPrePatternSynImports  :: !A.PatternSynDefns
    -- ^ Imported pattern synonyms.  Must not be serialized!
  , stPreGeneralizedVars    :: !(Strict.Maybe (Set QName))
    -- ^ Collected generalizable variables; used during scope checking of terms
  , stPrePragmaOptions      :: !PragmaOptions
    -- ^ Options applying to the current file. @OPTIONS@
    -- pragmas only affect this field.
  , stPreImportedBuiltins   :: !(BuiltinThings PrimFun)
  , stPreImportedDisplayForms :: !DisplayForms
    -- ^ Display forms added by someone else to imported identifiers
  , stPreImportedInstanceDefs :: !InstanceTable
  , stPreForeignCode        :: !(Map BackendName [ForeignCode])
    -- ^ @{-\# FOREIGN \#-}@ code that should be included in the compiled output.
    -- Does not include code for imported modules.
  , stPreFreshInteractionId :: !InteractionId
  , stPreImportedUserWarnings :: !(Map A.QName Text)
    -- ^ Imported @UserWarning@s, not to be stored in the @Interface@
  , stPreLocalUserWarnings    :: !(Map A.QName Text)
    -- ^ Locally defined @UserWarning@s, to be stored in the @Interface@
  , stPreWarningOnImport      :: !(Strict.Maybe Text)
    -- ^ Whether the current module should raise a warning when opened
  , stPreImportedPartialDefs :: !(Set QName)
    -- ^ Imported partial definitions, not to be stored in the @Interface@
  }

-- | Name disambiguation for the sake of highlighting.
data DisambiguatedName = DisambiguatedName NameKind A.QName
type DisambiguatedNames = IntMap DisambiguatedName

type ConcreteNames = Map Name [C.Name]

data PostScopeState = PostScopeState
  { stPostSyntaxInfo          :: !CompressedFile
    -- ^ Highlighting info.
  , stPostDisambiguatedNames  :: !DisambiguatedNames
    -- ^ Disambiguation carried out by the type checker.
    --   Maps position of first name character to disambiguated @'A.QName'@
    --   for each @'A.AmbiguousQName'@ already passed by the type checker.
  , stPostMetaStore           :: !MetaStore
  , stPostInteractionPoints   :: !InteractionPoints -- scope checker first
  , stPostAwakeConstraints    :: !Constraints
  , stPostSleepingConstraints :: !Constraints
  , stPostDirty               :: !Bool -- local
    -- ^ Dirty when a constraint is added, used to prevent pointer update.
    -- Currently unused.
  , stPostOccursCheckDefs     :: !(Set QName) -- local
    -- ^ Definitions to be considered during occurs check.
    --   Initialized to the current mutual block before the check.
    --   During occurs check, we remove definitions from this set
    --   as soon we have checked them.
  , stPostSignature           :: !Signature
    -- ^ Declared identifiers of the current file.
    --   These will be serialized after successful type checking.
  , stPostModuleCheckpoints   :: !(Map ModuleName CheckpointId)
    -- ^ For each module remember the checkpoint corresponding to the orignal
    --   context of the module parameters.
  , stPostImportsDisplayForms :: !DisplayForms
    -- ^ Display forms we add for imported identifiers
  , stPostCurrentModule       :: !(Strict.Maybe ModuleName)
    -- ^ The current module is available after it has been type
    -- checked.
  , stPostInstanceDefs        :: !TempInstanceTable
  , stPostConcreteNames       :: !ConcreteNames
    -- ^ Map keeping track of concrete names assigned to each abstract name
    --   (can be more than one name in case the first one is shadowed)
  , stPostUsedNames           :: !(Map RawName [RawName])
    -- ^ Map keeping track for each name root (= name w/o numeric
    -- suffixes) what names with the same root have been used during a
    -- TC computation. This information is used to build the
    -- @ShadowingNames@ map.
  , stPostShadowingNames      :: !(Map Name [RawName])
    -- ^ Map keeping track for each (abstract) name the list of all
    -- (raw) names that it could maybe be shadowed by.
  , stPostStatistics          :: !Statistics
    -- ^ Counters to collect various statistics about meta variables etc.
    --   Only for current file.
  , stPostTCWarnings          :: ![TCWarning]
  , stPostMutualBlocks        :: !(Map MutualId MutualBlock)
  , stPostLocalBuiltins       :: !(BuiltinThings PrimFun)
  , stPostFreshMetaId         :: !MetaId
  , stPostFreshMutualId       :: !MutualId
  , stPostFreshProblemId      :: !ProblemId
  , stPostFreshCheckpointId   :: !CheckpointId
  , stPostFreshInt            :: !Int
  , stPostFreshNameId         :: !NameId
  , stPostAreWeCaching        :: !Bool
  , stPostPostponeInstanceSearch :: !Bool
  , stPostConsideringInstance :: !Bool
  , stPostInstantiateBlocking :: !Bool
    -- ^ Should we instantiate away blocking metas?
    --   This can produce ill-typed terms but they are often more readable. See issue #3606.
    --   Best set to True only for calls to pretty*/reify to limit unwanted reductions.
  , stPostLocalPartialDefs    :: !(Set QName)
    -- ^ Local partial definitions, to be stored in the @Interface@
  }

-- | A mutual block of names in the signature.
data MutualBlock = MutualBlock
  { mutualInfo  :: Info.MutualInfo
    -- ^ The original info of the mutual block.
  , mutualNames :: Set QName
  } deriving (Show, Eq)

instance Null MutualBlock where
  empty = MutualBlock empty empty

-- | A part of the state which is not reverted when an error is thrown
-- or the state is reset.
data PersistentTCState = PersistentTCSt
  { stDecodedModules    :: DecodedModules
  , stPersistentOptions :: CommandLineOptions
  , stInteractionOutputCallback  :: InteractionOutputCallback
    -- ^ Callback function to call when there is a response
    --   to give to the interactive frontend.
    --   See the documentation of 'InteractionOutputCallback'.
  , stBenchmark         :: !Benchmark
    -- ^ Structure to track how much CPU time was spent on which Agda phase.
    --   Needs to be a strict field to avoid space leaks!
  , stAccumStatistics   :: !Statistics
    -- ^ Should be strict field.
  , stPersistLoadedFileCache :: !(Strict.Maybe LoadedFileCache)
    -- ^ Cached typechecking state from the last loaded file.
    --   Should be @Nothing@ when checking imports.
  , stPersistBackends   :: [Backend]
    -- ^ Current backends with their options
  , stPersistProjectConfigs :: !(Map FilePath ProjectConfig)
    -- ^ Map from directories to paths of closest enclosing .agda-lib
    --   files (or @Nothing@ if there are none).
  , stPersistAgdaLibFiles   :: !(Map FilePath AgdaLibFile)
    -- ^ Contents of .agda-lib files that have already been parsed.
  }

data LoadedFileCache = LoadedFileCache
  { lfcCached  :: !CachedTypeCheckLog
  , lfcCurrent :: !CurrentTypeCheckLog
  }

-- | A log of what the type checker does and states after the action is
-- completed.  The cached version is stored first executed action first.
type CachedTypeCheckLog = [(TypeCheckAction, PostScopeState)]

-- | Like 'CachedTypeCheckLog', but storing the log for an ongoing type
-- checking of a module.  Stored in reverse order (last performed action
-- first).
type CurrentTypeCheckLog = [(TypeCheckAction, PostScopeState)]

-- | A complete log for a module will look like this:
--
--   * 'Pragmas'
--
--   * 'EnterSection', entering the main module.
--
--   * 'Decl'/'EnterSection'/'LeaveSection', for declarations and nested
--     modules
--
--   * 'LeaveSection', leaving the main module.
data TypeCheckAction
  = EnterSection !ModuleName !A.Telescope
  | LeaveSection !ModuleName
  | Decl !A.Declaration
    -- ^ Never a Section or ScopeDecl
  | Pragmas !PragmaOptions

-- | Empty persistent state.

initPersistentState :: PersistentTCState
initPersistentState = PersistentTCSt
  { stPersistentOptions         = defaultOptions
  , stDecodedModules            = Map.empty
  , stInteractionOutputCallback = defaultInteractionOutputCallback
  , stBenchmark                 = empty
  , stAccumStatistics           = Map.empty
  , stPersistLoadedFileCache    = empty
  , stPersistBackends           = []
  , stPersistProjectConfigs     = Map.empty
  , stPersistAgdaLibFiles       = Map.empty
  }

-- | Empty state of type checker.

initPreScopeState :: PreScopeState
initPreScopeState = PreScopeState
  { stPreTokens               = mempty
  , stPreImports              = emptySignature
  , stPreImportedModules      = Set.empty
  , stPreModuleToSource       = Map.empty
  , stPreVisitedModules       = Map.empty
  , stPreScope                = emptyScopeInfo
  , stPrePatternSyns          = Map.empty
  , stPrePatternSynImports    = Map.empty
  , stPreGeneralizedVars      = mempty
  , stPrePragmaOptions        = defaultInteractionOptions
  , stPreImportedBuiltins     = Map.empty
  , stPreImportedDisplayForms = HMap.empty
  , stPreImportedInstanceDefs = Map.empty
  , stPreForeignCode          = Map.empty
  , stPreFreshInteractionId   = 0
  , stPreImportedUserWarnings = Map.empty
  , stPreLocalUserWarnings    = Map.empty
  , stPreWarningOnImport      = empty
  , stPreImportedPartialDefs  = Set.empty
  }

initPostScopeState :: PostScopeState
initPostScopeState = PostScopeState
  { stPostSyntaxInfo           = mempty
  , stPostDisambiguatedNames   = IntMap.empty
  , stPostMetaStore            = IntMap.empty
  , stPostInteractionPoints    = Map.empty
  , stPostAwakeConstraints     = []
  , stPostSleepingConstraints  = []
  , stPostDirty                = False
  , stPostOccursCheckDefs      = Set.empty
  , stPostSignature            = emptySignature
  , stPostModuleCheckpoints    = Map.empty
  , stPostImportsDisplayForms  = HMap.empty
  , stPostCurrentModule        = empty
  , stPostInstanceDefs         = (Map.empty , Set.empty)
  , stPostConcreteNames        = Map.empty
  , stPostUsedNames            = Map.empty
  , stPostShadowingNames       = Map.empty
  , stPostStatistics           = Map.empty
  , stPostTCWarnings           = []
  , stPostMutualBlocks         = Map.empty
  , stPostLocalBuiltins        = Map.empty
  , stPostFreshMetaId          = 0
  , stPostFreshMutualId        = 0
  , stPostFreshProblemId       = 1
  , stPostFreshCheckpointId    = 1
  , stPostFreshInt             = 0
  , stPostFreshNameId           = NameId 0 0
  , stPostAreWeCaching         = False
  , stPostPostponeInstanceSearch = False
  , stPostConsideringInstance  = False
  , stPostInstantiateBlocking  = False
  , stPostLocalPartialDefs     = Set.empty
  }

initState :: TCState
initState = TCSt
  { stPreScopeState   = initPreScopeState
  , stPostScopeState  = initPostScopeState
  , stPersistentState = initPersistentState
  }

-- * st-prefixed lenses
------------------------------------------------------------------------

stTokens :: Lens' CompressedFile TCState
stTokens f s =
  f (stPreTokens (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreTokens = x}}

stImports :: Lens' Signature TCState
stImports f s =
  f (stPreImports (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreImports = x}}

stImportedModules :: Lens' (Set ModuleName) TCState
stImportedModules f s =
  f (stPreImportedModules (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreImportedModules = x}}

stModuleToSource :: Lens' ModuleToSource TCState
stModuleToSource f s =
  f (stPreModuleToSource (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreModuleToSource = x}}

stVisitedModules :: Lens' VisitedModules TCState
stVisitedModules f s =
  f (stPreVisitedModules (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreVisitedModules = x}}

stScope :: Lens' ScopeInfo TCState
stScope f s =
  f (stPreScope (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreScope = x}}

stPatternSyns :: Lens' A.PatternSynDefns TCState
stPatternSyns f s =
  f (stPrePatternSyns (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPrePatternSyns = x}}

stPatternSynImports :: Lens' A.PatternSynDefns TCState
stPatternSynImports f s =
  f (stPrePatternSynImports (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPrePatternSynImports = x}}

stGeneralizedVars :: Lens' (Maybe (Set QName)) TCState
stGeneralizedVars f s =
  f (Strict.toLazy $ stPreGeneralizedVars (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreGeneralizedVars = Strict.toStrict x}}

stPragmaOptions :: Lens' PragmaOptions TCState
stPragmaOptions f s =
  f (stPrePragmaOptions (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPrePragmaOptions = x}}

stImportedBuiltins :: Lens' (BuiltinThings PrimFun) TCState
stImportedBuiltins f s =
  f (stPreImportedBuiltins (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreImportedBuiltins = x}}

stForeignCode :: Lens' (Map BackendName [ForeignCode]) TCState
stForeignCode f s =
  f (stPreForeignCode (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreForeignCode = x}}

stFreshInteractionId :: Lens' InteractionId TCState
stFreshInteractionId f s =
  f (stPreFreshInteractionId (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreFreshInteractionId = x}}

stImportedUserWarnings :: Lens' (Map A.QName Text) TCState
stImportedUserWarnings f s =
  f (stPreImportedUserWarnings (stPreScopeState s)) <&>
  \ x -> s {stPreScopeState = (stPreScopeState s) {stPreImportedUserWarnings = x}}

stLocalUserWarnings :: Lens' (Map A.QName Text) TCState
stLocalUserWarnings f s =
  f (stPreLocalUserWarnings (stPreScopeState s)) <&>
  \ x -> s {stPreScopeState = (stPreScopeState s) {stPreLocalUserWarnings = x}}

getUserWarnings :: ReadTCState m => m (Map A.QName Text)
getUserWarnings = do
  iuw <- useR stImportedUserWarnings
  luw <- useR stLocalUserWarnings
  return $ iuw `Map.union` luw

stWarningOnImport :: Lens' (Maybe Text) TCState
stWarningOnImport f s =
  f (Strict.toLazy $ stPreWarningOnImport (stPreScopeState s)) <&>
  \ x -> s {stPreScopeState = (stPreScopeState s) {stPreWarningOnImport = Strict.toStrict x}}

stImportedPartialDefs :: Lens' (Set QName) TCState
stImportedPartialDefs f s =
  f (stPreImportedPartialDefs (stPreScopeState s)) <&>
  \ x -> s {stPreScopeState = (stPreScopeState s) {stPreImportedPartialDefs = x}}

stLocalPartialDefs :: Lens' (Set QName) TCState
stLocalPartialDefs f s =
  f (stPostLocalPartialDefs (stPostScopeState s)) <&>
  \ x -> s {stPostScopeState = (stPostScopeState s) {stPostLocalPartialDefs = x}}

getPartialDefs :: ReadTCState m => m (Set QName)
getPartialDefs = do
  ipd <- useR stImportedPartialDefs
  lpd <- useR stLocalPartialDefs
  return $ ipd `Set.union` lpd

stLoadedFileCache :: Lens' (Maybe LoadedFileCache) TCState
stLoadedFileCache f s =
  f (Strict.toLazy $ stPersistLoadedFileCache (stPersistentState s)) <&>
  \x -> s {stPersistentState = (stPersistentState s) {stPersistLoadedFileCache = Strict.toStrict x}}

stBackends :: Lens' [Backend] TCState
stBackends f s =
  f (stPersistBackends (stPersistentState s)) <&>
  \x -> s {stPersistentState = (stPersistentState s) {stPersistBackends = x}}

stProjectConfigs :: Lens' (Map FilePath ProjectConfig) TCState
stProjectConfigs f s =
  f (stPersistProjectConfigs (stPersistentState s)) <&>
  \ x -> s {stPersistentState = (stPersistentState s) {stPersistProjectConfigs = x}}

stAgdaLibFiles :: Lens' (Map FilePath AgdaLibFile) TCState
stAgdaLibFiles f s =
  f (stPersistAgdaLibFiles (stPersistentState s)) <&>
  \ x -> s {stPersistentState = (stPersistentState s) {stPersistAgdaLibFiles = x}}

stFreshNameId :: Lens' NameId TCState
stFreshNameId f s =
  f (stPostFreshNameId (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostFreshNameId = x}}

stSyntaxInfo :: Lens' CompressedFile TCState
stSyntaxInfo f s =
  f (stPostSyntaxInfo (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostSyntaxInfo = x}}

stDisambiguatedNames :: Lens' DisambiguatedNames TCState
stDisambiguatedNames f s =
  f (stPostDisambiguatedNames (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostDisambiguatedNames = x}}

stMetaStore :: Lens' MetaStore TCState
stMetaStore f s =
  f (stPostMetaStore (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostMetaStore = x}}

stInteractionPoints :: Lens' InteractionPoints TCState
stInteractionPoints f s =
  f (stPostInteractionPoints (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostInteractionPoints = x}}

stAwakeConstraints :: Lens' Constraints TCState
stAwakeConstraints f s =
  f (stPostAwakeConstraints (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostAwakeConstraints = x}}

stSleepingConstraints :: Lens' Constraints TCState
stSleepingConstraints f s =
  f (stPostSleepingConstraints (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostSleepingConstraints = x}}

stDirty :: Lens' Bool TCState
stDirty f s =
  f (stPostDirty (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostDirty = x}}

stOccursCheckDefs :: Lens' (Set QName) TCState
stOccursCheckDefs f s =
  f (stPostOccursCheckDefs (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostOccursCheckDefs = x}}

stSignature :: Lens' Signature TCState
stSignature f s =
  f (stPostSignature (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostSignature = x}}

stModuleCheckpoints :: Lens' (Map ModuleName CheckpointId) TCState
stModuleCheckpoints f s =
  f (stPostModuleCheckpoints (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostModuleCheckpoints = x}}

stImportsDisplayForms :: Lens' DisplayForms TCState
stImportsDisplayForms f s =
  f (stPostImportsDisplayForms (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostImportsDisplayForms = x}}

stImportedDisplayForms :: Lens' DisplayForms TCState
stImportedDisplayForms f s =
  f (stPreImportedDisplayForms (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreImportedDisplayForms = x}}

stCurrentModule :: Lens' (Maybe ModuleName) TCState
stCurrentModule f s =
  f (Strict.toLazy $ stPostCurrentModule (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostCurrentModule = Strict.toStrict x}}

stImportedInstanceDefs :: Lens' InstanceTable TCState
stImportedInstanceDefs f s =
  f (stPreImportedInstanceDefs (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreImportedInstanceDefs = x}}

stInstanceDefs :: Lens' TempInstanceTable TCState
stInstanceDefs f s =
  f (stPostInstanceDefs (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostInstanceDefs = x}}

stConcreteNames :: Lens' ConcreteNames TCState
stConcreteNames f s =
  f (stPostConcreteNames (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostConcreteNames = x}}

stUsedNames :: Lens' (Map RawName [RawName]) TCState
stUsedNames f s =
  f (stPostUsedNames (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostUsedNames = x}}

stShadowingNames :: Lens' (Map Name [RawName]) TCState
stShadowingNames f s =
  f (stPostShadowingNames (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostShadowingNames = x}}

stStatistics :: Lens' Statistics TCState
stStatistics f s =
  f (stPostStatistics (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostStatistics = x}}

stTCWarnings :: Lens' [TCWarning] TCState
stTCWarnings f s =
  f (stPostTCWarnings (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostTCWarnings = x}}

stMutualBlocks :: Lens' (Map MutualId MutualBlock) TCState
stMutualBlocks f s =
  f (stPostMutualBlocks (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostMutualBlocks = x}}

stLocalBuiltins :: Lens' (BuiltinThings PrimFun) TCState
stLocalBuiltins f s =
  f (stPostLocalBuiltins (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostLocalBuiltins = x}}

stFreshMetaId :: Lens' MetaId TCState
stFreshMetaId f s =
  f (stPostFreshMetaId (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostFreshMetaId = x}}

stFreshMutualId :: Lens' MutualId TCState
stFreshMutualId f s =
  f (stPostFreshMutualId (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostFreshMutualId = x}}

stFreshProblemId :: Lens' ProblemId TCState
stFreshProblemId f s =
  f (stPostFreshProblemId (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostFreshProblemId = x}}

stFreshCheckpointId :: Lens' CheckpointId TCState
stFreshCheckpointId f s =
  f (stPostFreshCheckpointId (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostFreshCheckpointId = x}}

stFreshInt :: Lens' Int TCState
stFreshInt f s =
  f (stPostFreshInt (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostFreshInt = x}}

-- use @areWeCaching@ from the Caching module instead.
stAreWeCaching :: Lens' Bool TCState
stAreWeCaching f s =
  f (stPostAreWeCaching (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostAreWeCaching = x}}

stPostponeInstanceSearch :: Lens' Bool TCState
stPostponeInstanceSearch f s =
  f (stPostPostponeInstanceSearch (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostPostponeInstanceSearch = x}}

stConsideringInstance :: Lens' Bool TCState
stConsideringInstance f s =
  f (stPostConsideringInstance (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostConsideringInstance = x}}

stInstantiateBlocking :: Lens' Bool TCState
stInstantiateBlocking f s =
  f (stPostInstantiateBlocking (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostInstantiateBlocking = x}}

stBuiltinThings :: TCState -> BuiltinThings PrimFun
stBuiltinThings s = (s^.stLocalBuiltins) `Map.union` (s^.stImportedBuiltins)


-- * Fresh things
------------------------------------------------------------------------

class Enum i => HasFresh i where
    freshLens :: Lens' i TCState
    nextFresh' :: i -> i
    nextFresh' = succ

nextFresh :: HasFresh i => TCState -> (i, TCState)
nextFresh s =
  let !c = s^.freshLens
  in (c, set freshLens (nextFresh' c) s)

class Monad m => MonadFresh i m where
  fresh :: m i

  default fresh :: (MonadTrans t, MonadFresh i n, t n ~ m) => m i
  fresh = lift fresh

instance MonadFresh i m => MonadFresh i (ReaderT r m)
instance MonadFresh i m => MonadFresh i (StateT s m)
instance MonadFresh i m => MonadFresh i (ListT m)
instance MonadFresh i m => MonadFresh i (IdentityT m)

instance HasFresh i => MonadFresh i TCM where
  fresh = do
        !s <- getTC
        let (!c , !s') = nextFresh s
        putTC s'
        return c

instance HasFresh MetaId where
  freshLens = stFreshMetaId

instance HasFresh MutualId where
  freshLens = stFreshMutualId

instance HasFresh InteractionId where
  freshLens = stFreshInteractionId

instance HasFresh NameId where
  freshLens = stFreshNameId
  -- nextFresh increments the current fresh name by 2 so @NameId@s used
  -- before caching starts do not overlap with the ones used after.
  nextFresh' = succ . succ

instance HasFresh Int where
  freshLens = stFreshInt

instance HasFresh ProblemId where
  freshLens = stFreshProblemId

newtype CheckpointId = CheckpointId Int
  deriving (Data, Eq, Ord, Enum, Real, Integral, Num)

instance Show CheckpointId where
  show (CheckpointId n) = show n

instance Pretty CheckpointId where
  pretty (CheckpointId n) = pretty n

instance HasFresh CheckpointId where
  freshLens = stFreshCheckpointId

freshName :: MonadFresh NameId m => Range -> String -> m Name
freshName r s = do
  i <- fresh
  return $ mkName r i s

freshNoName :: MonadFresh NameId m => Range -> m Name
freshNoName r =
    do  i <- fresh
        return $ makeName i (C.NoName noRange i) r noFixity' False

freshNoName_ :: MonadFresh NameId m => m Name
freshNoName_ = freshNoName noRange

freshRecordName :: MonadFresh NameId m => m Name
freshRecordName = do
  i <- fresh
  return $ makeName i (C.setNotInScope $ C.simpleName "r") noRange noFixity' True

-- | Create a fresh name from @a@.
class FreshName a where
  freshName_ :: MonadFresh NameId m => a -> m Name

instance FreshName (Range, String) where
  freshName_ = uncurry freshName

instance FreshName String where
  freshName_ = freshName noRange

instance FreshName Range where
  freshName_ = freshNoName

instance FreshName () where
  freshName_ () = freshNoName_

---------------------------------------------------------------------------
-- ** Managing file names
---------------------------------------------------------------------------

-- | Maps top-level module names to the corresponding source file
-- names.

type ModuleToSource = Map TopLevelModuleName AbsolutePath

-- | Maps source file names to the corresponding top-level module
-- names.

type SourceToModule = Map AbsolutePath TopLevelModuleName

-- | Creates a 'SourceToModule' map based on 'stModuleToSource'.
--
--   O(n log n).
--
--   For a single reverse lookup in 'stModuleToSource',
--   rather use 'lookupModuleFromSourse'.

sourceToModule :: TCM SourceToModule
sourceToModule =
  Map.fromList
     .  List.map (\(m, f) -> (f, m))
     .  Map.toList
    <$> useTC stModuleToSource

-- | Lookup an 'AbsolutePath' in 'sourceToModule'.
--
--   O(n).

lookupModuleFromSource :: ReadTCState m => AbsolutePath -> m (Maybe TopLevelModuleName)
lookupModuleFromSource f =
  fmap fst . List.find ((f ==) . snd) . Map.toList <$> useR stModuleToSource


---------------------------------------------------------------------------
-- ** Associating concrete names to an abstract name
---------------------------------------------------------------------------

-- | A monad that has read and write access to the stConcreteNames
--   part of the TCState. Basically, this is a synonym for `MonadState
--   ConcreteNames m` (which cannot be used directly because of the
--   limitations of Haskell's typeclass system).
class Monad m => MonadStConcreteNames m where
  runStConcreteNames :: StateT ConcreteNames m a -> m a

  useConcreteNames :: m ConcreteNames
  useConcreteNames = runStConcreteNames get

  modifyConcreteNames :: (ConcreteNames -> ConcreteNames) -> m ()
  modifyConcreteNames = runStConcreteNames . modify

instance MonadStConcreteNames TCM where
  runStConcreteNames m = stateTCLensM stConcreteNames $ runStateT m

instance MonadStConcreteNames m => MonadStConcreteNames (IdentityT m) where
  runStConcreteNames m = IdentityT $ runStConcreteNames $ StateT $ runIdentityT . runStateT m

instance MonadStConcreteNames m => MonadStConcreteNames (ReaderT r m) where
  runStConcreteNames m = ReaderT $ runStConcreteNames . StateT . flip (runReaderT . runStateT m)

instance MonadStConcreteNames m => MonadStConcreteNames (StateT s m) where
  runStConcreteNames m = StateT $ \s -> runStConcreteNames $ StateT $ \ns -> do
    ((x,ns'),s') <- runStateT (runStateT m ns) s
    return ((x,s'),ns')

---------------------------------------------------------------------------
-- ** Interface
---------------------------------------------------------------------------


-- | Distinguishes between type-checked and scope-checked interfaces
--   when stored in the map of `VisitedModules`.
data ModuleCheckMode
  = ModuleScopeChecked
  | ModuleTypeChecked
  | ModuleTypeCheckedRetainingPrivates
  deriving (Eq, Ord, Bounded, Enum, Show)


data ModuleInfo = ModuleInfo
  { miInterface  :: Interface
  , miWarnings   :: [TCWarning]
    -- ^ Warnings were encountered when the module was type checked.
    --   These might include warnings not stored in the interface itself,
    --   specifically unsolved interaction metas.
    --   See "Agda.Interaction.Imports"
  , miPrimitive  :: Bool
    -- ^ 'True' if the module is a primitive module, which should always
    -- be importable.
  , miMode       :: ModuleCheckMode
    -- ^ The `ModuleCheckMode` used to create the `Interface`
  }

-- Note that the use of 'C.TopLevelModuleName' here is a potential
-- performance problem, because these names do not contain unique
-- identifiers.

type VisitedModules = Map C.TopLevelModuleName ModuleInfo
type DecodedModules = Map C.TopLevelModuleName ModuleInfo

data ForeignCode = ForeignCode Range String
  deriving Show

data Interface = Interface
  { iSourceHash      :: Hash
    -- ^ Hash of the source code.
  , iSource          :: TL.Text
    -- ^ The source code. The source code is stored so that the HTML
    -- and LaTeX backends can generate their output without having to
    -- re-read the (possibly out of date) source code.
  , iFileType        :: FileType
    -- ^ Source file type, determined from the file extension
  , iImportedModules :: [(ModuleName, Hash)]
    -- ^ Imported modules and their hashes.
  , iModuleName      :: ModuleName
    -- ^ Module name of this interface.
  , iScope           :: Map ModuleName Scope
    -- ^ Scope defined by this module.
    --
    --   Andreas, AIM XX: Too avoid duplicate serialization, this field is
    --   not serialized, so if you deserialize an interface, @iScope@
    --   will be empty.
    --   But 'constructIScope' constructs 'iScope' from 'iInsideScope'.
  , iInsideScope     :: ScopeInfo
    -- ^ Scope after we loaded this interface.
    --   Used in 'Agda.Interaction.BasicOps.AtTopLevel'
    --   and     'Agda.Interaction.CommandLine.interactionLoop'.
  , iSignature       :: Signature
  , iDisplayForms    :: DisplayForms
    -- ^ Display forms added for imported identifiers.
  , iUserWarnings    :: Map A.QName Text
    -- ^ User warnings for imported identifiers
  , iImportWarning   :: Maybe Text
    -- ^ Whether this module should raise a warning when imported
  , iBuiltin         :: BuiltinThings (String, QName)
  , iForeignCode     :: Map BackendName [ForeignCode]
  , iHighlighting    :: HighlightingInfo
  , iPragmaOptions   :: [OptionsPragma]
    -- ^ Pragma options set in the file.
  , iOptionsUsed     :: PragmaOptions
    -- ^ Options/features used when checking the file (can be different
    --   from options set directly in the file).
  , iPatternSyns     :: A.PatternSynDefns
  , iWarnings        :: [TCWarning]
  , iPartialDefs     :: Set QName
  }
  deriving Show

instance Pretty Interface where
  pretty (Interface
            sourceH source fileT importedM moduleN scope insideS signature
            display userwarn importwarn builtin foreignCode highlighting pragmaO
            oUsed patternS warnings partialdefs) =

    hang "Interface" 2 $ vcat
      [ "source hash:"         <+> (pretty . show) sourceH
      , "source:"              $$  nest 2 (text $ TL.unpack source)
      , "file type:"           <+> (pretty . show) fileT
      , "imported modules:"    <+> (pretty . show) importedM
      , "module name:"         <+> pretty moduleN
      , "scope:"               <+> (pretty . show) scope
      , "inside scope:"        <+> (pretty . show) insideS
      , "signature:"           <+> (pretty . show) signature
      , "display:"             <+> (pretty . show) display
      , "user warnings:"       <+> (pretty . show) userwarn
      , "import warning:"      <+> (pretty . show) importwarn
      , "builtin:"             <+> (pretty . show) builtin
      , "Foreign code:"        <+> (pretty . show) foreignCode
      , "highlighting:"        <+> (pretty . show) highlighting
      , "pragma options:"      <+> (pretty . show) pragmaO
      , "options used:"        <+> (pretty . show) oUsed
      , "pattern syns:"        <+> (pretty . show) patternS
      , "warnings:"            <+> (pretty . show) warnings
      , "partial definitions:" <+> (pretty . show) partialdefs
      ]

-- | Combines the source hash and the (full) hashes of the imported modules.
iFullHash :: Interface -> Hash
iFullHash i = combineHashes $ iSourceHash i : List.map snd (iImportedModules i)

---------------------------------------------------------------------------
-- ** Closure
---------------------------------------------------------------------------

data Closure a = Closure
  { clSignature        :: Signature
  , clEnv              :: TCEnv
  , clScope            :: ScopeInfo
  , clModuleCheckpoints :: Map ModuleName CheckpointId
  , clValue            :: a
  }
    deriving (Data, Functor, Foldable)

instance Show a => Show (Closure a) where
  show cl = "Closure { clValue = " ++ show (clValue cl) ++ " }"

instance HasRange a => HasRange (Closure a) where
  getRange = getRange . clValue

class LensClosure a b | b -> a where
  lensClosure :: Lens' (Closure a) b

instance LensClosure a (Closure a) where
  lensClosure = id

instance LensTCEnv (Closure a) where
  lensTCEnv f cl = (f $! clEnv cl) <&> \ env -> cl { clEnv = env }

buildClosure :: (MonadTCEnv m, ReadTCState m) => a -> m (Closure a)
buildClosure x = do
    env   <- askTC
    sig   <- useR stSignature
    scope <- useR stScope
    cps   <- useR stModuleCheckpoints
    return $ Closure sig env scope cps x

---------------------------------------------------------------------------
-- ** Constraints
---------------------------------------------------------------------------

type Constraints = [ProblemConstraint]

data ProblemConstraint = PConstr
  { constraintProblems  :: ISet ProblemId
  , constraintUnblocker :: Blocker
  , theConstraint       :: Closure Constraint
  }
  deriving (Show)

instance HasRange ProblemConstraint where
  getRange = getRange . theConstraint

data Constraint
  = ValueCmp Comparison CompareAs Term Term
  | ValueCmp_ Comparison CompareAs_ (Het 'LHS Term) (Het 'RHS Term)
  | ValueCmpOnFace Comparison Term Type Term Term
  | ElimCmp [Polarity] [IsForced] Type Term [Elim] [Elim]
  | ElimCmp_ [Polarity] [IsForced] TwinT (TwinT' Term) (H'LHS [Elim]) (H'RHS [Elim])
  | SortCmp Comparison Sort Sort
  | LevelCmp Comparison Level Level
--  | ShortCut MetaId Term Type
--    -- ^ A delayed instantiation.  Replaces @ValueCmp@ in 'postponeTypeCheckingProblem'.
  | HasBiggerSort Sort
  | HasPTSRule (Dom Type) (Abs Sort)
  | CheckMetaInst MetaId
  | UnBlock MetaId
    -- ^ Meta created for a term blocked by a postponed type checking problem or unsolved
    --   constraints. The 'MetaInstantiation' for the meta (when unsolved) is either 'BlockedConst'
    --   or 'PostponedTypeCheckingProblem'.
  | IsEmpty Range Type
    -- ^ The range is the one of the absurd pattern.
  | CheckSizeLtSat Term
    -- ^ Check that the 'Term' is either not a SIZELT or a non-empty SIZELT.
  | FindInstance MetaId (Maybe [Candidate])
    -- ^ the first argument is the instance argument and the second one is the list of candidates
    --   (or Nothing if we haven’t determined the list of candidates yet)
  | CheckFunDef Delayed A.DefInfo QName [A.Clause] TCErr
    -- ^ Last argument is the error causing us to postpone.
  | UnquoteTactic Term Term Type   -- ^ First argument is computation and the others are hole and goal type
  | CheckLockedVars Term Type (Arg Term) Type     -- ^ @CheckLockedVars t ty lk lk_ty@ with @t : ty@, @lk : lk_ty@ and @t lk@ well-typed.
  | UsableAtModality Modality Term   -- ^ is the term usable at the given modality?
  deriving (Show)

instance HasRange Constraint where
  getRange (IsEmpty r t) = r
  getRange _ = noRange
{- no Range instances for Term, Type, Elm, Tele, Sort, Level, MetaId
  getRange (ValueCmp cmp a u v) = getRange (a,u,v)
  getRange (ElimCmp pol a v es es') = getRange (a,v,es,es')
  getRange (TelCmp a b cmp tel tel') = getRange (a,b,tel,tel')
  getRange (SortCmp cmp s s') = getRange (s,s')
  getRange (LevelCmp cmp l l') = getRange (l,l')
  getRange (UnBlock x) = getRange x
  getRange (FindInstance x cands) = getRange x
-}

instance Free Constraint where
  freeVars' c =
    case c of
      ValueCmp _ t u v      -> freeVars' (t, (u, v))
      ValueCmp_ _ t u v   -> freeVars' (t, (u, v))
      ValueCmpOnFace _ p t u v -> freeVars' (p, (t, (u, v)))
      ElimCmp _ _ t u es es'  -> freeVars' ((t, u), (es, es'))
      ElimCmp_ _ _ t u es es'  -> freeVars' ((t, u), (es, es'))
      SortCmp _ s s'        -> freeVars' (s, s')
      LevelCmp _ l l'       -> freeVars' (l, l')
      UnBlock _             -> mempty
      IsEmpty _ t           -> freeVars' t
      CheckSizeLtSat u      -> freeVars' u
      FindInstance _ cs     -> freeVars' cs
      CheckFunDef{}         -> mempty
      HasBiggerSort s       -> freeVars' s
      HasPTSRule a s        -> freeVars' (a , s)
      CheckLockedVars a b c d -> freeVars' ((a,b),(c,d))
      UnquoteTactic t h g   -> freeVars' (t, (h, g))
      CheckMetaInst m       -> mempty
      UsableAtModality mod t -> freeVars' t

instance TermLike Constraint where
  foldTerm f = \case
      ValueCmp _ t u v       -> foldTerm f (t, u, v)
      ValueCmp_ _ t u v      -> foldTerm f (t, u, v)
      ValueCmpOnFace _ p t u v -> foldTerm f (p, t, u, v)
      ElimCmp _ _ t u es es' -> foldTerm f (t, u, es, es')
      ElimCmp_ _ _ t u es es' -> foldTerm f (t, u, es, es')
      LevelCmp _ l l'        -> foldTerm f (Level l, Level l')  -- Note wrapping as term, to ensure f gets to act on l and l'
      IsEmpty _ t            -> foldTerm f t
      CheckSizeLtSat u       -> foldTerm f u
      UnquoteTactic t h g    -> foldTerm f (t, h, g)
      SortCmp _ s1 s2        -> foldTerm f (Sort s1, Sort s2)   -- Same as LevelCmp case
      UnBlock _              -> mempty
      CheckLockedVars a b c d -> foldTerm f (a, b, c, d)
      FindInstance _ _       -> mempty
      CheckFunDef{}          -> mempty
      HasBiggerSort s        -> foldTerm f s
      HasPTSRule a s         -> foldTerm f (a, Sort <$> s)
      CheckMetaInst m        -> mempty
      UsableAtModality m t   -> foldTerm f t

  traverseTermM f c = __IMPOSSIBLE__ -- Not yet implemented

instance AllMetas Constraint

data Comparison = CmpEq | CmpLeq
  deriving (Eq, Data, Show)

instance Pretty Comparison where
  pretty CmpEq  = "="
  pretty CmpLeq = "=<"

-- | An extension of 'Comparison' to @>=@.
data CompareDirection = DirEq | DirLeq | DirGeq
  deriving (Eq, Show, Data)

instance Pretty CompareDirection where
  pretty = text . \case
    DirEq  -> "="
    DirLeq -> "=<"
    DirGeq -> ">="

-- | Embed 'Comparison' into 'CompareDirection'.
fromCmp :: Comparison -> CompareDirection
fromCmp CmpEq  = DirEq
fromCmp CmpLeq = DirLeq

-- | Flip the direction of comparison.
flipCmp :: CompareDirection -> CompareDirection
flipCmp DirEq  = DirEq
flipCmp DirLeq = DirGeq
flipCmp DirGeq = DirLeq

-- | Turn a 'Comparison' function into a 'CompareDirection' function.
--
--   Property: @dirToCmp f (fromCmp cmp) = f cmp@
dirToCmp :: (Comparison -> a -> a -> c) -> CompareDirection -> a -> a -> c
dirToCmp cont DirEq  = cont CmpEq
dirToCmp cont DirLeq = cont CmpLeq
dirToCmp cont DirGeq = flip $ cont CmpLeq

selectSmaller :: CompareDirection -> a -> a -> a
selectSmaller = dirToCmp (\_ a1 _ -> a1)

selectLarger :: CompareDirection -> a -> a -> a
selectLarger = dirToCmp (\_ _ a2 -> a2)

-- | We can either compare two terms at a given type, or compare two
--   types without knowing (or caring about) their sorts.
data CompareAs' a
  = AsTermsOf a    -- ^ @Type@ should not be @Size@.
                   --   But currently, we do not rely on this invariant.
  | AsSizes        -- ^ Replaces @AsTermsOf Size@.
  | AsTypes
  deriving (Data, Show, Functor, Foldable, Traversable)

type CompareAs = CompareAs' Type

type CompareAsHet = CompareAs' TwinT

type CompareAs_ = CompareAs' TwinT

instance Free a => Free (CompareAs' a) where
  freeVars' (AsTermsOf a) = freeVars' a
  freeVars' AsSizes       = mempty
  freeVars' AsTypes       = mempty

instance TermLike a => TermLike (CompareAs' a) where
  foldTerm f (AsTermsOf a) = foldTerm f a
  foldTerm f AsSizes       = mempty
  foldTerm f AsTypes       = mempty

  traverseTermM f = \case
    AsTermsOf a -> AsTermsOf <$> traverseTermM f a
    AsSizes     -> return AsSizes
    AsTypes     -> return AsTypes

instance AllMetas a => AllMetas (CompareAs' a) where
  allMetas f (AsTermsOf a) = allMetas f a
  allMetas _ AsSizes       = mempty
  allMetas _ AsTypes       = mempty

instance AllMetas () where
  allMetas _ () = mempty

instance AllMetas a => AllMetas (TwinT' a) where
  allMetas f (SingleT a) = allMetas f a
  -- TODO[het]: <victor> 2020-10-12 Remove twinCompat from here, see if it makes a difference
  allMetas f TwinT{twinLHS,twinRHS} =
#if __GLASGOW_HASKELL__ >= 804
    allMetas f twinLHS <> allMetas f twinRHS
#else
    allMetas f twinLHS `mappend` allMetas f twinRHS
#endif

---------------------------------------------------------------------------
-- * Open things
---------------------------------------------------------------------------

-- | A thing tagged with the context it came from.
data Open a = OpenThing { openThingCheckpoint :: CheckpointId, openThing :: a }
    deriving (Data, Show, Functor, Foldable, Traversable)

instance Decoration Open where
  traverseF f (OpenThing cp x) = OpenThing cp <$> f x

---------------------------------------------------------------------------
-- * Judgements
--
-- Used exclusively for typing of meta variables.
---------------------------------------------------------------------------

-- | Parametrized since it is used without MetaId when creating a new meta.
data Judgement a
  = HasType
    { jMetaId     :: a
    , jComparison :: Comparison -- ^ are we checking (@CmpLeq@) or inferring (@CmpEq@) the type?
    , jMetaType   :: Type
    }
  | IsSort
    { jMetaId   :: a
    , jMetaType :: Type -- Andreas, 2011-04-26: type needed for higher-order sort metas
    }

instance Pretty a => Pretty (Judgement a) where
    pretty (HasType a cmp t) = hsep [ pretty a, ":"    , pretty t ]
    pretty (IsSort  a t)     = hsep [ pretty a, ":sort", pretty t ]

-----------------------------------------------------------------------------
-- ** Generalizable variables
-----------------------------------------------------------------------------

data DoGeneralize = YesGeneralize | NoGeneralize
  deriving (Eq, Ord, Show, Data)

-- | The value of a generalizable variable. This is created to be a
--   generalizable meta before checking the type to be generalized.
data GeneralizedValue = GeneralizedValue
  { genvalCheckpoint :: CheckpointId
  , genvalTerm       :: Term
  , genvalType       :: Type
  } deriving (Show, Data)

---------------------------------------------------------------------------
-- ** Meta variables
---------------------------------------------------------------------------

data MetaVariable =
        MetaVar { mvInfo          :: MetaInfo
                , mvPriority      :: MetaPriority -- ^ some metavariables are more eager to be instantiated
                , mvPermutation   :: Permutation
                  -- ^ a metavariable doesn't have to depend on all variables
                  --   in the context, this "permutation" will throw away the
                  --   ones it does not depend on
                , mvJudgement     :: Judgement MetaId
                , mvInstantiation :: MetaInstantiation
                , mvListeners     :: Set Listener -- ^ meta variables scheduled for eta-expansion but blocked by this one
                , mvFrozen        :: Frozen -- ^ are we past the point where we can instantiate this meta variable?
                , mvTwin          :: Maybe MetaId -- ^ @Just m@ means this meta will be equated to @m@ when the latter is unblocked. See @blockedTermOnProblem@.
                }

data Listener = EtaExpand MetaId
              | CheckConstraint Nat ProblemConstraint

instance Eq Listener where
  EtaExpand       x   == EtaExpand       y   = x == y
  CheckConstraint x _ == CheckConstraint y _ = x == y
  _ == _ = False

instance Ord Listener where
  EtaExpand       x   `compare` EtaExpand       y   = x `compare` y
  CheckConstraint x _ `compare` CheckConstraint y _ = x `compare` y
  EtaExpand{} `compare` CheckConstraint{} = LT
  CheckConstraint{} `compare` EtaExpand{} = GT

-- | Frozen meta variable cannot be instantiated by unification.
--   This serves to prevent the completion of a definition by its use
--   outside of the current block.
--   (See issues 118, 288, 399).
data Frozen
  = Frozen        -- ^ Do not instantiate.
  | Instantiable
    deriving (Eq, Show)

data MetaInstantiation
        = InstV [Arg String] Term -- ^ solved by term (abstracted over some free variables)
        | Open               -- ^ unsolved
        | OpenInstance       -- ^ open, to be instantiated by instance search
        | BlockedConst Term  -- ^ solution blocked by unsolved constraints
        | PostponedTypeCheckingProblem (Closure TypeCheckingProblem)

-- | Solving a 'CheckArgs' constraint may or may not check the target type. If
--   it did, it returns a handle to any unsolved constraints.
data CheckedTarget = CheckedTarget (Maybe ProblemId)
                   | NotCheckedTarget

data PrincipalArgTypeMetas = PrincipalArgTypeMetas
  { patmMetas     :: Args -- ^ metas created for hidden and instance arguments
                          --   in the principal argument's type
  , patmRemainder :: Type -- ^ principal argument's type, stripped of hidden and
                          --   instance arguments
  }

data TypeCheckingProblem
  = CheckExpr Comparison A.Expr Type
  | CheckArgs ExpandHidden Range [NamedArg A.Expr] Type Type (ArgsCheckState CheckedTarget -> TCM Term)
  | CheckProjAppToKnownPrincipalArg Comparison A.Expr ProjOrigin (List1 QName) A.Args Type Int Term Type PrincipalArgTypeMetas
  | CheckLambda Comparison (Arg (List1 (WithHiding Name), Maybe Type)) A.Expr Type
    -- ^ @(λ (xs : t₀) → e) : t@
    --   This is not an instance of 'CheckExpr' as the domain type
    --   has already been checked.
    --   For example, when checking
    --     @(λ (x y : Fin _) → e) : (x : Fin n) → ?@
    --   we want to postpone @(λ (y : Fin n) → e) : ?@ where @Fin n@
    --   is a 'Type' rather than an 'A.Expr'.
  | DoQuoteTerm Comparison Term Type -- ^ Quote the given term and check type against `Term`

instance Show MetaInstantiation where
  show (InstV tel t) = "InstV " ++ show tel ++ " (" ++ show t ++ ")"
  show Open      = "Open"
  show OpenInstance = "OpenInstance"
  show (BlockedConst t) = "BlockedConst (" ++ show t ++ ")"
  show (PostponedTypeCheckingProblem{}) = "PostponedTypeCheckingProblem (...)"

-- | Meta variable priority:
--   When we have an equation between meta-variables, which one
--   should be instantiated?
--
--   Higher value means higher priority to be instantiated.
newtype MetaPriority = MetaPriority Int
    deriving (Eq , Ord , Show)

data RunMetaOccursCheck
  = RunMetaOccursCheck
  | DontRunMetaOccursCheck
  deriving (Eq , Ord , Show)

-- | @MetaInfo@ is cloned from one meta to the next during pruning.
data MetaInfo = MetaInfo
  { miClosRange       :: Closure Range -- TODO: Not so nice. But we want both to have the environment of the meta (Closure) and its range.
--  , miRelevance       :: Relevance          -- ^ Created in irrelevant position?
  , miMetaOccursCheck :: RunMetaOccursCheck -- ^ Run the extended occurs check that goes in definitions?
  , miNameSuggestion  :: MetaNameSuggestion
    -- ^ Used for printing.
    --   @Just x@ if meta-variable comes from omitted argument with name @x@.
  , miGeneralizable   :: Arg DoGeneralize
    -- ^ Should this meta be generalized if unsolved? If so, at what ArgInfo?
  }

-- | Name suggestion for meta variable.  Empty string means no suggestion.
type MetaNameSuggestion = String

-- | For printing, we couple a meta with its name suggestion.
data NamedMeta = NamedMeta
  { nmSuggestion :: MetaNameSuggestion
  , nmid         :: MetaId
  }

instance Pretty NamedMeta where
  pretty (NamedMeta "" x) = pretty x
  pretty (NamedMeta "_" x) = pretty x
  pretty (NamedMeta s  x) = text $ "_" ++ s ++ prettyShow x

type MetaStore = IntMap MetaVariable

instance HasRange MetaInfo where
  getRange = clValue . miClosRange

instance HasRange MetaVariable where
    getRange m = getRange $ getMetaInfo m

instance SetRange MetaInfo where
  setRange r m = m { miClosRange = (miClosRange m) { clValue = r }}

instance SetRange MetaVariable where
  setRange r m = m { mvInfo = setRange r (mvInfo m) }

normalMetaPriority :: MetaPriority
normalMetaPriority = MetaPriority 0

lowMetaPriority :: MetaPriority
lowMetaPriority = MetaPriority (-10)

highMetaPriority :: MetaPriority
highMetaPriority = MetaPriority 10

getMetaInfo :: MetaVariable -> Closure Range
getMetaInfo = miClosRange . mvInfo

getMetaScope :: MetaVariable -> ScopeInfo
getMetaScope m = clScope $ getMetaInfo m

getMetaEnv :: MetaVariable -> TCEnv
getMetaEnv m = clEnv $ getMetaInfo m

getMetaSig :: MetaVariable -> Signature
getMetaSig m = clSignature $ getMetaInfo m

getMetaRelevance :: MetaVariable -> Relevance
getMetaRelevance = getRelevance . getMetaEnv

getMetaModality :: MetaVariable -> Modality
-- Andrea 23/02/2020: use getModality to enforce invariants of the
--                    envModality field.
getMetaModality = getModality . getMetaEnv

-- Lenses

metaFrozen :: Lens' Frozen MetaVariable
metaFrozen f mv = f (mvFrozen mv) <&> \ x -> mv { mvFrozen = x }

_mvInfo :: Lens' MetaInfo MetaVariable
_mvInfo f mv = (f $! mvInfo mv) <&> \ mi -> mv { mvInfo = mi }

-- Lenses onto Closure Range

instance LensClosure Range MetaInfo where
  lensClosure f mi = (f $! miClosRange mi) <&> \ cl -> mi { miClosRange = cl }

instance LensClosure Range MetaVariable where
  lensClosure = _mvInfo . lensClosure

-- Lenses onto IsAbstract

instance LensIsAbstract TCEnv where
  lensIsAbstract f env =
     -- Andreas, 2019-08-19
     -- Using $! to prevent space leaks like #1829.
     -- This can crash when trying to get IsAbstract from IgnoreAbstractMode.
    (f $! fromMaybe __IMPOSSIBLE__ (aModeToDef $ envAbstractMode env))
    <&> \ a -> env { envAbstractMode = aDefToMode a }

instance LensIsAbstract (Closure a) where
  lensIsAbstract = lensTCEnv . lensIsAbstract

instance LensIsAbstract MetaInfo where
  lensIsAbstract = lensClosure . lensIsAbstract

---------------------------------------------------------------------------
-- ** Interaction meta variables
---------------------------------------------------------------------------

-- | Interaction points are created by the scope checker who sets the range.
--   The meta variable is created by the type checker and then hooked up to the
--   interaction point.
data InteractionPoint = InteractionPoint
  { ipRange :: Range        -- ^ The position of the interaction point.
  , ipMeta  :: Maybe MetaId -- ^ The meta variable, if any, holding the type etc.
  , ipSolved:: Bool         -- ^ Has this interaction point already been solved?
  , ipClause:: IPClause
      -- ^ The clause of the interaction point (if any).
      --   Used for case splitting.
  }

instance Eq InteractionPoint where (==) = (==) `on` ipMeta

-- | Data structure managing the interaction points.
--
--   We never remove interaction points from this map, only set their
--   'ipSolved' to @True@.  (Issue #2368)
type InteractionPoints = Map InteractionId InteractionPoint


-- | Flag to indicate whether the meta is overapplied in the
--   constraint.  A meta is overapplied if it has more arguments than
--   the size of the telescope in its creation environment
--   (as stored in MetaInfo).
data Overapplied = Overapplied | NotOverapplied deriving (Eq, Show, Data)

-- | Datatype representing a single boundary condition:
--   x_0 = u_0, ... ,x_n = u_n ⊢ t = ?n es
data IPBoundary' t = IPBoundary
  { ipbEquations :: [(t,t)] -- ^ [x_0 = u_0, ... ,x_n = u_n]
  , ipbValue     :: t          -- ^ @t@
  , ipbMetaApp   :: t          -- ^ @?n es@
  , ipbOverapplied :: Overapplied -- ^ Is @?n@ overapplied in @?n es@ ?
  }
  deriving (Show, Data, Functor, Foldable, Traversable)

type IPBoundary = IPBoundary' Term

-- | Which clause is an interaction point located in?
data IPClause = IPClause
  { ipcQName    :: QName              -- ^ The name of the function.
  , ipcClauseNo :: Int                -- ^ The number of the clause of this function.
  , ipcType     :: Type               -- ^ The type of the function
  , ipcWithSub  :: Maybe Substitution -- ^ Module parameter substitution
  , ipcClause   :: A.SpineClause      -- ^ The original AST clause.
  , ipcClosure  :: Closure ()         -- ^ Environment for rechecking the clause.
  , ipcBoundary :: [Closure IPBoundary] -- ^ The boundary imposed by the LHS.
  }
  | IPNoClause -- ^ The interaction point is not in the rhs of a clause.
  deriving (Data)

instance Eq IPClause where
  IPNoClause           == IPNoClause             = True
  IPClause x i _ _ _ _ _ == IPClause x' i' _ _ _ _ _ = x == x' && i == i'
  _                    == _                      = False

---------------------------------------------------------------------------
-- ** Signature
---------------------------------------------------------------------------

data Signature = Sig
      { _sigSections    :: Sections
      , _sigDefinitions :: Definitions
      , _sigRewriteRules:: RewriteRuleMap  -- ^ The rewrite rules defined in this file.
      }
  deriving (Data, Show)

sigSections :: Lens' Sections Signature
sigSections f s =
  f (_sigSections s) <&>
  \x -> s {_sigSections = x}

sigDefinitions :: Lens' Definitions Signature
sigDefinitions f s =
  f (_sigDefinitions s) <&>
  \x -> s {_sigDefinitions = x}

sigRewriteRules :: Lens' RewriteRuleMap Signature
sigRewriteRules f s =
  f (_sigRewriteRules s) <&>
  \x -> s {_sigRewriteRules = x}

type Sections    = Map ModuleName Section
type Definitions = HashMap QName Definition
type RewriteRuleMap = HashMap QName RewriteRules
type DisplayForms = HashMap QName [LocalDisplayForm]

newtype Section = Section { _secTelescope :: Telescope }
  deriving (Data, Show)

instance Pretty Section where
  pretty = pretty . _secTelescope

secTelescope :: Lens' Telescope Section
secTelescope f s =
  f (_secTelescope s) <&>
  \x -> s {_secTelescope = x}

emptySignature :: Signature
emptySignature = Sig Map.empty HMap.empty HMap.empty

-- | A @DisplayForm@ is in essence a rewrite rule
--   @
--      q ts --> dt
--   @
--   for a defined symbol (could be a constructor as well) @q@.
--   The right hand side is a 'DisplayTerm' which is used to
--   'reify' to a more readable 'Abstract.Syntax'.
--
--   The patterns @ts@ are just terms, but @var 0@ is interpreted
--   as a hole.  Each occurrence of @var 0@ is a new hole (pattern var).
--   For each *occurrence* of @var0@ the rhs @dt@ has a free variable.
--   These are instantiated when matching a display form against a
--   term @q vs@ succeeds.
data DisplayForm = Display
  { dfFreeVars :: Nat
    -- ^ Number @n@ of free variables in 'dfRHS'.
  , dfPats     :: Elims
    -- ^ Left hand side patterns, where @var 0@ stands for a pattern
    --   variable.  There should be @n@ occurrences of @var0@ in
    --   'dfPats'.
    --   The 'ArgInfo' is ignored in these patterns.
  , dfRHS      :: DisplayTerm
    -- ^ Right hand side, with @n@ free variables.
  }
  deriving (Data, Show)

type LocalDisplayForm = Open DisplayForm

-- | A structured presentation of a 'Term' for reification into
--   'Abstract.Syntax'.
data DisplayTerm
  = DWithApp DisplayTerm [DisplayTerm] Elims
    -- ^ @(f vs | ws) es@.
    --   The first 'DisplayTerm' is the parent function @f@ with its args @vs@.
    --   The list of 'DisplayTerm's are the with expressions @ws@.
    --   The 'Elims' are additional arguments @es@
    --   (possible in case the with-application is of function type)
    --   or projections (if it is of record type).
  | DCon ConHead ConInfo [Arg DisplayTerm]
    -- ^ @c vs@.
  | DDef QName [Elim' DisplayTerm]
    -- ^ @d vs@.
  | DDot Term
    -- ^ @.v@.
  | DTerm Term
    -- ^ @v@.
  deriving (Data, Show)

instance Free DisplayForm where
  freeVars' (Display n ps t) = underBinder (freeVars' ps) `mappend` underBinder' n (freeVars' t)

instance Free DisplayTerm where
  freeVars' (DWithApp t ws es) = freeVars' (t, (ws, es))
  freeVars' (DCon _ _ vs)      = freeVars' vs
  freeVars' (DDef _ es)        = freeVars' es
  freeVars' (DDot v)           = freeVars' v
  freeVars' (DTerm v)          = freeVars' v

instance Pretty DisplayTerm where
  prettyPrec p v =
    case v of
      DTerm v          -> prettyPrec p v
      DDot v           -> "." <> prettyPrec 10 v
      DDef f es        -> pretty f `pApp` es
      DCon c _ vs      -> pretty (conName c) `pApp` map Apply vs
      DWithApp h ws es ->
        mparens (p > 0)
          (sep [ pretty h
              , nest 2 $ fsep [ "|" <+> pretty w | w <- ws ] ])
        `pApp` es
    where
      pApp :: Pretty el => Doc -> [el] -> Doc
      pApp d els = mparens (not (null els) && p > 9) $
                   sep [d, nest 2 $ fsep (map (prettyPrec 10) els)]

-- | By default, we have no display form.
defaultDisplayForm :: QName -> [LocalDisplayForm]
defaultDisplayForm c = []

-- | Non-linear (non-constructor) first-order pattern.
data NLPat
  = PVar !Int [Arg Int]
    -- ^ Matches anything (modulo non-linearity) that only contains bound
    --   variables that occur in the given arguments.
  | PDef QName PElims
    -- ^ Matches @f es@
  | PLam ArgInfo (Abs NLPat)
    -- ^ Matches @λ x → t@
  | PPi (Dom NLPType) (Abs NLPType)
    -- ^ Matches @(x : A) → B@
  | PSort NLPSort
    -- ^ Matches a sort of the given shape.
  | PBoundVar {-# UNPACK #-} !Int PElims
    -- ^ Matches @x es@ where x is a lambda-bound variable
  | PTerm Term
    -- ^ Matches the term modulo β (ideally βη).
  deriving (Data, Show)
type PElims = [Elim' NLPat]

data NLPType = NLPType
  { nlpTypeSort :: NLPSort
  , nlpTypeUnEl :: NLPat
  } deriving (Data, Show)

data NLPSort
  = PType NLPat
  | PProp NLPat
  | PInf IsFibrant Integer
  | PSizeUniv
  | PLockUniv
  deriving (Data, Show)

type RewriteRules = [RewriteRule]

-- | Rewrite rules can be added independently from function clauses.
data RewriteRule = RewriteRule
  { rewName    :: QName      -- ^ Name of rewrite rule @q : Γ → f ps ≡ rhs@
                             --   where @≡@ is the rewrite relation.
  , rewContext :: Telescope  -- ^ @Γ@.
  , rewHead    :: QName      -- ^ @f@.
  , rewPats    :: PElims     -- ^ @Γ ⊢ f ps : t@.
  , rewRHS     :: Term       -- ^ @Γ ⊢ rhs : t@.
  , rewType    :: Type       -- ^ @Γ ⊢ t@.
  , rewFromClause :: Bool    -- ^ Was this rewrite rule created from a clause in the definition of the function?
  }
    deriving (Data, Show)

data Definition = Defn
  { defArgInfo        :: ArgInfo -- ^ Hiding should not be used.
  , defName           :: QName   -- ^ The canonical name, used e.g. in compilation.
  , defType           :: Type    -- ^ Type of the lifted definition.
  , defPolarity       :: [Polarity]
    -- ^ Variance information on arguments of the definition.
    --   Does not include info for dropped parameters to
    --   projection(-like) functions and constructors.
  , defArgOccurrences :: [Occurrence]
    -- ^ Positivity information on arguments of the definition.
    --   Does not include info for dropped parameters to
    --   projection(-like) functions and constructors.

    --   Sometimes Agda looks up 'Occurrence's in these lists based on
    --   their position, so one might consider replacing the list
    --   with, say, an 'IntMap'. However, presumably these lists tend
    --   to be short, in which case 'IntMap's could be slower than
    --   lists. For instance, at one point the longest list
    --   encountered for the standard library (in serialised
    --   interfaces) had length 27. Distribution:
    --
    --   Length, number of lists
    --   -----------------------
    --
    --    0, 2444
    --    1,  721
    --    2,  433
    --    3,  668
    --    4,  602
    --    5,  624
    --    6,  626
    --    7,  484
    --    8,  375
    --    9,  264
    --   10,  305
    --   11,  188
    --   12,  171
    --   13,  108
    --   14,   84
    --   15,   80
    --   16,   38
    --   17,   23
    --   18,   16
    --   19,    8
    --   20,    7
    --   21,    5
    --   22,    2
    --   23,    3
    --   27,    1

  , defArgGeneralizable :: NumGeneralizableArgs
    -- ^ How many arguments should be generalised.
  , defGeneralizedParams :: [Maybe Name]
    -- ^ Gives the name of the (bound variable) parameter for named generalized
    --   parameters. This is needed to bring it into scope when type checking
    --   the data/record definition corresponding to a type with generalized
    --   parameters.
  , defDisplay        :: [LocalDisplayForm]
  , defMutual         :: MutualId
  , defCompiledRep    :: CompiledRepresentation
  , defInstance       :: Maybe QName
    -- ^ @Just q@ when this definition is an instance of class q
  , defCopy           :: Bool
    -- ^ Has this function been created by a module
                         -- instantiation?
  , defMatchable      :: Set QName
    -- ^ The set of symbols with rewrite rules that match against this symbol
  , defNoCompilation  :: Bool
    -- ^ should compilers skip this? Used for e.g. cubical's comp
  , defInjective      :: Bool
    -- ^ Should the def be treated as injective by the pattern matching unifier?
  , defCopatternLHS   :: Bool
    -- ^ Is this a function defined by copatterns?
  , defBlocked        :: Blocked_
    -- ^ What blocking tag to use when we cannot reduce this def?
    --   Used when checking a function definition is blocked on a meta
    --   in the type.
  , theDef            :: Defn
  }
    deriving (Data, Show)

instance LensArgInfo Definition where
  getArgInfo = defArgInfo
  mapArgInfo f def = def { defArgInfo = f $ defArgInfo def }

instance LensModality  Definition where
instance LensQuantity  Definition where
instance LensRelevance Definition where

data NumGeneralizableArgs
  = NoGeneralizableArgs
  | SomeGeneralizableArgs Int
    -- ^ When lambda-lifting new args are generalizable if
    --   'SomeGeneralizableArgs', also when the number is zero.
  deriving (Data, Show)

theDefLens :: Lens' Defn Definition
theDefLens f d = f (theDef d) <&> \ df -> d { theDef = df }

-- | Create a definition with sensible defaults.
defaultDefn :: ArgInfo -> QName -> Type -> Defn -> Definition
defaultDefn info x t def = Defn
  { defArgInfo        = info
  , defName           = x
  , defType           = t
  , defPolarity       = []
  , defArgOccurrences = []
  , defArgGeneralizable = NoGeneralizableArgs
  , defGeneralizedParams = []
  , defDisplay        = defaultDisplayForm x
  , defMutual         = 0
  , defCompiledRep    = noCompiledRep
  , defInstance       = Nothing
  , defCopy           = False
  , defMatchable      = Set.empty
  , defNoCompilation  = False
  , defInjective      = False
  , defCopatternLHS   = False
  , defBlocked        = NotBlocked ReallyNotBlocked ()
  , theDef            = def
  }

-- | Polarity for equality and subtype checking.
data Polarity
  = Covariant      -- ^ monotone
  | Contravariant  -- ^ antitone
  | Invariant      -- ^ no information (mixed variance)
  | Nonvariant     -- ^ constant
  deriving (Data, Show, Eq)

instance Pretty Polarity where
  pretty = text . \case
    Covariant     -> "+"
    Contravariant -> "-"
    Invariant     -> "*"
    Nonvariant    -> "_"

-- | Information about whether an argument is forced by the type of a function.
data IsForced
  = Forced
  | NotForced
  deriving (Data, Show, Eq)

-- | The backends are responsible for parsing their own pragmas.
data CompilerPragma = CompilerPragma Range String
  deriving (Data, Show, Eq)

instance HasRange CompilerPragma where
  getRange (CompilerPragma r _) = r

type BackendName    = String

jsBackendName, ghcBackendName :: BackendName
jsBackendName  = "JS"
ghcBackendName = "GHC"

type CompiledRepresentation = Map BackendName [CompilerPragma]

noCompiledRep :: CompiledRepresentation
noCompiledRep = Map.empty

-- A face represented as a list of equality constraints.
-- (r,False) ↦ (r = i0)
-- (r,True ) ↦ (r = i1)
type Face = [(Term,Bool)]

-- | An alternative representation of partial elements in a telescope:
--   Γ ⊢ λ Δ. [φ₁ u₁, ... , φₙ uₙ] : Δ → PartialP (∨_ᵢ φᵢ) T
--   see cubicaltt paper (however we do not store the type T).
data System = System
  { systemTel :: Telescope
    -- ^ the telescope Δ, binding vars for the clauses, Γ ⊢ Δ
  , systemClauses :: [(Face,Term)]
    -- ^ a system [φ₁ u₁, ... , φₙ uₙ] where Γ, Δ ⊢ φᵢ and Γ, Δ, φᵢ ⊢ uᵢ
  } deriving (Data, Show)

-- | Additional information for extended lambdas.
data ExtLamInfo = ExtLamInfo
  { extLamModule    :: ModuleName
    -- ^ For complicated reasons the scope checker decides the QName of a
    --   pattern lambda, and thus its module. We really need to decide the
    --   module during type checking though, since if the lambda appears in a
    --   refined context the module picked by the scope checker has very much
    --   the wrong parameters.
  , extLamAbsurd :: Bool
    -- ^ Was this definition created from an absurd lambda @λ ()@?
  , extLamSys :: !(Strict.Maybe System)
  } deriving (Data, Show)

modifySystem :: (System -> System) -> ExtLamInfo -> ExtLamInfo
modifySystem f e = let !e' = e { extLamSys = f <$> extLamSys e } in e'

-- | Additional information for projection 'Function's.
data Projection = Projection
  { projProper    :: Maybe QName
    -- ^ @Nothing@ if only projection-like, @Just r@ if record projection.
    --   The @r@ is the name of the record type projected from.
    --   This field is updated by module application.
  , projOrig      :: QName
    -- ^ The original projection name
    --   (current name could be from module application).
  , projFromType  :: Arg QName
    -- ^ Type projected from. Original record type if @projProper = Just{}@.
    --   Also stores @ArgInfo@ of the principal argument.
    --   This field is unchanged by module application.
  , projIndex     :: Int
    -- ^ Index of the record argument.
    --   Start counting with 1, because 0 means that
    --   it is already applied to the record value.
    --   This can happen in module instantiation, but
    --   then either the record value is @var 0@, or @funProjection == Nothing@.
  , projLams :: ProjLams
    -- ^ Term @t@ to be be applied to record parameters and record value.
    --   The parameters will be dropped.
    --   In case of a proper projection, a postfix projection application
    --   will be created: @t = \ pars r -> r .p@
    --   (Invariant: the number of abstractions equals 'projIndex'.)
    --   In case of a projection-like function, just the function symbol
    --   is returned as 'Def':  @t = \ pars -> f@.
  } deriving (Data, Show)

-- | Abstractions to build projection function (dropping parameters).
newtype ProjLams = ProjLams { getProjLams :: [Arg ArgName] }
  deriving (Data, Show, Null)

-- | Building the projection function (which drops the parameters).
projDropPars :: Projection -> ProjOrigin -> Term
-- Proper projections:
projDropPars (Projection Just{} d _ _ lams) o =
  case initLast $ getProjLams lams of
    Nothing -> Def d []
    Just (pars, Arg i y) ->
      let core = Lam i $ Abs y $ Var 0 [Proj o d] in
      List.foldr (\ (Arg ai x) -> Lam ai . NoAbs x) core pars
-- Projection-like functions:
projDropPars (Projection Nothing _ _ _ lams) o | null lams = __IMPOSSIBLE__
projDropPars (Projection Nothing d _ _ lams) o =
  List.foldr (\ (Arg ai x) -> Lam ai . NoAbs x) (Def d []) $ init $ getProjLams lams

-- | The info of the principal (record) argument.
projArgInfo :: Projection -> ArgInfo
projArgInfo (Projection _ _ _ _ lams) =
  maybe __IMPOSSIBLE__ getArgInfo $ lastMaybe $ getProjLams lams

-- | Should a record type admit eta-equality?
data EtaEquality
  = Specified { theEtaEquality :: !HasEta }  -- ^ User specifed 'eta-equality' or 'no-eta-equality'.
  | Inferred  { theEtaEquality :: !HasEta }  -- ^ Positivity checker inferred whether eta is safe.
  deriving (Data, Show, Eq)

instance PatternMatchingAllowed EtaEquality where
  patternMatchingAllowed = patternMatchingAllowed . theEtaEquality

instance CopatternMatchingAllowed EtaEquality where
  copatternMatchingAllowed = copatternMatchingAllowed . theEtaEquality

-- | Make sure we do not overwrite a user specification.
setEtaEquality :: EtaEquality -> HasEta -> EtaEquality
setEtaEquality e@Specified{} _ = e
setEtaEquality _ b = Inferred b

data FunctionFlag
  = FunStatic  -- ^ Should calls to this function be normalised at compile-time?
  | FunInline  -- ^ Should calls to this function be inlined by the compiler?
  | FunMacro   -- ^ Is this function a macro?
  deriving (Data, Eq, Ord, Enum, Show)

data CompKit = CompKit
  { nameOfHComp :: Maybe QName
  , nameOfTransp :: Maybe QName
  }
  deriving (Data, Eq, Ord, Show)

emptyCompKit :: CompKit
emptyCompKit = CompKit Nothing Nothing

data Defn = Axiom -- ^ Postulate
          | DataOrRecSig
            { datarecPars :: Int }
            -- ^ Data or record type signature that doesn't yet have a definition
          | GeneralizableVar -- ^ Generalizable variable (introduced in `generalize` block)
          | AbstractDefn Defn
            -- ^ Returned by 'getConstInfo' if definition is abstract.
          | Function
            { funClauses        :: [Clause]
            , funCompiled       :: Maybe CompiledClauses
              -- ^ 'Nothing' while function is still type-checked.
              --   @Just cc@ after type and coverage checking and
              --   translation to case trees.
            , funSplitTree      :: Maybe SplitTree
              -- ^ The split tree constructed by the coverage
              --   checker. Needed to re-compile the clauses after
              --   forcing translation.
            , funTreeless       :: Maybe Compiled
              -- ^ Intermediate representation for compiler backends.
            , funCovering       :: [Clause]
              -- ^ Covering clauses computed by coverage checking.
              --   Erased by (IApply) confluence checking(?)
            , funInv            :: FunctionInverse
            , funMutual         :: Maybe [QName]
              -- ^ Mutually recursive functions, @data@s and @record@s.
              --   Does include this function.
              --   Empty list if not recursive.
              --   @Nothing@ if not yet computed (by positivity checker).
            , funAbstr          :: IsAbstract
            , funDelayed        :: Delayed
              -- ^ Are the clauses of this definition delayed?
            , funProjection     :: Maybe Projection
              -- ^ Is it a record projection?
              --   If yes, then return the name of the record type and index of
              --   the record argument.  Start counting with 1, because 0 means that
              --   it is already applied to the record. (Can happen in module
              --   instantiation.) This information is used in the termination
              --   checker.
            , funFlags          :: Set FunctionFlag
            , funTerminates     :: Maybe Bool
              -- ^ Has this function been termination checked?  Did it pass?
            , funExtLam         :: Maybe ExtLamInfo
              -- ^ Is this function generated from an extended lambda?
              --   If yes, then return the number of hidden and non-hidden lambda-lifted arguments
            , funWith           :: Maybe QName
              -- ^ Is this a generated with-function? If yes, then what's the
              --   name of the parent function.
            }
          | Datatype
            { dataPars           :: Nat            -- ^ Number of parameters.
            , dataIxs            :: Nat            -- ^ Number of indices.
            , dataClause         :: (Maybe Clause) -- ^ This might be in an instantiated module.
            , dataCons           :: [QName]
              -- ^ Constructor names , ordered according to the order of their definition.
            , dataSort           :: Sort
            , dataMutual         :: Maybe [QName]
              -- ^ Mutually recursive functions, @data@s and @record@s.
              --   Does include this data type.
              --   Empty if not recursive.
              --   @Nothing@ if not yet computed (by positivity checker).
            , dataAbstr          :: IsAbstract
            , dataPathCons       :: [QName]        -- ^ Path constructor names (subset of dataCons)
            }
          | Record
            { recPars           :: Nat
              -- ^ Number of parameters.
            , recClause         :: Maybe Clause
              -- ^ Was this record type created by a module application?
              --   If yes, the clause is its definition (linking back to the original record type).
            , recConHead        :: ConHead
              -- ^ Constructor name and fields.
            , recNamedCon       :: Bool
              -- ^ Does this record have a @constructor@?
            , recFields         :: [Dom QName]
              -- ^ The record field names.
            , recTel            :: Telescope
              -- ^ The record field telescope. (Includes record parameters.)
              --   Note: @TelV recTel _ == telView' recConType@.
              --   Thus, @recTel@ is redundant.
            , recMutual         :: Maybe [QName]
              -- ^ Mutually recursive functions, @data@s and @record@s.
              --   Does include this record.
              --   Empty if not recursive.
              --   @Nothing@ if not yet computed (by positivity checker).
            , recEtaEquality'    :: EtaEquality
              -- ^ Eta-expand at this record type?
              --   @False@ for unguarded recursive records and coinductive records
              --   unless the user specifies otherwise.
            , recPatternMatching :: PatternOrCopattern
              -- ^ In case eta-equality is off, do we allow pattern matching on the
              --   constructor or construction by copattern matching?
              --   Having both loses subject reduction, see issue #4560.
              --   After positivity checking, this field is obsolete, part of 'EtaEquality'.
            , recInduction      :: Maybe Induction
              -- ^ 'Inductive' or 'CoInductive'?  Matters only for recursive records.
              --   'Nothing' means that the user did not specify it, which is an error
              --   for recursive records.
            , recAbstr          :: IsAbstract
            , recComp           :: CompKit
            }
          | Constructor
            { conPars   :: Int         -- ^ Number of parameters.
            , conArity  :: Int         -- ^ Number of arguments (excluding parameters).
            , conSrcCon :: ConHead     -- ^ Name of (original) constructor and fields. (This might be in a module instance.)
            , conData   :: QName       -- ^ Name of datatype or record type.
            , conAbstr  :: IsAbstract
            , conInd    :: Induction   -- ^ Inductive or coinductive?
            , conComp   :: CompKit     -- ^ Cubical composition.
            , conProj   :: Maybe [QName] -- ^ Projections. 'Nothing' if not yet computed.
            , conForced :: [IsForced]
              -- ^ Which arguments are forced (i.e. determined by the type of the constructor)?
              --   Either this list is empty (if the forcing analysis isn't run), or its length is @conArity@.
            , conErased :: Maybe [Bool]
              -- ^ Which arguments are erased at runtime (computed during compilation to treeless)?
              --   'True' means erased, 'False' means retained.
              --   'Nothing' if no erasure analysis has been performed yet.
              --   The length of the list is @conArity@.
            }
          | Primitive
            { primAbstr :: IsAbstract
            , primName  :: String
            , primClauses :: [Clause]
              -- ^ 'null' for primitive functions, @not null@ for builtin functions.
            , primInv      :: FunctionInverse
              -- ^ Builtin functions can have inverses. For instance, natural number addition.
            , primCompiled :: Maybe CompiledClauses
              -- ^ 'Nothing' for primitive functions,
              --   @'Just' something@ for builtin functions.
            }
            -- ^ Primitive or builtin functions.
          | PrimitiveSort
            { primName :: String
            , primSort :: Sort
            }
    deriving (Data, Show)

instance Pretty Definition where
  pretty Defn{..} =
    "Defn {" <?> vcat
      [ "defArgInfo        =" <?> pshow defArgInfo
      , "defName           =" <?> pretty defName
      , "defType           =" <?> pretty defType
      , "defPolarity       =" <?> pshow defPolarity
      , "defArgOccurrences =" <?> pshow defArgOccurrences
      , "defGeneralizedParams =" <?> pshow defGeneralizedParams
      , "defDisplay        =" <?> pshow defDisplay -- TODO: pretty DisplayForm
      , "defMutual         =" <?> pshow defMutual
      , "defCompiledRep    =" <?> pshow defCompiledRep
      , "defInstance       =" <?> pshow defInstance
      , "defCopy           =" <?> pshow defCopy
      , "defMatchable      =" <?> pshow (Set.toList defMatchable)
      , "defInjective      =" <?> pshow defInjective
      , "defCopatternLHS   =" <?> pshow defCopatternLHS
      , "theDef            =" <?> pretty theDef ] <+> "}"

instance Pretty Defn where
  pretty Axiom = "Axiom"
  pretty (DataOrRecSig n)   = "DataOrRecSig" <+> pretty n
  pretty GeneralizableVar{} = "GeneralizableVar"
  pretty (AbstractDefn def) = "AbstractDefn" <?> parens (pretty def)
  pretty Function{..} =
    "Function {" <?> vcat
      [ "funClauses      =" <?> vcat (map pretty funClauses)
      , "funCompiled     =" <?> pretty funCompiled
      , "funSplitTree    =" <?> pretty funSplitTree
      , "funTreeless     =" <?> pshow funTreeless
      , "funInv          =" <?> pshow funInv
      , "funMutual       =" <?> pshow funMutual
      , "funAbstr        =" <?> pshow funAbstr
      , "funDelayed      =" <?> pshow funDelayed
      , "funProjection   =" <?> pshow funProjection
      , "funFlags        =" <?> pshow funFlags
      , "funTerminates   =" <?> pshow funTerminates
      , "funWith         =" <?> pretty funWith ] <?> "}"
  pretty Datatype{..} =
    "Datatype {" <?> vcat
      [ "dataPars       =" <?> pshow dataPars
      , "dataIxs        =" <?> pshow dataIxs
      , "dataClause     =" <?> pretty dataClause
      , "dataCons       =" <?> pshow dataCons
      , "dataSort       =" <?> pretty dataSort
      , "dataMutual     =" <?> pshow dataMutual
      , "dataAbstr      =" <?> pshow dataAbstr ] <?> "}"
  pretty Record{..} =
    "Record {" <?> vcat
      [ "recPars         =" <?> pshow recPars
      , "recClause       =" <?> pretty recClause
      , "recConHead      =" <?> pshow recConHead
      , "recNamedCon     =" <?> pshow recNamedCon
      , "recFields       =" <?> pshow recFields
      , "recTel          =" <?> pretty recTel
      , "recMutual       =" <?> pshow recMutual
      , "recEtaEquality' =" <?> pshow recEtaEquality'
      , "recInduction    =" <?> pshow recInduction
      , "recAbstr        =" <?> pshow recAbstr ] <?> "}"
  pretty Constructor{..} =
    "Constructor {" <?> vcat
      [ "conPars   =" <?> pshow conPars
      , "conArity  =" <?> pshow conArity
      , "conSrcCon =" <?> pshow conSrcCon
      , "conData   =" <?> pshow conData
      , "conAbstr  =" <?> pshow conAbstr
      , "conInd    =" <?> pshow conInd
      , "conErased =" <?> pshow conErased ] <?> "}"
  pretty Primitive{..} =
    "Primitive {" <?> vcat
      [ "primAbstr    =" <?> pshow primAbstr
      , "primName     =" <?> pshow primName
      , "primClauses  =" <?> pshow primClauses
      , "primCompiled =" <?> pshow primCompiled ] <?> "}"
  pretty PrimitiveSort{..} =
    "PrimitiveSort {" <?> vcat
      [ "primName =" <?> pshow primName
      , "primSort =" <?> pshow primSort
      ] <?> "}"


-- | Is the record type recursive?
recRecursive :: Defn -> Bool
recRecursive (Record { recMutual = Just qs }) = not $ null qs
recRecursive _ = __IMPOSSIBLE__

recEtaEquality :: Defn -> HasEta
recEtaEquality = theEtaEquality . recEtaEquality'

-- | A template for creating 'Function' definitions, with sensible defaults.
emptyFunction :: Defn
emptyFunction = Function
  { funClauses     = []
  , funCompiled    = Nothing
  , funSplitTree   = Nothing
  , funTreeless    = Nothing
  , funInv         = NotInjective
  , funMutual      = Nothing
  , funAbstr       = ConcreteDef
  , funDelayed     = NotDelayed
  , funProjection  = Nothing
  , funFlags       = Set.empty
  , funTerminates  = Nothing
  , funExtLam      = Nothing
  , funWith        = Nothing
  , funCovering    = []
  }

funFlag :: FunctionFlag -> Lens' Bool Defn
funFlag flag f def@Function{ funFlags = flags } =
  f (Set.member flag flags) <&>
  \ b -> def{ funFlags = (if b then Set.insert else Set.delete) flag flags }
funFlag _ f def = f False $> def

funStatic, funInline, funMacro :: Lens' Bool Defn
funStatic       = funFlag FunStatic
funInline       = funFlag FunInline
funMacro        = funFlag FunMacro

isMacro :: Defn -> Bool
isMacro = (^. funMacro)

-- | Checking whether we are dealing with a function yet to be defined.
isEmptyFunction :: Defn -> Bool
isEmptyFunction def =
  case def of
    Function { funClauses = [] } -> True
    _ -> False

isCopatternLHS :: [Clause] -> Bool
isCopatternLHS = List.any (List.any (isJust . A.isProjP) . namedClausePats)

recCon :: Defn -> QName
recCon Record{ recConHead } = conName recConHead
recCon _ = __IMPOSSIBLE__

defIsRecord :: Defn -> Bool
defIsRecord Record{} = True
defIsRecord _        = False

defIsDataOrRecord :: Defn -> Bool
defIsDataOrRecord Record{}   = True
defIsDataOrRecord Datatype{} = True
defIsDataOrRecord _          = False

defConstructors :: Defn -> [QName]
defConstructors Datatype{dataCons = cs} = cs
defConstructors Record{recConHead = c} = [conName c]
defConstructors _ = __IMPOSSIBLE__

newtype Fields = Fields [(C.Name, Type)]
  deriving Null

-- | Did we encounter a simplifying reduction?
--   In terms of CIC, that would be a iota-reduction.
--   In terms of Agda, this is a constructor or literal
--   pattern that matched.
--   Just beta-reduction (substitution) or delta-reduction
--   (unfolding of definitions) does not count as simplifying?

data Simplification = YesSimplification | NoSimplification
  deriving (Data, Eq, Show)

instance Null Simplification where
  empty = NoSimplification
  null  = (== NoSimplification)

instance Semigroup Simplification where
  YesSimplification <> _ = YesSimplification
  NoSimplification  <> s = s

instance Monoid Simplification where
  mempty = NoSimplification
  mappend = (<>)

data Reduced no yes
  = NoReduction no
  | YesReduction Simplification yes
  deriving Functor

redReturn :: a -> ReduceM (Reduced a' a)
redReturn = return . YesReduction YesSimplification

-- | Conceptually: @redBind m f k = either (return . Left . f) k =<< m@

redBind :: ReduceM (Reduced a a') -> (a -> b) ->
           (a' -> ReduceM (Reduced b b')) -> ReduceM (Reduced b b')
redBind ma f k = do
  r <- ma
  case r of
    NoReduction x    -> return $ NoReduction $ f x
    YesReduction _ y -> k y

-- | Three cases: 1. not reduced, 2. reduced, but blocked, 3. reduced, not blocked.
data IsReduced
  = NotReduced
  | Reduced    (Blocked ())

data MaybeReduced a = MaybeRed
  { isReduced     :: IsReduced
  , ignoreReduced :: a
  }
  deriving (Functor)

instance IsProjElim e => IsProjElim (MaybeReduced e) where
  isProjElim = isProjElim . ignoreReduced

type MaybeReducedArgs = [MaybeReduced (Arg Term)]
type MaybeReducedElims = [MaybeReduced Elim]

notReduced :: a -> MaybeReduced a
notReduced x = MaybeRed NotReduced x

reduced :: Blocked (Arg Term) -> MaybeReduced (Arg Term)
reduced b = MaybeRed (Reduced $ () <$ b) $ ignoreBlocking b

-- | Controlling 'reduce'.
data AllowedReduction
  = ProjectionReductions     -- ^ (Projection and) projection-like functions may be reduced.
  | InlineReductions         -- ^ Functions marked INLINE may be reduced.
  | CopatternReductions      -- ^ Copattern definitions may be reduced.
  | FunctionReductions       -- ^ Non-recursive functions and primitives may be reduced.
  | RecursiveReductions      -- ^ Even recursive functions may be reduced.
  | LevelReductions          -- ^ Reduce @'Level'@ terms.
  | TypeLevelReductions      -- ^ Allow @allReductions@ in types, even
                             --   if not allowed at term level (used
                             --   by confluence checker)
  | UnconfirmedReductions    -- ^ Functions whose termination has not (yet) been confirmed.
  | NonTerminatingReductions -- ^ Functions that have failed termination checking.
  deriving (Show, Eq, Ord, Enum, Bounded, Ix, Data)

type AllowedReductions = SmallSet AllowedReduction

-- | Not quite all reductions (skip non-terminating reductions)
allReductions :: AllowedReductions
allReductions = SmallSet.delete NonTerminatingReductions reallyAllReductions

reallyAllReductions :: AllowedReductions
reallyAllReductions = SmallSet.total

data ReduceDefs
  = OnlyReduceDefs (Set QName)
  | DontReduceDefs (Set QName)
  deriving (Data)

reduceAllDefs :: ReduceDefs
reduceAllDefs = DontReduceDefs empty

locallyReduceDefs :: MonadTCEnv m => ReduceDefs -> m a -> m a
locallyReduceDefs = locallyTC eReduceDefs . const

locallyReduceAllDefs :: MonadTCEnv m => m a -> m a
locallyReduceAllDefs = locallyReduceDefs reduceAllDefs

shouldReduceDef :: (MonadTCEnv m) => QName -> m Bool
shouldReduceDef f = asksTC envReduceDefs <&> \case
  OnlyReduceDefs defs -> f `Set.member` defs
  DontReduceDefs defs -> not $ f `Set.member` defs

instance Semigroup ReduceDefs where
  OnlyReduceDefs qs1 <> OnlyReduceDefs qs2 = OnlyReduceDefs $ Set.intersection qs1 qs2
  OnlyReduceDefs qs1 <> DontReduceDefs qs2 = OnlyReduceDefs $ Set.difference   qs1 qs2
  DontReduceDefs qs1 <> OnlyReduceDefs qs2 = OnlyReduceDefs $ Set.difference   qs2 qs1
  DontReduceDefs qs1 <> DontReduceDefs qs2 = DontReduceDefs $ Set.union        qs1 qs2

instance Monoid ReduceDefs where
  mempty  = reduceAllDefs
  mappend = (<>)


locallyReconstructed :: MonadTCEnv m => m a -> m a
locallyReconstructed = locallyTC eReconstructed . const $ True

isReconstructed :: (MonadTCEnv m) => m Bool
isReconstructed = asksTC envReconstructed

-- | Primitives

data PrimitiveImpl = PrimImpl Type PrimFun

data PrimFun = PrimFun
  { primFunName           :: QName
  , primFunArity          :: Arity
  , primFunImplementation :: [Arg Term] -> Int -> ReduceM (Reduced MaybeReducedArgs Term)
  }

primFun :: QName -> Arity -> ([Arg Term] -> ReduceM (Reduced MaybeReducedArgs Term)) -> PrimFun
primFun q ar imp = PrimFun q ar (\ args _ -> imp args)

defClauses :: Definition -> [Clause]
defClauses Defn{theDef = Function{funClauses = cs}}        = cs
defClauses Defn{theDef = Primitive{primClauses = cs}}      = cs
defClauses Defn{theDef = Datatype{dataClause = Just c}}    = [c]
defClauses Defn{theDef = Record{recClause = Just c}}       = [c]
defClauses _                                               = []

defCompiled :: Definition -> Maybe CompiledClauses
defCompiled Defn{theDef = Function {funCompiled  = mcc}} = mcc
defCompiled Defn{theDef = Primitive{primCompiled = mcc}} = mcc
defCompiled _ = Nothing

defParameters :: Definition -> Maybe Nat
defParameters Defn{theDef = Datatype{dataPars = n}} = Just n
defParameters Defn{theDef = Record  {recPars  = n}} = Just n
defParameters _                                     = Nothing

defInverse :: Definition -> FunctionInverse
defInverse Defn{theDef = Function { funInv  = inv }} = inv
defInverse Defn{theDef = Primitive{ primInv = inv }} = inv
defInverse _                                         = NotInjective

defCompilerPragmas :: BackendName -> Definition -> [CompilerPragma]
defCompilerPragmas b = reverse . fromMaybe [] . Map.lookup b . defCompiledRep
  -- reversed because we add new pragmas to the front of the list

-- | Are the clauses of this definition delayed?
defDelayed :: Definition -> Delayed
defDelayed Defn{theDef = Function{funDelayed = d}} = d
defDelayed _                                       = NotDelayed

-- | Has the definition failed the termination checker?
defNonterminating :: Definition -> Bool
defNonterminating Defn{theDef = Function{funTerminates = Just False}} = True
defNonterminating _                                                   = False

-- | Has the definition not termination checked or did the check fail?
defTerminationUnconfirmed :: Definition -> Bool
defTerminationUnconfirmed Defn{theDef = Function{funTerminates = Just True}} = False
defTerminationUnconfirmed Defn{theDef = Function{funTerminates = _        }} = True
defTerminationUnconfirmed _ = False

defAbstract :: Definition -> IsAbstract
defAbstract d = case theDef d of
    Axiom{}                   -> ConcreteDef
    DataOrRecSig{}            -> ConcreteDef
    GeneralizableVar{}        -> ConcreteDef
    AbstractDefn{}            -> AbstractDef
    Function{funAbstr = a}    -> a
    Datatype{dataAbstr = a}   -> a
    Record{recAbstr = a}      -> a
    Constructor{conAbstr = a} -> a
    Primitive{primAbstr = a}  -> a
    PrimitiveSort{}           -> ConcreteDef

defForced :: Definition -> [IsForced]
defForced d = case theDef d of
    Constructor{conForced = fs} -> fs
    Axiom{}                     -> []
    DataOrRecSig{}              -> []
    GeneralizableVar{}          -> []
    AbstractDefn{}              -> []
    Function{}                  -> []
    Datatype{}                  -> []
    Record{}                    -> []
    Primitive{}                 -> []
    PrimitiveSort{}             -> []

---------------------------------------------------------------------------
-- ** Injectivity
---------------------------------------------------------------------------

type FunctionInverse = FunctionInverse' Clause
type InversionMap c = Map TermHead [c]

data FunctionInverse' c
  = NotInjective
  | Inverse (InversionMap c)
  deriving (Data, Show, Functor)

data TermHead = SortHead
              | PiHead
              | ConsHead QName
              | VarHead Nat
              | UnknownHead
  deriving (Data, Eq, Ord, Show)

instance Pretty TermHead where
  pretty = \ case
    SortHead    -> "SortHead"
    PiHead      -> "PiHead"
    ConsHead q  -> "ConsHead" <+> pretty q
    VarHead i   -> text ("VarHead " ++ show i)
    UnknownHead -> "UnknownHead"

---------------------------------------------------------------------------
-- ** Mutual blocks
---------------------------------------------------------------------------

newtype MutualId = MutId Int32
  deriving (Data, Eq, Ord, Show, Num, Enum)

---------------------------------------------------------------------------
-- ** Statistics
---------------------------------------------------------------------------

type Statistics = Map String Integer

---------------------------------------------------------------------------
-- ** Trace
---------------------------------------------------------------------------

data Call
  = CheckClause Type A.SpineClause
  | CheckLHS A.SpineLHS
  | CheckPattern A.Pattern Telescope Type
  | CheckPatternLinearityType C.Name
  | CheckPatternLinearityValue C.Name
  | CheckLetBinding A.LetBinding
  | InferExpr A.Expr
  | CheckExprCall Comparison A.Expr Type
  | CheckDotPattern A.Expr Term
  | CheckProjection Range QName Type
  | IsTypeCall Comparison A.Expr Sort
  | IsType_ A.Expr
  | InferVar Name
  | InferDef QName
  | CheckArguments Range [NamedArg A.Expr] Type (Maybe Type)
  | CheckMetaSolution Range MetaId Type Term
  | CheckTargetType Range Type Type
  | CheckDataDef Range QName [A.LamBinding] [A.Constructor]
  | CheckRecDef Range QName [A.LamBinding] [A.Constructor]
  | CheckConstructor QName Telescope Sort A.Constructor
  | CheckConstructorFitsIn QName Type Sort
  | CheckFunDefCall Range QName [A.Clause] Bool
    -- ^ Highlight (interactively) if and only if the boolean is 'True'.
  | CheckPragma Range A.Pragma
  | CheckPrimitive Range QName A.Expr
  | CheckIsEmpty Range Type
  | CheckConfluence QName QName
  | CheckWithFunctionType Type
  | CheckSectionApplication Range ModuleName A.ModuleApplication
  | CheckNamedWhere ModuleName
  | ScopeCheckExpr C.Expr
  | ScopeCheckDeclaration NiceDeclaration
  | ScopeCheckLHS C.QName C.Pattern
  | NoHighlighting
  | ModuleContents  -- ^ Interaction command: show module contents.
  | SetRange Range  -- ^ used by 'setCurrentRange'
  deriving Data

instance Pretty Call where
    pretty CheckClause{}             = "CheckClause"
    pretty CheckLHS{}                = "CheckLHS"
    pretty CheckPattern{}            = "CheckPattern"
    pretty CheckPatternLinearityType{}  = "CheckPatternLinearityType"
    pretty CheckPatternLinearityValue{} = "CheckPatternLinearityValue"
    pretty InferExpr{}               = "InferExpr"
    pretty CheckExprCall{}           = "CheckExprCall"
    pretty CheckLetBinding{}         = "CheckLetBinding"
    pretty CheckProjection{}         = "CheckProjection"
    pretty IsTypeCall{}              = "IsTypeCall"
    pretty IsType_{}                 = "IsType_"
    pretty InferVar{}                = "InferVar"
    pretty InferDef{}                = "InferDef"
    pretty CheckArguments{}          = "CheckArguments"
    pretty CheckMetaSolution{}       = "CheckMetaSolution"
    pretty CheckTargetType{}         = "CheckTargetType"
    pretty CheckDataDef{}            = "CheckDataDef"
    pretty CheckRecDef{}             = "CheckRecDef"
    pretty CheckConstructor{}        = "CheckConstructor"
    pretty CheckConstructorFitsIn{}  = "CheckConstructorFitsIn"
    pretty CheckFunDefCall{}         = "CheckFunDefCall"
    pretty CheckPragma{}             = "CheckPragma"
    pretty CheckPrimitive{}          = "CheckPrimitive"
    pretty CheckWithFunctionType{}   = "CheckWithFunctionType"
    pretty CheckNamedWhere{}         = "CheckNamedWhere"
    pretty ScopeCheckExpr{}          = "ScopeCheckExpr"
    pretty ScopeCheckDeclaration{}   = "ScopeCheckDeclaration"
    pretty ScopeCheckLHS{}           = "ScopeCheckLHS"
    pretty CheckDotPattern{}         = "CheckDotPattern"
    pretty SetRange{}                = "SetRange"
    pretty CheckSectionApplication{} = "CheckSectionApplication"
    pretty CheckIsEmpty{}            = "CheckIsEmpty"
    pretty CheckConfluence{}         = "CheckConfluence"
    pretty NoHighlighting{}          = "NoHighlighting"
    pretty ModuleContents{}          = "ModuleContents"

instance HasRange Call where
    getRange (CheckClause _ c)               = getRange c
    getRange (CheckLHS lhs)                  = getRange lhs
    getRange (CheckPattern p _ _)            = getRange p
    getRange (CheckPatternLinearityType x)   = getRange x
    getRange (CheckPatternLinearityValue x)  = getRange x
    getRange (InferExpr e)                   = getRange e
    getRange (CheckExprCall _ e _)           = getRange e
    getRange (CheckLetBinding b)             = getRange b
    getRange (CheckProjection r _ _)         = r
    getRange (IsTypeCall cmp e s)            = getRange e
    getRange (IsType_ e)                     = getRange e
    getRange (InferVar x)                    = getRange x
    getRange (InferDef f)                    = getRange f
    getRange (CheckArguments r _ _ _)        = r
    getRange (CheckMetaSolution r _ _ _)     = r
    getRange (CheckTargetType r _ _)         = r
    getRange (CheckDataDef i _ _ _)          = getRange i
    getRange (CheckRecDef i _ _ _)           = getRange i
    getRange (CheckConstructor _ _ _ c)      = getRange c
    getRange (CheckConstructorFitsIn c _ _)  = getRange c
    getRange (CheckFunDefCall i _ _ _)       = getRange i
    getRange (CheckPragma r _)               = r
    getRange (CheckPrimitive i _ _)          = getRange i
    getRange CheckWithFunctionType{}         = noRange
    getRange (CheckNamedWhere m)             = getRange m
    getRange (ScopeCheckExpr e)              = getRange e
    getRange (ScopeCheckDeclaration d)       = getRange d
    getRange (ScopeCheckLHS _ p)             = getRange p
    getRange (CheckDotPattern e _)           = getRange e
    getRange (SetRange r)                    = r
    getRange (CheckSectionApplication r _ _) = r
    getRange (CheckIsEmpty r _)              = r
    getRange (CheckConfluence rule1 rule2)   = max (getRange rule1) (getRange rule2)
    getRange NoHighlighting                  = noRange
    getRange ModuleContents                  = noRange

---------------------------------------------------------------------------
-- ** Instance table
---------------------------------------------------------------------------

-- | The instance table is a @Map@ associating to every name of
--   record/data type/postulate its list of instances
type InstanceTable = Map QName (Set QName)

-- | When typechecking something of the following form:
--
--     instance
--       x : _
--       x = y
--
--   it's not yet known where to add @x@, so we add it to a list of
--   unresolved instances and we'll deal with it later.
type TempInstanceTable = (InstanceTable , Set QName)

---------------------------------------------------------------------------
-- ** Builtin things
---------------------------------------------------------------------------

data BuiltinDescriptor
  = BuiltinData (TCM Type) [String]
  | BuiltinDataCons (TCM Type)
  | BuiltinPrim String (Term -> TCM ())
  | BuiltinSort String
  | BuiltinPostulate Relevance (TCM Type)
  | BuiltinUnknown (Maybe (TCM Type)) (Term -> Type -> TCM ())
    -- ^ Builtin of any kind.
    --   Type can be checked (@Just t@) or inferred (@Nothing@).
    --   The second argument is the hook for the verification function.

data BuiltinInfo =
   BuiltinInfo { builtinName :: String
               , builtinDesc :: BuiltinDescriptor }

type BuiltinThings pf = Map String (Builtin pf)

data Builtin pf
        = Builtin Term
        | Prim pf
    deriving (Show, Functor, Foldable, Traversable)

---------------------------------------------------------------------------
-- * Highlighting levels
---------------------------------------------------------------------------

-- | How much highlighting should be sent to the user interface?

data HighlightingLevel
  = None
  | NonInteractive
  | Interactive
    -- ^ This includes both non-interactive highlighting and
    -- interactive highlighting of the expression that is currently
    -- being type-checked.
    deriving (Eq, Ord, Show, Read, Data)

-- | How should highlighting be sent to the user interface?

data HighlightingMethod
  = Direct
    -- ^ Via stdout.
  | Indirect
    -- ^ Both via files and via stdout.
    deriving (Eq, Show, Read, Data)

-- | @ifTopLevelAndHighlightingLevelIs l b m@ runs @m@ when we're
-- type-checking the top-level module and either the highlighting
-- level is /at least/ @l@ or @b@ is 'True'.

ifTopLevelAndHighlightingLevelIsOr ::
  MonadTCEnv tcm => HighlightingLevel -> Bool -> tcm () -> tcm ()
ifTopLevelAndHighlightingLevelIsOr l b m = do
  e <- askTC
  when (envHighlightingLevel e >= l || b) $
    case (envImportPath e) of
      -- No current module
      [] -> pure ()
      -- Top level ("main") module
      (_:[]) -> m
      -- Below the main module
      (_:_:_) -> pure ()

-- | @ifTopLevelAndHighlightingLevelIs l m@ runs @m@ when we're
-- type-checking the top-level module and the highlighting level is
-- /at least/ @l@.

ifTopLevelAndHighlightingLevelIs ::
  MonadTCEnv tcm => HighlightingLevel -> tcm () -> tcm ()
ifTopLevelAndHighlightingLevelIs l =
  ifTopLevelAndHighlightingLevelIsOr l False

---------------------------------------------------------------------------
-- * Directed tuples
---------------------------------------------------------------------------

data a :∈ b = a :∈ b
  deriving (Data, Show)

type b :∋ a = a :∈ b

instance Bifunctor (:∈) where bimap f g (a :∈ b) = f a :∈ g b
instance Bifoldable (:∈) where bifoldMap f g (a :∈ b) = bifoldMap f g (a,b)

pattern (:∋) :: forall a b. b -> a -> a :∈ b
pattern b :∋ a = a :∈ b
#if __GLASGOW_HASKELL__ >= 804
{-# COMPLETE (:∋) #-}
#endif

instance (AsTwin a, AsTwin b) => AsTwin (a :∈ b) where
  type AsTwin_ (a :∈ b) = AsTwin_ a :∈ AsTwin_ b
  asTwin (a :∈ b) = asTwin a :∈ asTwin b

instance (Pretty a, Pretty b) => Pretty (a :∈ b) where
  pretty (a :∈ b) = pretty a <+> "∈" <+> pretty b

---------------------------------------------------------------------------
-- * Heterogeneous contexts
---------------------------------------------------------------------------

-- | The context is in right-to-left order; i.e. each variable is bound
--   by all the preceding variables
-- newtype ContextHet' a = ContextHet { unContextHet :: [a] }
--  deriving (Data, Show, Functor, Foldable)
data ContextHet' a = Empty
                   | Entry (ISet ProblemId) {-# UNPACK #-} !(a :∈ (ContextHet' a))
  deriving (Data, Show)

instance Functor ContextHet' where
  fmap _ Empty = Empty
  fmap f (Entry b γ) = Entry b (bimap f (fmap f) γ)

instance Foldable ContextHet' where
  foldMap f Empty = mempty
  foldMap f (Entry _ γ) = bifoldMap f (foldMap f) γ

instance Semigroup (ContextHet' a) where
  Empty <> x     = x
  x     <> Empty = x
  (Entry b_a_γΓ (a :∈ γΓ)) <> δΔ =
    Entry (b_a_γΓ <> getPids δΔ) (a :∈ (γΓ <> δΔ))

instance Monoid (ContextHet' a) where
  mempty = Empty
  mappend = (<>)

class HasPids a where getPids :: a -> ISet ProblemId

instance HasPids (ContextHet' a) where
  getPids Empty = ISet.empty
  getPids (Entry b _) = b
instance (HasPids b) => HasPids (Name,b) where
  getPids (_,b) = getPids b
instance HasPids Name where
  getPids _ = ISet.empty
instance HasPids (TwinT'' a c) where
  getPids SingleT{} = ISet.empty
  getPids (TwinT{twinPid}) = twinPid
instance HasPids a => HasPids (Dom a) where
  getPids = getPids . unDom

type ContextEntry_ = Dom (Name, TwinT)
type ContextHet = ContextHet' ContextEntry_

type Context_' a = ContextHet' a
type Context_ = ContextHet

instance Pretty a => Pretty (Context_' a) where
  pretty = pretty . contextHetToList

infixr 5 :⊣
pattern (:⊣) :: a -> ContextHet' a -> ContextHet' a
pattern a :⊣ γΓ <- γΓ :⊢ a

infixl 5 :⊢
pattern (:⊢) :: ContextHet' a -> a -> ContextHet' a
pattern γΓ :⊢ a <- Entry _ (a :∈ γΓ)

infixl 5 ⊢:
(⊢:) :: (HasPids a) => ContextHet' a -> a -> ContextHet' a
(⊢:) = flip (⊣:)

infixl 5 ⊢!:
(⊢!:) :: (AsTwin a, AsTwin_ a ~ b) => ContextHet' a -> b -> ContextHet' a
(⊢!:) = flip (⊣!:)

infixr 5 ⊣!:
(⊣!:) :: (AsTwin a, AsTwin_ a ~ b) => b -> ContextHet' a -> ContextHet' a
a ⊣!: γΓ = Entry (getPids γΓ) (asTwin a :∈ γΓ)

infixr 5 ⊣:
(⊣:) :: (HasPids a) => a -> ContextHet' a -> ContextHet' a
a ⊣: γΓ = Entry (getPids a <> getPids γΓ) (a :∈ γΓ)

#if __GLASGOW_HASKELL__ >= 804
{-# COMPLETE Empty, (:⊢) #-}
{-# COMPLETE Empty, (:⊣) #-}
#endif

-- (⊣::), (⊢::) :: ContextHet' a -> ContextHet' a -> ContextHet' a
-- δΔ ⊣:: γΓ = δΔ <> γΓ
-- γΓ ⊢:: δΔ = δΔ ⊣:: γΓ

infixr 5 ⊣::
(⊣::) :: HasPids a => [a] -> ContextHet' a -> ContextHet' a
[]     ⊣:: γΓ = γΓ
(b:bs) ⊣:: γΓ = Entry (getPids b <> getPids γΓ') (b :∈ γΓ')
  where γΓ' = bs ⊣:: γΓ

(⊣!::) :: (AsTwin a, AsTwin_ a ~ b) => [b] -> ContextHet' a -> ContextHet' a
[]     ⊣!:: γΓ = γΓ
(b:bs) ⊣!:: γΓ = Entry (getPids γΓ) (asTwin b :∈ (bs ⊣!:: γΓ))


-- * Manipulating context as a list.

-- | > contextHetAsList (a :⊣ b :⊣ … :⊣ Empty)
--     (a:b:…:[])
-- Also: contextHetToList :: ContextHet -> [Dom (Name, TwinT)]
contextHetToList :: Context_' a -> [a]
contextHetToList Empty = []
contextHetToList (a :⊣ γΓ) = a:contextHetToList γΓ

contextHetFromList :: HasPids a => [a] -> Context_' a
contextHetFromList []     = Empty
contextHetFromList (a:as) = a ⊣: contextHetFromList as

-- * Switch heterogeneous context to a specific side
switchSide :: forall s a m. (HetSideIsType s, MonadTCEnv m) => m a -> m a
switchSide = unsafeModifyContext {- IdS -} (asTwin . twinAt @s)

{-# INLINE switchSide_ #-}
switchSide_ :: forall s a m. (HetSideIsType s, MonadTCEnv m) =>
  ((forall b n. MonadTCEnv n => n b -> n b) -> m a) -> m a
switchSide_ κ = do
  ctx <- asksTC envContext
  unsafeModifyContext {- IdS -} (asTwin . twinAt @s) (κ (unsafeModifyContext {- IdS -} (const ctx)))

-- * Heterogeneous telescope

type Telescope_ = Tele (Dom TwinT)

-- * Describing parts of twin contexts

data HetSide = LHS | RHS | Compat | Both

type H'LHS = Het 'LHS
type H'RHS = Het 'RHS
type H'Compat = Het 'Compat
type H'Both = Het 'Both

pattern H'LHS :: a -> H'LHS a
pattern H'LHS a = Het a

pattern H'RHS :: a -> H'RHS a
pattern H'RHS a = Het a

pattern H'Compat :: a -> H'Compat a
pattern H'Compat a = Het a

pattern H'Both :: a -> H'Both a
pattern H'Both a = Het a

#if __GLASGOW_HASKELL__ >= 804
{-# COMPLETE H'LHS #-}
{-# COMPLETE H'RHS #-}
{-# COMPLETE H'Compat #-}
{-# COMPLETE H'Both #-}
#endif

type OnSide = Het
type OnLHS = OnSide 'LHS
type OnRHS = OnSide 'RHS

pattern OnLHS :: a -> OnLHS a
pattern OnLHS a = Het a
pattern OnRHS :: a -> OnRHS a
pattern OnRHS a = Het a

#if __GLASGOW_HASKELL__ >= 804
{-# COMPLETE OnLHS #-}
{-# COMPLETE OnRHS #-}
#endif

onSide :: forall s a m b. (MonadAddContext m, HetSideIsType s) => (a -> m b) -> Het s a -> m (Het s b)
onSide κ = switchSide @s . traverse κ

onSide_ :: forall s a m b. (MonadAddContext m, HetSideIsType s) => (a -> m b) -> Het s a -> m b
onSide_ κ = fmap (unHet @s) . switchSide @s . traverse κ

-- Dependent type boilerplate
data instance SingT (a :: HetSide) where
  SLHS    :: SingT 'LHS
  SRHS    :: SingT 'RHS
  SCompat :: SingT 'Compat
  SBoth   :: SingT 'Both
instance Sing 'LHS    where sing = SLHS
instance Sing 'RHS    where sing = SRHS
instance Sing 'Both   where sing = SBoth
instance Sing 'Compat where sing = SCompat

-- | Distinguishes which sides of a twin type corresponds to a single type
type family HetSideIsType_ (s :: HetSide) :: Bool where
  HetSideIsType_ 'LHS    = 'True
  HetSideIsType_ 'RHS    = 'True
  HetSideIsType_ 'Compat = 'True
  HetSideIsType_ 'Both   = 'True
type HetSideIsType s = (Sing s, HetSideIsType_ s ~ 'True)

-- | Distinguishes which sides of a twin type corresponds to a single type
type family LeftOrRightSide_ (s :: HetSide) :: Bool where
  LeftOrRightSide_ 'LHS    = 'True
  LeftOrRightSide_ 'RHS    = 'True
  LeftOrRightSide_ 'Compat = 'False
  LeftOrRightSide_ 'Both   = 'False
type LeftOrRightSide s = (Sing s, LeftOrRightSide_ s ~ 'True)

-- | Distinguishes which sides of a twin type corresponds to a single type
type family AreSides_ (s₁ :: HetSide) (s₂ :: HetSide) :: Bool where
  AreSides_ 'LHS 'RHS = 'True
  AreSides_ 'RHS 'LHS = 'True
  AreSides_ _    _    = 'False
type AreSides s₁ s₂ = (LeftOrRightSide s₁, LeftOrRightSide s₂, AreSides_ s₁ s₂ ~ 'True)

newtype Het (side :: HetSide) t = Het { unHet :: t }
  deriving (Foldable, Traversable, Pretty)

deriving instance (Typeable side, Data t) => Data (Het side t)
deriving instance Show t => Show (Het side t)
deriving instance Functor (Het side)
instance AllMetas a => AllMetas (Het side a) where allMetas f xs = foldMap (allMetas f) xs

instance Decoration (Het s) where
  traverseF f = fmap coerce . f . coerce
  distributeF = traverseF id

instance Applicative (Het s) where
  pure = Het
  Het f <*> Het a = Het (f a)

instance Monad (Het s) where
  Het a >>= f = f a

instance (HetSideIsType side, Free a) => Free (Het side a) where
  freeVars' (Het a) = freeVars' a

instance TermLike a => TermLike (Het side a) where
  foldTerm f = foldTerm f . unHet

instance Apply a => Apply (Het s a) where
  apply t as = fmap (flip apply as) t
  applyE t es = fmap (flip applyE es) t

instance Suggest a => Suggest (Het s a) where
  suggestName = suggestName . twinAt @s

-- * Converting to and from twin types

class AsTwin b where
  type AsTwin_ b
  asTwin :: AsTwin_ b -> b
instance AsTwin b => AsTwin (CompareAs' b) where
  type AsTwin_ (CompareAs' b) = CompareAs' (AsTwin_ b)
  asTwin = fmap asTwin
instance AsTwin (TwinT'' b a) where
  type AsTwin_ (TwinT'' b a) = a
  asTwin = SingleT . Het @'Both
instance AsTwin ContextHet where
  type AsTwin_ ContextHet = Context
  asTwin = contextHetFromList . (fmap (fmap (fmap asTwin)))
instance AsTwin (Het side a) where
  type AsTwin_ (Het side a) = a
  asTwin = coerce
instance AsTwin a => AsTwin (Dom a) where
  type AsTwin_ (Dom a) = Dom (AsTwin_ a)
  asTwin = fmap asTwin
instance AsTwin () where type AsTwin_ () = (); asTwin = id
instance AsTwin a => AsTwin (Abs a) where
  type AsTwin_ (Abs a) = Abs (AsTwin_ a)
  asTwin = fmap asTwin
instance AsTwin a => AsTwin (Tele a) where
  type AsTwin_ (Tele a) = Tele (AsTwin_ a)
  asTwin = fmap asTwin
instance (AsTwin a, AsTwin b) => AsTwin (a, b) where
  type AsTwin_ (a, b) = (AsTwin_ a, AsTwin_ b)
  asTwin (a, b) = (asTwin a, asTwin b)
instance AsTwin Name where
  type AsTwin_ Name = Name
  asTwin = id

class TwinAt (s :: HetSide) a where
  type TwinAt_ s a
  twinAt :: a -> TwinAt_ s a

instance HetSideIsType s => TwinAt s (TwinT' a) where
  type TwinAt_ s (TwinT' a) = a
  {-# INLINE twinAt #-}
  twinAt (SingleT a) = unHet @'Both a
  twinAt TwinT{direction,twinPid,twinLHS,twinRHS} = case (sing :: SingT s) of
    SLHS    -> unHet @s $ twinLHS
    SRHS    -> unHet @s $ twinRHS
    SBoth   | ISet.null twinPid ->
                selectSmaller direction (unHet @'LHS twinLHS) (unHet @'RHS twinRHS)
            | otherwise -> __IMPOSSIBLE__
    SCompat -> __UNIMPLEMENTED__

instance TwinAt s a => TwinAt s (Name, a) where
  type TwinAt_ s (Name, a) = (Name, TwinAt_ s a)
  {-# INLINE twinAt #-}
  twinAt = fmap (twinAt @s)

instance TwinAt s a => TwinAt s (ArgName, a) where
  type TwinAt_ s (ArgName, a) = (ArgName, TwinAt_ s a)
  {-# INLINE twinAt #-}
  twinAt = fmap (twinAt @s)

instance TwinAt s a => TwinAt s (Dom a) where
  type TwinAt_ s (Dom a) = Dom (TwinAt_ s a)
  {-# INLINE twinAt #-}
  twinAt = fmap (twinAt @s)

instance TwinAt s a => TwinAt s (Abs a) where
  type TwinAt_ s (Abs a) = Abs (TwinAt_ s a)
  {-# INLINE twinAt #-}
  twinAt = fmap (twinAt @s)

instance TwinAt s a => TwinAt s (ContextHet' a) where
  type TwinAt_ s (ContextHet' a) = [TwinAt_ s a]
  {-# INLINE twinAt #-}
  twinAt = map (twinAt @s) . contextHetToList

instance TwinAt s (Het s a) where
  type TwinAt_ s (Het s a) = a
  {-# INLINE twinAt #-}
  twinAt = coerce

-- instance TwinAt 'Compat (Het 'LHS a) where
--   type TwinAt_ 'Compat (Het 'LHS a) = a
--   twinAt = coerce
--
-- instance TwinAt 'Compat (Het 'RHS a) where
--   type TwinAt_ 'Compat (Het 'RHS a) = a
--   twinAt = coerce

instance TwinAt s () where
  type TwinAt_ s () = ()
  {-# INLINE twinAt #-}
  twinAt = id

instance TwinAt s a => TwinAt s (CompareAs' a) where
  type TwinAt_ s (CompareAs' a) = CompareAs' (TwinAt_ s a)
  {-# INLINE twinAt #-}
  twinAt = fmap (twinAt @s)

instance TwinAt s a => TwinAt s (Tele a) where
  type TwinAt_ s (Tele a) = Tele (TwinAt_ s a)
  {-# INLINE twinAt #-}
  twinAt = fmap (twinAt @s)

instance TwinAt s a => TwinAt s (Maybe a) where
  type TwinAt_ s (Maybe a) = Maybe (TwinAt_ s a)
  {-# INLINE twinAt #-}
  twinAt = fmap (twinAt @s)

instance TwinAt s a => TwinAt s [a] where
  type TwinAt_ s [a] = [TwinAt_ s a]
  {-# INLINE twinAt #-}
  twinAt = fmap (twinAt @s)

instance TwinAt s a => TwinAt s (Elim' a) where
  type TwinAt_ s (Elim' a) = Elim' (TwinAt_ s a)
  {-# INLINE twinAt #-}
  twinAt = fmap (twinAt @s)

-- instance TwinAt s a => TwinAt s (Elim' a) where
--   type TwinAt_ s (Elim' a) = Elim' (TwinAt_ s a)
--   type TwinAt_ s (Elim' a) = Elim' (TwinAt_ s a)
--   twinAt = fmap (twinAt @s)

instance TwinAt s a => TwinAt s (Arg a) where
  type TwinAt_ s (Arg a) = Arg (TwinAt_ s a)
  {-# INLINE twinAt #-}
  twinAt = fmap (twinAt @s)

instance Sized ContextHet where
  size Empty = 0
  size (_ :⊣ γΓ) = 1 + size γΓ

type Type_ = TwinT
type TwinT = TwinT' Type
type TwinT' = TwinT'' Bool
data TwinT'' b a =
    SingleT { unSingleT :: OnSide 'Both a }
  | TwinT { twinPid    :: ISet ProblemId   -- ^ Unification problems which are sufficient
                                           --   for LHS and RHS to be equal
          , necessary  :: b                -- ^ Whether solving twinPid is necessary,
                                           --   not only sufficient.
          , direction  :: CompareDirection -- ^ Whether the putative associated constraint is
                                           --   ≤, ≡ or ≥
                                           --   The twin simplifies to the smaller of the
                                           --   two sides when the associated constraints are solved.
          , twinLHS    :: OnLHS a       -- ^ Left hand side of the twin
          , twinRHS    :: OnRHS a       -- ^ Right hand side of the twin
          }

-- Víctor (2021-02-24): Using these instances is risky, as they
-- sidestep the safeguards of
deriving instance Functor (TwinT'' b)
deriving instance Foldable (TwinT'' b)
deriving instance Traversable (TwinT'' b)

deriving instance (Data a, Data b) => Data (TwinT'' a b)
deriving instance (Show a, Show b) => Show (TwinT'' a b)
-- instance Applicative TwinT' where
--   pure a = SingleT (Het @'Both a)
--   (SingleT f) <*> (SingleT a) = SingleT (f <*> a)
--   (TwinT pid nec a b c) <*> (TwinT pid' nec' a' b' c') = TwinT (pid ++ pid') (nec && nec') (a <*> a') (b <*> b') (c <*> c')
--   (TwinT pid nec a b c) <*> SingleT (Het x) = TwinT pid nec (($x) <$> a) (($x) <$> b) (($x) <$> c)
--   (SingleT (Het f)) <*> (TwinT pid nec a b c) = TwinT pid nec (f <$> a) (f <$> b) (f <$> c)

instance Free () where
  freeVars' () = mempty

instance Free a => Free (TwinT' a) where
  freeVars' (SingleT a) = freeVars' a
  freeVars' (TwinT{twinLHS,twinRHS}) = freeVars' twinLHS <> freeVars' twinRHS

instance TermLike () where
  traverseTermM _ () = return ()
  foldTerm _ () = mempty

instance TermLike a => TermLike (TwinT' a) where
  traverseTermM f = \case
    SingleT a -> SingleT <$> traverseTermM f a
    TwinT{twinPid,direction,necessary,twinLHS=a,twinRHS=b} ->
      (\a' b' -> TwinT{twinPid,direction,necessary,twinLHS=a',twinRHS=b'}) <$>
        traverseTermM f a <*> traverseTermM f b

instance Pretty a => Pretty (TwinT' a) where
  pretty (SingleT a) = pretty a
  pretty (TwinT{twinPid,necessary,twinLHS=a,twinRHS=b}) =
    pretty a <> "‡"
             <> (if necessary then "" else "*")
             <> pretty twinPid
             <> pretty b

instance GetSort a => GetSort (Het s a) where
  getSort = getSort . unHet @s

instance GetSort a => GetSort (TwinT' a) where
  getSort (SingleT a) = getSort a
  getSort t@TwinT{direction,..} = selectSmaller direction lhs rhs
    where
      lhs = getSort twinLHS
      rhs = getSort twinRHS

-- | Unmark necessary bit after the twin has gone under a none-injective computation
twinDirty :: TwinT'' Bool a -> TwinT'' Bool a
twinDirty a@SingleT{} = a
twinDirty a@TwinT{}   = a{necessary = False}

---------------------------------------------------------------------------
-- * Type checking environment
---------------------------------------------------------------------------

-- envContextCompat :: TCEnv -> Context
-- envContextCompat = twinAt @'Compat . envContext

data TCEnv =
    TCEnv { envContext             :: ContextHet
          , envLetBindings         :: LetBindings
          , envCurrentModule       :: ModuleName
          , envCurrentPath         :: Maybe AbsolutePath
            -- ^ The path to the file that is currently being
            -- type-checked.  'Nothing' if we do not have a file
            -- (like in interactive mode see @CommandLine@).
          , envAnonymousModules    :: [(ModuleName, Nat)] -- ^ anonymous modules and their number of free variables
          , envImportPath          :: [C.TopLevelModuleName]
            -- ^ The module stack with the entry being the top-level module as
            --   Agda chases modules. It will be empty if there is no main
            --   module, will have a single entry for the top level module, or
            --   more when descending past the main module. This is used to
            --   detect import cycles and in some cases highlighting behavior.
            --   The level of a given module is not necessarily the same as the
            --   length, in the module dependency graph, of the shortest path
            --   from the top-level module; it depends on in which order Agda
            --   chooses to chase dependencies.
          , envMutualBlock         :: Maybe MutualId -- ^ the current (if any) mutual block
          , envTerminationCheck    :: TerminationCheck ()  -- ^ are we inside the scope of a termination pragma
          , envCoverageCheck       :: CoverageCheck        -- ^ are we inside the scope of a coverage pragma
          , envMakeCase            :: Bool                 -- ^ are we inside a make-case (if so, ignore forcing analysis in unifier)
          , envSolvingConstraints  :: Bool
                -- ^ Are we currently in the process of solving active constraints?
          , envCheckingWhere       :: Bool
                -- ^ Have we stepped into the where-declarations of a clause?
                --   Everything under a @where@ will be checked with this flag on.
          , envWorkingOnTypes      :: Bool
                -- ^ Are we working on types? Turned on by 'workOnTypes'.
          , envAssignMetas         :: Bool
            -- ^ Are we allowed to assign metas?
          , envActiveProblems      :: ISet ProblemId
          , envAbstractMode        :: AbstractMode
                -- ^ When checking the typesignature of a public definition
                --   or the body of a non-abstract definition this is true.
                --   To prevent information about abstract things leaking
                --   outside the module.
          , envModality            :: Modality
                -- ^ 'Relevance' component:
                -- Are we checking an irrelevant argument? (=@Irrelevant@)
                -- Then top-level irrelevant declarations are enabled.
                -- Other value: @Relevant@, then only relevant decls. are available.
                --
                -- 'Quantity' component:
                -- Are we checking a runtime-irrelevant thing? (='Quantity0')
                -- Then runtime-irrelevant things are usable.
                -- Other value: @Quantity1@, runtime relevant.
                -- @Quantityω@ is not allowed here, see Bob Atkey, LiCS 2018.
          , envSplitOnStrict       :: Bool
                -- ^ Are we currently case-splitting on a strict
                --   datatype (i.e. in SSet)? If yes, the
                --   pattern-matching unifier will solve reflexive
                --   equations even --without-K.
          , envDisplayFormsEnabled :: Bool
                -- ^ Sometimes we want to disable display forms.
          , envRange :: Range
          , envHighlightingRange :: Range
                -- ^ Interactive highlighting uses this range rather
                --   than 'envRange'.
          , envClause :: IPClause
                -- ^ What is the current clause we are type-checking?
                --   Will be recorded in interaction points in this clause.
          , envCall  :: Maybe (Closure Call)
                -- ^ what we're doing at the moment
          , envHighlightingLevel  :: HighlightingLevel
                -- ^ Set to 'None' when imported modules are
                --   type-checked.
          , envHighlightingMethod :: HighlightingMethod
          , envExpandLast :: ExpandHidden
                -- ^ When type-checking an alias f=e, we do not want
                -- to insert hidden arguments in the end, because
                -- these will become unsolved metas.
          , envAppDef :: Maybe QName
                -- ^ We are reducing an application of this function.
                -- (For debugging of incomplete matches only.)
          , envSimplification :: Simplification
                -- ^ Did we encounter a simplification (proper match)
                --   during the current reduction process?
          , envAllowedReductions :: AllowedReductions
          , envReduceDefs :: ReduceDefs
          , envReconstructed :: Bool
          , envInjectivityDepth :: Int
                -- ^ Injectivity can cause non-termination for unsolvable contraints
                --   (#431, #3067). Keep a limit on the nesting depth of injectivity
                --   uses.
          , envCompareBlocked :: Bool
                -- ^ When @True@, the conversion checker will consider
                --   all term constructors as injective, including
                --   blocked function applications and metas. Warning:
                --   this should only be used when not assigning any
                --   metas (e.g. when @envAssignMetas@ is @False@ or
                --   when running @pureEqualTerms@) or else we get
                --   non-unique meta solutions.
          , envPrintDomainFreePi :: Bool
                -- ^ When @True@, types will be omitted from printed pi types if they
                --   can be inferred.
          , envPrintMetasBare :: Bool
                -- ^ When @True@, throw away meta numbers and meta elims.
                --   This is used for reifying terms for feeding into the
                --   user's source code, e.g., for the interaction tactics @solveAll@.
          , envInsideDotPattern :: Bool
                -- ^ Used by the scope checker to make sure that certain forms
                --   of expressions are not used inside dot patterns: extended
                --   lambdas and let-expressions.
          , envUnquoteFlags :: UnquoteFlags
          , envInstanceDepth :: !Int
                -- ^ Until we get a termination checker for instance search (#1743) we
                --   limit the search depth to ensure termination.
          , envIsDebugPrinting :: Bool
          , envPrintingPatternLambdas :: [QName]
                -- ^ #3004: pattern lambdas with copatterns may refer to themselves. We
                --   don't have a good story for what to do in this case, but at least
                --   printing shouldn't loop. Here we keep track of which pattern lambdas
                --   we are currently in the process of printing.
          , envCallByNeed :: Bool
                -- ^ Use call-by-need evaluation for reductions.
          , envCurrentCheckpoint :: CheckpointId
                -- ^ Checkpoints track the evolution of the context as we go
                -- under binders or refine it by pattern matching.
          , envCheckpoints :: Map CheckpointId Substitution
                -- ^ Keeps the substitution from each previous checkpoint to
                --   the current context.
          , envGeneralizeMetas :: DoGeneralize
                -- ^ Should new metas generalized over.
          , envGeneralizedVars :: Map QName GeneralizedValue
                -- ^ Values for used generalizable variables.
          , envActiveBackendName :: Maybe BackendName
                -- ^ Is some backend active at the moment, and if yes, which?
                --   NB: we only store the 'BackendName' here, otherwise
                --   @instance Data TCEnv@ is not derivable.
                --   The actual backend can be obtained from the name via 'stBackends'.
          , envEffortLevel :: EffortLevel

          }
    deriving Data

initEnv :: TCEnv
initEnv = TCEnv { envContext             = Empty
                , envLetBindings         = Map.empty
                , envCurrentModule       = noModuleName
                , envCurrentPath         = Nothing
                , envAnonymousModules    = []
                , envImportPath          = []
                , envMutualBlock         = Nothing
                , envTerminationCheck    = TerminationCheck
                , envCoverageCheck       = YesCoverageCheck
                , envMakeCase            = False
                , envSolvingConstraints  = False
                , envCheckingWhere       = False
                , envActiveProblems      = ISet.empty
                , envWorkingOnTypes      = False
                , envAssignMetas         = True
                , envAbstractMode        = ConcreteMode
  -- Andreas, 2013-02-21:  This was 'AbstractMode' until now.
  -- However, top-level checks for mutual blocks, such as
  -- constructor-headedness, should not be able to look into
  -- abstract definitions unless abstract themselves.
  -- (See also discussion on issue 796.)
  -- The initial mode should be 'ConcreteMode', ensuring you
  -- can only look into abstract things in an abstract
  -- definition (which sets 'AbstractMode').
                , envModality               = unitModality
                , envSplitOnStrict          = False
                , envDisplayFormsEnabled    = True
                , envRange                  = noRange
                , envHighlightingRange      = noRange
                , envClause                 = IPNoClause
                , envCall                   = Nothing
                , envHighlightingLevel      = None
                , envHighlightingMethod     = Indirect
                , envExpandLast             = ExpandLast
                , envAppDef                 = Nothing
                , envSimplification         = NoSimplification
                , envAllowedReductions      = allReductions
                , envReduceDefs             = reduceAllDefs
                , envReconstructed          = False
                , envInjectivityDepth       = 0
                , envCompareBlocked         = False
                , envPrintDomainFreePi      = False
                , envPrintMetasBare         = False
                , envInsideDotPattern       = False
                , envUnquoteFlags           = defaultUnquoteFlags
                , envInstanceDepth          = 0
                , envIsDebugPrinting        = False
                , envPrintingPatternLambdas = []
                , envCallByNeed             = True
                , envCurrentCheckpoint      = 0
                , envCheckpoints            = Map.singleton 0 IdS
                , envGeneralizeMetas        = NoGeneralize
                , envGeneralizedVars        = Map.empty
                , envActiveBackendName      = Nothing
                , envEffortLevel            = minBound
                }

class LensTCEnv a where
  lensTCEnv :: Lens' TCEnv a

instance LensTCEnv TCEnv where
  lensTCEnv = id

instance LensModality TCEnv where
  -- Cohesion shouldn't have an environment component.
  getModality = setCohesion defaultCohesion . envModality
  mapModality f e = e { envModality = setCohesion defaultCohesion $ f $ envModality e }

instance LensRelevance TCEnv where
instance LensQuantity  TCEnv where

data UnquoteFlags = UnquoteFlags
  { _unquoteNormalise :: Bool }
  deriving Data

defaultUnquoteFlags :: UnquoteFlags
defaultUnquoteFlags = UnquoteFlags
  { _unquoteNormalise = False }

unquoteNormalise :: Lens' Bool UnquoteFlags
unquoteNormalise f e = f (_unquoteNormalise e) <&> \ x -> e { _unquoteNormalise = x }

eUnquoteNormalise :: Lens' Bool TCEnv
eUnquoteNormalise = eUnquoteFlags . unquoteNormalise

-- * e-prefixed lenses
------------------------------------------------------------------------

eContext :: Lens' ContextHet TCEnv
eContext f e = f (envContext e) <&> \ x -> e { envContext = x }

eLetBindings :: Lens' LetBindings TCEnv
eLetBindings f e = f (envLetBindings e) <&> \ x -> e { envLetBindings = x }

eCurrentModule :: Lens' ModuleName TCEnv
eCurrentModule f e = f (envCurrentModule e) <&> \ x -> e { envCurrentModule = x }

eCurrentPath :: Lens' (Maybe AbsolutePath) TCEnv
eCurrentPath f e = f (envCurrentPath e) <&> \ x -> e { envCurrentPath = x }

eAnonymousModules :: Lens' [(ModuleName, Nat)] TCEnv
eAnonymousModules f e = f (envAnonymousModules e) <&> \ x -> e { envAnonymousModules = x }

eImportPath :: Lens' [C.TopLevelModuleName] TCEnv
eImportPath f e = f (envImportPath e) <&> \ x -> e { envImportPath = x }

eMutualBlock :: Lens' (Maybe MutualId) TCEnv
eMutualBlock f e = f (envMutualBlock e) <&> \ x -> e { envMutualBlock = x }

eTerminationCheck :: Lens' (TerminationCheck ()) TCEnv
eTerminationCheck f e = f (envTerminationCheck e) <&> \ x -> e { envTerminationCheck = x }

eCoverageCheck :: Lens' CoverageCheck TCEnv
eCoverageCheck f e = f (envCoverageCheck e) <&> \ x -> e { envCoverageCheck = x }

eMakeCase :: Lens' Bool TCEnv
eMakeCase f e = f (envMakeCase e) <&> \ x -> e { envMakeCase = x }

eSolvingConstraints :: Lens' Bool TCEnv
eSolvingConstraints f e = f (envSolvingConstraints e) <&> \ x -> e { envSolvingConstraints = x }

eCheckingWhere :: Lens' Bool TCEnv
eCheckingWhere f e = f (envCheckingWhere e) <&> \ x -> e { envCheckingWhere = x }

eWorkingOnTypes :: Lens' Bool TCEnv
eWorkingOnTypes f e = f (envWorkingOnTypes e) <&> \ x -> e { envWorkingOnTypes = x }

eAssignMetas :: Lens' Bool TCEnv
eAssignMetas f e = f (envAssignMetas e) <&> \ x -> e { envAssignMetas = x }

eActiveProblems :: Lens' (ISet ProblemId) TCEnv
eActiveProblems f e = f (envActiveProblems e) <&> \ x -> e { envActiveProblems = x }

eAbstractMode :: Lens' AbstractMode TCEnv
eAbstractMode f e = f (envAbstractMode e) <&> \ x -> e { envAbstractMode = x }

-- Andrea 23/02/2020: use get/setModality to enforce invariants of the
--                    envModality field.
eModality :: Lens' Modality TCEnv
eModality f e = f (getModality e) <&> \ x -> setModality x e

eRelevance :: Lens' Relevance TCEnv
eRelevance = eModality . lModRelevance

eQuantity :: Lens' Quantity TCEnv
eQuantity = eModality . lModQuantity

eSplitOnStrict :: Lens' Bool TCEnv
eSplitOnStrict f e = f (envSplitOnStrict e) <&> \ x -> e { envSplitOnStrict = x }

eDisplayFormsEnabled :: Lens' Bool TCEnv
eDisplayFormsEnabled f e = f (envDisplayFormsEnabled e) <&> \ x -> e { envDisplayFormsEnabled = x }

eRange :: Lens' Range TCEnv
eRange f e = f (envRange e) <&> \ x -> e { envRange = x }

eHighlightingRange :: Lens' Range TCEnv
eHighlightingRange f e = f (envHighlightingRange e) <&> \ x -> e { envHighlightingRange = x }

eCall :: Lens' (Maybe (Closure Call)) TCEnv
eCall f e = f (envCall e) <&> \ x -> e { envCall = x }

eHighlightingLevel :: Lens' HighlightingLevel TCEnv
eHighlightingLevel f e = f (envHighlightingLevel e) <&> \ x -> e { envHighlightingLevel = x }

eHighlightingMethod :: Lens' HighlightingMethod TCEnv
eHighlightingMethod f e = f (envHighlightingMethod e) <&> \ x -> e { envHighlightingMethod = x }

eExpandLast :: Lens' ExpandHidden TCEnv
eExpandLast f e = f (envExpandLast e) <&> \ x -> e { envExpandLast = x }

eAppDef :: Lens' (Maybe QName) TCEnv
eAppDef f e = f (envAppDef e) <&> \ x -> e { envAppDef = x }

eSimplification :: Lens' Simplification TCEnv
eSimplification f e = f (envSimplification e) <&> \ x -> e { envSimplification = x }

eAllowedReductions :: Lens' AllowedReductions TCEnv
eAllowedReductions f e = f (envAllowedReductions e) <&> \ x -> e { envAllowedReductions = x }

eReduceDefs :: Lens' ReduceDefs TCEnv
eReduceDefs f e = f (envReduceDefs e) <&> \ x -> e { envReduceDefs = x }

eReconstructed :: Lens' Bool TCEnv
eReconstructed f e = f (envReconstructed e) <&> \ x -> e { envReconstructed = x }

eInjectivityDepth :: Lens' Int TCEnv
eInjectivityDepth f e = f (envInjectivityDepth e) <&> \ x -> e { envInjectivityDepth = x }

eCompareBlocked :: Lens' Bool TCEnv
eCompareBlocked f e = f (envCompareBlocked e) <&> \ x -> e { envCompareBlocked = x }

ePrintDomainFreePi :: Lens' Bool TCEnv
ePrintDomainFreePi f e = f (envPrintDomainFreePi e) <&> \ x -> e { envPrintDomainFreePi = x }

eInsideDotPattern :: Lens' Bool TCEnv
eInsideDotPattern f e = f (envInsideDotPattern e) <&> \ x -> e { envInsideDotPattern = x }

eUnquoteFlags :: Lens' UnquoteFlags TCEnv
eUnquoteFlags f e = f (envUnquoteFlags e) <&> \ x -> e { envUnquoteFlags = x }

eInstanceDepth :: Lens' Int TCEnv
eInstanceDepth f e = f (envInstanceDepth e) <&> \ x -> e { envInstanceDepth = x }

eIsDebugPrinting :: Lens' Bool TCEnv
eIsDebugPrinting f e = f (envIsDebugPrinting e) <&> \ x -> e { envIsDebugPrinting = x }

ePrintingPatternLambdas :: Lens' [QName] TCEnv
ePrintingPatternLambdas f e = f (envPrintingPatternLambdas e) <&> \ x -> e { envPrintingPatternLambdas = x }

eCallByNeed :: Lens' Bool TCEnv
eCallByNeed f e = f (envCallByNeed e) <&> \ x -> e { envCallByNeed = x }

eCurrentCheckpoint :: Lens' CheckpointId TCEnv
eCurrentCheckpoint f e = f (envCurrentCheckpoint e) <&> \ x -> e { envCurrentCheckpoint = x }

eCheckpoints :: Lens' (Map CheckpointId Substitution) TCEnv
eCheckpoints f e = f (envCheckpoints e) <&> \ x -> e { envCheckpoints = x }

eGeneralizeMetas :: Lens' DoGeneralize TCEnv
eGeneralizeMetas f e = f (envGeneralizeMetas e) <&> \ x -> e { envGeneralizeMetas = x }

eGeneralizedVars :: Lens' (Map QName GeneralizedValue) TCEnv
eGeneralizedVars f e = f (envGeneralizedVars e) <&> \ x -> e { envGeneralizedVars = x }

eActiveBackendName :: Lens' (Maybe BackendName) TCEnv
eActiveBackendName f e = f (envActiveBackendName e) <&> \ x -> e { envActiveBackendName = x }

eEffortLevel :: Lens' EffortLevel TCEnv
eEffortLevel f e = f (envEffortLevel e) <&> \ x -> e { envEffortLevel = x }

---------------------------------------------------------------------------
-- ** Context
---------------------------------------------------------------------------

-- | The @Context@ is a stack of 'ContextEntry's.
type Context      = [ContextEntry]
type ContextEntry = Dom (Name, Type)

---------------------------------------------------------------------------
-- ** Let bindings
---------------------------------------------------------------------------

type LetBindings = Map Name (Open (Term, Dom Type))

---------------------------------------------------------------------------
-- ** Abstract mode
---------------------------------------------------------------------------

data AbstractMode
  = AbstractMode        -- ^ Abstract things in the current module can be accessed.
  | ConcreteMode        -- ^ No abstract things can be accessed.
  | IgnoreAbstractMode  -- ^ All abstract things can be accessed.
  deriving (Data, Show, Eq)

aDefToMode :: IsAbstract -> AbstractMode
aDefToMode AbstractDef = AbstractMode
aDefToMode ConcreteDef = ConcreteMode

aModeToDef :: AbstractMode -> Maybe IsAbstract
aModeToDef AbstractMode = Just AbstractDef
aModeToDef ConcreteMode = Just ConcreteDef
aModeToDef _ = Nothing

---------------------------------------------------------------------------
-- ** Insertion of implicit arguments
---------------------------------------------------------------------------

data ExpandHidden
  = ExpandLast      -- ^ Add implicit arguments in the end until type is no longer hidden 'Pi'.
  | DontExpandLast  -- ^ Do not append implicit arguments.
  | ReallyDontExpandLast -- ^ Makes 'doExpandLast' have no effect. Used to avoid implicit insertion of arguments to metavariables.
  deriving (Eq, Data)

isDontExpandLast :: ExpandHidden -> Bool
isDontExpandLast ExpandLast           = False
isDontExpandLast DontExpandLast       = True
isDontExpandLast ReallyDontExpandLast = True

data CandidateKind
  = LocalCandidate
  | GlobalCandidate QName
  deriving (Show, Data)

-- | A candidate solution for an instance meta is a term with its type.
--   It may be the case that the candidate is not fully applied yet or
--   of the wrong type, hence the need for the type.
data Candidate  = Candidate { candidateKind :: CandidateKind
                            , candidateTerm :: Term
                            , candidateType :: Type
                            , candidateOverlappable :: Bool
                            }
  deriving (Show, Data)

instance Free Candidate where
  freeVars' (Candidate _ t u _) = freeVars' (t, u)


---------------------------------------------------------------------------
-- ** Checking arguments
---------------------------------------------------------------------------

data ArgsCheckState a = ACState
       { acRanges :: [Maybe Range]
         -- ^ Ranges of checked arguments, where present.
         -- e.g. inserted implicits have no correponding abstract syntax.
       , acElims  :: Elims
         -- ^ Checked and inserted arguments so far.
       , acConstraints :: [Maybe (Abs Constraint)]
         -- ^ Constraints for the head so far,
         -- i.e. before applying the correponding elim.
       , acType   :: Type
         -- ^ Type for the rest of the application.
       , acData   :: a
       }
  deriving (Show)


---------------------------------------------------------------------------
-- * Type checking warnings (aka non-fatal errors)
---------------------------------------------------------------------------

-- | A non-fatal error is an error which does not prevent us from
-- checking the document further and interacting with the user.

data Warning
  = NicifierIssue            DeclarationWarning
  | TerminationIssue         [TerminationError]
  | UnreachableClauses       QName [Range]
  -- ^ `UnreachableClauses f rs` means that the clauses in `f` whose ranges are rs
  --   are unreachable
  | CoverageIssue            QName [(Telescope, [NamedArg DeBruijnPattern])]
  -- ^ `CoverageIssue f pss` means that `pss` are not covered in `f`
  | CoverageNoExactSplit     QName [Clause]
  | NotStrictlyPositive      QName (Seq OccursWhere)
  | UnsolvedMetaVariables    [Range]  -- ^ Do not use directly with 'warning'
  | UnsolvedInteractionMetas [Range]  -- ^ Do not use directly with 'warning'
  | UnsolvedConstraints      Constraints
    -- ^ Do not use directly with 'warning'
  | CantGeneralizeOverSorts [MetaId]
  | AbsurdPatternRequiresNoRHS [NamedArg DeBruijnPattern]
  | OldBuiltin               String String
    -- ^ In `OldBuiltin old new`, the BUILTIN old has been replaced by new
  | EmptyRewritePragma
    -- ^ If the user wrote just @{-\# REWRITE \#-}@.
  | EmptyWhere
    -- ^ An empty @where@ block is dead code.
  | IllformedAsClause String
    -- ^ If the user wrote something other than an unqualified name
    --   in the @as@ clause of an @import@ statement.
    --   The 'String' gives optionally extra explanation.
  | ClashesViaRenaming NameOrModule [C.Name]
    -- ^ If a `renaming' import directive introduces a name or module name clash
    --   in the exported names of a module.
    --   (See issue #4154.)
  | UselessPatternDeclarationForRecord String
    -- ^ The 'pattern' declaration is useless in the presence
    --   of either @coinductive@ or @eta-equality@.
    --   Content of 'String' is "coinductive" or "eta", resp.
  | UselessPublic
    -- ^ If the user opens a module public before the module header.
    --   (See issue #2377.)
  | UselessHiding [C.ImportedName]
    -- ^ Names in `hiding` directive that don't hide anything
    --   imported by a `using` directive.
  | UselessInline            QName
  | WrongInstanceDeclaration
  | InstanceWithExplicitArg  QName
  -- ^ An instance was declared with an implicit argument, which means it
  --   will never actually be considered by instance search.
  | InstanceNoOutputTypeName Doc
  -- ^ The type of an instance argument doesn't end in a named or
  -- variable type, so it will never be considered by instance search.
  | InstanceArgWithExplicitArg Doc
  -- ^ As InstanceWithExplicitArg, but for local bindings rather than
  --   top-level instances.
  | InversionDepthReached    QName
  -- ^ The --inversion-max-depth was reached.

  -- Generic warnings for one-off things
  | GenericWarning           Doc
    -- ^ Harmless generic warning (not an error)
  | GenericNonFatalError     Doc
    -- ^ Generic error which doesn't abort proceedings (not a warning)
  | GenericUseless  Range    Doc
    -- ^ Generic warning when code is useless and thus ignored.
    --   'Range' is for dead code highlighting.

  -- Safe flag errors
  | SafeFlagPostulate C.Name
  | SafeFlagPragma [String]                -- ^ Unsafe OPTIONS.
  | SafeFlagNonTerminating
  | SafeFlagTerminating
  | SafeFlagWithoutKFlagPrimEraseEquality
  | WithoutKFlagPrimEraseEquality
  | SafeFlagNoPositivityCheck
  | SafeFlagPolarity
  | SafeFlagNoUniverseCheck
  | SafeFlagNoCoverageCheck
  | SafeFlagInjective
  | SafeFlagEta                            -- ^ ETA pragma is unsafe.
  | ParseWarning             ParseWarning
  | LibraryWarning           LibWarning
  | DeprecationWarning String String String
    -- ^ `DeprecationWarning old new version`:
    --   `old` is deprecated, use `new` instead. This will be an error in Agda `version`.
  | UserWarning Text
    -- ^ User-defined warning (e.g. to mention that a name is deprecated)
  | DuplicateUsing (List1 C.ImportedName)
    -- ^ Duplicate mentions of the same name in @using@ directive(s).
  | FixityInRenamingModule (List1 Range)
    -- ^ Fixity of modules cannot be changed via renaming (since modules have no fixity).
  | ModuleDoesntExport C.QName [C.Name] [C.Name] [C.ImportedName]
    -- ^ Some imported names are not actually exported by the source module.
    --   The second argument is the names that could be exported.
    --   The third  argument is the module names that could be exported.
  | InfectiveImport String ModuleName
    -- ^ Importing a file using an infective option into one which doesn't
  | CoInfectiveImport String ModuleName
    -- ^ Importing a file not using a coinfective option from one which does
  | RewriteNonConfluent Term Term Term Doc
    -- ^ Confluence checker found critical pair and equality checking
    --   resulted in a type error
  | RewriteMaybeNonConfluent Term Term [Doc]
    -- ^ Confluence checker got stuck on computing overlap between two
    --   rewrite rules
  | RewriteAmbiguousRules Term Term Term
    -- ^ The global confluence checker found a term @u@ that reduces
    --   to both @v1@ and @v2@ and there is no rule to resolve the
    --   ambiguity.
  | RewriteMissingRule Term Term Term
    -- ^ The global confluence checker found a term @u@ that reduces
    --   to @v@, but @v@ does not reduce to @rho(u)@.
  | PragmaCompileErased BackendName QName
    -- ^ COMPILE directive for an erased symbol
  | NotInScopeW [C.QName]
    -- ^ Out of scope error we can recover from
  | AsPatternShadowsConstructorOrPatternSynonym Bool
    -- ^ The as-name in an as-pattern may not shadow a constructor (@False@)
    --   or pattern synonym name (@True@),
    --   because this can be confusing to read.
  | RecordFieldWarning RecordFieldWarning
  deriving (Show)

data RecordFieldWarning
  = DuplicateFieldsWarning [(C.Name, Range)]
      -- ^ Each redundant field comes with a range of associated dead code.
  | TooManyFieldsWarning QName [C.Name] [(C.Name, Range)]
      -- ^ Record type, fields not supplied by user, non-fields but supplied.
      --   The redundant fields come with a range of associated dead code.
  deriving (Show, Data)

recordFieldWarningToError :: RecordFieldWarning -> TypeError
recordFieldWarningToError = \case
  DuplicateFieldsWarning    xrs -> DuplicateFields    $ map fst xrs
  TooManyFieldsWarning q ys xrs -> TooManyFields q ys $ map fst xrs

warningName :: Warning -> WarningName
warningName = \case
  -- special cases
  NicifierIssue dw             -> declarationWarningName dw
  ParseWarning pw              -> parseWarningName pw
  LibraryWarning lw            -> libraryWarningName lw
  AsPatternShadowsConstructorOrPatternSynonym{} -> AsPatternShadowsConstructorOrPatternSynonym_
  -- scope- and type-checking errors
  AbsurdPatternRequiresNoRHS{} -> AbsurdPatternRequiresNoRHS_
  CantGeneralizeOverSorts{}    -> CantGeneralizeOverSorts_
  CoverageIssue{}              -> CoverageIssue_
  CoverageNoExactSplit{}       -> CoverageNoExactSplit_
  DeprecationWarning{}         -> DeprecationWarning_
  EmptyRewritePragma           -> EmptyRewritePragma_
  EmptyWhere                   -> EmptyWhere_
  IllformedAsClause{}          -> IllformedAsClause_
  WrongInstanceDeclaration{}   -> WrongInstanceDeclaration_
  InstanceWithExplicitArg{}    -> InstanceWithExplicitArg_
  InstanceNoOutputTypeName{}   -> InstanceNoOutputTypeName_
  InstanceArgWithExplicitArg{} -> InstanceArgWithExplicitArg_
  DuplicateUsing{}             -> DuplicateUsing_
  FixityInRenamingModule{}     -> FixityInRenamingModule_
  GenericNonFatalError{}       -> GenericNonFatalError_
  GenericUseless{}             -> GenericUseless_
  GenericWarning{}             -> GenericWarning_
  InversionDepthReached{}      -> InversionDepthReached_
  ModuleDoesntExport{}         -> ModuleDoesntExport_
  NotInScopeW{}                -> NotInScope_
  NotStrictlyPositive{}        -> NotStrictlyPositive_
  OldBuiltin{}                 -> OldBuiltin_
  SafeFlagNoPositivityCheck    -> SafeFlagNoPositivityCheck_
  SafeFlagNonTerminating       -> SafeFlagNonTerminating_
  SafeFlagNoUniverseCheck      -> SafeFlagNoUniverseCheck_
  SafeFlagPolarity             -> SafeFlagPolarity_
  SafeFlagPostulate{}          -> SafeFlagPostulate_
  SafeFlagPragma{}             -> SafeFlagPragma_
  SafeFlagEta                  -> SafeFlagEta_
  SafeFlagInjective            -> SafeFlagInjective_
  SafeFlagNoCoverageCheck      -> SafeFlagNoCoverageCheck_
  SafeFlagWithoutKFlagPrimEraseEquality -> SafeFlagWithoutKFlagPrimEraseEquality_
  WithoutKFlagPrimEraseEquality -> WithoutKFlagPrimEraseEquality_
  SafeFlagTerminating          -> SafeFlagTerminating_
  TerminationIssue{}           -> TerminationIssue_
  UnreachableClauses{}         -> UnreachableClauses_
  UnsolvedInteractionMetas{}   -> UnsolvedInteractionMetas_
  UnsolvedConstraints{}        -> UnsolvedConstraints_
  UnsolvedMetaVariables{}      -> UnsolvedMetaVariables_
  UselessHiding{}              -> UselessHiding_
  UselessInline{}              -> UselessInline_
  UselessPublic{}              -> UselessPublic_
  UselessPatternDeclarationForRecord{} -> UselessPatternDeclarationForRecord_
  ClashesViaRenaming{}         -> ClashesViaRenaming_
  UserWarning{}                -> UserWarning_
  InfectiveImport{}            -> InfectiveImport_
  CoInfectiveImport{}          -> CoInfectiveImport_
  RewriteNonConfluent{}        -> RewriteNonConfluent_
  RewriteMaybeNonConfluent{}   -> RewriteMaybeNonConfluent_
  RewriteAmbiguousRules{}      -> RewriteAmbiguousRules_
  RewriteMissingRule{}         -> RewriteMissingRule_
  PragmaCompileErased{}        -> PragmaCompileErased_
  -- record field warnings
  RecordFieldWarning w -> case w of
    DuplicateFieldsWarning{}   -> DuplicateFieldsWarning_
    TooManyFieldsWarning{}     -> TooManyFieldsWarning_

data TCWarning
  = TCWarning
    { tcWarningLocation :: CallStack
        -- ^ Location in the internal Agda source code location where the error raised
    , tcWarningRange    :: Range
        -- ^ Range where the warning was raised
    , tcWarning         :: Warning
        -- ^ The warning itself
    , tcWarningPrintedWarning :: Doc
        -- ^ The warning printed in the state and environment where it was raised
    , tcWarningCached :: Bool
        -- ^ Should the warning be affected by caching.
    }
  deriving Show


tcWarningOrigin :: TCWarning -> SrcFile
tcWarningOrigin = rangeFile . tcWarningRange

instance HasRange TCWarning where
  getRange = tcWarningRange

-- used for merging lists of warnings
instance Eq TCWarning where
  (==) = (==) `on` tcWarningPrintedWarning

---------------------------------------------------------------------------
-- * Type checking errors
---------------------------------------------------------------------------

-- | Information about a call.

data CallInfo = CallInfo
  { callInfoTarget :: QName
    -- ^ Target function name.
  , callInfoRange :: Range
    -- ^ Range of the target function.
  , callInfoCall :: Closure Term
    -- ^ To be formatted representation of the call.
  } deriving (Data, Show)
    -- no Eq, Ord instances: too expensive! (see issues 851, 852)

-- | We only 'show' the name of the callee.
instance Pretty CallInfo where pretty = pretty . callInfoTarget

-- | Information about a mutual block which did not pass the
-- termination checker.

data TerminationError = TerminationError
  { termErrFunctions :: [QName]
    -- ^ The functions which failed to check. (May not include
    -- automatically generated functions.)
  , termErrCalls :: [CallInfo]
    -- ^ The problematic call sites.
  } deriving (Data, Show)

-- | Error when splitting a pattern variable into possible constructor patterns.
data SplitError
  = NotADatatype        (Closure Type)  -- ^ Neither data type nor record.
  | BlockedType Blocker (Closure Type)  -- ^ Type could not be sufficiently reduced.
  | IrrelevantDatatype  (Closure Type)  -- ^ Data type, but in irrelevant position.
  | ErasedDatatype Bool (Closure Type)  -- ^ Data type, but in erased position.
                                        --   If the boolean is 'True',
                                        --   then the reason for the
                                        --   error is that the K rule
                                        --   is turned off.
  | CoinductiveDatatype (Closure Type)  -- ^ Split on codata not allowed.
  -- UNUSED, but keep!
  -- -- | NoRecordConstructor Type  -- ^ record type, but no constructor
  | UnificationStuck
    { cantSplitBlocker  :: Maybe Blocker -- ^ Blocking metavariable (if any)
    , cantSplitConName  :: QName        -- ^ Constructor.
    , cantSplitTel      :: Telescope    -- ^ Context for indices.
    , cantSplitConIdx   :: Args         -- ^ Inferred indices (from type of constructor).
    , cantSplitGivenIdx :: Args         -- ^ Expected indices (from checking pattern).
    , cantSplitFailures :: [UnificationFailure] -- ^ Reason(s) why unification got stuck.
    }
  | CosplitCatchall
      -- ^ Copattern split with a catchall
  | CosplitNoTarget
      -- ^ We do not know the target type of the clause.
  | CosplitNoRecordType (Closure Type)
      -- ^ Target type is not a record type.
  | CannotCreateMissingClause QName (Telescope,[NamedArg DeBruijnPattern]) Doc (Closure (Abs Type))

  | GenericSplitError String
  deriving (Show)

data NegativeUnification
  = UnifyConflict Telescope Term Term
  | UnifyCycle Telescope Int Term
  deriving (Show)

data UnificationFailure
  = UnifyIndicesNotVars Telescope Type Term Term Args -- ^ Failed to apply injectivity to constructor of indexed datatype
  | UnifyRecursiveEq Telescope Type Int Term          -- ^ Can't solve equation because variable occurs in (type of) lhs
  | UnifyReflexiveEq Telescope Type Term              -- ^ Can't solve reflexive equation because --without-K is enabled
  | UnifyUnusableModality Telescope Type Int Term Modality  -- ^ Can't solve equation because solution modality is less "usable"
  deriving (Show)

data UnquoteError
  = BadVisibility String (Arg I.Term)
  | ConInsteadOfDef QName String String
  | DefInsteadOfCon QName String String
  | NonCanonical String I.Term
  | BlockedOnMeta TCState Blocker
  | UnquotePanic String
  deriving (Show)

data TypeError
        = InternalError String
        | NotImplemented String
        | NotSupported String
        | CompilationError String
        | PropMustBeSingleton
        | DataMustEndInSort Term
{- UNUSED
        | DataTooManyParameters
            -- ^ In @data D xs where@ the number of parameters @xs@ does not fit the
            --   the parameters given in the forward declaraion @data D Gamma : T@.
-}
        | ShouldEndInApplicationOfTheDatatype Type
            -- ^ The target of a constructor isn't an application of its
            -- datatype. The 'Type' records what it does target.
        | ShouldBeAppliedToTheDatatypeParameters Term Term
            -- ^ The target of a constructor isn't its datatype applied to
            --   something that isn't the parameters. First term is the correct
            --   target and the second term is the actual target.
        | ShouldBeApplicationOf Type QName
            -- ^ Expected a type to be an application of a particular datatype.
        | ConstructorPatternInWrongDatatype QName QName -- ^ constructor, datatype
        | CantResolveOverloadedConstructorsTargetingSameDatatype QName (List1 QName)
          -- ^ Datatype, constructors.
        | DoesNotConstructAnElementOf QName Type -- ^ constructor, type
        | WrongHidingInLHS
            -- ^ The left hand side of a function definition has a hidden argument
            --   where a non-hidden was expected.
        | WrongHidingInLambda Type
            -- ^ Expected a non-hidden function and found a hidden lambda.
        | WrongHidingInApplication Type
            -- ^ A function is applied to a hidden argument where a non-hidden was expected.
        | WrongNamedArgument (NamedArg A.Expr) [NamedName]
            -- ^ A function is applied to a hidden named argument it does not have.
            -- The list contains names of possible hidden arguments at this point.
        | WrongIrrelevanceInLambda
            -- ^ Wrong user-given relevance annotation in lambda.
        | WrongQuantityInLambda
            -- ^ Wrong user-given quantity annotation in lambda.
        | WrongCohesionInLambda
            -- ^ Wrong user-given cohesion annotation in lambda.
        | QuantityMismatch Quantity Quantity
            -- ^ The given quantity does not correspond to the expected quantity.
        | HidingMismatch Hiding Hiding
            -- ^ The given hiding does not correspond to the expected hiding.
        | RelevanceMismatch Relevance Relevance
            -- ^ The given relevance does not correspond to the expected relevane.
        | UninstantiatedDotPattern A.Expr
        | ForcedConstructorNotInstantiated A.Pattern
        | IllformedProjectionPattern A.Pattern
        | CannotEliminateWithPattern (Maybe Blocker) (NamedArg A.Pattern) Type
        | WrongNumberOfConstructorArguments QName Nat Nat
        | ShouldBeEmpty Type [DeBruijnPattern]
        | ShouldBeASort Type
            -- ^ The given type should have been a sort.
        | ShouldBePi Type
            -- ^ The given type should have been a pi.
        | ShouldBePath Type
        | ShouldBeRecordType Type
        | ShouldBeRecordPattern DeBruijnPattern
        | NotAProjectionPattern (NamedArg A.Pattern)
        | NotAProperTerm
        | InvalidTypeSort Sort
            -- ^ This sort is not a type expression.
        | InvalidType Term
            -- ^ This term is not a type expression.
        | FunctionTypeInSizeUniv Term
            -- ^ This term, a function type constructor, lives in
            --   @SizeUniv@, which is not allowed.
        | SplitOnIrrelevant (Dom Type)
        | SplitOnUnusableCohesion (Dom Type)
        -- UNUSED: -- | SplitOnErased (Dom Type)
        | SplitOnNonVariable Term Type
        | SplitOnNonEtaRecord QName
        | DefinitionIsIrrelevant QName
        | DefinitionIsErased QName
        | VariableIsIrrelevant Name
        | VariableIsErased Name
        | VariableIsOfUnusableCohesion Name Cohesion
        | UnequalLevel Comparison Level Level
        | UnequalTerms_ Comparison (H'LHS Term) (H'RHS Term) CompareAs_
        | UnequalTypes Comparison Type Type
--      | UnequalTelescopes Comparison Telescope Telescope -- UNUSED
        | UnequalRelevance Comparison Term Term
            -- ^ The two function types have different relevance.
        | UnequalQuantity Comparison Term Term
            -- ^ The two function types have different relevance.
        | UnequalCohesion Comparison Term Term
            -- ^ The two function types have different cohesion.
        | UnequalHiding Term Term
            -- ^ The two function types have different hiding.
        | UnequalSorts Sort Sort
        | UnequalBecauseOfUniverseConflict Comparison Term Term
        | NotLeqSort Sort Sort
        | MetaCannotDependOn MetaId Nat
            -- ^ The arguments are the meta variable and the parameter that it wants to depend on.
        | MetaOccursInItself MetaId
        | MetaIrrelevantSolution MetaId Term
        | MetaErasedSolution MetaId Term
        | GenericError String
        | GenericDocError Doc
        | SortOfSplitVarError (Maybe Blocker) Doc
          -- ^ the meta is what we might be blocked on.
        | BuiltinMustBeConstructor String A.Expr
        | NoSuchBuiltinName String
        | DuplicateBuiltinBinding String Term Term
        | NoBindingForBuiltin String
        | NoSuchPrimitiveFunction String
        | DuplicatePrimitiveBinding String QName QName
        | WrongModalityForPrimitive String ArgInfo ArgInfo
        | ShadowedModule C.Name [A.ModuleName]
        | BuiltinInParameterisedModule String
        | IllegalLetInTelescope C.TypedBinding
        | IllegalPatternInTelescope C.Binder
        | NoRHSRequiresAbsurdPattern [NamedArg A.Pattern]
        | TooManyFields QName [C.Name] [C.Name]
          -- ^ Record type, fields not supplied by user, non-fields but supplied.
        | DuplicateFields [C.Name]
        | DuplicateConstructors [C.Name]
        | WithOnFreeVariable A.Expr Term
        | UnexpectedWithPatterns [A.Pattern]
        | WithClausePatternMismatch A.Pattern (NamedArg DeBruijnPattern)
        | FieldOutsideRecord
        | ModuleArityMismatch A.ModuleName Telescope [NamedArg A.Expr]
        | GeneralizeCyclicDependency
        | GeneralizeUnsolvedMeta
    -- Coverage errors
-- UNUSED:        | IncompletePatternMatching Term [Elim] -- can only happen if coverage checking is switched off
        | SplitError SplitError
        | ImpossibleConstructor QName NegativeUnification
    -- Positivity errors
        | TooManyPolarities QName Int
    -- Import errors
        | LocalVsImportedModuleClash ModuleName
        | SolvedButOpenHoles
          -- ^ Some interaction points (holes) have not been filled by user.
          --   There are not 'UnsolvedMetas' since unification solved them.
          --   This is an error, since interaction points are never filled
          --   without user interaction.
        | CyclicModuleDependency [C.TopLevelModuleName]
        | FileNotFound C.TopLevelModuleName [AbsolutePath]
        | OverlappingProjects AbsolutePath C.TopLevelModuleName C.TopLevelModuleName
        | AmbiguousTopLevelModuleName C.TopLevelModuleName [AbsolutePath]
        | ModuleNameUnexpected C.TopLevelModuleName C.TopLevelModuleName
          -- ^ Found module name, expected module name.
        | ModuleNameDoesntMatchFileName C.TopLevelModuleName [AbsolutePath]
        | ClashingFileNamesFor ModuleName [AbsolutePath]
        | ModuleDefinedInOtherFile C.TopLevelModuleName AbsolutePath AbsolutePath
          -- ^ Module name, file from which it was loaded, file which
          -- the include path says contains the module.
    -- Scope errors
        | BothWithAndRHS
        | AbstractConstructorNotInScope A.QName
        | NotInScope [C.QName]
        | NoSuchModule C.QName
        | AmbiguousName C.QName (List1 A.QName)
        | AmbiguousModule C.QName (List1 A.ModuleName)
        | ClashingDefinition C.QName A.QName (Maybe NiceDeclaration)
        | ClashingModule A.ModuleName A.ModuleName
        | ClashingImport C.Name A.QName
        | ClashingModuleImport C.Name A.ModuleName
        | PatternShadowsConstructor C.Name A.QName
        | DuplicateImports C.QName [C.ImportedName]
        | InvalidPattern C.Pattern
        | RepeatedVariablesInPattern [C.Name]
        | GeneralizeNotSupportedHere A.QName
        | MultipleFixityDecls [(C.Name, [Fixity'])]
        | MultiplePolarityPragmas [C.Name]
    -- Concrete to Abstract errors
        | NotAModuleExpr C.Expr
            -- ^ The expr was used in the right hand side of an implicit module
            --   definition, but it wasn't of the form @m Delta@.
        | NotAnExpression C.Expr
        | NotAValidLetBinding NiceDeclaration
        | NotValidBeforeField NiceDeclaration
        | NothingAppliedToHiddenArg C.Expr
        | NothingAppliedToInstanceArg C.Expr
    -- Pattern synonym errors
        | BadArgumentsToPatternSynonym A.AmbiguousQName
        | TooFewArgumentsToPatternSynonym A.AmbiguousQName
        | CannotResolveAmbiguousPatternSynonym (List1 (A.QName, A.PatternSynDefn))
        | UnusedVariableInPatternSynonym
    -- Operator errors
        | NoParseForApplication (List2 C.Expr)
        | AmbiguousParseForApplication (List2 C.Expr) (List1 C.Expr)
        | NoParseForLHS LHSOrPatSyn [C.Pattern] C.Pattern
            -- ^ The list contains patterns that failed to be interpreted.
            --   If it is non-empty, the first entry could be printed as error hint.
        | AmbiguousParseForLHS LHSOrPatSyn C.Pattern [C.Pattern]
            -- ^ Pattern and its possible interpretations.
        | OperatorInformation [NotationSection] TypeError
{- UNUSED
        | NoParseForPatternSynonym C.Pattern
        | AmbiguousParseForPatternSynonym C.Pattern [C.Pattern]
-}
    -- Usage errors
    -- Instance search errors
        | InstanceNoCandidate Type [(Term, TCErr)]
    -- Reflection errors
        | UnquoteFailed UnquoteError
        | DeBruijnIndexOutOfScope Nat Telescope [Name]
    -- Language option errors
        | NeedOptionCopatterns
        | NeedOptionRewriting
        | NeedOptionProp
        | NeedOptionTwoLevel
    -- Failure associated to warnings
        | NonFatalErrors [TCWarning]
    -- Instance search errors
        | InstanceSearchDepthExhausted Term Type Int
        | TriedToCopyConstrainedPrim QName
          deriving Show

mkUnequalTerms :: Comparison -> Term -> Term -> CompareAs -> TypeError
mkUnequalTerms cmp u v a = UnequalTerms_ cmp (OnLHS u) (OnRHS v) (asTwin a)

pattern UnequalRelevance_ :: Comparison -> H'LHS Term -> H'RHS Term -> TypeError
pattern UnequalRelevance_ dir u v <- UnequalRelevance dir (Het -> u) (Het -> v)
  where UnequalRelevance_ dir (Het u) (Het v) = UnequalRelevance dir u v

pattern UnequalQuantity_ :: Comparison -> H'LHS Term -> H'RHS Term -> TypeError
pattern UnequalQuantity_ dir u v <- UnequalQuantity dir (Het -> u) (Het -> v)
  where UnequalQuantity_ dir (Het u) (Het v) = UnequalQuantity dir u v

pattern UnequalCohesion_ :: Comparison -> H'LHS Term -> H'RHS Term -> TypeError
pattern UnequalCohesion_ dir u v <- UnequalCohesion dir (Het -> u) (Het -> v)
  where UnequalCohesion_ dir (Het u) (Het v) = UnequalCohesion dir u v

pattern UnequalHiding_ :: H'LHS Term -> H'RHS Term -> TypeError
pattern UnequalHiding_ u v <- UnequalHiding (Het -> u) (Het -> v)
  where UnequalHiding_ (Het u) (Het v) = UnequalHiding u v

-- | Distinguish error message when parsing lhs or pattern synonym, resp.
data LHSOrPatSyn = IsLHS | IsPatSyn deriving (Eq, Show)

-- | Type-checking errors.

data TCErr
  = TypeError
    { tcErrLocation :: CallStack
       -- ^ Location in the internal Agda source code where the error was raised
    , tcErrState    :: TCState
        -- ^ The state in which the error was raised.
    , tcErrClosErr  :: Closure TypeError
        -- ^ The environment in which the error as raised plus the error.
    }
  | Exception Range Doc
  | IOException TCState Range E.IOException
    -- ^ The first argument is the state in which the error was
    -- raised.
  | PatternErr Blocker
      -- ^ The exception which is usually caught.
      --   Raised for pattern violations during unification ('assignV')
      --   but also in other situations where we want to backtrack.
      --   Contains an unblocker to control when the computation should
      --   be retried.

instance Show TCErr where
  show (TypeError _ _ e)   = prettyShow (envRange $ clEnv e) ++ ": " ++ show (clValue e)
  show (Exception r d)     = prettyShow r ++ ": " ++ render d
  show (IOException _ r e) = prettyShow r ++ ": " ++ show e
  show PatternErr{}        = "Pattern violation (you shouldn't see this)"

instance HasRange TCErr where
  getRange (TypeError _ _ cl)  = envRange $ clEnv cl
  getRange (Exception r _)     = r
  getRange (IOException s r _) = r
  getRange PatternErr{}        = noRange

instance E.Exception TCErr

-----------------------------------------------------------------------------
-- * Accessing options
-----------------------------------------------------------------------------

instance MonadIO m => HasOptions (TCMT m) where
  pragmaOptions = useTC stPragmaOptions

  commandLineOptions = do
    p  <- useTC stPragmaOptions
    cl <- stPersistentOptions . stPersistentState <$> getTC
    return $ cl { optPragmaOptions = p }

-- HasOptions lifts through monad transformers
-- (see default signatures in the HasOptions class).

-- Ternary options are annoying to deal with so we provide auxiliary
-- definitions using @collapseDefault@.

sizedTypesOption :: HasOptions m => m Bool
sizedTypesOption = collapseDefault . optSizedTypes <$> pragmaOptions

guardednessOption :: HasOptions m => m Bool
guardednessOption = collapseDefault . optGuardedness <$> pragmaOptions

withoutKOption :: HasOptions m => m Bool
withoutKOption = collapseDefault . optWithoutK <$> pragmaOptions

enableCaching :: HasOptions m => m Bool
enableCaching = optCaching <$> pragmaOptions
-----------------------------------------------------------------------------
-- * The reduce monad
-----------------------------------------------------------------------------

-- | Environment of the reduce monad.
data ReduceEnv = ReduceEnv
  { redEnv :: TCEnv    -- ^ Read only access to environment.
  , redSt  :: TCState  -- ^ Read only access to state (signature, metas...).
  }

mapRedEnv :: (TCEnv -> TCEnv) -> ReduceEnv -> ReduceEnv
mapRedEnv f s = s { redEnv = f (redEnv s) }

mapRedSt :: (TCState -> TCState) -> ReduceEnv -> ReduceEnv
mapRedSt f s = s { redSt = f (redSt s) }

mapRedEnvSt :: (TCEnv -> TCEnv) -> (TCState -> TCState) -> ReduceEnv
            -> ReduceEnv
mapRedEnvSt f g (ReduceEnv e s) = ReduceEnv (f e) (g s)

-- Lenses
reduceEnv :: Lens' TCEnv ReduceEnv
reduceEnv f s = f (redEnv s) <&> \ e -> s { redEnv = e }

reduceSt :: Lens' TCState ReduceEnv
reduceSt f s = f (redSt s) <&> \ e -> s { redSt = e }

newtype ReduceM a = ReduceM { unReduceM :: ReduceEnv -> a }
--  deriving (Functor, Applicative, Monad)

onReduceEnv :: (ReduceEnv -> ReduceEnv) -> ReduceM a -> ReduceM a
onReduceEnv f (ReduceM m) = ReduceM (m . f)

fmapReduce :: (a -> b) -> ReduceM a -> ReduceM b
fmapReduce f (ReduceM m) = ReduceM $ \ e -> f $! m e
{-# INLINE fmapReduce #-}

apReduce :: ReduceM (a -> b) -> ReduceM a -> ReduceM b
apReduce (ReduceM f) (ReduceM x) = ReduceM $ \ e -> f e $! x e
{-# INLINE apReduce #-}

bindReduce :: ReduceM a -> (a -> ReduceM b) -> ReduceM b
bindReduce (ReduceM m) f = ReduceM $ \ e -> unReduceM (f $! m e) e
{-# INLINE bindReduce #-}

instance Functor ReduceM where
  fmap = fmapReduce

instance Applicative ReduceM where
  pure x = ReduceM (const x)
  (<*>) = apReduce

instance Monad ReduceM where
  return = pure
  (>>=) = bindReduce
  (>>) = (*>)
#if __GLASGOW_HASKELL__ < 808
  fail = Fail.fail
#endif

instance Fail.MonadFail ReduceM where
  fail = error

instance ReadTCState ReduceM where
  getTCState = ReduceM redSt
  locallyTCState l f = onReduceEnv $ mapRedSt $ over l f

runReduceM :: ReduceM a -> TCM a
runReduceM m = do
  e <- askTC
  s <- getTC
  return $! unReduceM m (ReduceEnv e s)

runReduceF :: (a -> ReduceM b) -> TCM (a -> b)
runReduceF f = do
  e <- askTC
  s <- getTC
  return $ \x -> unReduceM (f x) (ReduceEnv e s)

instance MonadTCEnv ReduceM where
  askTC   = ReduceM redEnv
  localTC = onReduceEnv . mapRedEnv

-- Andrea comments (https://github.com/agda/agda/issues/1829#issuecomment-522312084):
--
--   useR forces the result of projecting the lens,
--   this usually prevents retaining the whole structure when we only need a field.
--
-- This fixes (or contributes to the fix of) the space leak issue #1829 (caching).
useR :: (ReadTCState m) => Lens' a TCState -> m a
useR l = do
  !x <- (^.l) <$> getTCState
  return x

askR :: ReduceM ReduceEnv
askR = ReduceM ask

localR :: (ReduceEnv -> ReduceEnv) -> ReduceM a -> ReduceM a
localR f = ReduceM . local f . unReduceM

instance HasOptions ReduceM where
  pragmaOptions      = useR stPragmaOptions
  commandLineOptions = do
    p  <- useR stPragmaOptions
    cl <- stPersistentOptions . stPersistentState <$> getTCState
    return $ cl{ optPragmaOptions = p }

class ( Applicative m
      , MonadTCEnv m
      , ReadTCState m
      , HasOptions m
      ) => MonadReduce m where
  liftReduce :: ReduceM a -> m a

  default liftReduce :: (MonadTrans t, MonadReduce n, t n ~ m) => ReduceM a -> m a
  liftReduce = lift . liftReduce

instance MonadReduce ReduceM where
  liftReduce = id

instance MonadReduce m => MonadReduce (ChangeT m)
instance MonadReduce m => MonadReduce (ExceptT err m)
instance MonadReduce m => MonadReduce (IdentityT m)
instance MonadReduce m => MonadReduce (ListT m)
instance MonadReduce m => MonadReduce (MaybeT m)
instance MonadReduce m => MonadReduce (ReaderT r m)
instance MonadReduce m => MonadReduce (StateT w m)
instance (Monoid w, MonadReduce m) => MonadReduce (WriterT w m)
instance MonadReduce m => MonadReduce (BlockT m)

---------------------------------------------------------------------------
-- * Monad with read-only 'TCEnv'
---------------------------------------------------------------------------

-- | @MonadTCEnv@ made into its own dedicated service class.
--   This allows us to use 'MonadReader' for 'ReaderT' extensions of @TCM@.
class Monad m => MonadTCEnv m where
  askTC   :: m TCEnv
  localTC :: (TCEnv -> TCEnv) -> m a -> m a

  default askTC :: (MonadTrans t, MonadTCEnv n, t n ~ m) => m TCEnv
  askTC = lift askTC

  default localTC
    :: (MonadTransControl t, MonadTCEnv n, t n ~ m)
    =>  (TCEnv -> TCEnv) -> m a -> m a
  localTC = liftThrough . localTC

instance MonadTCEnv m => MonadTCEnv (ChangeT m)
instance MonadTCEnv m => MonadTCEnv (ExceptT err m)
instance MonadTCEnv m => MonadTCEnv (IdentityT m)
instance MonadTCEnv m => MonadTCEnv (MaybeT m)
instance MonadTCEnv m => MonadTCEnv (ReaderT r m)
instance MonadTCEnv m => MonadTCEnv (StateT s m)
instance (Monoid w, MonadTCEnv m) => MonadTCEnv (WriterT w m)

instance MonadTCEnv m => MonadTCEnv (ListT m) where
  localTC = mapListT . localTC

asksTC :: MonadTCEnv m => (TCEnv -> a) -> m a
asksTC f = f <$> askTC

viewTC :: MonadTCEnv m => Lens' a TCEnv -> m a
viewTC l = asksTC (^. l)

-- | Modify the lens-indicated part of the @TCEnv@ in a subcomputation.
locallyTC :: MonadTCEnv m => Lens' a TCEnv -> (a -> a) -> m b -> m b
locallyTC l = localTC . over l

---------------------------------------------------------------------------
-- * Monad with mutable 'TCState'
---------------------------------------------------------------------------

-- | @MonadTCState@ made into its own dedicated service class.
--   This allows us to use 'MonadState' for 'StateT' extensions of @TCM@.
class Monad m => MonadTCState m where
  getTC :: m TCState
  putTC :: TCState -> m ()
  modifyTC :: (TCState -> TCState) -> m ()

  default getTC :: (MonadTrans t, MonadTCState n, t n ~ m) => m TCState
  getTC = lift getTC

  default putTC :: (MonadTrans t, MonadTCState n, t n ~ m) => TCState -> m ()
  putTC = lift . putTC

  default modifyTC :: (MonadTrans t, MonadTCState n, t n ~ m) => (TCState -> TCState) -> m ()
  modifyTC = lift . modifyTC

instance MonadTCState m => MonadTCState (MaybeT m)
instance MonadTCState m => MonadTCState (ListT m)
instance MonadTCState m => MonadTCState (ExceptT err m)
instance MonadTCState m => MonadTCState (ReaderT r m)
instance MonadTCState m => MonadTCState (StateT s m)
instance MonadTCState m => MonadTCState (ChangeT m)
instance MonadTCState m => MonadTCState (IdentityT m)
instance (Monoid w, MonadTCState m) => MonadTCState (WriterT w m)

-- ** @TCState@ accessors (no lenses)

getsTC :: ReadTCState m => (TCState -> a) -> m a
getsTC f = f <$> getTCState

-- | A variant of 'modifyTC' in which the computation is strict in the
-- new state.
modifyTC' :: MonadTCState m => (TCState -> TCState) -> m ()
modifyTC' f = do
  s' <- getTC
  putTC $! f s'

-- SEE TC.Monad.State
-- -- | Restore the 'TCState' after computation.
-- localTCState :: MonadTCState m => m a -> m a
-- localTCState = bracket_ getTC putTC

-- ** @TCState@ accessors via lenses

useTC :: ReadTCState m => Lens' a TCState -> m a
useTC l = do
  !x <- getsTC (^. l)
  return x

infix 4 `setTCLens`

-- | Overwrite the part of the 'TCState' focused on by the lens.
setTCLens :: MonadTCState m => Lens' a TCState -> a -> m ()
setTCLens l = modifyTC . set l

-- | Modify the part of the 'TCState' focused on by the lens.
modifyTCLens :: MonadTCState m => Lens' a TCState -> (a -> a) -> m ()
modifyTCLens l = modifyTC . over l

-- | Modify a part of the state monadically.
modifyTCLensM :: MonadTCState m => Lens' a TCState -> (a -> m a) -> m ()
modifyTCLensM l f = putTC =<< l f =<< getTC

-- | Modify the part of the 'TCState' focused on by the lens, and return some result.
stateTCLens :: MonadTCState m => Lens' a TCState -> (a -> (r , a)) -> m r
stateTCLens l f = stateTCLensM l $ return . f

-- | Modify a part of the state monadically, and return some result.
stateTCLensM :: MonadTCState m => Lens' a TCState -> (a -> m (r , a)) -> m r
stateTCLensM l f = do
  s <- getTC
  (result , x) <- f $ s ^. l
  putTC $ set l x s
  return result


---------------------------------------------------------------------------
-- ** Monad with capability to block a computation
---------------------------------------------------------------------------

class Monad m => MonadBlock m where

  -- | `patternViolation b` aborts the current computation
  patternViolation :: Blocker -> m a

  default patternViolation :: (MonadTrans t, MonadBlock n, m ~ t n) => Blocker -> m a
  patternViolation = lift . patternViolation

  -- | `catchPatternErr handle m` runs m, handling pattern violations
  --    with `handle` (doesn't roll back the state)
  catchPatternErr :: (Blocker -> m a) -> m a -> m a

newtype BlockT m a = BlockT { unBlockT :: ExceptT Blocker m a }
  deriving ( Functor, Applicative, Monad, MonadTrans, MonadIO, Fail.MonadFail
           , ReadTCState, HasOptions
           , MonadTCEnv, MonadTCState, MonadTCM
           )

instance Monad m => MonadBlock (BlockT m) where
  patternViolation = BlockT . throwError
  catchPatternErr h f = BlockT $ catchError (unBlockT f) (unBlockT . h)

instance Monad m => MonadBlock (ExceptT TCErr m) where
  patternViolation = throwError . PatternErr
  catchPatternErr h f = catchError f $ \case
    PatternErr b -> h b
    err          -> throwError err

runBlocked :: Monad m => BlockT m a -> m (Either Blocker a)
runBlocked = runExceptT . unBlockT

instance MonadBlock m => MonadBlock (MaybeT m) where
  catchPatternErr h m = MaybeT $ catchPatternErr (runMaybeT . h) $ runMaybeT m

instance MonadBlock m => MonadBlock (ReaderT e m) where
  catchPatternErr h m = ReaderT $ \ e ->
    let run = flip runReaderT e in catchPatternErr (run . h) (run m)

-------------------------------------------------------------------
-- * Constraint prioritization
-------------------------------------------------------------------

data Strive = Doable
            | ExtraEffort EffortDelta
strive :: (MonadTCEnv m) =>
          EffortLevel
          -- ^ Effort required for the following action
          -> m Strive
strive e = do
  e' <- asksTC envEffortLevel
  if e <= e' then
    return Doable
  else
    return $ ExtraEffort $ effortDeltaFromTo e' e

---------------------------------------------------------------------------
-- * Type checking monad transformer
---------------------------------------------------------------------------

-- | The type checking monad transformer.
-- Adds readonly 'TCEnv' and mutable 'TCState'.
newtype TCMT m a = TCM { unTCM :: IORef TCState -> TCEnv -> m a }

-- | Type checking monad.
type TCM = TCMT IO

{-# SPECIALIZE INLINE mapTCMT :: (forall a. IO a -> IO a) -> TCM a -> TCM a #-}
mapTCMT :: (forall a. m a -> n a) -> TCMT m a -> TCMT n a
mapTCMT f (TCM m) = TCM $ \ s e -> f (m s e)

pureTCM :: MonadIO m => (TCState -> TCEnv -> a) -> TCMT m a
pureTCM f = TCM $ \ r e -> do
  s <- liftIO $ readIORef r
  return (f s e)

-- One goal of the definitions and pragmas below is to inline the
-- monad operations as much as possible. This doesn't seem to have a
-- large effect on the performance of the normal executable, but (at
-- least on one machine/configuration) it has a massive effect on the
-- performance of the profiling executable [1], and reduces the time
-- attributed to bind from over 90% to about 25%.
--
-- [1] When compiled with -auto-all and run with -p: roughly 750%
-- faster for one example.

returnTCMT :: MonadIO m => a -> TCMT m a
returnTCMT = \x -> TCM $ \_ _ -> return x
{-# INLINE returnTCMT #-}

bindTCMT :: MonadIO m => TCMT m a -> (a -> TCMT m b) -> TCMT m b
bindTCMT = \(TCM m) k -> TCM $ \r e -> m r e >>= \x -> unTCM (k x) r e
{-# INLINE bindTCMT #-}

thenTCMT :: MonadIO m => TCMT m a -> TCMT m b -> TCMT m b
thenTCMT = \(TCM m1) (TCM m2) -> TCM $ \r e -> m1 r e >> m2 r e
{-# INLINE thenTCMT #-}

instance MonadIO m => Functor (TCMT m) where
  fmap = fmapTCMT

fmapTCMT :: MonadIO m => (a -> b) -> TCMT m a -> TCMT m b
fmapTCMT = \f (TCM m) -> TCM $ \r e -> fmap f (m r e)
{-# INLINE fmapTCMT #-}

instance MonadIO m => Applicative (TCMT m) where
  pure  = returnTCMT
  (<*>) = apTCMT

apTCMT :: MonadIO m => TCMT m (a -> b) -> TCMT m a -> TCMT m b
apTCMT = \(TCM mf) (TCM m) -> TCM $ \r e -> ap (mf r e) (m r e)
{-# INLINE apTCMT #-}

instance MonadTrans TCMT where
    lift m = TCM $ \_ _ -> m

-- We want a special monad implementation of fail.
instance MonadIO m => Monad (TCMT m) where
    return = pure
    (>>=)  = bindTCMT
    (>>)   = (*>)
#if __GLASGOW_HASKELL__ < 808
    fail   = Fail.fail
#endif

instance MonadIO m => Fail.MonadFail (TCMT m) where
  fail = internalError

instance MonadIO m => MonadIO (TCMT m) where
  liftIO m = TCM $ \ s env -> do
    liftIO $ wrap s (envRange env) $ do
      x <- m
      x `seq` return x
    where
      wrap s r m = E.catch m $ \ err -> do
        s <- readIORef s
        E.throwIO $ IOException s r err

instance MonadIO m => MonadTCEnv (TCMT m) where
  askTC             = TCM $ \ _ e -> return e
  localTC f (TCM m) = TCM $ \ s e -> m s (f e)

instance MonadIO m => MonadTCState (TCMT m) where
  getTC   = TCM $ \ r _e -> liftIO (readIORef r)
  putTC s = TCM $ \ r _e -> liftIO (writeIORef r s)
  modifyTC f = putTC . f =<< getTC

instance MonadIO m => ReadTCState (TCMT m) where
  getTCState = getTC
  locallyTCState l f = bracket_ (useTC l <* modifyTCLens l f) (setTCLens l)

instance MonadBlock TCM where
  patternViolation b = throwError (PatternErr b)
  catchPatternErr handle v =
       catchError_ v $ \err ->
       case err of
            -- Not putting s (which should really be the what's already there) makes things go
            -- a lot slower (+20% total time on standard library). How is that possible??
            -- The problem is most likely that there are internal catchErrors which forgets the
            -- state. catchError should preserve the state on pattern violations.
           PatternErr u -> handle u
           _            -> throwError err


instance MonadError TCErr TCM where
  throwError = liftIO . E.throwIO
  catchError m h = TCM $ \ r e -> do  -- now we are in the IO monad
    oldState <- readIORef r
    unTCM m r e `E.catch` \err -> do
      -- Reset the state, but do not forget changes to the persistent
      -- component. Not for pattern violations.
      case err of
        PatternErr{} -> return ()
        _            ->
          liftIO $ do
            newState <- readIORef r
            writeIORef r $ oldState { stPersistentState = stPersistentState newState }
      unTCM (h err) r e

-- | Like 'catchError', but resets the state completely before running the handler.
--   This means it also loses changes to the 'stPersistentState'.
--
--   The intended use is to catch internal errors during debug printing.
--   In debug printing, we are not expecting state changes.
instance CatchImpossible TCM where
  catchImpossibleJust f m h = TCM $ \ r e -> do
    -- save the state
    s <- readIORef r
    catchImpossibleJust f (unTCM m r e) $ \ err -> do
      writeIORef r s
      unTCM (h err) r e

instance MonadIO m => MonadReduce (TCMT m) where
  liftReduce = liftTCM . runReduceM

instance (IsString a, MonadIO m) => IsString (TCMT m a) where
  fromString s = return (fromString s)

-- | Strict (non-shortcut) semigroup.
--
--   Note that there might be a lazy alternative, e.g.,
--   for TCM All we might want 'Agda.Utils.Monad.and2M' as concatenation,
--   to shortcut conjunction in case we already have 'False'.
--
instance {-# OVERLAPPABLE #-} (MonadIO m, Semigroup a) => Semigroup (TCMT m a) where
  (<>) = liftA2 (<>)

-- | Strict (non-shortcut) monoid.
instance {-# OVERLAPPABLE #-} (MonadIO m, Semigroup a, Monoid a) => Monoid (TCMT m a) where
  mempty  = pure mempty
  mappend = (<>)
  mconcat = mconcat <.> sequence

instance {-# OVERLAPPABLE #-} (MonadIO m, Null a) => Null (TCMT m a) where
  empty = return empty
  null  = __IMPOSSIBLE__

-- | Preserve the state of the failing computation.
catchError_ :: TCM a -> (TCErr -> TCM a) -> TCM a
catchError_ m h = TCM $ \r e ->
  unTCM m r e
  `E.catch` \err -> unTCM (h err) r e

-- | Execute a finalizer even when an exception is thrown.
--   Does not catch any errors.
--   In case both the regular computation and the finalizer
--   throw an exception, the one of the finalizer is propagated.
finally_ :: TCM a -> TCM b -> TCM a
finally_ m f = do
    x <- m `catchError_` \ err -> f >> throwError err
    _ <- f
    return x

-- | Embedding a TCM computation.

class ( Applicative tcm, MonadIO tcm
      , MonadTCEnv tcm
      , MonadTCState tcm
      , HasOptions tcm
      ) => MonadTCM tcm where
    liftTCM :: TCM a -> tcm a

    default liftTCM :: (MonadTCM m, MonadTrans t, tcm ~ t m) => TCM a -> tcm a
    liftTCM = lift . liftTCM

{-# RULES "liftTCM/id" liftTCM = id #-}
instance MonadIO m => MonadTCM (TCMT m) where
    liftTCM = mapTCMT liftIO

instance MonadTCM tcm => MonadTCM (ChangeT tcm)
instance MonadTCM tcm => MonadTCM (ExceptT err tcm)
instance MonadTCM tcm => MonadTCM (IdentityT tcm)
instance MonadTCM tcm => MonadTCM (ListT tcm)
instance MonadTCM tcm => MonadTCM (MaybeT tcm)
instance MonadTCM tcm => MonadTCM (ReaderT r tcm)
instance MonadTCM tcm => MonadTCM (StateT s tcm)
instance (Monoid w, MonadTCM tcm) => MonadTCM (WriterT w tcm)

-- | We store benchmark statistics in an IORef.
--   This enables benchmarking pure computation, see
--   "Agda.Benchmarking".
instance MonadBench TCM where
  type BenchPhase TCM = Phase
  getBenchmark = liftIO $ getBenchmark
  putBenchmark = liftIO . putBenchmark
  finally = finally_

instance Null (TCM Doc) where
  empty = return empty
  null = __IMPOSSIBLE__

internalError :: (HasCallStack, MonadTCM tcm) => String -> tcm a
internalError s = withCallerCallStack $ \ loc ->
  liftTCM $ typeError' loc $ InternalError s

-- | The constraints needed for 'typeError' and similar.
type MonadTCError m = (MonadTCEnv m, ReadTCState m, MonadError TCErr m)

-- | Utility function for 1-arg constructed type errors.
-- Note that the @HasCallStack@ constraint is on the *resulting* function.
locatedTypeError :: MonadTCError m => (a -> TypeError) -> (HasCallStack => a -> m b)
locatedTypeError f e = withCallerCallStack (flip typeError' (f e))

genericError :: (HasCallStack, MonadTCError m) => String -> m a
genericError = locatedTypeError GenericError

{-# SPECIALIZE genericDocError :: Doc -> TCM a #-}
genericDocError :: (HasCallStack, MonadTCError m) => Doc -> m a
genericDocError = locatedTypeError GenericDocError

{-# SPECIALIZE typeError' :: CallStack -> TypeError -> TCM a #-}
typeError' :: MonadTCError m => CallStack -> TypeError -> m a
typeError' loc err = throwError =<< typeError'_ loc err

{-# SPECIALIZE typeError :: HasCallStack => TypeError -> TCM a #-}
typeError :: (HasCallStack, MonadTCError m) => TypeError -> m a
typeError err = withCallerCallStack $ \loc -> throwError =<< typeError'_ loc err

{-# SPECIALIZE typeError'_ :: CallStack -> TypeError -> TCM TCErr #-}
typeError'_ :: (MonadTCEnv m, ReadTCState m) => CallStack -> TypeError -> m TCErr
typeError'_ loc err = TypeError loc <$> getTCState <*> buildClosure err

{-# SPECIALIZE typeError_ :: HasCallStack => TypeError -> TCM TCErr #-}
typeError_ :: (HasCallStack, MonadTCEnv m, ReadTCState m) => TypeError -> m TCErr
typeError_ = withCallerCallStack . flip typeError'_

-- | Running the type checking monad (most general form).
{-# SPECIALIZE runTCM :: TCEnv -> TCState -> TCM a -> IO (a, TCState) #-}
runTCM :: MonadIO m => TCEnv -> TCState -> TCMT m a -> m (a, TCState)
runTCM e s m = do
  r <- liftIO $ newIORef s
  a <- unTCM m r e
  s <- liftIO $ readIORef r
  return (a, s)

-- | Running the type checking monad on toplevel (with initial state).
runTCMTop :: TCM a -> IO (Either TCErr a)
runTCMTop m = (Right <$> runTCMTop' m) `E.catch` (return . Left)

runTCMTop' :: MonadIO m => TCMT m a -> m a
runTCMTop' m = do
  r <- liftIO $ newIORef initState
  unTCM m r initEnv

-- | 'runSafeTCM' runs a safe 'TCM' action (a 'TCM' action which
--   cannot fail, except that it might raise 'IOException's) in the
--   initial environment.

runSafeTCM :: TCM a -> TCState -> IO (a, TCState)
runSafeTCM m st =
  runTCM initEnv st m `E.catch` \(e :: TCErr) -> case e of
    IOException _ _ err -> E.throwIO err
    _                   -> __IMPOSSIBLE__

-- | Runs the given computation in a separate thread, with /a copy/ of
-- the current state and environment.
--
-- Note that Agda sometimes uses actual, mutable state. If the
-- computation given to @forkTCM@ tries to /modify/ this state, then
-- bad things can happen, because accesses are not mutually exclusive.
-- The @forkTCM@ function has been added mainly to allow the thread to
-- /read/ (a snapshot of) the current state in a convenient way.
--
-- Note also that exceptions which are raised in the thread are not
-- propagated to the parent, so the thread should not do anything
-- important.

forkTCM :: TCM a -> TCM ()
forkTCM m = do
  s <- getTC
  e <- askTC
  liftIO $ void $ C.forkIO $ void $ runTCM e s m

---------------------------------------------------------------------------
-- * Names for generated definitions
---------------------------------------------------------------------------

-- | Base name for patterns in telescopes
patternInTeleName :: String
patternInTeleName = ".patternInTele"

-- | Base name for extended lambda patterns
extendedLambdaName :: String
extendedLambdaName = ".extendedlambda"

-- | Check whether we have an definition from an extended lambda.
isExtendedLambdaName :: A.QName -> Bool
isExtendedLambdaName = (extendedLambdaName `List.isPrefixOf`) . prettyShow . nameConcrete . qnameName

-- | Name of absurdLambda definitions.
absurdLambdaName :: String
absurdLambdaName = ".absurdlambda"

-- | Check whether we have an definition from an absurd lambda.
isAbsurdLambdaName :: QName -> Bool
isAbsurdLambdaName = (absurdLambdaName ==) . prettyShow . qnameName

-- | Base name for generalized variable projections
generalizedFieldName :: String
generalizedFieldName = ".generalizedField-"

-- | Check whether we have a generalized variable field
getGeneralizedFieldName :: A.QName -> Maybe String
getGeneralizedFieldName q
  | generalizedFieldName `List.isPrefixOf` strName = Just (drop (length generalizedFieldName) strName)
  | otherwise                                      = Nothing
  where strName = prettyShow $ nameConcrete $ qnameName q

---------------------------------------------------------------------------
-- * KillRange instances
---------------------------------------------------------------------------

instance KillRange Signature where
  killRange (Sig secs defs rews) = killRange2 Sig secs defs rews

instance KillRange Sections where
  killRange = fmap killRange

instance KillRange Definitions where
  killRange = fmap killRange

instance KillRange RewriteRuleMap where
  killRange = fmap killRange

instance KillRange Section where
  killRange (Section tel) = killRange1 Section tel

instance KillRange Definition where
  killRange (Defn ai name t pols occs gens gpars displ mut compiled inst copy ma nc inj copat blk def) =
    killRange18 Defn ai name t pols occs gens gpars displ mut compiled inst copy ma nc inj copat blk def
    -- TODO clarify: Keep the range in the defName field?

instance KillRange NumGeneralizableArgs where
  killRange = id

instance KillRange NLPat where
  killRange (PVar x y) = killRange2 PVar x y
  killRange (PDef x y) = killRange2 PDef x y
  killRange (PLam x y) = killRange2 PLam x y
  killRange (PPi x y)  = killRange2 PPi x y
  killRange (PSort x)  = killRange1 PSort x
  killRange (PBoundVar x y) = killRange2 PBoundVar x y
  killRange (PTerm x)  = killRange1 PTerm x

instance KillRange NLPType where
  killRange (NLPType s a) = killRange2 NLPType s a

instance KillRange NLPSort where
  killRange (PType l) = killRange1 PType l
  killRange (PProp l) = killRange1 PProp l
  killRange s@(PInf f n) = s
  killRange PSizeUniv = PSizeUniv
  killRange PLockUniv = PLockUniv

instance KillRange RewriteRule where
  killRange (RewriteRule q gamma f es rhs t c) =
    killRange6 RewriteRule q gamma f es rhs t c

instance KillRange CompiledRepresentation where
  killRange = id


instance KillRange EtaEquality where
  killRange = id

instance KillRange System where
  killRange (System tel sys) = System (killRange tel) (killRange sys)

instance KillRange ExtLamInfo where
  killRange (ExtLamInfo m b sys) = killRange3 ExtLamInfo m b sys

instance KillRange FunctionFlag where
  killRange = id

instance KillRange CompKit where
  killRange = id

instance KillRange Defn where
  killRange def =
    case def of
      Axiom -> Axiom
      DataOrRecSig n -> DataOrRecSig n
      GeneralizableVar -> GeneralizableVar
      AbstractDefn{} -> __IMPOSSIBLE__ -- only returned by 'getConstInfo'!
      Function cls comp ct tt covering inv mut isAbs delayed proj flags term extlam with ->
        killRange14 Function cls comp ct tt covering inv mut isAbs delayed proj flags term extlam with
      Datatype a b c d e f g h       -> killRange7 Datatype a b c d e f g h
      Record a b c d e f g h i j k l -> killRange12 Record a b c d e f g h i j k l
      Constructor a b c d e f g h i j-> killRange10 Constructor a b c d e f g h i j
      Primitive a b c d e            -> killRange5 Primitive a b c d e
      PrimitiveSort a b              -> killRange2 PrimitiveSort a b

instance KillRange MutualId where
  killRange = id

instance KillRange c => KillRange (FunctionInverse' c) where
  killRange NotInjective = NotInjective
  killRange (Inverse m)  = Inverse $ killRangeMap m

instance KillRange TermHead where
  killRange SortHead     = SortHead
  killRange PiHead       = PiHead
  killRange (ConsHead q) = ConsHead $ killRange q
  killRange h@VarHead{}  = h
  killRange UnknownHead  = UnknownHead

instance KillRange Projection where
  killRange (Projection a b c d e) = killRange5 Projection a b c d e

instance KillRange ProjLams where
  killRange = id

instance KillRange a => KillRange (Open a) where
  killRange = fmap killRange

instance KillRange DisplayForm where
  killRange (Display n es dt) = killRange3 Display n es dt

instance KillRange Polarity where
  killRange = id

instance KillRange IsForced where
  killRange = id

instance KillRange DoGeneralize where
  killRange = id

instance KillRange DisplayTerm where
  killRange dt =
    case dt of
      DWithApp dt dts es -> killRange3 DWithApp dt dts es
      DCon q ci dts     -> killRange3 DCon q ci dts
      DDef q dts        -> killRange2 DDef q dts
      DDot v            -> killRange1 DDot v
      DTerm v           -> killRange1 DTerm v

instance KillRange a => KillRange (Closure a) where
  killRange = id
