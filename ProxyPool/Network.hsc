{-# LANGUAGE CPP, ForeignFunctionInterface #-}

#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

-- | Network module for proxy pool, fixes everything that's wrong with Haskell's network package
module ProxyPool.Network (configureKeepAlive, connectTimeout) where

import Foreign
import Foreign.C.Types
import Foreign.C.Error

import Network
import Network.Socket
import Network.Socket.Internal

import Control.Concurrent.MVar

import System.Posix.Types
import System.Posix.IO.Select
import System.Posix.IO.Select.Types

foreign import ccall unsafe "setsockopt"
    -- socket, level, option_name, option_value, option_len
    c_setsockopt :: CInt -> CInt -> CInt -> Ptr CInt -> CInt -> IO CInt

foreign import ccall unsafe "connect"
    c_connect :: CInt -> Ptr SockAddr -> CInt{-CSockLen???-} -> IO CInt

-- | Sets TCP_KEEPIDLE, TCP_KEEPINTVL and TCP_KEEPCNT if avaliable
configureKeepAlive :: Socket -> IO Bool
configureKeepAlive sock = do
#if defined(TCP_KEEPIDLE) && defined(TCP_KEEPINTVL) && defined(TCP_KEEPCNT)
    alloca $ \ptr -> do
        poke ptr 120
        _ <- c_setsockopt (fdSocket sock) (#const IPPROTO_TCP) (#const TCP_KEEPIDLE) ptr $ fromIntegral $ sizeOf (undefined :: CInt)
        poke ptr 1
        _ <- c_setsockopt (fdSocket sock) (#const IPPROTO_TCP) (#const TCP_KEEPINTVL) ptr $ fromIntegral $ sizeOf (undefined :: CInt)
        poke ptr 5
        _ <- c_setsockopt (fdSocket sock) (#const IPPROTO_TCP) (#const TCP_KEEPCNT) ptr $ fromIntegral $ sizeOf (undefined :: CInt)
        return ()

    return True
#else
    return False
#endif

-- | Modified version of 'connect' with a timeout, for the record, the Haskell TCP networking library is utter garbage.
connectTimeout :: Socket   -- Unconnected Socket
               -> SockAddr -- Socket address stuff
               -> Int      -- Timeout, in seconds
               -> IO ()
connectTimeout sock@(MkSocket s _family _stype _protocol socketStatus) addr timeout = do
    modifyMVar_ socketStatus $ \currentStatus -> do
        if currentStatus /= NotConnected && currentStatus /= Bound
        then
            ioError (userError ("connect: can't peform connect on socket in status " ++ show currentStatus))
        else do
            withSockAddr addr $ \p_addr sz -> do
                let connectLoop = do
                        r <- c_connect s p_addr (fromIntegral sz)
                        if r == -1
                            then do
#if !(defined(HAVE_WINSOCK2_H) && !defined(cygwin32_HOST_OS))
                                err <- getErrno
                                case () of
                                    _ | err == eINTR -> connectLoop
                                    _ | err == eINPROGRESS -> connectBlocked
                                    _ -> throwSocketError "connect"
#else
                                rc <- c_getLastError
                                case rc of
                                    #{const WSANOTINITIALISED} -> do
                                        withSocketsDo (return ())
                                        r <- c_connect s p_addr (fromIntegral sz)
                                        if r == -1
                                            then throwSocketError "connect"
                                            else return r
                                    _ -> throwSocketError "connect"
#endif
                           else return r

                    connectBlocked = do
                        -- use select so that 'connect' can be timed out
                        result <- select'' [] [Fd . fromIntegral $ s] [] (Time $ CTimeval (fromIntegral timeout) 0)

                        if result <= 0
                            then do
                                throwSocketError "connect"
                            else do
                                err <- getSocketOption sock SoError
                                if (err == 0)
                                    then return 0
                                    else throwSocketErrorCode "connect" (fromIntegral err)

                _ <- connectLoop
                return Connected
