defmodule CodexPooler.MixTasks.TailwindInstallTest do
  use ExUnit.Case, async: false

  import Bitwise, only: [band: 2]
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [start_upstream: 1]

  alias CodexPooler.FakeUpstream

  @moduletag capture_log: true
  @binary <<0, 1, 2, 250, 251, 252, 253, 254, 255>>

  setup do
    root = Path.join(System.tmp_dir!(), "tailwind-install-#{System.pid()}-#{System.unique_integer([:positive])}")
    path = Path.join(root, "tailwindcss")
    previous = Application.fetch_env(:tailwind, :path)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:tailwind, :path, value)
        :error -> Application.delete_env(:tailwind, :path)
      end

      File.rm_rf!(root)
      refute File.exists?(root)
    end)

    Application.put_env(:tailwind, :path, path)
    %{path: path}
  end

  for padding_size <- [100, 12_000] do
    test "installs the configured binary through #{padding_size}-byte response headers", %{path: path} do
      upstream = start_upstream(FakeUpstream.raw_response(@binary, headers: [{"x-padding", String.duplicate("a", unquote(padding_size))}]))
      assert :ok = Tailwind.install(FakeUpstream.url(upstream))
      assert FakeUpstream.count(upstream) == 1
      assert File.read!(path) == @binary
      assert band(File.stat!(path).mode, 0o777) == 0o755
    end
  end
end
