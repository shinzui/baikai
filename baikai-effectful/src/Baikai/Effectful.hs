-- | An effectful binding for baikai's transport. (Effect + interpreters land in M2/M3.)
module Baikai.Effectful
  ( -- * Re-exports of the baikai request/response vocabulary
    Model,
    Context,
    Options,
    Response,
    AssistantMessageEvent,
  )
where

import Baikai (AssistantMessageEvent, Context, Model, Options, Response)
