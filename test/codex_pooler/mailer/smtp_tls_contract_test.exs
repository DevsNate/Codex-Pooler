defmodule CodexPooler.Mailer.SmtpTlsContractTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Mailer.Config
  alias Swoosh.Adapters.SMTP

  setup_all do
    certificate = :public_key.pkix_test_data(%{root: [digest: :sha256, key: {:rsa, 2048, 65_537}], peer: [digest: :sha256, key: {:rsa, 2048, 65_537}, extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}]]})
    %{certificate: certificate}
  end

  test "implicit TLS accepts mail without a second TLS upgrade for saved STARTTLS preferences", %{certificate: certificate} do
    for tls <- ["always", "if_available", "never"] do
      {port, server, receipt} = start_smtp!(:implicit, certificate)
      config = adapter_config(port, true, tls, certificate)
      result = SMTP.deliver(email(), config)

      assert_receive {:smtp_receipt, ^receipt, commands, accepted}, 10_000
      assert_receive {:DOWN, ^server, :process, _pid, :normal}, 10_000
      assert match?({:ok, _receipt}, result)
      assert accepted
      assert commands == [:ehlo, :mail, :rcpt, :data, :quit]
    end
  end

  test "required STARTTLS upgrades a plain connection and accepts mail", %{certificate: certificate} do
    {port, server, receipt} = start_smtp!(:starttls, certificate)
    config = adapter_config(port, false, "always", certificate)
    result = SMTP.deliver(email(), config)

    assert_receive {:smtp_receipt, ^receipt, commands, accepted}, 10_000
    assert_receive {:DOWN, ^server, :process, _pid, :normal}, 10_000
    assert match?({:ok, _receipt}, result)
    assert accepted
    assert commands == [:ehlo, :starttls, :ehlo, :mail, :rcpt, :data, :quit]
  end

  defp adapter_config(port, ssl, tls, certificate) do
    {:ok, %{adapter_config: config}} = Config.from_settings(%{enabled: true, host: "localhost", port: port, username: nil, password: nil, from: "sender@example.com", ssl: ssl, tls: tls, retries: 0})
    tls_key = if ssl, do: :sockopts, else: :tls_options
    assert config[tls_key][:verify] == :verify_peer
    assert config[tls_key][:server_name_indication] == ~c"localhost"

    config
    |> Keyword.update!(tls_key, &Keyword.put(&1, :cacerts, certificate[:cacerts]))
    |> Keyword.put(:hostname, "client.example.com")
    |> Keyword.put(:timeout, 5_000)
  end

  defp email do
    Swoosh.Email.new()
    |> Swoosh.Email.from("sender@example.com")
    |> Swoosh.Email.to("recipient@example.com")
    |> Swoosh.Email.subject("Synthetic SMTP contract")
    |> Swoosh.Email.text_body("Synthetic SMTP contract")
  end

  defp start_smtp!(mode, certificate) do
    parent = self()
    receipt = make_ref()
    tls_options = [cert: certificate[:cert], key: certificate[:key]]

    pid =
      start_supervised!(%{
        id: receipt,
        start: {Task, :start_link, [fn -> serve(parent, receipt, mode, tls_options) end]},
        restart: :temporary
      })

    monitor = Process.monitor(pid)
    assert_receive {:smtp_ready, ^receipt, port}, 10_000
    {port, monitor, receipt}
  end

  defp serve(parent, receipt, mode, tls_options) do
    transport = if mode == :implicit, do: :ssl, else: :gen_tcp
    options = [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}]
    options = if mode == :implicit, do: options ++ tls_options, else: options
    {:ok, listener} = transport.listen(0, options)

    result =
      try do
        socket_info = if transport == :ssl, do: :ssl, else: :inet
        {:ok, {_ip, port}} = socket_info.sockname(listener)
        send(parent, {:smtp_ready, receipt, port})
        socket = accept!(transport, listener)

        try do
          :ok = transport.send(socket, "220 localhost ready\r\n")
          exchange(transport, socket, mode, tls_options, [], false)
        after
          transport.close(socket)
        end
      after
        transport.close(listener)
      end

    {commands, accepted} = result
    send(parent, {:smtp_receipt, receipt, commands, accepted})
  end

  defp accept!(:ssl, listener) do
    {:ok, socket} = :ssl.transport_accept(listener, 10_000)
    {:ok, socket} = :ssl.handshake(socket, 10_000)
    socket
  end

  defp accept!(:gen_tcp, listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 10_000)
    socket
  end

  defp exchange(transport, socket, mode, tls_options, commands, accepted) do
    {:ok, line} = transport.recv(socket, 0, 10_000)

    case line do
      "EHLO " <> _hostname ->
        reply = if mode == :starttls, do: "250-localhost\r\n250 STARTTLS\r\n", else: "250 localhost\r\n"
        :ok = transport.send(socket, reply)
        exchange(transport, socket, mode, tls_options, [:ehlo | commands], accepted)

      "STARTTLS\r\n" ->
        :ok = transport.send(socket, "220 upgrade\r\n")
        {:ok, secured} = :ssl.handshake(socket, tls_options, 10_000)

        try do
          exchange(:ssl, secured, :secured, tls_options, [:starttls | commands], accepted)
        after
          :ssl.close(secured)
        end

      "MAIL " <> _sender ->
        :ok = transport.send(socket, "250 ok\r\n")
        exchange(transport, socket, mode, tls_options, [:mail | commands], accepted)

      "RCPT " <> _recipient ->
        :ok = transport.send(socket, "250 ok\r\n")
        exchange(transport, socket, mode, tls_options, [:rcpt | commands], accepted)

      "DATA\r\n" ->
        :ok = transport.send(socket, "354 data\r\n")
        discard_message(transport, socket)
        :ok = transport.send(socket, "250 accepted\r\n")
        exchange(transport, socket, mode, tls_options, [:data | commands], true)

      "QUIT\r\n" ->
        reply_to_quit(transport, socket)

        {Enum.reverse([:quit | commands]), accepted}
    end
  end

  defp reply_to_quit(transport, socket) do
    # gen_smtp closes immediately after QUIT without waiting for the reply.
    case transport.send(socket, "221 bye\r\n") do
      :ok -> :ok
      {:error, :closed} -> :ok
    end
  end

  defp discard_message(transport, socket) do
    case transport.recv(socket, 0, 10_000) do
      {:ok, ".\r\n"} -> :ok
      {:ok, _line} -> discard_message(transport, socket)
      {:error, _reason} -> flunk("SMTP message stream closed before its terminator")
    end
  end
end
