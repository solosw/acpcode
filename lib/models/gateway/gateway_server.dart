import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../network/tls.dart';
import '../../usage/usage_ledger.dart';
import '../../usage/usage_capture.dart';
import '../../usage/usage_trace.dart';
import '../codex/codex_accounts_io.dart';
import '../model_provider.dart';
import '../model_providers.dart';
import '../proxy/model_proxy.dart';
import '../proxy/translate/thinking.dart';
import '../proxy/watched_socket.dart';
import '../upstream.dart';
import 'gateway_protocol.dart';

/// The user's upstreams at one loopback endpoint. Protocol conversion uses
/// an owned ModelProxy, independently of the app's Claude Code proxy.
class GatewayServer {
  GatewayServer({
    required ModelProviders providers,
    this.apiKey = 'baocode',
    String Function(Uri)? findProxy,
    CodexAccounts? codex,
    UsageLedger Function()? usage,
  }) : _providers = providers,
       _findProxy = findProxy,
       _usage = usage,
       _bridge = ModelProxy(
         provider: providers.provider,
         key: providers.key,
         onError: providers.reportError,
         findProxy: findProxy,
         followRedirects: false,
         codex: codex,
         usage: usage,
         usageSource: 'gateway',
       );

  final ModelProviders _providers;
  final String apiKey;
  final String Function(Uri)? _findProxy;
  final ModelProxy _bridge;
  final UsageLedger Function()? _usage;
  HttpServer? _server;
  WatchedServerSocket? _sockets;
  Future<void>? _starting;
  bool _closing = false;
  HttpClient? _client;
  Future<HttpClient>? _openingClient;
  HttpClient? _local;
  final _calls = <_Call>{};

  int? get port => _server?.port;
  String? get baseUrl => port == null ? null : 'http://127.0.0.1:$port';

  Future<void> start({int port = 8317}) {
    if (_closing) return Future.error(StateError('Gateway is stopping'));
    if (_server != null) return Future.value();
    return _starting ??= _bind(port).whenComplete(() => _starting = null);
  }

  Future<void> _bind(int port) async {
    if (apiKey.isEmpty || apiKey.contains(RegExp(r'\s'))) {
      throw const FormatException(
        'The gateway key must not be empty or contain whitespace',
      );
    }
    final sockets = await WatchedServerSocket.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    _sockets = sockets;
    final server = _server = HttpServer.listenOn(sockets);
    server.listen((request) => unawaited(_handle(request)));
  }

  Future<void> close() async {
    _closing = true;
    try {
      try {
        await _starting;
      } on Object {
        /* A failed bind owns no socket. */
      }
      for (final call in _calls.toList()) {
        call.cancel();
      }
      try {
        await _openingClient;
      } on Object {
        // A failed TLS context does not own a client.
      }
      _openingClient = null;
      _client?.close(force: true);
      _local?.close(force: true);
      _client = null;
      _local = null;
      await _server?.close(force: true);
      _server = null;
      await _sockets?.close();
      _sockets = null;
      await _bridge.close();
    } finally {
      _closing = false;
    }
  }

  bool _authorized(HttpRequest request) {
    final bearer = request.headers.value(HttpHeaders.authorizationHeader);
    final given = bearer != null && bearer.startsWith('Bearer ')
        ? bearer.substring(7)
        : request.headers.value('x-api-key');
    if (given == null || given.length != apiKey.length) return false;
    var different = 0;
    for (var i = 0; i < given.length; i++) {
      different |= given.codeUnitAt(i) ^ apiKey.codeUnitAt(i);
    }
    return different == 0;
  }

  bool _localHost(HttpRequest request) {
    final host = request.headers.value(HttpHeaders.hostHeader);
    return host == '127.0.0.1:$port' || host == 'localhost:$port';
  }

  List<({ModelProvider provider, ProviderModel model})> get _models => [
    for (final provider in _providers.providers)
      if (provider.enabled)
        for (final model in provider.models)
          if (model.enabled) (provider: provider, model: model),
  ];

