# Local model gateway

Settings → Models → Local model gateway combines the models configured on enabled upstreams into one local API. It is off by default. When enabled, it starts with BaoCode and stops when BaoCode exits.

The default listening address is `http://127.0.0.1:8317` and the default API key is `baocode`. The port and key can be changed in the panel. Save and Apply restarts the service with the new configuration; turning the gateway off closes its port and cancels in-flight requests. A bind failure, such as a port already in use, is displayed in the panel and can be retried with Save and Apply.

Enable “Use BaoCode network proxy” to reach upstreams through Settings → Network. Turn it off to connect directly. The local API and its internal protocol bridge always connect directly over loopback.

## API

Send `Authorization: Bearer baocode`, or `x-api-key: baocode` for an Anthropic client. The service listens only on IPv4 loopback and accepts local API clients without an Origin header.

| Endpoint | Format |
| --- | --- |
| `GET /v1/models` | Combined list of enabled models |
| `POST /v1/chat/completions` | OpenAI Chat Completions |
| `POST /v1/responses` | OpenAI Responses |
| `POST /v1/messages` | Anthropic Messages |
| `POST /v1/messages/count_tokens` | Anthropic token counting, estimated for other protocols |

For an OpenAI client, set its base URL to `http://127.0.0.1:8317/v1`. For an Anthropic client, set its base URL to `http://127.0.0.1:8317`. Clients must use the configured key even when the upstream itself needs no key.

Use the exact model IDs returned by `/v1/models`: `@<upstream-id>/<model-name>`. This keeps models with the same name on different upstreams distinct. An unqualified model name also works when it identifies exactly one enabled model. Changes to upstreams, model enablement, upstream credentials and per-model protocol overrides apply to subsequent requests without restarting the gateway. Upstream credentials stay inside BaoCode.

Requests using the upstream's own protocol pass through with their native options. Other combinations translate stateless conversations, including streamed text, function tools and results, reasoning and supported images. Cross-protocol requests for stateful Responses, built-in tools or structured output return an explicit error; use the upstream's native protocol for those features. The gateway exposes conversation APIs; models configured only for image generation remain listed with their kind but cannot be called through these conversation endpoints.

## Usage and agent attribution

Calls through all three gateway APIs are included in Settings → Usage when recording is enabled, including native and translated requests, streaming and non-streaming replies. Each gateway request is counted once. Token counts come from the upstream usage fields; missing counts are not estimated. Costs use the actual upstream and model prices. The model list and count_tokens endpoint are excluded.

To reliably identify a client, configure it to send `x-baocode-agent: My ACP agent`. The gateway gives that label priority, then checks known agent signatures in User-Agent and client headers. A specific User-Agent product name is used as a fallback. Requests with only generic SDK headers stay labeled as the local model gateway. Client labels are for usage attribution.

Cache read and write counts use the fields reported by the upstream, including OpenAI-style usage details and DeepSeek cache hits. The gateway separates these counts from uncached input for pricing.

Clients may send `x-baocode-session` to associate calls with a BaoCode conversation. Existing Claude Code request-class, agent ID, parent agent ID and agent-type hints are retained separately. Without these hints, the gateway cannot infer the conversation or subagent. The Usage page agent filter separates gateway clients.

Configuration is stored in the `models.gateway` object in `settings.json`:

```json
{
  "models.gateway": {
    "enabled": false,
    "port": 8317,
    "apiKey": "baocode",
    "useNetworkProxy": true
  }
}
```
