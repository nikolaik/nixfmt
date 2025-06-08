-- | Atomic file IO.
--
-- This modules allows one to replace the contents of a file atomically by
-- leveraging the atomicity of the @rename@ operation.
--
-- This module is a crossover of the `atomic-write` and `safeio` libraries
-- with the fs-related behaviour of the first and interface of the second.
module System.IO.Atomic (
  withOutputFile,
)
where

import Control.Exception.Safe (mask, onException)
import Control.Monad (when)
import System.Directory (doesFileExist, removeFile, renameFile)
import System.FilePath (takeDirectory, takeFileName)
import System.IO (Handle, hClose, openTempFileWithDefaultPermissions)
import System.Posix.Files (fileGroup, fileMode, fileOwner, getFileStatus, setFileMode, setOwnerAndGroup)

-- | Like @withFile@ but replaces the contents atomically.
--
-- This function allocates a temporary file and provides its handle to the
-- IO action. After the action finishes, it /atomically/ replaces the original
-- target file with the temporary one. If the action fails with an exception,
-- the temporary file is cleaned up.
--
-- Since the procedure involves creation of an entirely new file, preserving
-- the attributes is a challenge. This function tries its best, but currently
-- it is Unix-specific and there is definitely room for improvement even on Unix.
withOutputFile ::
  -- | Final file path
  FilePath ->
  -- | IO action that writes to the file
  (Handle -> IO a) ->
  IO a
withOutputFile path act = transact begin commit rollback $ \(tpath, th) -> do
  copyAttributes (tpath, th)
  act th
  where
    tmpDir = takeDirectory path
    tmpTemplate = "." <> takeFileName path <> ".atomic"

    begin :: IO (FilePath, Handle)
    begin = openTempFileWithDefaultPermissions tmpDir tmpTemplate

    -- TODO: Support for non-unix platofrms.
    -- TODO: Preserve ctime?
    -- TODO: Preserve extended attributes (ACLs, ...)?
    copyAttributes :: (FilePath, Handle) -> IO ()
    copyAttributes (tpath, _th) = do
      exists <- doesFileExist path
      when exists $ do
        status <- getFileStatus path
        setFileMode tpath (fileMode status)
        -- Set the temporary files owner to the same as the original file.
        -- This only succeeds if either:
        -- - The owner matches already, no change necessary
        -- - The current user has the CAP_CHOWN permission
        -- See also https://stackoverflow.com/a/49079630 for more context
        setOwnerAndGroup tpath (fileOwner status) (fileGroup status)

    commit :: (FilePath, Handle) -> IO ()
    commit (tpath, th) = hClose th *> renameFile tpath path

    rollback :: (FilePath, Handle) -> IO ()
    rollback (tpath, th) = hClose th *> removeFile tpath

---
-- Helpers
--

-- | A variant of @bracket@ with two different finalisation actions.
--
-- Semantically, the following is /almost/ true:
--
-- > bracket acquire release = transact acquire release release
--
-- except that @bracket@ always runs the cleanup action exactly once, while
-- here, if the action completes but commit fails, we will still run rollback,
-- so there exists an execution in which both finalisation actions are run.
transact ::
  -- | computation to run first (\"begin transaction\")
  IO a ->
  -- | computation to run on success (\"commit transaction\")
  (a -> IO b) ->
  -- | computation to run on failure (\"rollback transaction\")
  (a -> IO c) ->
  -- | computation to run in-between
  (a -> IO d) ->
  IO d -- returns the value from the in-between computation
transact begin commit rollback act =
  mask $ \restore -> do
    a <- begin
    res <- restore (act a) `onException` rollback a
    _ <- commit a `onException` rollback a
    pure res
