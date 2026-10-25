-- | CAP-30, docs/capabilities/structured-answer-span-export.md.
module Shape.Cap30 (shape) where

import Baikai.Response (Response)
import Baikai.Trace (withTrace)
import Baikai.Trace.Sink.OpenTelemetry (otelSink)
import Shape.Fixtures (ctx, model, opts, tracer)

shape :: IO Response
shape = do
  -- BEGIN CAP-30
  withTrace (otelSink tracer) model ctx opts

-- END CAP-30