  ({ModelProvider provider, ProviderModel model}) _resolve(String name) {
    final qualified = parseModelRef(name);
    final suffix = parseSuffix(qualified?.model ?? name);
    final found = _models
        .where(
          (entry) =>
              (qualified == null || entry.provider.id == qualified.provider) &&
              entry.model.id == suffix.modelName,
        )
        .toList();
    if (found.isEmpty) throw _Failure(404, 'No enabled model: $name');
    if (found.length > 1) {
      throw _Failure(
        400,
        'Ambiguous model: $name. Use its @upstream/model ID from /v1/models.',
      );
    }
    return found.single;
  }

  Future<void> _handle(HttpRequest request) async {
    final call = _Call();
    _calls.add(call);
    unawaited(_sockets?.endOf(request)?.then((_) => call.cancel()));
    unawaited(
      request.response.done.then<void>(
        (_) {},
        onError: (Object _) => call.cancel(),
      ),
    );
    UsageLedger? ledger;
    UsageMeter? meter;
    var status = 502;
    var started = false;
    var protocol = GatewayProtocol.openaiChat;
    try {
      if (_closing) throw const _Failure(503, 'The gateway is stopping');
      if (request.headers.value('origin') != null || !_localHost(request)) {
        throw const _Failure(
          403,
          'Only local API clients may use this gateway',
        );
      }
      if (!_authorized(request)) {
        throw const _Failure(401, 'Invalid gateway key');
      }
      final path = request.uri.path;
      if (path == '/v1/models' && request.method == 'GET') {
        final models = [
          for (final (:provider, :model) in _models)
            {
              'id': modelRef(provider.id, model.id),
              'object': 'model',
              'type': 'model',
              'created': 0,
              'created_at': '1970-01-01T00:00:00Z',
              'owned_by': provider.id,
              'display_name': model.label ?? model.id,
              'upstream': provider.name,
              'protocol': provider.protocolOf(model).id,
              'kind': model.kind.id,
            },
        ];
        return await _json(request.response, 200, {
          'object': 'list',
          'data': models,
          'has_more': false,
          'first_id': models.firstOrNull?['id'],
          'last_id': models.lastOrNull?['id'],
        });
      }
      final countTokens = path == '/v1/messages/count_tokens';
      protocol = switch (path) {
        '/v1/chat/completions' => GatewayProtocol.openaiChat,
        '/v1/responses' => GatewayProtocol.openaiResponses,
        '/v1/messages' ||
        '/v1/messages/count_tokens' => GatewayProtocol.anthropic,
        _ => throw const _Failure(404, 'No such gateway endpoint'),
      };
      if (request.method != 'POST') {
        throw const _Failure(405, 'Use POST for this endpoint');
      }
      final body = await _readBody(request);
      final name = body['model'];
      if (name is! String || name.isEmpty) {
        throw const _Failure(400, 'A model is required');
      }
      final found = _resolve(name);
      if (found.model.kind == ModelKind.image) {
        throw const _Failure(
          400,
          'This image model does not support conversation endpoints',
        );
      }
      final provider = found.provider.speakingFor(found.model.id);
      final native = switch (protocol) {
        GatewayProtocol.anthropic =>
          provider.protocol == ProviderProtocol.anthropic,
        GatewayProtocol.openaiChat =>
          provider.protocol == ProviderProtocol.openaiChat,
        GatewayProtocol.openaiResponses =>
          provider.protocol == ProviderProtocol.openaiResponses,
      };
      final HttpClientResponse answer;
      if (native) {
        if (!countTokens) {
          ledger = _usage?.call();
          if (ledger != null && ledger.enabled) {
            final info = _requestInfo(body, protocol, request, ledger.detailed);
            final followed = meter = UsageMeter(
              provider: provider.id,
              providerName: provider.name,
              protocol: provider.protocol.name,
              responseProtocol: protocol.name,
              source: 'gateway',
              clientAgent: gatewayClientAgent(request.headers.value),
              model: found.model.id,
              effort: _effort(body, protocol),
              stream: body['stream'] == true,
              session:
                  request.headers.value(UsageHeaders.session) ??
                  sessionId(
                    body,
                    header: request.headers.value(sessionHeaderName),
                  ),
              requestBytes: utf8.encode(jsonEncode(body)).length,
              info: info,
            );
            call.meter = followed;
            ledger.begin(followed, () => followed.progress);
            if (ledger.trace) {
              followed.trace = UsageTrace(UsageTrace.newId(DateTime.now()))
                ..asked(
                  method: request.method,
                  url: request.uri.toString(),
                  headers: UsageTraceMessage.headersOf(request.headers.forEach),
                  body: jsonEncode(body),
                );
            }
          }
        }
        answer = await _direct(
          provider,
          {...body, 'model': found.model.id},
          request,
          call,
          countTokens,
        );
      } else {
        if (found.model.kind.generatesImages) {
          throw const _Failure(
            400,
            'Image conversations require their upstream protocol',
          );
        }
        answer = await _translated(
          provider,
          found.model.id,
          body,
          request,
          protocol,
          call,
          countTokens,
        );
      }
      status = answer.statusCode;
      meter?.answered();
      meter?.trace?.answered(
        answer.statusCode,
        UsageTraceMessage.headersOf(answer.headers.forEach),
      );
      if (call.cancelled) return;
      if (answer.statusCode >= 300 && answer.statusCode < 400) {
        await call.read(answer).drain<void>();
        throw const _Failure(
          502,
          'The upstream redirected the request. Configure its final endpoint URL.',
        );
      }
      final response = request.response;
      if (native ||
          protocol == GatewayProtocol.anthropic ||
          countTokens ||
          answer.statusCode >= 300) {
        _copyHeaders(answer, response);
        response.bufferOutput = false;
        started = true;
        await for (final chunk in call.read(answer)) {
          response.add(chunk);
          await response.flush();
        }
        await response.close();
      } else if (body['stream'] == true) {
        response.headers
          ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
          ..set(HttpHeaders.cacheControlHeader, 'no-cache');
        response.bufferOutput = false;
        started = true;
        final translator = GatewayStreamTranslator(protocol, model: name);
        await for (final line
            in call
                .read(answer)
                .transform(const Utf8Decoder())
                .transform(const LineSplitter())) {
          for (final frame in translator.convert(line)) {
            response.write(frame);
          }
          await response.flush();
        }
        for (final frame in translator.finish()) {
          response.write(frame);
        }
        await response.close();
      } else {
        try {
          final message = jsonDecode(
            await utf8.decodeStream(call.read(answer)),
          );
          if (message is! Map<String, dynamic>) {
            throw const _Failure(
              502,
              'The upstream returned an invalid message',
            );
          }
          final converted = gatewayFromAnthropic(message, protocol);
          converted['model'] = name;
          await _json(response, answer.statusCode, converted);
        } on FormatException {
          throw const _Failure(502, 'The upstream returned an invalid message');
        }
      }
    } on _Failure catch (error) {
      status = error.status;
      meter?.fail(error.message);
      if (!call.cancelled && !started) {
        await _error(request.response, error.status, error.message, protocol);
      }
    } on FormatException catch (error) {
      status = 400;
      meter?.fail(error.message);
      if (!call.cancelled && !started) {
        await _error(request.response, 400, error.message, protocol);
      }
    } on Object {
      status = 502;
      meter?.fail('Unable to complete the upstream request');
      if (!call.cancelled && !started) {
        await _error(
          request.response,
          502,
          'Unable to complete the upstream request',
          protocol,
        );
      }
    } finally {
      call.done = true;
      if (call.cancelled) meter?.cancel();
      final trace = meter?.trace;
      trace?.finish(
        status,
        UsageTraceMessage.headersOf(request.response.headers.forEach),
      );
      if (meter?.finish(status) case final record?) {
        ledger?.record(record, trace: trace);
      }
      if (meter != null) ledger?.end(meter);
      _calls.remove(call);
      await request.response.close().catchError((Object _) {});
    }
  }

