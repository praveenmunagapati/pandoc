{-# LANGUAGE CPP               #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards     #-}

{-
Copyright (C) 2014-2017 Jesse Rosenthal <jrosenthal@jhu.edu>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module      : Text.Pandoc.Readers.Docx
   Copyright   : Copyright (C) 2014-2017 Jesse Rosenthal
   License     : GNU GPL, version 2 or above

   Maintainer  : Jesse Rosenthal <jrosenthal@jhu.edu>
   Stability   : alpha
   Portability : portable

Conversion of Docx type (defined in Text.Pandoc.Readers.Docx.Parse)
to 'Pandoc' document.  -}

{-
Current state of implementation of Docx entities ([x] means
implemented, [-] means partially implemented):

* Blocks

  - [X] Para
  - [X] CodeBlock (styled with `SourceCode`)
  - [X] BlockQuote (styled with `Quote`, `BlockQuote`, or, optionally,
        indented)
  - [X] OrderedList
  - [X] BulletList
  - [X] DefinitionList (styled with adjacent `DefinitionTerm` and `Definition`)
  - [X] Header (styled with `Heading#`)
  - [ ] HorizontalRule
  - [-] Table (column widths and alignments not yet implemented)

* Inlines

  - [X] Str
  - [X] Emph
  - [X] Strong
  - [X] Strikeout
  - [X] Superscript
  - [X] Subscript
  - [X] SmallCaps
  - [-] Underline (was previously converted to Emph)
  - [ ] Quoted
  - [ ] Cite
  - [X] Code (styled with `VerbatimChar`)
  - [X] Space
  - [X] LineBreak (these are invisible in Word: entered with Shift-Return)
  - [X] Math
  - [X] Link (links to an arbitrary bookmark create a span with the target as
        id and "anchor" class)
  - [X] Image
  - [X] Note (Footnotes and Endnotes are silently combined.)
-}

module Text.Pandoc.Readers.Docx
       ( readDocx
       ) where

import Codec.Archive.Zip
import Control.Monad.Reader
import Control.Monad.State.Strict
import qualified Data.ByteString.Lazy as B
import Data.Default (Default)
import Data.List (delete, intersect)
import qualified Data.Map as M
import Data.Sequence (ViewL (..), viewl)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Text.Pandoc.Builder
-- import Text.Pandoc.Definition
import Text.Pandoc.MediaBag (MediaBag)
import Text.Pandoc.Options
import Text.Pandoc.Readers.Docx.Combine
import Text.Pandoc.Readers.Docx.Lists
import Text.Pandoc.Readers.Docx.Parse
import Text.Pandoc.Shared
import Text.Pandoc.Walk
import Text.TeXMath (writeTeX)
#if !(MIN_VERSION_base(4,8,0))
import Data.Traversable (traverse)
#endif
import Control.Monad.Except (throwError)
import Text.Pandoc.Class (PandocMonad)
import qualified Text.Pandoc.Class as P
import Text.Pandoc.Error
import Text.Pandoc.Logging

readDocx :: PandocMonad m
         => ReaderOptions
         -> B.ByteString
         -> m Pandoc
readDocx opts bytes
  | Right archive <- toArchiveOrFail bytes
  , Right (docx, parserWarnings) <- archiveToDocxWithWarnings archive = do
      mapM_ (P.report . DocxParserWarning) parserWarnings
      (meta, blks) <- docxToOutput opts docx
      return $ Pandoc meta blks
readDocx _ _ =
  throwError $ PandocSomeError "couldn't parse docx file"

data DState = DState { docxAnchorMap :: M.Map String String
                     , docxMediaBag  :: MediaBag
                     , docxDropCap   :: Inlines
                     , docxWarnings  :: [String]
                     }

instance Default DState where
  def = DState { docxAnchorMap = M.empty
               , docxMediaBag  = mempty
               , docxDropCap   = mempty
               , docxWarnings  = []
               }

data DEnv = DEnv { docxOptions       :: ReaderOptions
                 , docxInHeaderBlock :: Bool }

instance Default DEnv where
  def = DEnv def False

type DocxContext m = ReaderT DEnv (StateT DState m)

evalDocxContext :: PandocMonad m => DocxContext m a -> DEnv -> DState -> m a
evalDocxContext ctx env st = flip evalStateT st $flip runReaderT env ctx

-- This is empty, but we put it in for future-proofing.
spansToKeep :: [String]
spansToKeep = []

divsToKeep :: [String]
divsToKeep = ["list-item", "Definition", "DefinitionTerm"]

metaStyles :: M.Map String String
metaStyles = M.fromList [ ("Title", "title")
                        , ("Subtitle", "subtitle")
                        , ("Author", "author")
                        , ("Date", "date")
                        , ("Abstract", "abstract")]

sepBodyParts :: [BodyPart] -> ([BodyPart], [BodyPart])
sepBodyParts = span (\bp -> isMetaPar bp || isEmptyPar bp)

isMetaPar :: BodyPart -> Bool
isMetaPar (Paragraph pPr _) =
  not $ null $ intersect (pStyle pPr) (M.keys metaStyles)
isMetaPar _ = False

isEmptyPar :: BodyPart -> Bool
isEmptyPar (Paragraph _ parParts) =
  all isEmptyParPart parParts
  where
    isEmptyParPart (PlainRun (Run _ runElems)) = all isEmptyElem runElems
    isEmptyParPart _                           = False
    isEmptyElem (TextRun s) = trim s == ""
    isEmptyElem _           = True
isEmptyPar _ = False

bodyPartsToMeta' :: PandocMonad m => [BodyPart] -> DocxContext m (M.Map String MetaValue)
bodyPartsToMeta' [] = return M.empty
bodyPartsToMeta' (bp : bps)
  | (Paragraph pPr parParts) <- bp
  , (c : _)<- intersect (pStyle pPr) (M.keys metaStyles)
  , (Just metaField) <- M.lookup c metaStyles = do
    inlines <- smushInlines <$> mapM parPartToInlines parParts
    remaining <- bodyPartsToMeta' bps
    let
      f (MetaInlines ils) (MetaInlines ils') = MetaBlocks [Para ils, Para ils']
      f (MetaInlines ils) (MetaBlocks blks) = MetaBlocks (Para ils : blks)
      f m (MetaList mv) = MetaList (m : mv)
      f m n             = MetaList [m, n]
    return $ M.insertWith f metaField (MetaInlines (toList inlines)) remaining
bodyPartsToMeta' (_ : bps) = bodyPartsToMeta' bps

bodyPartsToMeta :: PandocMonad m => [BodyPart] -> DocxContext m Meta
bodyPartsToMeta bps = do
  mp <- bodyPartsToMeta' bps
  let mp' =
        case M.lookup "author" mp of
          Just mv -> M.insert "author" (fixAuthors mv) mp
          Nothing -> mp
  return $ Meta mp'

fixAuthors :: MetaValue -> MetaValue
fixAuthors (MetaBlocks blks) =
  MetaList $ map g $ filter f blks
    where f (Para _) = True
          f _        = False
          g (Para ils) = MetaInlines ils
          g _          = MetaInlines []
fixAuthors mv = mv

codeStyles :: [String]
codeStyles = ["VerbatimChar"]

codeDivs :: [String]
codeDivs = ["SourceCode"]

runElemToInlines :: RunElem -> Inlines
runElemToInlines (TextRun s)     = text s
runElemToInlines LnBrk         = linebreak
runElemToInlines Tab           = space
runElemToInlines SoftHyphen    = text "\xad"
runElemToInlines NoBreakHyphen = text "\x2011"

runElemToString :: RunElem -> String
runElemToString (TextRun s)     = s
runElemToString LnBrk         = ['\n']
runElemToString Tab           = ['\t']
runElemToString SoftHyphen    = ['\xad']
runElemToString NoBreakHyphen = ['\x2011']

runToString :: Run -> String
runToString (Run _ runElems) = concatMap runElemToString runElems
runToString _                = ""

parPartToString :: ParPart -> String
parPartToString (PlainRun run)             = runToString run
parPartToString (InternalHyperLink _ runs) = concatMap runToString runs
parPartToString (ExternalHyperLink _ runs) = concatMap runToString runs
parPartToString _                          = ""

blacklistedCharStyles :: [String]
blacklistedCharStyles = ["Hyperlink"]

resolveDependentRunStyle :: RunStyle -> RunStyle
resolveDependentRunStyle rPr
  | Just (s, _)  <- rStyle rPr, s `elem` blacklistedCharStyles =
    rPr
  | Just (_, cs) <- rStyle rPr =
      let rPr' = resolveDependentRunStyle cs
      in
       RunStyle { isBold = case isBold rPr of
                     Just bool -> Just bool
                     Nothing   -> isBold rPr'
                , isItalic = case isItalic rPr of
                     Just bool -> Just bool
                     Nothing   -> isItalic rPr'
                , isSmallCaps = case isSmallCaps rPr of
                     Just bool -> Just bool
                     Nothing   -> isSmallCaps rPr'
                , isStrike = case isStrike rPr of
                     Just bool -> Just bool
                     Nothing   -> isStrike rPr'
                , rVertAlign = case rVertAlign rPr of
                     Just valign -> Just valign
                     Nothing     -> rVertAlign rPr'
                , rUnderline = case rUnderline rPr of
                     Just ulstyle -> Just ulstyle
                     Nothing      -> rUnderline rPr'
                , rStyle = rStyle rPr }
  | otherwise = rPr

runStyleToTransform :: RunStyle -> (Inlines -> Inlines)
runStyleToTransform rPr
  | Just (s, _) <- rStyle rPr
  , s `elem` spansToKeep =
    let rPr' = rPr{rStyle = Nothing}
    in
     spanWith ("", [s], []) . runStyleToTransform rPr'
  | Just True <- isItalic rPr =
      emph . runStyleToTransform rPr {isItalic = Nothing}
  | Just True <- isBold rPr =
      strong . runStyleToTransform rPr {isBold = Nothing}
  | Just True <- isSmallCaps rPr =
      smallcaps . runStyleToTransform rPr {isSmallCaps = Nothing}
  | Just True <- isStrike rPr =
      strikeout . runStyleToTransform rPr {isStrike = Nothing}
  | Just SupScrpt <- rVertAlign rPr =
      superscript . runStyleToTransform rPr {rVertAlign = Nothing}
  | Just SubScrpt <- rVertAlign rPr =
      subscript . runStyleToTransform rPr {rVertAlign = Nothing}
  | Just "single" <- rUnderline rPr =
      underlineSpan . runStyleToTransform rPr {rUnderline = Nothing}
  | otherwise = id

runToInlines :: PandocMonad m => Run -> DocxContext m Inlines
runToInlines (Run rs runElems)
  | Just (s, _) <- rStyle rs
  , s `elem` codeStyles =
    let rPr = resolveDependentRunStyle rs
        codeString = code $ concatMap runElemToString runElems
    in
     return $ case rVertAlign rPr of
     Just SupScrpt -> superscript codeString
     Just SubScrpt -> subscript codeString
     _             -> codeString
  | otherwise = do
    let ils = smushInlines (map runElemToInlines runElems)
    return $ (runStyleToTransform $ resolveDependentRunStyle rs) ils
runToInlines (Footnote bps) = do
  blksList <- smushBlocks <$> mapM bodyPartToBlocks bps
  return $ note blksList
runToInlines (Endnote bps) = do
  blksList <- smushBlocks <$> mapM bodyPartToBlocks bps
  return $ note blksList
runToInlines (InlineDrawing fp title alt bs ext) = do
  (lift . lift) $ P.insertMedia fp Nothing bs
  return $ imageWith (extentToAttr ext) fp title $ text alt
runToInlines InlineChart = return $ spanWith ("", ["chart"], []) $ text "[CHART]"

extentToAttr :: Extent -> Attr
extentToAttr (Just (w, h)) =
  ("", [], [("width", showDim w), ("height", showDim h)] )
  where
    showDim d = show (d / 914400) ++ "in"
extentToAttr _ = nullAttr

blocksToInlinesWarn :: PandocMonad m => String -> Blocks -> DocxContext m Inlines
blocksToInlinesWarn cmtId blks = do
  let blkList = toList blks
      notParaOrPlain :: Block -> Bool
      notParaOrPlain (Para _)  = False
      notParaOrPlain (Plain _) = False
      notParaOrPlain _         = True
  unless (null $ filter notParaOrPlain blkList) $
    lift $ P.report $ DocxParserWarning $
      "Docx comment " ++ cmtId ++ " will not retain formatting"
  return $ fromList $ blocksToInlines blkList

parPartToInlines :: PandocMonad m => ParPart -> DocxContext m Inlines
parPartToInlines (PlainRun r) = runToInlines r
parPartToInlines (Insertion _ author date runs) = do
  opts <- asks docxOptions
  case readerTrackChanges opts of
    AcceptChanges -> smushInlines <$> mapM runToInlines runs
    RejectChanges -> return mempty
    AllChanges    -> do
      ils <- smushInlines <$> mapM runToInlines runs
      let attr = ("", ["insertion"], [("author", author), ("date", date)])
      return $ spanWith attr ils
parPartToInlines (Deletion _ author date runs) = do
  opts <- asks docxOptions
  case readerTrackChanges opts of
    AcceptChanges -> return mempty
    RejectChanges -> smushInlines <$> mapM runToInlines runs
    AllChanges    -> do
      ils <- smushInlines <$> mapM runToInlines runs
      let attr = ("", ["deletion"], [("author", author), ("date", date)])
      return $ spanWith attr ils
parPartToInlines (CommentStart cmtId author date bodyParts) = do
  opts <- asks docxOptions
  case readerTrackChanges opts of
    AllChanges -> do
      blks <- smushBlocks <$> mapM bodyPartToBlocks bodyParts
      ils <- blocksToInlinesWarn cmtId blks
      let attr = ("", ["comment-start"], [("id", cmtId), ("author", author), ("date", date)])
      return $ spanWith attr ils
    _ -> return mempty
parPartToInlines (CommentEnd cmtId) = do
  opts <- asks docxOptions
  case readerTrackChanges opts of
    AllChanges -> do
      let attr = ("", ["comment-end"], [("id", cmtId)])
      return $ spanWith attr mempty
    _ -> return mempty
parPartToInlines (BookMark _ anchor) | anchor `elem` dummyAnchors =
  return mempty
parPartToInlines (BookMark _ anchor) =
  -- We record these, so we can make sure not to overwrite
  -- user-defined anchor links with header auto ids.
  do
    -- get whether we're in a header.
    inHdrBool <- asks docxInHeaderBlock
    -- Get the anchor map.
    anchorMap <- gets docxAnchorMap
    -- We don't want to rewrite if we're in a header, since we'll take
    -- care of that later, when we make the header anchor. If the
    -- bookmark were already in uniqueIdent form, this would lead to a
    -- duplication. Otherwise, we check to see if the id is already in
    -- there. Rewrite if necessary. This will have the possible effect
    -- of rewriting user-defined anchor links. However, since these
    -- are not defined in pandoc, it seems like a necessary evil to
    -- avoid an extra pass.
    let newAnchor =
          if not inHdrBool && anchor `elem` M.elems anchorMap
          then uniqueIdent [Str anchor] (Set.fromList $ M.elems anchorMap)
          else anchor
    unless inHdrBool
      (modify $ \s -> s { docxAnchorMap = M.insert anchor newAnchor anchorMap})
    return $ spanWith (newAnchor, ["anchor"], []) mempty
parPartToInlines (Drawing fp title alt bs ext) = do
  (lift . lift) $ P.insertMedia fp Nothing bs
  return $ imageWith (extentToAttr ext) fp title $ text alt
parPartToInlines Chart =
  return $ spanWith ("", ["chart"], []) $ text "[CHART]"
parPartToInlines (InternalHyperLink anchor runs) = do
  ils <- smushInlines <$> mapM runToInlines runs
  return $ link ('#' : anchor) "" ils
parPartToInlines (ExternalHyperLink target runs) = do
  ils <- smushInlines <$> mapM runToInlines runs
  return $ link target "" ils
parPartToInlines (PlainOMath exps) =
  return $ math $ writeTeX exps
parPartToInlines (SmartTag runs) = do
  smushInlines <$> mapM runToInlines runs

isAnchorSpan :: Inline -> Bool
isAnchorSpan (Span (_, classes, kvs) _) =
  classes == ["anchor"] &&
  null kvs
isAnchorSpan _ = False

dummyAnchors :: [String]
dummyAnchors = ["_GoBack"]

makeHeaderAnchor :: PandocMonad m => Blocks -> DocxContext m Blocks
makeHeaderAnchor bs = traverse makeHeaderAnchor' bs

makeHeaderAnchor' :: PandocMonad m => Block -> DocxContext m Block
-- If there is an anchor already there (an anchor span in the header,
-- to be exact), we rename and associate the new id with the old one.
makeHeaderAnchor' (Header n (ident, classes, kvs) ils)
  | (c:_) <- filter isAnchorSpan ils
  , (Span (anchIdent, ["anchor"], _) cIls) <- c = do
    hdrIDMap <- gets docxAnchorMap
    let newIdent = if null ident
                   then uniqueIdent ils (Set.fromList $ M.elems hdrIDMap)
                   else ident
        newIls = concatMap f ils where f il | il == c   = cIls
                                            | otherwise = [il]
    modify $ \s -> s {docxAnchorMap = M.insert anchIdent newIdent hdrIDMap}
    makeHeaderAnchor' $ Header n (newIdent, classes, kvs) newIls
-- Otherwise we just give it a name, and register that name (associate
-- it with itself.)
makeHeaderAnchor' (Header n (ident, classes, kvs) ils) =
  do
    hdrIDMap <- gets docxAnchorMap
    let newIdent = if null ident
                   then uniqueIdent ils (Set.fromList $ M.elems hdrIDMap)
                   else ident
    modify $ \s -> s {docxAnchorMap = M.insert newIdent newIdent hdrIDMap}
    return $ Header n (newIdent, classes, kvs) ils
makeHeaderAnchor' blk = return blk

-- Rewrite a standalone paragraph block as a plain
singleParaToPlain :: Blocks -> Blocks
singleParaToPlain blks
  | (Para ils :< seeq) <- viewl $ unMany blks
  , Seq.null seeq =
      singleton $ Plain ils
singleParaToPlain blks = blks

cellToBlocks :: PandocMonad m => Cell -> DocxContext m Blocks
cellToBlocks (Cell bps) = do
  blks <- smushBlocks <$> mapM bodyPartToBlocks bps
  return $ fromList $ blocksToDefinitions $ blocksToBullets $ toList blks

rowToBlocksList :: PandocMonad m => Row -> DocxContext m [Blocks]
rowToBlocksList (Row cells) = do
  blksList <- mapM cellToBlocks cells
  return $ map singleParaToPlain blksList

-- like trimInlines, but also take out linebreaks
trimSps :: Inlines -> Inlines
trimSps (Many ils) = Many $ Seq.dropWhileL isSp $Seq.dropWhileR isSp ils
  where isSp Space     = True
        isSp SoftBreak = True
        isSp LineBreak = True
        isSp _         = False

parStyleToTransform :: ParagraphStyle -> (Blocks -> Blocks)
parStyleToTransform pPr
  | (c:cs) <- pStyle pPr
  , c `elem` divsToKeep =
    let pPr' = pPr { pStyle = cs }
    in
     divWith ("", [c], []) . parStyleToTransform pPr'
  | (c:cs) <- pStyle pPr,
    c `elem` listParagraphDivs =
      let pPr' = pPr { pStyle = cs, indentation = Nothing}
      in
       divWith ("", [c], []) . parStyleToTransform pPr'
  | (_:cs) <- pStyle pPr
  , Just True <- pBlockQuote pPr =
    let pPr' = pPr { pStyle = cs }
    in
     blockQuote . parStyleToTransform pPr'
  | (_:cs) <- pStyle pPr =
      let pPr' = pPr { pStyle = cs}
      in
       parStyleToTransform pPr'
  | null (pStyle pPr)
  , Just left <- indentation pPr >>= leftParIndent
  , Just hang <- indentation pPr >>= hangingParIndent =
    let pPr' = pPr { indentation = Nothing }
    in
     case (left - hang) > 0 of
       True  -> blockQuote . (parStyleToTransform pPr')
       False -> parStyleToTransform pPr'
  | null (pStyle pPr),
    Just left <- indentation pPr >>= leftParIndent =
      let pPr' = pPr { indentation = Nothing }
      in
       case left > 0 of
         True  -> blockQuote . (parStyleToTransform pPr')
         False -> parStyleToTransform pPr'
parStyleToTransform _ = id

bodyPartToBlocks :: PandocMonad m => BodyPart -> DocxContext m Blocks
bodyPartToBlocks (Paragraph pPr parparts)
  | not $ null $ codeDivs `intersect` (pStyle pPr) =
    return
    $ parStyleToTransform pPr
    $ codeBlock
    $ concatMap parPartToString parparts
  | Just (style, n) <- pHeading pPr = do
    ils <-local (\s-> s{docxInHeaderBlock=True})
           (smushInlines <$> mapM parPartToInlines parparts)
    makeHeaderAnchor $
      headerWith ("", delete style (pStyle pPr), []) n ils
  | otherwise = do
    ils <- (trimSps . smushInlines) <$> mapM parPartToInlines parparts
    dropIls <- gets docxDropCap
    let ils' = dropIls <> ils
    if dropCap pPr
      then do modify $ \s -> s { docxDropCap = ils' }
              return mempty
      else do modify $ \s -> s { docxDropCap = mempty }
              return $ case isNull ils' of
                True -> mempty
                _    -> parStyleToTransform pPr $ para ils'
bodyPartToBlocks (ListItem pPr numId lvl (Just levelInfo) parparts) = do
  let
    kvs = case levelInfo of
      (_, fmt, txt, Just start) -> [ ("level", lvl)
                                   , ("num-id", numId)
                                   , ("format", fmt)
                                   , ("text", txt)
                                   , ("start", show start)
                                   ]

      (_, fmt, txt, Nothing)    -> [ ("level", lvl)
                                   , ("num-id", numId)
                                   , ("format", fmt)
                                   , ("text", txt)
                                   ]
  blks <- bodyPartToBlocks (Paragraph pPr parparts)
  return $ divWith ("", ["list-item"], kvs) blks
bodyPartToBlocks (ListItem pPr _ _ _ parparts) =
  let pPr' = pPr {pStyle = "ListParagraph": pStyle pPr}
  in
    bodyPartToBlocks $ Paragraph pPr' parparts
bodyPartToBlocks (Tbl _ _ _ []) =
  return $ para mempty
bodyPartToBlocks (Tbl cap _ look (r:rs)) = do
  let caption = text cap
      (hdr, rows) = case firstRowFormatting look of
        True | null rs -> (Nothing, [r])
             | otherwise -> (Just r, rs)
        False -> (Nothing, r:rs)

  cells <- mapM rowToBlocksList rows

  let width = case cells of
        r':_ -> length r'
        -- shouldn't happen
        []   -> 0

  hdrCells <- case hdr of
    Just r' -> rowToBlocksList r'
    Nothing -> return $ replicate width mempty

      -- The two following variables (horizontal column alignment and
      -- relative column widths) go to the default at the
      -- moment. Width information is in the TblGrid field of the Tbl,
      -- so should be possible. Alignment might be more difficult,
      -- since there doesn't seem to be a column entity in docx.
  let alignments = replicate width AlignDefault
      widths = replicate width 0 :: [Double]

  return $ table caption (zip alignments widths) hdrCells cells
bodyPartToBlocks (OMathPara e) =
  return $ para $ displayMath (writeTeX e)


-- replace targets with generated anchors.
rewriteLink' :: PandocMonad m => Inline -> DocxContext m Inline
rewriteLink' l@(Link attr ils ('#':target, title)) = do
  anchorMap <- gets docxAnchorMap
  return $ case M.lookup target anchorMap of
    Just newTarget -> Link attr ils ('#':newTarget, title)
    Nothing        -> l
rewriteLink' il = return il

rewriteLinks :: PandocMonad m => [Block] -> DocxContext m [Block]
rewriteLinks = mapM (walkM rewriteLink')

bodyToOutput :: PandocMonad m => Body -> DocxContext m (Meta, [Block])
bodyToOutput (Body bps) = do
  let (metabps, blkbps) = sepBodyParts bps
  meta <- bodyPartsToMeta metabps
  blks <- smushBlocks <$> mapM bodyPartToBlocks blkbps
  blks' <- rewriteLinks $ blocksToDefinitions $ blocksToBullets $ toList blks
  return (meta, blks')

docxToOutput :: PandocMonad m
             => ReaderOptions
             -> Docx
             -> m (Meta, [Block])
docxToOutput opts (Docx (Document _ body)) =
  let dEnv   = def { docxOptions  = opts} in
   evalDocxContext (bodyToOutput body) dEnv def
