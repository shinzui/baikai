-- | CAP-10, docs/capabilities/opentelemetry-span-export.md. The checker reads
-- the first @haskell@ fence under @## Shape@, so the record's second block
-- (@otelSinkWith@ under a parent context) is not compiled here.
module Shape.Cap10 (shape) where

import Baikai hiding (model)
import Baikai.Trace (withTrace)
import Baikai.Trace.Sink.OpenTelemetry (otelSink)
import Shape.Fixtures (ctx, model, opts, tracer)

shape :: IO Response
shape = do
  -- BEGIN CAP-10
  withTrace (otelSink tracer) model ctx opts

-- END CAP-10