  Future<HttpClient> _upstream() => _openingClient ??= _makeClient();

  Future<HttpClient> _makeClient() async {
    try {
      return _client = HttpClient(context: await upstreamSecurityContext())
        ..connectionTimeout = const Duration(seconds: 30)
        ..idleTimeout = const Duration(seconds: 30)
        ..findProxy = _findProxy ?? (_) => 'DIRECT';
    } on Object {
      _openingClient = null;
      rethrow;
    }
  }

  Future<HttpClientResponse> _direct(
    ModelProvider provider,
    Map<String, dynamic> body,
    HttpRequest incoming,
    _Call call,
    bool countTokens,
  ) async {
    var url = UpstreamUrls.endpoint(provider);
    if (url == null) {
      throw const _Failure(400, 'The upstream has no valid endpoint');
    }
    if (countTokens) url = url.replace(path: '${url.path}/count_tokens');
    final query = [
      url.query,
      incoming.uri.query,
    ].where((value) => value.isNotEmpty).join('&');
    url = url.replace(query: query.isEmpty ? null : query);
    final client = await _upstream();
    if (call.cancelled) throw const _ClientGone();
    final request = await client.postUrl(url);
    call.attach(request);
    request.followRedirects = false;
    upstreamHeaders(
      provider,
      await _providers.key(provider.id),
    ).forEach(request.headers.set);
    if (provider.protocol == ProviderProtocol.anthropic) {
      for (final name in const ['anthropic-version', 'anthropic-beta']) {
        final value = incoming.headers.value(name);
        if (value != null) request.headers.set(name, value);
      }
    }
    customUpstreamHeaders(
      provider,
      session: sessionId(
        body,
        header: incoming.headers.value(sessionHeaderName),
      ),
      model: body['model'] as String,
    ).forEach(request.headers.set);
    request.headers
      ..contentType = ContentType.json
      ..set(
        HttpHeaders.acceptHeader,
        body['stream'] == true ? 'text/event-stream' : 'application/json',
      );
    if (body['stream'] == true &&
        provider.protocol == ProviderProtocol.openaiChat) {
      body = {
        ...body,
        'stream_options': {
          if (body['stream_options'] is Map) ...body['stream_options'] as Map,
          'include_usage': true,
        },
      };
    }
    final payload = jsonEncode(body);
    call.meter?.trace?.sending(
      method: 'POST',
      url: url,
      headers: UsageTraceMessage.headersOf(request.headers.forEach),
      body: payload,
    );
    request.write(payload);
    return request.close();
  }

