defmodule CodexPooler.Gateway.Transports.HTTPStreamFailureMetadataTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.RequestLogs.DebugProjection.TransportFailure
  alias CodexPooler.Gateway.Transports.TransportFailureReason

  for {source, _original, _expected_source, reason, _phase, _exception} = scenario <- [
        {:http_body_done, :done, "http_body_done", "done", "upstream_close", nil},
        {:http_stream_error, %Finch.TransportError{reason: :closed}, "http_transport_error", "closed", "receive", "Finch.TransportError"},
        {:http_stream_error, %Finch.HTTPError{reason: :invalid_chunk_size}, "http_protocol_error", "invalid_chunk_size", "receive", "Finch.HTTPError"},
        {:http_stream_error, {:upstream_idle_timeout, %Finch.TransportError{reason: :timeout}}, "http_receive_timeout", "timeout", "receive_timeout", "Finch.TransportError"},
        {:http_stream_error, :upstream_stream_interrupted, "http_stream_error", "upstream_stream_interrupted", "receive", nil},
        {:pooler_stream_drain, :shutdown, "pooler_stream_drain", "shutdown", "receive", nil},
        {:pooler_stream_cancel, :native_preamble_limit_exceeded, "pooler_stream_cancel", "native_preamble_limit_exceeded", "receive", nil},
        {:downstream_write_error, :closed, "downstream_write_error", "closed", "send_payload", nil}
      ] do
    test "observed #{source} #{reason} survives sanitization and projection" do
      assert_observed_projection(unquote(Macro.escape(scenario)))
    end
  end

  test "metadata does not retain raw exception fields or arbitrary observation values" do
    sentinel = "raw body sentinel with private data"
    failure = TransportFailureReason.observed_http_stream_failure(:http_stream_error, %Finch.HTTPError{reason: {:invalid_chunk_size, sentinel}})
    assert failure["reason"] == "invalid_chunk_size"
    refute inspect(failure) =~ sentinel

    assert TransportFailureReason.sanitize_transport_failure_metadata(%{
             "termination_source" => sentinel,
             "evidence_source" => sentinel,
             "body" => sentinel
           }) == %{}
  end

  test "historical inferred interruptions never acquire an observed HTTP EOF source" do
    projected =
      TransportFailure.build(%Attempt{
        network_error_code: "upstream_stream_error",
        response_metadata: %{"error_kind" => "stream_interrupted"}
      })

    assert projected.evidence_source == "inferred"
    refute Map.has_key?(projected, :termination_source)

    legacy = TransportFailure.build(%Attempt{response_metadata: %{"transport_failure" => %{"reason" => "closed_before_terminal"}}})
    refute Map.has_key?(legacy, :evidence_source)
    refute Map.has_key?(legacy, :termination_source)
  end

  defp assert_observed_projection({source, original, expected_source, reason, phase, exception}) do
    observed = TransportFailureReason.observed_http_stream_failure(source, original)
    persisted = Accounting.sanitize_metadata(%{"transport_failure" => observed})
    projected = TransportFailure.build(%Attempt{response_metadata: persisted})

    assert projected.termination_source == expected_source
    assert projected.evidence_source == "observed"
    assert projected.reason == reason
    assert projected.phase == phase
    assert Map.get(projected, :exception) == exception
    assert persisted["transport_failure"] == observed
  end
end
