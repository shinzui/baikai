-- | The one HTTP client cache, and the one place a base URL becomes
-- something baikai will actually connect to.
--
-- Building a @ClientEnv@ — @servant-client@'s pairing of a parsed base
-- URL with an @http-client@ 'HTTP.Manager', which owns the connection
-- pool and the TLS state — costs a TLS manager setup, so baikai keeps
-- one per base URL for the life of the process. That cache used to be
-- duplicated in each provider package and keyed on the raw base-URL
-- text, which meant @https:\/\/h@ and @https:\/\/h\/@ were two managers
-- and two connection pools to one host, and that the three copies could
-- disagree about what "the same host" means. There is one cache here
-- now, and its key is the canonical rendering of "Baikai.Url"'s parse.
--
-- The cache is unbounded on purpose. The set of distinct base URLs a
-- process talks to is configuration-sized rather than request-sized;
-- normalisation removes the one unbounded source (textual variants of a
-- single host); and how long a connection lives is already the
-- 'HTTP.Manager''s idle timeout. A fleet of per-tenant base URLs is not
-- a supported use of @Model.baseUrl@.
module Baikai.Http
  ( canonicalBaseUrl,
    getClientEnvCached,
    cachedClientEnvCount,
  )
where

import Baikai.Error (invalidRequest)
import Baikai.Url qualified as Url
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (throwIO)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS qualified as TLS
import Servant.Client qualified as Client
import System.IO.Unsafe (unsafePerformIO)

-- | Parse a base URL into the @servant-client@ 'Client.BaseUrl' baikai
-- will send to, normalised so that every spelling of one target is one
-- value: the host lower-cased by 'Url.parseUrl', the port made explicit
-- from the scheme's default when none was given, and trailing slashes
-- removed from the path.
--
-- Built from 'Url.parseUrl' directly rather than by handing the raw text
-- to @servant-client@'s own @parseBaseUrl@, so that the host baikai
-- resolves a key for and the host it opens a connection to are decided
-- by the same function. (@parseBaseUrl@ also silently prepends
-- @http:\/\/@ to a scheme-less URL, which would send a bearer token in
-- plaintext, and rejects userinfo and query strings with an exception
-- that says nothing useful.)
--
-- 'Left' carries a reason fit to show a caller.
canonicalBaseUrl :: Text -> Either Text Client.BaseUrl
canonicalBaseUrl raw = case Url.parseUrl raw of
  Nothing -> Left "no host could be found in it"
  Just parts -> case Url.scheme parts of
    Nothing ->
      Left
        ( Url.renderEndpoint parts
            <> " has no scheme; start it with https:// or http://"
        )
    Just s
      | s /= "http",
        s /= "https" ->
          Left
            ( Url.renderEndpoint parts
                <> " uses the scheme "
                <> s
                <> "; only http and https are sent"
            )
      | otherwise ->
          let secure = s == "https"
           in Right
                Client.BaseUrl
                  { Client.baseUrlScheme = if secure then Client.Https else Client.Http,
                    Client.baseUrlHost = Text.unpack (Url.host parts),
                    Client.baseUrlPort =
                      maybe (if secure then 443 else 80) id (Url.port parts),
                    Client.baseUrlPath =
                      Text.unpack (Text.dropWhileEnd (== '/') (Url.path parts))
                  }

-- | The cached 'Client.ClientEnv' for a base URL, building one on first
-- use. Two spellings of one target share an entry, because the key is
-- 'canonicalBaseUrl''s rendering rather than the caller's text.
--
-- Throws a 'Baikai.Error.BaikaiError' in the
-- 'Baikai.Error.InvalidRequest' category when the base URL is not one
-- baikai can send to.
getClientEnvCached :: Text -> IO Client.ClientEnv
getClientEnvCached raw = case canonicalBaseUrl raw of
  Left problem ->
    throwIO (invalidRequest ("Model.baseUrl is not usable: " <> problem))
  Right base -> do
    let key = Text.pack (Client.showBaseUrl base)
    modifyMVar clientEnvCache $ \cache ->
      case Map.lookup key cache of
        Just env -> pure (cache, env)
        Nothing -> do
          env <- newClientEnv base
          pure (Map.insert key env cache, env)

-- | How many distinct targets the cache holds. Exposed so a test can
-- observe that two spellings of one host are one entry.
cachedClientEnvCount :: IO Int
cachedClientEnvCount =
  modifyMVar clientEnvCache $ \cache -> pure (cache, Map.size cache)

-- | A fresh manager with no per-response timeout: a streaming response
-- is open for as long as the model is thinking, and @Options.timeoutMs@
-- bounds the whole call from outside.
newClientEnv :: Client.BaseUrl -> IO Client.ClientEnv
newClientEnv base = do
  manager <-
    TLS.newTlsManagerWith
      TLS.tlsManagerSettings
        { HTTP.managerResponseTimeout = HTTP.responseTimeoutNone
        }
  pure (Client.mkClientEnv manager base)

{-# NOINLINE clientEnvCache #-}
clientEnvCache :: MVar (Map Text Client.ClientEnv)
clientEnvCache = unsafePerformIO (newMVar Map.empty)