  Future<HttpClientResponse> _translated(
    ModelProvider provider,
    String model,
    Map<String, dynamic> body,
    HttpRequest incoming,
    GatewayProtocol protocol,
    _Call call,
    bool countTokens,
  ) async {
    final converted = gatewayToAnthropic(body, protocol);
    final effort = _effort(body, protocol);
    final requested = parseSuffix(
      parseModelRef(body['model'] as String)?.model ?? body['model'] as String,
    );
    final suffix = effort == null
        ? (requested.hasSuffix ? '(${requested.rawSuffix})' : '')
        : '($effort)';
    // The private proxy interprets suffixes only for OpenAI/Codex. Its
    // Anthropic path passes the model verbatim; thinking is already held
    // in converted['thinking'] and converted['output_config'] there.
    converted['model'] = provider.protocol == ProviderProtocol.anthropic
        ? model
        : '$model$suffix';
    final endpoint = await _bridge.endpoint(provider.id);
    if (call.cancelled) throw const _ClientGone();
    final local = _local ??= HttpClient()..findProxy = (_) => 'DIRECT';
    final url = Uri.parse(
      '${endpoint.baseUrl}/v1/messages${countTokens ? '/count_tokens' : ''}',
    );
    final request = await local.postUrl(url);
    call.attach(request);
    request.followRedirects = false;
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${endpoint.token}');
    for (final name in const [
      sessionHeaderName,
      UsageHeaders.session,
      UsageHeaders.requestClass,
      UsageHeaders.agentId,
      UsageHeaders.parentAgentId,
      UsageHeaders.agentType,
      UsageHeaders.promptId,
      UsageHeaders.compaction,
      UsageHeaders.contextCompacted,
      UsageHeaders.toolDurations,
      'anthropic-beta',
      'anthropic-version',
    ]) {
      final value = incoming.headers.value(name);
      if (value != null) request.headers.set(name, value);
    }
    final agent = gatewayClientAgent(incoming.headers.value);
    if (agent != null) request.headers.set(UsageHeaders.clientAgent, agent);
    request.write(jsonEncode(converted));
    return request.close();
  }

  static UsageRequestInfo _requestInfo(
    Map<String, dynamic> body,
    GatewayProtocol protocol,
    HttpRequest request,
    bool detailed,
  ) {
    // Context estimates use the common Messages representation. Native-only
    // features must remain usable even when no cross-protocol equivalent exists.
    try {
      return analyzeRequest(
        gatewayToAnthropic(body, protocol),
        request.headers.value,
        detailed: detailed,
      );
    } on FormatException {
      return analyzeRequest(
        const {'messages': <Object>[]},
        request.headers.value,
        detailed: false,
      );
    }
  }

