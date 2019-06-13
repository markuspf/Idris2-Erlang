module Core.Binary

import Core.Context
import Core.Core
import Core.Hash
import Core.Normalise
import Core.Options
import Core.TT
import Core.TTC
import Core.UnifyState

import Data.IntMap
import Data.NameMap

-- Reading and writing 'Defs' from/to  a binary file
-- In order to be saved, a name must have been flagged using 'toSave'.
-- (Otherwise we'd save out everything, not just the things in the current
-- file).

import public Utils.Binary

import Data.Buffer

%default covering

-- increment this when changing anything in the data format
-- TTC files can only be compatible if the version number is the same
export
ttcVersion : Int
ttcVersion = 1

export
checkTTCVersion : Int -> Int -> Core ()
checkTTCVersion ver exp
  = if ver < exp
       then throw (TTCError FormatOlder)
       else if ver > exp
            then throw (TTCError FormatNewer)
            else pure ()

record TTCFile extra where
  constructor MkTTCFile
  version : Int
  ifaceHash : Int
  importHashes : List (List String, Int)
  nameMap : NameRefs -- All the names referenced in the file
                     -- This is a mapping from the index used in the file
                     -- to the actual name
  holes : List (Int, (FC, Name))
  guesses : List (Int, (FC, Name))
  constraints : List (Int, Constraint)
  context : List GlobalDef
  autoHints : List (Name, Bool)
  typeHints : List (Name, Name, Bool)
  imported : List (List String, Bool, List String)
  nextVar : Int
  currentNS : List String
  pairnames : Maybe PairNames
  rewritenames : Maybe RewriteNames
  primnames : PrimNames
  namedirectives : List (Name, List String)
  cgdirectives : List (CG, String)
  extraData : extra

asName : List String -> Maybe (List String) -> Name -> Name
asName mod (Just ns) (NS oldns n) 
    = if mod == oldns 
         then NS ns n -- TODO: What about if there are nested namespaces in a module?
         else NS oldns n
asName _ _ n = n

readNameMap : {auto c : Ref Ctxt Defs} ->
              NameRefs -> Ref Bin Binary -> Core NameRefs
readNameMap r b
    = do ns <- fromBuf r b
         log 10 $ "Name map:\n" ++ dumpMap 0 ns
         coreLift $ fromList ns
  where
    dumpMap : Int -> List (Maybe (Name, Maybe Int)) -> String
    dumpMap i [] = ""
    dumpMap i (Just (n, _) :: ns) 
        = show i ++ ": " ++ show n ++ "\n" ++ dumpMap (i+1) ns
    dumpMap i (_ :: ns) = dumpMap (i + 1) ns

-- For every name we're going to read from the file, work out what it's
-- new resolved name is going to be in the context and update the name
-- map accordingly
-- Also update namespace if we've done "import ... as ..."
updateEntries : {auto c : Ref Ctxt Defs} ->
                Context GlobalDef ->
                List String -> Maybe (List String) ->
                Int -> Int -> NameRefs -> Core (Context GlobalDef)
