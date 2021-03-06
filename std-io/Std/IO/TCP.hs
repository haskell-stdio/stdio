{-# LANGUAGE MagicHash #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-|
Module      : Std.IO.TCP
Description : TCP servers and clients
Copyright   : (c) Dong Han, 2018
License     : BSD
Maintainer  : winterland1989@gmail.com
Stability   : experimental
Portability : non-portable

This module provides an API for creating TCP servers and clients.

-}

module Std.IO.TCP (
  -- * TCP Client
    ClientConfig(..)
  , defaultClientConfig
  , initClient
  -- * TCP Server
  , ServerConfig(..)
  , defaultServerConfig
  , startServer
  , module Std.IO.SockAddr
  ) where

import           Control.Concurrent
import           Control.Concurrent.MVar
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Int
import           Data.Primitive.PrimArray
import           Foreign.C.Types
import           Foreign.Ptr
import           GHC.Ptr
import           Std.Foreign.PrimArray
import           Std.Data.Array
import           Std.IO.Buffered
import           Std.IO.Exception
import           Std.IO.SockAddr
import           Std.IO.Resource
import           Std.IO.UV.FFI
import           Std.IO.UV.Manager
import           Std.Data.Vector

initTCPStream :: HasCallStack => UVManager -> Resource UVStream
initTCPStream = initUVStream (\ loop handle ->
    throwUVIfMinus_ (uv_tcp_init loop handle))

initTCPExStream :: HasCallStack => CUInt -> UVManager -> Resource UVStream
initTCPExStream family = initUVStream (\ loop handle ->
    throwUVIfMinus_ (uv_tcp_init_ex loop handle family))

--------------------------------------------------------------------------------

-- | TCP Stream.
newtype TCP = TCP UVStream deriving (Show, Input, Output)

-- | A TCP client configuration
--
data ClientConfig = ClientConfig
    { clientLocalAddr :: Maybe SockAddr -- ^ assign a local address, or let OS pick one
    , clientTargetAddr :: SockAddr      -- ^ target address
    , clientNoDelay :: Bool             -- ^ if we want to use @TCP_NODELAY@
    }

defaultClientConfig :: ClientConfig
defaultClientConfig = ClientConfig Nothing (SockAddrInet 8888 inetLoopback) True

initClient :: HasCallStack => ClientConfig -> Resource TCP
initClient ClientConfig{..} = do
    uvm <- liftIO getUVManager
    client <- initTCPStream uvm
    let handle = uvsHandle client
    liftIO . withSockAddr clientTargetAddr $ \ targetPtr -> do
        forM_ clientLocalAddr $ \ clientLocalAddr' ->
            withSockAddr clientLocalAddr' $ \ localPtr ->
                -- bind is safe without withUVManager
                throwUVIfMinus_ (uv_tcp_bind handle localPtr 0)
        -- nodelay is safe without withUVManager
        when clientNoDelay $ throwUVIfMinus_ (uv_tcp_nodelay handle 1)
        withUVRequest uvm $ \ _ -> hs_uv_tcp_connect handle targetPtr
    return (TCP client)

--------------------------------------------------------------------------------

-- | A TCP server configuration
--
data ServerConfig = ServerConfig
    { serverAddr       :: SockAddr      -- ^ listening address
    , serverBackLog    :: Int           -- ^ listening socket's backlog size
    , serverWorker     :: TCP -> IO ()  -- ^ worker which get an accepted TCP stream,
                                            -- the socket will be closed upon exception or worker finishes.
    , serverWorkerNoDelay :: Bool       -- ^ if we want to use @TCP_NODELAY@
    }