  static String? _effort(Map<String, dynamic> body, GatewayProtocol protocol) {
    final effort = switch (protocol) {
      GatewayProtocol.openaiChat => body['reasoning_effort'],
      GatewayProtocol.openaiResponses =>
        (body['reasoning'] is Map
            ? (body['reasoning'] as Map)['effort']
            : null),
      GatewayProtocol.anthropic =>
        (body['output_config'] is Map
            ? (body['output_config'] as Map)['effort']
            : null),
    };
    if (effort is String && effort.isNotEmpty) return effort;
    final thinking = body['thinking'];
    if (thinking is Map) {
      if (thinking['type'] == 'disabled') return ThinkingLevel.none;
      final budget = thinking['budget_tokens'];
      if (budget is int) return convertBudgetToLevel(budget);
      if (thinking['type'] == 'adaptive') return ThinkingLevel.auto;
    }
    return null;
  }

  static Future<Map<String, dynamic>> _readBody(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      if (bytes.length + chunk.length > 16 * 1024 * 1024) {
        throw const _Failure(413, 'The request exceeds 16 MiB');
      }
      bytes.addAll(chunk);
    }
    final body = jsonDecode(utf8.decode(bytes));
    if (body is! Map<String, dynamic>) {
      throw const _Failure(400, 'The request must be a JSON object');
    }
    return body;
  }

  static void _copyHeaders(HttpClientResponse source, HttpResponse target) {
    target.statusCode = source.statusCode;
    const excluded = {
      'connection',
      'keep-alive',
      'transfer-encoding',
      'content-length',
      'content-encoding',
      'proxy-authenticate',
      'proxy-authorization',
      'trailer',
      'upgrade',
      'set-cookie',
      // A client must not resend its gateway key to the upstream's redirect.
      'location',
    };
    final connection =
        source.headers
            .value('connection')
            ?.split(',')
            .map((name) => name.trim().toLowerCase())
            .toSet() ??
        const <String>{};
    source.headers.forEach((name, values) {
      if (!excluded.contains(name) && !connection.contains(name)) {
        target.headers.set(name, values);
      }
    });
  }

  static Future<void> _error(
    HttpResponse response,
    int status,
    String message,
    GatewayProtocol protocol,
  ) async {
    try {
      await _json(
        response,
        status,
        protocol == GatewayProtocol.anthropic
            ? {
                'type': 'error',
                'error': {'type': 'invalid_request_error', 'message': message},
              }
            : {
                'error': {
                  'type': 'invalid_request_error',
                  'message': message,
                  'code': status,
                },
              },
      );
    } on Object {
      // A disconnect may race writing the error response.
    }
  }

  static Future<void> _json(HttpResponse response, int status, Object body) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    return response.close();
  }
}

class _Call {
  final _gone = Completer<void>();
  HttpClientRequest? _request;
  UsageMeter? meter;
  bool done = false;
  bool get cancelled => _gone.isCompleted;

  void attach(HttpClientRequest request) {
    _request = request;
    if (cancelled) request.abort(const _ClientGone());
  }

  void cancel() {
    if (done || cancelled) return;
    _gone.complete();
    _request?.abort(const _ClientGone());
  }

  Stream<List<int>> read(Stream<List<int>> input) {
    StreamSubscription<List<int>>? subscription;
    late StreamController<List<int>> output;
    output = StreamController<List<int>>(
      onListen: () {
        subscription = input.listen(
          (chunk) {
            meter?.bytes(chunk);
            output.add(chunk);
          },
          onError: output.addError,
          onDone: output.close,
        );
        unawaited(
          _gone.future.then((_) {
            if (output.isClosed) return;
            unawaited(subscription?.cancel());
            output
              ..addError(const _ClientGone())
              ..close();
          }),
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () => subscription?.cancel(),
    );
    return output.stream;
  }
}

class _Failure implements Exception {
  const _Failure(this.status, this.message);
  final int status;
  final String message;
}

class _ClientGone implements Exception {
  const _ClientGone();
}
