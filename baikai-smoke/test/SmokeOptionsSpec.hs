module Main (main) where

import Baikai (AssistantContent (..), TextContent (..), emptyResponse, emptyThinkingContent)
import Baikai.Api (Api (AnthropicMessages, OpenAIResponses))
import Baikai.Model (api, modelId)
import ClaudeReplayCheck (matchesSignedReplay, signedBlocks)
import Control.Lens ((&), (.~))
import Control.Monad (forM_, unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Generics.Labels ()
import Data.List (nub)
import Data.Vector qualified as Vector
import SmokeOptions

main :: IO ()
main = do
  check "ordinary mode" (parseSmokeOptions [] == Right (SmokeOptions False False Nothing))
  check "focused required mode" (parseSmokeOptions ["--new-models", "--require-keys"] == Right (SmokeOptions True True Nothing))
  check "reversed flags" (parseSmokeOptions ["--require-keys", "--new-models"] == Right (SmokeOptions True True Nothing))
  check "required ordinary mode" (parseSmokeOptions ["--require-keys"] == Right (SmokeOptions False True Nothing))
  check "reject unknown option" (case parseSmokeOptions ["--new-model"] of Left _ -> True; _ -> False)
  check "named case" (parseSmokeOptions ["--new-models", "--case", "astra-tools"] == Right (SmokeOptions True False (Just "astra-tools")))
  check "twenty-four unique cases" (length caseNames == 24 && nub caseNames == caseNames)
  check "Terra cases are available" (all (`elem` caseNames) ["terra61-text", "terra61-tools"])
  forM_ caseNames $ \name -> do
    check (name <> " selected alone") (parseSmokeOptions ["--new-models", "--require-keys", "--case", name] == Right (SmokeOptions True True (Just name)))
    check (name <> " excludes other cases") (selectCaseNames (Just name) == [name])
    let expected = if name `elem` ["fable-text", "fable-tools", "fable52-text", "fable52-tools", "opus55-text", "opus55-tools", "sonnet55-text", "sonnet55-tools", "haiku55-text", "haiku55-tools"] then Just "anthropic" else Just "openai"
    check (name <> " credential group") (caseProvider name == expected)
  forM_ [("astra62-text", "gpt-6.2-astra", False), ("astra62-tools", "gpt-6.2-astra", True), ("sol62-text", "gpt-6.2-sol", False), ("sol62-tools", "gpt-6.2-sol", True)] $ \(label, ident, tools) ->
    case selectModelCases (Just label) of
      [(selected, m, keys, toolsCase)] ->
        check (label <> " routes to its exact generated Responses model and credential group") $
          (selected, modelId m, api m, keys, toolsCase) == (label, ident, OpenAIResponses, ["OPENAI_KEY", "OPENAI_API_KEY"], tools)
      _ -> fail (label <> " did not select exactly one case")
  check "case needs focused mode" (case parseSmokeOptions ["--case", "astra-tools"] of Left _ -> True; _ -> False)
  check "unknown case rejected" (case parseSmokeOptions ["--new-models", "--case", "typo"] of Left _ -> True; _ -> False)
  let openaiKeys = ["OPENAI_KEY", "OPENAI_API_KEY"]
      anthropicKeys = ["ANTHROPIC_KEY", "ANTHROPIC_API_KEY"]
      groups = [openaiKeys, anthropicKeys]
  forM_ [("fable52-text", False), ("fable52-tools", True)] $ \(label, tools) ->
    case selectModelCases (Just label) of
      [(selected, m, keys, toolsCase)] ->
        check (label <> " routes to the Fable 5.2 Messages binding and credential group") $
          (selected, modelId m, api m, keys, toolsCase) == (label, "claude-fable-5-2", AnthropicMessages, anthropicKeys, tools)
      _ -> fail (label <> " did not select exactly one case")
  check "absent credentials" (missingKeys [] groups == groups)
  check "empty credentials" (missingKeys [("OPENAI_KEY", Just ""), ("ANTHROPIC_KEY", Nothing)] groups == groups)
  check "fallback keys accepted" (null (missingKeys [("OPENAI_API_KEY", Just "synthetic"), ("ANTHROPIC_API_KEY", Just "synthetic")] groups))
  check "one missing provider" (missingKeys [("OPENAI_KEY", Just "synthetic")] groups == [last groups])
  forM_ caseNames $ \name -> do
    let (key, keys) = if caseProvider name == Just "openai" then ("OPENAI_KEY", openaiKeys) else ("ANTHROPIC_KEY", anthropicKeys)
    check (name <> " requires only its provider") (null (missingKeys [(key, Just "synthetic")] [keys]))
    check (name <> " missing key fails preflight") (missingKeys [] [keys] == [keys])
  forM_ cacheCaseNames $ \name -> do
    check (name <> " standalone route") (parseSmokeOptions ["--case", name, "--require-keys"] == Right (SmokeOptions False True (Just name)))
    check (name <> " cache route") (isCacheCase name && caseProvider name == Just "openai")
    check (name <> " rejects new-models") (case parseSmokeOptions ["--new-models", "--case", name] of Left _ -> True; _ -> False)
    check (name <> " absent required key") (missingKeys [] [openaiKeys] == [openaiKeys])
    check (name <> " ignores Anthropic key") (missingKeys [("ANTHROPIC_KEY", Just "synthetic")] [openaiKeys] == [openaiKeys])
  check "duplicate selectors refused" (case parseSmokeOptions ["--case", "openai-cache-chat", "--case", "astra-text", "--new-models"] of Left _ -> True; _ -> False)
  let thought summary signature = object ["type" .= String "thinking", "thinking" .= String summary, "signature" .= String signature]
      first = thought "" "signature-one"
      second = thought "summary" "signature-two"
      textBlock = object ["type" .= String "text", "text" .= String "progress"]
      result = object ["type" .= String "tool_result", "tool_use_id" .= String "toolu_clock"]
      wire role blocks = object ["role" .= String role, "content" .= (blocks :: [Value])]
      followUp blocks = object ["messages" .= [wire "assistant" blocks, wire "user" [result]]]
      reply =
        emptyResponse
          & #message . #content
            .~ Vector.fromList
              [ AssistantThinking (emptyThinkingContent & #signature .~ Just "signature-one"),
                AssistantText (TextContent "progress"),
                AssistantThinking (emptyThinkingContent & #thinking .~ "summary" & #signature .~ Just "signature-two")
              ]
      matches = matchesSignedReplay ["toolu_clock"] (signedBlocks reply) . followUp
  check "signed comparison captures empty and visible thinking at the original positions" (signedBlocks reply == [(0, first), (2, second)])
  check "signed blocks in order match the follow-up" (matches [first, textBlock, second])
  check "a missing signed block fails the follow-up comparison" (not (matches [first, textBlock]))
  check "a changed signature fails the follow-up comparison" (not (matches [first, textBlock, thought "summary" "changed"]))
  check "reordered signed blocks fail the follow-up comparison" (not (matches [second, textBlock, first]))
  check "an extra signed block fails the follow-up comparison" (not (matches [first, textBlock, second, first]))
  check "the follow-up must carry the corresponding tool result" (not (matchesSignedReplay ["toolu_other"] (signedBlocks reply) (followUp [first, textBlock, second])))
  putStrLn "all smoke option and credential checks passed (no environment access)."
  where
    check label ok = unless ok (fail label)