-- | A default hello world server on localhost:8888
--
-- Test it with @main = startServer defaultServerConfig@, now try @nc -v 127.0.0.1 8888@
--
defaultServerConfig :: ServerConfig
defaultServerConfig = ServerConfig
    (SockAddrInet 8888 inetAny)
    128
    (\ uvs -> writeOutput uvs (Ptr "hello world"#) 11)
    True

-- | Start a server
--
-- Fork new worker thread upon a new connection.
--
startServer :: HasCallStack => ServerConfig -> IO ()
startServer ServerConfig{..} = do
    serverManager <- getUVManager
    withResource (initTCPStream serverManager) $ \ (UVStream serverHandle serverSlot _ _) ->
        bracket
            (throwOOMIfNull $ hs_uv_accept_check_alloc serverHandle)
            hs_uv_accept_check_close $ \ check -> do
                throwUVIfMinus_ $ hs_uv_accept_check_init check
                withSockAddr serverAddr $ \ addrPtr -> do
                    m <- getBlockMVar serverManager serverSlot
                    acceptBuf <- newPinnedPrimArray ACCEPT_BUFFER_SIZE
                    let acceptBufPtr = coerce (mutablePrimArrayContents acceptBuf :: Ptr UVFD)

                    withUVManager_ serverManager $ do
                        pokeBufferTable serverManager serverSlot acceptBufPtr 0
                        throwUVIfMinus_ (uv_tcp_bind serverHandle addrPtr 0)
                        throwUVIfMinus_ (hs_uv_listen serverHandle (max 4 (fromIntegral serverBackLog)))

                    forever $ do
                        takeMVar m

                        -- we lock uv manager here in case of next uv_run overwrite current accept buffer
                        acceptBufCopy <- withUVManager_ serverManager $ do
                            tryTakeMVar m
                            accepted <- peekBufferTable serverManager serverSlot
                            acceptBuf' <- newPrimArray accepted
                            copyMutablePrimArray acceptBuf' 0 acceptBuf 0 accepted
                            pokeBufferTable serverManager serverSlot acceptBufPtr 0
                            unsafeFreezePrimArray acceptBuf'

                        let accepted = sizeofPrimArray acceptBufCopy

                        forM_ [0..accepted-1] $ \ i -> do
                            let fd = indexPrimArray acceptBufCopy i
                            if fd < 0
                            -- minus fd indicate a server error and we should close server
                            then throwUVIfMinus_ (return fd)
                            -- It's important to use the worker thread's mananger instead of server's one!
                            else void . forkBa $ do
                                uvm <- getUVManager
                                withResource (initUVStream (\ loop handle -> do
                                    throwUVIfMinus_ (uv_tcp_init loop handle)
                                    throwUVIfMinus_ (hs_uv_tcp_open handle fd)) uvm) $ \ client -> do
                                    when serverWorkerNoDelay . throwUVIfMinus_ $
                                        -- safe without withUVManager
                                        uv_tcp_nodelay (uvsHandle client) 1
                                    serverWorker (TCP client)

                        when (accepted == ACCEPT_BUFFER_SIZE) $
                            withUVManager_ serverManager (hs_uv_listen_resume serverHandle)

-- The buffer passing of accept is a litte complicated here, to get maximum performance,
-- we do batch accepting. i.e. recv multiple client inside libuv's event loop:
--
-- + we poke uvmanager's buffer table as a Ptr Word8, with byte size (ACCEPT_BUFFER_SIZE*sizeof(UVFD))
-- + inside libuv event loop, we cast the buffer back to int32_t* pointer.
-- + each accept callback push a new socket fd to the buffer, and increase a counter(buffer table's size).
-- + ACCEPT_BUFFER_SIZE is large enough 1020, so under windows we can't possibly filled it up within one
--   uv_run.
-- + under unix we hacked uv internal to provide a stop and resume function, when ACCEPT_BUFFER_SIZE is
--   reached, we will stop receiving.
-- + once back to haskell side, we poked all the accepted sockets and fork worker threads.
-- + if ACCEPT_BUFFER_SIZE is reached, we resume receiving from haskell side, which will affect next
--   uv_run.
