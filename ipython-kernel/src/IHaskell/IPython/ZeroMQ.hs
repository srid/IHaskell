{-# LANGUAGE OverloadedStrings, DoAndIfThenElse #-}

-- | Description : Low-level ZeroMQ communication wrapper.
--
-- The "ZeroMQ" module abstracts away the low-level 0MQ based interface with IPython, replacing it
-- instead with a Haskell Channel based interface. The `serveProfile` function takes a IPython
-- profile specification and returns the channel interface to use.
module IHaskell.IPython.ZeroMQ (ZeroMQInterface(..), ZeroMQStdin(..), serveProfile, serveStdin) where

import qualified Data.ByteString.Lazy as LBS
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char
import           Control.Concurrent
import           Control.Monad
import           System.IO.Unsafe
import           Data.Aeson (encode)
import           System.ZMQ4 hiding (stdin)
import           Data.Digest.Pure.SHA as SHA
import           Data.Monoid ((<>))

import           IHaskell.IPython.Types
import           IHaskell.IPython.Message.Parser
import           IHaskell.IPython.Message.Writer

-- | The channel interface to the ZeroMQ sockets. All communication is done via Messages, which are
-- encoded and decoded into a lower level form before being transmitted to IPython. These channels
-- should functionally serve as high-level sockets which speak Messages instead of ByteStrings.
data ZeroMQInterface =
       Channels
         { 
         -- | A channel populated with requests from the frontend.
         shellRequestChannel :: Chan Message
         -- | Writing to this channel causes a reply to be sent to the frontend.
         , shellReplyChannel :: Chan Message
         -- | This channel is a duplicate of the shell request channel, though using a different backend
         -- socket.
         , controlRequestChannel :: Chan Message
         -- | This channel is a duplicate of the shell reply channel, though using a different backend
         -- socket.
         , controlReplyChannel :: Chan Message
         -- | Writing to this channel sends an iopub message to the frontend.
         , iopubChannel :: Chan Message
         -- | Key used to sign messages.
         , hmacKey :: ByteString
         }

data ZeroMQStdin =
       StdinChannel
         { stdinRequestChannel :: Chan Message
         , stdinReplyChannel :: Chan Message
         }

-- | Start responding on all ZeroMQ channels used to communicate with IPython | via the provided
-- profile. Return a set of channels which can be used to | communicate with IPython in a more
-- structured manner.
serveProfile :: Profile            -- ^ The profile specifying which ports and transport mechanisms to use.
             -> Bool               -- ^ Print debug output
             -> IO ZeroMQInterface -- ^ The Message-channel based interface to the sockets.
serveProfile profile debug = do
  -- Create all channels which will be used for higher level communication.
  shellReqChan <- newChan
  shellRepChan <- newChan
  controlReqChan <- dupChan shellReqChan
  controlRepChan <- dupChan shellRepChan
  iopubChan <- newChan
  let channels = Channels shellReqChan shellRepChan controlReqChan controlRepChan iopubChan
                   (signatureKey profile)

  -- Create the context in a separate thread that never finishes. If withContext or withSocket
  -- complete, the context or socket become invalid.
  forkIO $ withContext $ \context -> do
    -- Serve on all sockets.
    forkIO $ serveSocket context Rep (hbPort profile) $ heartbeat channels
    forkIO $ serveSocket context Router (controlPort profile) $ control debug channels
    forkIO $ serveSocket context Router (shellPort profile) $ shell debug channels

    -- The context is reference counted in this thread only. Thus, the last serveSocket cannot be
    -- asynchronous, because otherwise context would be garbage collectable - since it would only be
    -- used in other threads. Thus, keep the last serveSocket in this thread.
    serveSocket context Pub (iopubPort profile) $ iopub debug channels

  return channels

serveStdin :: Profile -> IO ZeroMQStdin
serveStdin profile = do
  reqChannel <- newChan
  repChannel <- newChan

  -- Create the context in a separate thread that never finishes. If withContext or withSocket
  -- complete, the context or socket become invalid.
  forkIO $ withContext $ \context ->
    -- Serve on all sockets.
    serveSocket context Router (stdinPort profile) $ \socket -> do
      -- Read the request from the interface channel and send it.
      readChan reqChannel >>= sendMessage False (signatureKey profile) socket

      -- Receive a response and write it to the interface channel.
      receiveMessage False socket >>= writeChan repChannel

  return $ StdinChannel reqChannel repChannel

-- | Serve on a given socket in a separate thread. Bind the socket in the | given context and then
-- loop the provided action, which should listen | on the socket and respond to any events.
serveSocket :: SocketType a => Context -> a -> Port -> (Socket a -> IO b) -> IO ()
serveSocket context socketType port action = void $
  withSocket context socketType $ \socket -> do
    bind socket $ "tcp://127.0.0.1:" ++ show port
    forever $ action socket

-- | Listener on the heartbeat port. Echoes back any data it was sent.
heartbeat :: ZeroMQInterface -> Socket Rep -> IO ()
heartbeat _ socket = do
  -- Read some data.
  request <- receive socket

  -- Send it back.
  send socket [] request

-- | Listener on the shell port. Reads messages and writes them to | the shell request channel. For
-- each message, reads a response from the | shell reply channel of the interface and sends it back
-- to the frontend.
shell :: Bool -> ZeroMQInterface -> Socket Router -> IO ()
shell debug channels socket = do
  -- Receive a message and write it to the interface channel.
  receiveMessage debug socket >>= writeChan requestChannel

  -- Read the reply from the interface channel and send it.
  readChan replyChannel >>= sendMessage debug (hmacKey channels) socket

  where
    requestChannel = shellRequestChannel channels
    replyChannel = shellReplyChannel channels

-- | Listener on the shell port. Reads messages and writes them to | the shell request channel. For
-- each message, reads a response from the | shell reply channel of the interface and sends it back
-- to the frontend.
control :: Bool -> ZeroMQInterface -> Socket Router -> IO ()
control debug channels socket = do
  -- Receive a message and write it to the interface channel.
  receiveMessage debug socket >>= writeChan requestChannel

  -- Read the reply from the interface channel and send it.
  readChan replyChannel >>= sendMessage debug (hmacKey channels) socket

  where
    requestChannel = controlRequestChannel channels
    replyChannel = controlReplyChannel channels

-- | Send messages via the iopub channel. | This reads messages from the ZeroMQ iopub interface
-- channel | and then writes the messages to the socket.
iopub :: Bool -> ZeroMQInterface -> Socket Pub -> IO ()
iopub debug channels socket =
  readChan (iopubChannel channels) >>= sendMessage debug (hmacKey channels) socket

-- | Receive and parse a message from a socket.
receiveMessage :: Receiver a => Bool -> Socket a -> IO Message
receiveMessage debug socket = do
  -- Read all identifiers until the identifier/message delimiter.
  idents <- readUntil "<IDS|MSG>"

  -- Ignore the signature for now.
  void next

  headerData <- next
  parentHeader <- next
  metadata <- next
  content <- next

  when debug $ do
    putStr "Header: "
    Char.putStrLn headerData
    putStr "Content: "
    Char.putStrLn content

  let message = parseMessage idents headerData parentHeader metadata content
  return message

  where
    -- Receive the next piece of data from the socket.
    next = receive socket

    -- Read data from the socket until we hit an ending string. Return all data as a list, which does
    -- not include the ending string.
    readUntil str = do
      line <- next
      if line /= str
        then do
          remaining <- readUntil str
          return $ line : remaining
        else return []

-- | Encode a message in the IPython ZeroMQ communication protocol and send it through the provided
-- socket. Sign it using HMAC with SHA-256 using the provided key.
sendMessage :: Sender a => Bool -> ByteString -> Socket a -> Message -> IO ()
sendMessage _ _ _ SendNothing = return ()
sendMessage debug hmacKey socket message = do
  when debug $ print message

  -- Send all pieces of the message.
  mapM_ sendPiece idents
  sendPiece "<IDS|MSG>"
  sendPiece signature
  sendPiece headStr
  sendPiece parentHeaderStr
  sendPiece metadata

  -- Conclude transmission with content.
  sendLast content

  where
    sendPiece = send socket [SendMore]
    sendLast = send socket []

    -- Encode to a strict bytestring.
    encodeStrict :: ToJSON a => a -> ByteString
    encodeStrict = LBS.toStrict . encode

    -- Signature for the message using HMAC SHA-256.
    signature :: ByteString
    signature = hmac $ headStr <> parentHeaderStr <> metadata <> content

    -- Compute the HMAC SHA-256 signature of a bytestring message.
    hmac :: ByteString -> ByteString
    hmac = Char.pack . SHA.showDigest . SHA.hmacSha256 (LBS.fromStrict hmacKey) . LBS.fromStrict

    -- Pieces of the message.
    head = header message
    parentHeaderStr = maybe "{}" encodeStrict $ parentHeader head
    idents = identifiers head
    metadata = "{}"
    content = encodeStrict message
    headStr = encodeStrict head
