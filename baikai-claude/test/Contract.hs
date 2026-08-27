-- | The stream protocol, as an assertion.
--
-- Lives in its own module rather than in @Main@ because three suites
-- need it — the end-to-end cases in @Main@, the failure-stream cases in
-- @SseSpec@, and the evidence cases in @EvidenceSpec@ — and a protocol
-- asserted three slightly different ways is not asserted at all.
module Contract (assertErrorContract, assertOneErrorTerminal) where

import Baikai.Stream.Event
  ( AssistantMessageEvent (..),
    StartPayload (..),
    TerminalPayload (..),
    isTerminal,
  )
import Test.Tasty.HUnit (Assertion, assertFailure, (@?=))

-- | The whole documented protocol for a failing stream: exactly one
-- 'EventStart', first; exactly one terminal; and that terminal an
-- 'EventError' carrying structured 'errorInfo'.
--
-- Use this on anything that drains a provider stream. A fragment folded
-- straight through @translate@ never carried a start event, so it gets
-- 'assertOneErrorTerminal' instead.
assertErrorContract :: [AssistantMessageEvent] -> Assertion
assertErrorContract events = do
  case events of
    EventStart StartPayload {} : _ -> pure ()
    other -> assertFailure ("stream must begin with EventStart, got: " <> show (take 1 other))
  length [() | EventStart {} <- events] @?= 1
  assertOneErrorTerminal events
  case reverse events of
    (EventError TerminalPayload {} : _) -> pure ()
    other -> assertFailure ("stream must end with EventError, got: " <> show (take 1 other))

-- | The terminal half of 'assertErrorContract', for translator-level
-- fragments that never carried a start event.
assertOneErrorTerminal :: [AssistantMessageEvent] -> Assertion
assertOneErrorTerminal events = do
  let terminals = filter isTerminal events
  length terminals @?= 1
  case terminals of
    [EventError TerminalPayload {errorInfo = Nothing}] ->
      assertFailure "terminal EventError omitted errorInfo"
    [EventError TerminalPayload {errorInfo = Just _}] -> pure ()
    other -> assertFailure ("expected exactly one terminal EventError, got: " <> show other)