updateEntries ctxt mod as pos end r
    = if pos >= end
         then pure ctxt
         else do Just (n, Nothing) <- coreLift $ readArray r pos
                      | _ => updateEntries ctxt mod as (pos+1) end r
                 let n' = asName mod as n
                 (idx, ctxt') <- getPosition n' ctxt
                 coreLift $ writeArray r pos (n', Just idx)
                 updateEntries ctxt' mod as (pos+1) end r

writeNameMap : Ref Bin Binary -> NameRefs -> Core ()
writeNameMap b r
    = do ns <- coreLift $ toList r
         toBuf b ns

-- NOTE: TTC files are only compatible if the version number is the same,
-- *and* the 'annot/extra' type are the same, or there are no holes/constraints
writeTTCFile : TTC extra => Ref Bin Binary -> TTCFile extra -> Core ()
writeTTCFile b file
      = do toBuf b "TTC"
           toBuf b (version file)
           toBuf b (ifaceHash file)
           toBuf b (importHashes file)
           writeNameMap b (nameMap file)
           toBuf b (holes file)
           toBuf b (guesses file)
           toBuf b (constraints file)
           toBuf b (context file)
           toBuf b (autoHints file)
           toBuf b (typeHints file)
           toBuf b (imported file)
           toBuf b (nextVar file)
           toBuf b (currentNS file)
           toBuf b (pairnames file)
           toBuf b (rewritenames file)
           toBuf b (primnames file)
           toBuf b (namedirectives file)
           toBuf b (cgdirectives file)
           toBuf b (extraData file)

readTTCFile : TTC extra => 
              {auto c : Ref Ctxt Defs} ->
              List String -> Maybe (List String) ->
              NameRefs -> Ref Bin Binary -> Core (TTCFile extra)
readTTCFile modns as r b
      = do hdr <- fromBuf r b
           when (hdr /= "TTC") $ corrupt "TTC header"
           ver <- fromBuf r b
           checkTTCVersion ver ttcVersion
           ifaceHash <- fromBuf r b
           importHashes <- fromBuf r b
           -- Read in name map, update 'r'
           r <- readNameMap r b
           defs <- get Ctxt
           gam' <- updateEntries (gamma defs) modns as 0 (max r) r
           setCtxt gam' 
           holes <- fromBuf r b
--            coreLift $ putStrLn $ "Read " ++ show (length holes) ++ " holes"
           guesses <- fromBuf r b
--            coreLift $ putStrLn $ "Read " ++ show (length guesses) ++ " guesses"
           constraints <- the (Core (List (Int, Constraint))) $ fromBuf r b
--            coreLift $ putStrLn $ "Read " ++ show (length constraints) ++ " constraints"
           defs <- fromBuf r b
           autohs <- fromBuf r b
           typehs <- fromBuf r b
--            coreLift $ putStrLn ("Hints: " ++ show typehs)
--            coreLift $ putStrLn $ "Read " ++ show (length (map fullname defs)) ++ " defs"
           imp <- fromBuf r b
           nextv <- fromBuf r b
           cns <- fromBuf r b
           pns <- fromBuf r b
           rws <- fromBuf r b
           prims <- fromBuf r b
           nds <- fromBuf r b
           cgds <- fromBuf r b
           ex <- fromBuf r b
           pure (MkTTCFile ver ifaceHash importHashes r
                           holes guesses constraints defs 
                           autohs typehs imp nextv cns 
                           pns rws prims nds cgds ex)

-- Pull out the list of GlobalDefs that we want to save
getSaveDefs : List Name -> List GlobalDef -> Defs -> Core (List GlobalDef)
getSaveDefs [] acc _ = pure acc
getSaveDefs (n :: ns) acc defs
    = do Just gdef <- lookupCtxtExact n (gamma defs)
              | Nothing => getSaveDefs ns acc defs -- 'n' really should exist though!
         -- No need to save builtins
         case definition gdef of
              Builtin _ => getSaveDefs ns acc defs
              _ => getSaveDefs ns (gdef :: acc) defs

-- Write out the things in the context which have been defined in the
-- current source file
export
writeToTTC : TTC extra =>
             {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST UState} ->
             extra -> (fname : String) -> Core ()
writeToTTC extradata fname
  = logTime "Writing TTC" $ 
      do buf <- initBinary
         defs <- get Ctxt
         ust <- get UST
         gdefs <- getSaveDefs !getSave [] defs
         log 5 $ "Writing " ++ fname ++ " with hash " ++ show (ifaceHash defs)
         r <- getNameRefs (gamma defs)
         writeTTCFile buf 
                   (MkTTCFile ttcVersion (ifaceHash defs) (importHashes defs)
                              r
                              (toList (holes ust)) 
                              (toList (guesses ust)) 
                              (toList (constraints ust))
                              gdefs
                              (saveAutoHints defs)
                              (saveTypeHints defs)
                              (imported defs)
                              (nextName ust)
                              (currentNS defs)
                              (pairnames (options defs)) 
                              (rewritenames (options defs)) 
                              (primnames (options defs)) 
                              (namedirectives (options defs)) 
                              (cgdirectives defs)
                              extradata)
         Right ok <- coreLift $ writeToFile fname !(get Bin)
               | Left err => throw (InternalError (fname ++ ": " ++ show err))
         pure ()

addGlobalDef : {auto c : Ref Ctxt Defs} ->
               (modns : List String) -> (importAs : Maybe (List String)) ->
               GlobalDef -> Core ()
addGlobalDef modns as def 
    = do let n = fullname def
         addDef (asName modns as n) def
         pure ()

addTypeHint : {auto c : Ref Ctxt Defs} ->
              FC -> (Name, Name, Bool) -> Core ()
addTypeHint fc (tyn, hintn, d) 
   = do logC 10 (pure (show !(getFullName hintn) ++ " for " ++ 
                       show !(getFullName tyn)))
        addHintFor fc tyn hintn d True

addAutoHint : {auto c : Ref Ctxt Defs} ->
              (Name, Bool) -> Core ()
addAutoHint (hintn, d) = addGlobalHint hintn d

export
updatePair : {auto c : Ref Ctxt Defs} -> 
             Maybe PairNames -> Core ()
updatePair p
    = do defs <- get Ctxt
         put Ctxt (record { options->pairnames $= (p <+>) } defs)

export
updateRewrite : {auto c : Ref Ctxt Defs} -> 
                Maybe RewriteNames -> Core ()
updateRewrite r
    = do defs <- get Ctxt
         put Ctxt (record { options->rewritenames $= (r <+>) } defs)

export
updatePrims : {auto c : Ref Ctxt Defs} -> 
              PrimNames -> Core ()
updatePrims p
    = do defs <- get Ctxt
         put Ctxt (record { options->primnames = p } defs)

-- Add definitions from a binary file to the current context
-- Returns the "extra" section of the file (user defined data), the interface
-- hash and the list of additional TTCs that need importing
-- (we need to return these, rather than do it here, because after loading
-- the data that's when we process the extra data...)
export
readFromTTC : TTC extra =>
              {auto c : Ref Ctxt Defs} ->
              {auto u : Ref UST UState} ->
              FC -> Bool ->
              (fname : String) -> -- file containing the module
              (modNS : List String) -> -- module namespace
              (importAs : List String) -> -- namespace to import as
              Core (Maybe (extra, Int, 
                           List (List String, Bool, List String),
                           NameRefs))
readFromTTC loc reexp fname modNS importAs
  = logTime "Reading TTC" $
      do defs <- get Ctxt
         -- If it's already in the context, don't load it again
         let False = (fname, importAs) `elem` allImported defs
              | True => pure Nothing
         put Ctxt (record { allImported $= ((fname, importAs) :: ) } defs)

         Right buf <- coreLift $ readFromFile fname
               | Left err => throw (InternalError (fname ++ ": " ++ show err))
         bin <- newRef Bin buf -- for reading the file into
         r <- initNameRefs 1 -- this will be updated when we read the name
                             -- map from the file
         let as = if importAs == modNS 
                     then Nothing 
                     else Just importAs
         ttc <- readTTCFile modNS as r bin
         traverse (addGlobalDef modNS as) (context ttc)
         setNS (currentNS ttc)
         -- Set up typeHints and autoHints based on the loaded data
         traverse_ (addTypeHint loc) (typeHints ttc)
         defs <- get Ctxt
         traverse_ addAutoHint (autoHints ttc)
         -- Set up pair/rewrite etc names
         updatePair (pairnames ttc)
         updateRewrite (rewritenames ttc)
         updatePrims (primnames ttc)
         -- TODO: Name directives

         when (not reexp) clearSavedHints
         resetFirstEntry

         -- Finally, update the unification state with the holes from the
         -- ttc
         ust <- get UST
         put UST (record { holes = fromList (holes ttc),
                           constraints = fromList (constraints ttc),
                           nextName = nextVar ttc } ust)
         pure (Just (extraData ttc, ifaceHash ttc, imported ttc, nameMap ttc))

getImportHashes : NameRefs -> Ref Bin Binary ->
                  Core (List (List String, Int))
getImportHashes r b
    = do hdr <- fromBuf r {a = String} b
         when (hdr /= "TTC") $ corrupt "TTC header"
         ver <- fromBuf r {a = Int} b
         checkTTCVersion ver ttcVersion
         ifaceHash <- fromBuf r {a = Int} b
         fromBuf r b

getHash : NameRefs -> Ref Bin Binary -> Core Int
getHash r b
    = do hdr <- fromBuf r {a = String} b
         when (hdr /= "TTC") $ corrupt "TTC header"
         ver <- fromBuf r {a = Int} b
         checkTTCVersion ver ttcVersion
         fromBuf r b

export
readIFaceHash : (fname : String) -> -- file containing the module
                Core Int
readIFaceHash fname
    = do Right buf <- coreLift $ readFromFile fname
            | Left err => pure 0
         b <- newRef Bin buf
         r <- initNameRefs 1
         catch (getHash r b)
               (\err => pure 0)

export
readImportHashes : (fname : String) -> -- file containing the module
                   Core (List (List String, Int))
readImportHashes fname
    = do Right buf <- coreLift $ readFromFile fname
            | Left err => pure []
         b <- newRef Bin buf
         r <- initNameRefs 1
         catch (getImportHashes r b)
               (\err => pure [])

