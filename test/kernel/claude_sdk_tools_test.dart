import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const call = ClaudeSdkCall(cwd: '/p', sessionId: 's');

  tearDown(() => ClaudeSdkTools.unregister('echo'));

  test('no tools, no server', () {
    expect(ClaudeSdkTools.any, isFalse);
    expect(ClaudeSdkTools.servers, isEmpty);
  });

  test('lists and calls its tools, failures as errors', () async {
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'echo',
        description: 'Says it back.',
        inputSchema: const {'type': 'object'},
        run: (input, call) async {
          if (input['fail'] == true) throw StateError('no');
          return '${input['text']} in ${call.cwd}';
        },
      ),
    );
    expect(ClaudeSdkTools.servers, ['baocode']);

    final init = await ClaudeSdkTools.handle({
      'jsonrpc': '2.0',
      'id': 0,
      'method': 'initialize',
      'params': {'protocolVersion': '2025-06-18'},
    }, call);
    expect((init['result'] as Map)['protocolVersion'], '2025-06-18');

    final list = await ClaudeSdkTools.handle({
      'id': 1,
      'method': 'tools/list',
    }, call);
    final tools = (list['result'] as Map)['tools'] as List;
    expect(tools.single, containsPair('name', 'echo'));

    final ok = await ClaudeSdkTools.handle({
      'id': 2,
      'method': 'tools/call',
      'params': {
        'name': 'echo',
        'arguments': {'text': 'hi'},
      },
    }, call);
    expect(ok['id'], 2);
    expect(ok['result'], {
      'content': [
        {'type': 'text', 'text': 'hi in /p'},
      ],
    });

    final failed = await ClaudeSdkTools.handle({
      'id': 3,
      'method': 'tools/call',
      'params': {
        'name': 'echo',
        'arguments': {'fail': true},
      },
    }, call);
    expect((failed['result'] as Map)['isError'], isTrue);

    final unknown = await ClaudeSdkTools.handle({
      'id': 4,
      'method': 'resources/list',
    }, call);
    expect((unknown['error'] as Map)['code'], -32601);
  });
}
