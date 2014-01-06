{-# LANGUAGE CPP, ForeignFunctionInterface #-}

#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

module ProxyPool.Util (configureKeepAlive) where

import Foreign
import Foreign.C.Types

import Network
import Network.Socket

foreign import ccall unsafe "setsockopt"
    -- socket, level, option_name, option_value, option_len
    c_setsockopt :: CInt -> CInt -> CInt -> Ptr CInt -> CInt -> IO CInt

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
