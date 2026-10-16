defmodule CodexPooler.Gateway.OpenAICompatibility.NativeImageResult do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.ImageResult

  @spec valid?(binary()) :: boolean()
  def valid?(body) do
    case CodexPooler.JSON.decode(body) do
      {:ok, %{"created" => created, "data" => [_ | _] = data} = response}
      when is_integer(created) and created >= 0 ->
        is_nil(response["error"]) and Enum.all?(data, &valid_image?/1)

      _invalid ->
        false
    end
  end

  defp valid_image?(%{"b64_json" => encoded}), do: ImageResult.encoded_image?(encoded)

  defp valid_image?(_image), do: false
end
