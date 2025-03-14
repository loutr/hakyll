--------------------------------------------------------------------------------
-- | Wraps pandocs bibiliography handling
--
-- In order to add a bibliography, you will need a bibliography file (e.g.
-- @.bib@) and a CSL file (@.csl@). Both need to be compiled with their
-- respective compilers ('biblioCompiler' and 'cslCompiler'). Then, you can
-- refer to these files when you use 'readPandocBiblio'. This function also
-- takes the reader options for completeness -- you can use
-- 'defaultHakyllReaderOptions' if you're unsure. If you already read the
-- source into a 'Pandoc' type and need to add processing for the bibliography,
-- you can use 'processPandocBiblio' instead.
-- 'pandocBiblioCompiler' is a convenience wrapper which works like 'pandocCompiler',
-- but also takes paths to compiled bibliography and csl files;
-- 'pandocBibliosCompiler' is similar but instead takes a glob pattern for bib files.
{-# LANGUAGE Arrows                     #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
module Hakyll.Web.Pandoc.Biblio
    ( CSL (..)
    , cslCompiler
    , Biblio (..)
    , biblioCompiler
    , readPandocBiblio
    , readPandocBiblios
    , processPandocBiblio
    , processPandocBiblios
    , pandocBiblioCompiler
    , pandocBibliosCompiler
    ) where


--------------------------------------------------------------------------------
import           Control.Monad                 (liftM)
import           Data.Binary                   (Binary (..))
import qualified Data.ByteString               as B
import qualified Data.ByteString.Lazy          as BL
import qualified Data.Map                      as Map
import qualified Data.Time                     as Time
import qualified Data.Text                     as T (pack)
import           Data.Typeable                 (Typeable)
import           Hakyll.Core.Compiler
import           Hakyll.Core.Compiler.Internal
import           Hakyll.Core.Identifier
import           Hakyll.Core.Identifier.Pattern (fromGlob)
import           Hakyll.Core.Item
import           Hakyll.Core.Metadata          (getMetadataField)
import           Hakyll.Core.Writable
import           Hakyll.Web.Pandoc
import           Text.Pandoc                   (Extension (..), Pandoc,
                                                PandocPure, ReaderOptions (..),
                                                enableExtension)
import qualified Text.Pandoc                   as Pandoc
import           Text.Pandoc.Builder           (setMeta)
import qualified Text.Pandoc.Citeproc          as Pandoc (processCitations)
import           Text.Pandoc.Walk              (Walkable (query))
import           System.FilePath               (addExtension, takeExtension)


--------------------------------------------------------------------------------
newtype CSL = CSL {unCSL :: B.ByteString}
    deriving (Binary, Show, Typeable)



--------------------------------------------------------------------------------
instance Writable CSL where
    -- Shouldn't be written.
    write _ _ = return ()


--------------------------------------------------------------------------------
cslCompiler :: Compiler (Item CSL)
cslCompiler = fmap (CSL . BL.toStrict) <$> getResourceLBS


--------------------------------------------------------------------------------
newtype Biblio = Biblio {unBiblio :: B.ByteString}
    deriving (Binary, Show, Typeable)


--------------------------------------------------------------------------------
instance Writable Biblio where
    -- Shouldn't be written.
    write _ _ = return ()


--------------------------------------------------------------------------------
biblioCompiler :: Compiler (Item Biblio)
biblioCompiler = fmap (Biblio . BL.toStrict) <$> getResourceLBS


--------------------------------------------------------------------------------
readPandocBiblio :: ReaderOptions
                 -> Item CSL
                 -> Item Biblio
                 -> (Item String)
                 -> Compiler (Item Pandoc)
readPandocBiblio ropt csl biblio = readPandocBiblios ropt csl [biblio]

readPandocBiblios :: ReaderOptions
                  -> Item CSL
                  -> [Item Biblio]
                  -> (Item String)
                  -> Compiler (Item Pandoc)
readPandocBiblios ropt csl biblios item = do
  pandoc <- readPandocWith ropt item
  processPandocBiblios csl biblios pandoc


--------------------------------------------------------------------------------

-- | Process a bibliography file with the given style.
--
-- This function supports pandoc's
-- <https://pandoc.org/chunkedhtml-demo/9.6-including-uncited-items-in-the-bibliography.html nocite>
-- functionality when there is a @nocite@ metadata field present.
--
-- ==== __Example__
--
-- In your main function, first compile the respective files:
--
-- > main = hakyll $ do
-- >   …
-- >   match "style.csl" $ compile cslCompiler
-- >   match "bib.bib"   $ compile biblioCompiler
--
-- Then, create a function like the following:
--
-- > processBib :: Item Pandoc -> Compiler (Item Pandoc)
-- > processBib pandoc = do
-- >   csl <- load @CSL    "bib/style.csl"
-- >   bib <- load @Biblio "bib/bibliography.bib"
-- >   processPandocBiblio csl bib pandoc
--
-- Now, feed this function to your pandoc compiler:
--
-- > myCompiler :: Compiler (Item String)
-- > myCompiler = pandocItemCompilerWithTransformM myReader myWriter processBib
processPandocBiblio :: Item CSL
                    -> Item Biblio
                    -> (Item Pandoc)
                    -> Compiler (Item Pandoc)
processPandocBiblio csl biblio = processPandocBiblios csl [biblio]

-- | Like 'processPandocBiblio', which see, but support multiple bibliography
-- files.
processPandocBiblios :: Item CSL
                     -> [Item Biblio]
                     -> (Item Pandoc)
                     -> Compiler (Item Pandoc)
processPandocBiblios csl biblios item' = do
    -- It's not straightforward to use the Pandoc API as of 2.11 to deal with
    -- citations, since it doesn't export many things in 'Text.Pandoc.Citeproc'.
    -- The 'citeproc' package is also hard to use.
    --
    -- So instead, we try treating Pandoc as a black box.  Pandoc can read
    -- specific csl and bilbio files based on metadata keys.
    --
    -- So we load the CSL and Biblio files and pass them to Pandoc using the
    -- ersatz filesystem.

    -- Honour nocite metadata fields
    item <- getUnderlying >>= (`getMetadataField` "nocite") >>= \case
        Nothing -> pure item'
        Just x  -> withItemBody (pure . setMeta "nocite" x) item'

    let Pandoc.Pandoc (Pandoc.Meta meta) blocks = itemBody item
        cslFile = Pandoc.FileInfo zeroTime . unCSL $ itemBody csl
        bibFiles = zipWith (\x y ->
            ( addExtension ("_hakyll/bibliography-" ++ show x)
                           (takeExtension $ toFilePath $ itemIdentifier y)
            , Pandoc.FileInfo zeroTime . unBiblio . itemBody $ y
            )
          )
          [0 :: Integer ..]
          biblios

        stFiles = foldr ((.) . uncurry Pandoc.insertInFileTree)
                    (Pandoc.insertInFileTree "_hakyll/style.csl" cslFile)
                    bibFiles

        addBiblioFiles = \st -> st { Pandoc.stFiles = stFiles $ Pandoc.stFiles st }

        biblioMeta = Pandoc.Meta .
            Map.insert "csl" (Pandoc.MetaString "_hakyll/style.csl") .
            Map.insert "bibliography"
              (Pandoc.MetaList $ map (Pandoc.MetaString . T.pack . fst) bibFiles) $
            meta

    pandoc <- do
        let p = Pandoc.Pandoc biblioMeta blocks
        p' <- case Pandoc.lookupMeta "nocite" biblioMeta of
            Just (Pandoc.MetaString nocite) -> do
                Pandoc.Pandoc _ b <- runPandoc $
                    Pandoc.readMarkdown defaultHakyllReaderOptions nocite
                let nocites = Pandoc.MetaInlines . flip query b $ \case
                        c@Pandoc.Cite{} -> [c]
                        _               -> []
                return $ setMeta "nocite" nocites p
            _ -> return p
        runPandoc $ do
            Pandoc.modifyPureState addBiblioFiles
            Pandoc.processCitations p'
    return $ fmap (const pandoc) item

  where
    zeroTime = Time.UTCTime (toEnum 0) 0

    runPandoc :: PandocPure a -> Compiler a
    runPandoc with = case Pandoc.runPure with of
        Left  e -> compilerThrow ["Error during processCitations: " ++ show e]
        Right x -> pure x

--------------------------------------------------------------------------------
-- | Compiles a markdown file via Pandoc. Requires the .csl and .bib files to be known to the compiler via match statements.
pandocBiblioCompiler :: String -> String -> Compiler (Item String)
pandocBiblioCompiler cslFileName bibFileName = do
    csl <- load $ fromFilePath cslFileName
    bib <- load $ fromFilePath bibFileName
    liftM writePandoc
        (getResourceBody >>= readPandocBiblio ropt csl bib)
    where ropt = defaultHakyllReaderOptions
            { -- The following option enables citation rendering
              readerExtensions = enableExtension Ext_citations $ readerExtensions defaultHakyllReaderOptions
            }

--------------------------------------------------------------------------------
-- | Compiles a markdown file via Pandoc. Requires the .csl and .bib files to be known to the compiler via match statements.
pandocBibliosCompiler :: String -> String -> Compiler (Item String)
pandocBibliosCompiler cslFileName bibFileName = do
    csl  <- load    $ fromFilePath cslFileName
    bibs <- loadAll $ fromGlob bibFileName
    liftM writePandoc
        (getResourceBody >>= readPandocBiblios ropt csl bibs)
    where ropt = defaultHakyllReaderOptions
            { -- The following option enables citation rendering
              readerExtensions = enableExtension Ext_citations $ readerExtensions defaultHakyllReaderOptions
            }
