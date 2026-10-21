defmodule CodexPooler.Files.RequestLog do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.FailureResponse
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Files.RequestMetadata

  @type gateway_error :: %{
          required(:status) => pos_integer(),
          required(:code) => String.t(),
          required(:message) => String.t()
        }

  @spec record_file_request(map(), String.t(), pos_integer(), RequestMetadata.t(), map()) ::
          {:ok, Request.t()} | {:error, gateway_error()}
  def record_file_request(
        auth,
        status,
        response_status,
        %RequestMetadata{} = request_metadata,
        metadata
      ) do
    attrs =
      %{
        endpoint: request_metadata.endpoint,
        transport: request_metadata.transport,
        status: status,
        response_status_code: response_status,
        correlation_id: Ecto.UUID.generate(),
        client_ip: request_metadata.client_ip,
        user_agent: request_metadata.user_agent,
        request_metadata: file_request_metadata(request_metadata, metadata),
        now: request_metadata.now
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case Accounting.record_metadata_request(auth, attrs) do
      {:ok, %{request: request}} ->
        {:ok, request}

      {:error, reason} ->
        FailureResponse.accounting_failure(:record_file_request, nil, nil, reason)
    end
  end

  @spec merge_bridge_route_metadata(Request.t(), map()) ::
          {:ok, Request.t()} | {:error, gateway_error()}
  def merge_bridge_route_metadata(request, %{route_metadata: route_metadata})
      when is_map(route_metadata) and map_size(route_metadata) > 0 do
    case Accounting.merge_request_metadata(request, route_metadata) do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} ->
        FailureResponse.accounting_failure(:merge_file_request_metadata, request, nil, reason)
    end
  end

  def merge_bridge_route_metadata(request, _bridge_result), do: {:ok, request}

  @spec bridge_route_metadata(map()) :: map()
  def bridge_route_metadata(%{upstream: upstream}) when is_map(upstream) do
    Map.take(upstream, ["routing", "candidate_exclusions", :candidate_exclusions])
  end

  def bridge_route_metadata(_bridge_error), do: %{}

  defp file_request_metadata(%RequestMetadata{} = request_metadata, metadata) do
    metadata
    |> Map.merge(%{
      "request" =>
        drop_nil_values(%{
          "request_bytes" => request_metadata.request_bytes,
          "upload_bytes" => request_metadata.upload_bytes,
          "request_content_type" => request_metadata.request_content_type
        }),
      "routing" => routing_metadata(metadata, request_metadata.route_class)
    })
    |> maybe_put_client_request_id(request_metadata)
    |> drop_empty_maps()
  end

  defp routing_metadata(metadata, route_class) do
    routing =
      case Map.get(metadata, "routing") do
        value when is_map(value) -> value
        _invalid -> %{}
      end

    %{"routing" => routing}
    |> Accounting.sanitize_metadata()
    |> Map.fetch!("routing")
    |> Map.delete(:route_class)
    |> Map.merge(drop_nil_values(%{"route_class" => route_class}))
  end

  defp maybe_put_client_request_id(metadata, %RequestMetadata{client_request_id: value})
       when is_binary(value) do
    value = value |> String.trim() |> String.slice(0, 160)

    if value == "" do
      metadata
    else
      Map.put(metadata, "client_request_id", value)
    end
  end

  defp maybe_put_client_request_id(metadata, %RequestMetadata{}), do: metadata

  defp drop_empty_maps(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_map(value) and map_size(value) == 0 end)
    |> Map.new()
  end

  defp drop_nil_values(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
