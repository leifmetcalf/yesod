{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-- | A subsite which serves static content which is embedded at compile time.
--
-- At compile time, you supply a list of files, directories, processing functions (like javascript
-- minification), and even custom content generators.  You can also specify the specific relative
-- locations within the static subsite where these resources should appear.  The 'mkEmbeddedStatic'
-- function then computes the resources and embeds them directly into the executable at
-- compile time, so that the original files do not need to be distributed along with
-- the executable.  The content is also compressed and hashed at compile time, so that
-- during runtime the compressed content can be sent directly on the wire with the appropriate
-- HTTP header.  The precomputed hash is used for an ETag so the client does not redownload
-- the content multiple times.  There is also a development mode which does not embed the
-- contents but recomputes it on every request. A simple example using an embedded static
-- subsite is
-- <https://github.com/yesodweb/yesod/blob/master/yesod-static/sample-embed.hs static-embed.hs>.
--
-- To add this to a scaffolded project, replace the code in @Settings/StaticFiles.hs@
-- with a call to 'mkEmbeddedStatic' with the list of all your generators, use the type
-- 'EmbeddedStatic' in your site datatype for @getStatic@, update the route for @/static@ to
-- use the type 'EmbeddedStatic', use 'embedStaticContent' for 'addStaticContent' in
-- @Foundation.hs@, use the routes generated by 'mkEmbeddedStatic' and exported by
-- @Settings/StaticFiles.hs@ to link to your static content, and finally update
-- @Application.hs@ use the variable binding created by 'mkEmbeddedStatic' which
-- contains the created 'EmbeddedStatic'.
--
-- It is recommended that you serve static resources from a separate domain to save time
-- on transmitting cookies.  You can use 'urlParamRenderOverride' to do so, by redirecting
-- routes to this subsite to a different domain (but the same path) and then pointing the
-- alternative domain to this server.  In addition, you might consider using a reverse
-- proxy like varnish or squid to cache the static content, but the embedded content in
-- this subsite is cached and served directly from memory so is already quite fast.
module Yesod.EmbeddedStatic (
  -- * Subsite
    EmbeddedStatic
  , embeddedResourceR
  , mkEmbeddedStatic
  , embedStaticContent

  -- * Generators
  , module Yesod.EmbeddedStatic.Generators
) where

import Control.Applicative as A ((<$>))
import Data.IORef
import Data.Maybe (catMaybes)
import Language.Haskell.TH
import Network.HTTP.Types.Status (status404)
import Network.Wai (responseLBS, pathInfo)
import Network.Wai.Application.Static (staticApp)
import System.IO.Unsafe (unsafePerformIO)
import Yesod.Core (YesodSubDispatch(..))
import Yesod.Core.Types
          ( YesodSubRunnerEnv(..)
          , YesodRunnerEnv(..)
          )
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.HashMap.Strict as M
import qualified WaiAppStatic.Storage.Embedded as Static

import Yesod.EmbeddedStatic.Types
import Yesod.EmbeddedStatic.Internal
import Yesod.EmbeddedStatic.Generators

-- Haddock doesn't support associated types in instances yet so we can't
-- export EmbeddedResourceR directly.

-- | Construct a route to an embedded resource.
embeddedResourceR :: [T.Text] -> [(T.Text, T.Text)] -> Route EmbeddedStatic
embeddedResourceR = EmbeddedResourceR

instance YesodSubDispatch EmbeddedStatic master where
    yesodSubDispatch YesodSubRunnerEnv {..} req = resp
        where
            master = yreSite ysreParentEnv
            site = ysreGetSub master
            resp = case pathInfo req of
                            ("res":_) -> stApp site req
                            ("widget":_) -> staticApp (widgetSettings site) req
                            _ -> ($ responseLBS status404 [] "Not Found")

-- | Create the haskell variable for the link to the entry
mkRoute :: ComputedEntry -> Q [Dec]
mkRoute (ComputedEntry { cHaskellName = Nothing }) = return []
mkRoute (c@ComputedEntry { cHaskellName = Just name }) = do
    routeType <- [t| Route EmbeddedStatic |]
    link <- [| $(cLink c) |]
    return [ SigD name routeType
           , ValD (VarP name) (NormalB link) []
           ]

-- | Creates an 'EmbeddedStatic' by running, at compile time, a list of generators. 
-- Each generator produces a list of entries to embed into the executable.
--
-- This template haskell splice creates a variable binding holding the resulting
-- 'EmbeddedStatic' and in addition creates variable bindings for all the routes
-- produced by the generators.  For example, if a directory called static has
-- the following contents:
--
-- * js/jquery.js
--
-- * css/bootstrap.css
--
-- * img/logo.png
--
-- then a call to
--
-- > #ifdef DEVELOPMENT
-- > #define DEV_BOOL True
-- > #else
-- > #define DEV_BOOL False
-- > #endif
-- > mkEmbeddedStatic DEV_BOOL "myStatic" [embedDir "static"]
--
-- will produce variables
--
-- > myStatic :: EmbeddedStatic
-- > js_jquery_js :: Route EmbeddedStatic
-- > css_bootstrap_css :: Route EmbeddedStatic
-- > img_logo_png :: Route EmbeddedStatic
mkEmbeddedStatic :: Bool -- ^ development?
                 -> String -- ^ variable name for the created 'EmbeddedStatic'
                 -> [Generator] -- ^ the generators (see "Yesod.EmbeddedStatic.Generators")
                 -> Q [Dec]
mkEmbeddedStatic dev esName gen = do
    entries <- concat A.<$> sequence gen
    computed <- runIO $ mapM (if dev then devEmbed else prodEmbed) entries

    let settings = Static.mkSettings $ return $ map cStEntry computed
        devExtra = listE $ catMaybes $ map ebDevelExtraFiles entries
        ioRef  = [| unsafePerformIO $ newIORef M.empty |]

    -- build the embedded static
    esType <- [t| EmbeddedStatic |]
    esCreate <- if dev
                  then [| EmbeddedStatic (develApp $settings $devExtra) $ioRef |]
                  else [| EmbeddedStatic (staticApp $! $settings) $ioRef |]
    let es = [ SigD (mkName esName) esType
             , ValD (VarP $ mkName esName) (NormalB esCreate) []
             ]

    routes <- mapM mkRoute computed

    return $ es ++ concat routes

-- | Use this for 'addStaticContent' to have the widget static content be served by
--   the embedded static subsite.  For example,
--
-- > import Yesod
-- > import Yesod.EmbeddedStatic
-- > import Text.Jasmine (minifym)
-- >
-- > data MySite = { ..., getStatic :: EmbeddedStatic, ... }
-- >
-- > mkYesod "MySite" [parseRoutes|
-- > ...
-- > /static StaticR EmbeddedStatic getStatic
-- > ...
-- > |]
-- >
-- > instance Yesod MySite where
-- >     ...
-- >     addStaticContent = embedStaticContent getStatic StaticR mini
-- >         where mini = if development then Right else minifym
-- >     ...
embedStaticContent :: (site -> EmbeddedStatic)   -- ^ How to retrieve the embedded static subsite from your site
                   -> (Route EmbeddedStatic -> Route site) -- ^ how to convert an embedded static route
                   -> (BL.ByteString -> Either a BL.ByteString) -- ^ javascript minifier
                   -> AddStaticContent site
embedStaticContent = staticContentHelper
