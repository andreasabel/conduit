{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveDataTypeable #-}
-- | Defines the types for a source, which is a producer of data.
module Data.Conduit.Types.Source
    ( StreamState (..)
    , SourceResult (..)
    , Source (..)
    , SourceM (..)
    , BSource (..)
    , SourceInvariantException (..)
    ) where

import Control.Monad.Trans.Resource (ResourceT)
import Data.Monoid (Monoid (..))
import Control.Monad.Base (MonadBase (liftBase))
import qualified Data.IORef as I
import Control.Monad (liftM)
import Data.Typeable (Typeable)
import Control.Exception (Exception, throw)

-- | A stream can be in one of two states: open or closed.
data StreamState = StreamOpen | StreamClosed

-- | When pulling data from a source, it returns back a list of values pulled
-- from the stream. It also indicates whether or not the stream has been
-- closed.
data SourceResult a = SourceResult StreamState [a]

instance Functor SourceResult where
    fmap f (SourceResult x a) = SourceResult x (map f a)

-- | A 'Source' has two operations on it: pull some data, and close the
-- 'Source'. Since 'Source' is built on top of 'ResourceT', all acquired
-- resources should be automatically released anyway. Closing a 'Source' early
-- is merely an optimization to free scarce resources as soon as possible.
--
-- A 'Source' has two invariants:
--
-- * It is illegal to call 'sourcePull' after a previous call returns 'StreamClosed'.
--
-- * It is legal to call 'sourceClose' multiple times.
--
-- 'Source's are not expected to call 'sourceClose' when they return an
-- 'SourceClosed' from 'sourcePull', though based on the second invariant, they
-- are free to do so.
data Source m a = Source
    { sourcePull :: ResourceT m (SourceResult a)
    , sourceClose :: ResourceT m ()
    }

instance Monad m => Functor (Source m) where
    fmap f src = src
        { sourcePull = liftM (fmap f) (sourcePull src)
        }

-- | All but the simplest of 'Source's (e.g., @repeat@ and @cycle@) require
-- some type of state to track their current status. This may be in the form of
-- a mutable variable (e.g., @IORef@), or via opening a resource like a
-- @Handle@. While a 'Source' is given no opportunity to acquire such
-- resources, this type is.
--
-- A 'SourceM' is simply a monadic action that returns a 'Source'. One nice
-- consequence of this is the possibility of creating an efficient 'Monoid'
-- instance, which will only acquire one resource at a time, instead of bulk
-- acquiring all resources at the beginning of running the 'SourceM'.
--
-- Note that each time you \"call\" a @SourceM@, it is started from scratch. If
-- you want a resumable source (e.g., one which can be passed to multiple
-- @Sink@s), you likely want to use a 'BSource'.
newtype SourceM m a = SourceM { genSource :: ResourceT m (Source m a) }

instance Monad m => Functor (SourceM m) where
    fmap f (SourceM msrc) = SourceM (liftM (fmap f) msrc)

instance MonadBase IO m => Monoid (SourceM m a) where
    mempty = SourceM (return Source
        { sourcePull = return $ SourceResult StreamClosed []
        , sourceClose = return ()
        })
    mappend a b = mconcat [a, b]
    mconcat [] = mempty
    mconcat (SourceM mnext:rest0) = SourceM $ do
        -- open up the first SourceM...
        next0 <- mnext
        -- and place it in a mutable reference along with all of the upcoming
        -- SourceMs
        istate <- liftBase (I.newIORef (next0, rest0))
        return Source
            { sourcePull = pull istate
            , sourceClose = close istate
            }
      where
        pull istate =
            liftBase (I.readIORef istate) >>= pull'
          where
            pull' (current, rest) = do
                stream@(SourceResult state _) <- sourcePull current
                case state of
                    -- end of the current Source
                    StreamClosed -> do
                        -- close the current Source
                        sourceClose current
                        case rest of
                            -- ... and open the next one
                            SourceM ma:as -> do
                                a <- ma
                                liftBase (I.writeIORef istate (a, as))
                                -- continue pulling base on this new state
                                pull istate
                            -- no more source, return an EOF
                            [] -> do
                                -- give an error message if the first Source
                                -- invariant is violated (read data after EOF)
                                liftBase $ I.writeIORef istate $
                                    throw $ PullAfterEOF "SourceM:mconcat"
                                return stream
                    StreamOpen -> return stream
        close istate = do
            -- we only need to close the current Source, since they are opened
            -- one at a time
            (current, _) <- liftBase (I.readIORef istate)
            sourceClose current

-- | When actually interacting with 'Source's, we usually want to be able to
-- buffer the output, in case any intermediate steps return leftover data. A
-- 'BSource' allows for such buffering, via the 'bsourceUnpull' function.
--
-- A 'BSource', unlike a 'SourceM', is resumable, meaning it can be passed to
-- multiple 'Sink's without restarting.
--
-- Finally, a 'BSource' relaxes one of the invariants of a 'Source': calling
-- 'bsourcePull' after an 'EOF' will simply return another 'EOF'.
data BSource m a = BSource
    { bsourcePull :: ResourceT m (SourceResult a)
    , bsourceUnpull :: [a] -> ResourceT m () -- ^ It is the responsibility of the 'BSource' to check if the argument is null.
    , bsourceClose :: ResourceT m ()
    }

data SourceInvariantException = PullAfterEOF String
    deriving (Show, Typeable)
instance Exception SourceInvariantException