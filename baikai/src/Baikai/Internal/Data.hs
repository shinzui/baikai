-- | Recover atomic data omitted by a failure terminal, without duplicating
-- blocks when event indices have gaps and terminal content is compacted.
module Baikai.Internal.Data (recoverDataBlocks) where

import Baikai.Content (AssistantContent (..), DataContent, TextContent (..))
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.List (mapAccumL)
import Data.Vector (Vector)
import Data.Vector qualified as V

recoverDataBlocks :: IntMap AssistantContent -> Vector AssistantContent -> Vector AssistantContent
recoverDataBlocks closed terminal
  | not (IntMap.null closed), V.all blankText terminal = V.fromList (IntMap.elems closed)
  | otherwise = foldl insert terminal missing
  where
    blankText (AssistantText (TextContent "")) = True
    blankText _ = False
    terminalData = [d | AssistantData d <- V.toList terminal]
    (_, candidates) = mapAccumL consume terminalData (zip [0 ..] (IntMap.elems closed))
    missing = [entry | Just entry <- candidates]
    consume remaining (ordinal, AssistantData d) = case removeOne d remaining of
      Just rest -> (rest, Nothing)
      Nothing -> (remaining, Just (ordinal, AssistantData d))
    consume remaining _ = (remaining, Nothing)
    insert blocks (ordinal, block) =
      let position = min ordinal (V.length blocks)
       in V.take position blocks <> V.singleton block <> V.drop position blocks

removeOne :: DataContent -> [DataContent] -> Maybe [DataContent]
removeOne _ [] = Nothing
removeOne wanted (d : ds)
  | wanted == d = Just ds
  | otherwise = (d :) <$> removeOne wanted ds
