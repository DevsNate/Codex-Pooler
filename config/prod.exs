import Config

config :codex_pooler, CodexPoolerWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

config :codex_pooler, CodexPoolerWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto],
    exclude: [
      hosts: ["localhost", "127.0.0.1"],
      paths: ["/healthz", "/readyz", "/metrics"],
      conn: {CodexPoolerWeb.Plugs.ForwardedSSL, :websocket_over_forwarded_ssl?, []}
    ]
  ]

config :swoosh, api_client: Swoosh.ApiClient.Req

config :swoosh, local: false

config :logger, level: :info
