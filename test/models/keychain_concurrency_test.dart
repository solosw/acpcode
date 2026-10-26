@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:baocode/models/secret_store_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('concurrent reads of an account share one security process', () async {
    var calls = 0;
    final pending = Completer<ProcessResult>();
    final store = KeychainSecretStore(
      run: (_, _, {input}) {
        calls++;
        return pending.future;
      },
    );
    final reads = List.generate(100, (_) => store.read('forge.example'));
    expect(calls, 1);
    pending.complete(ProcessResult(1, 0, 'token\n', ''));
    expect(await Future.wait(reads), everyElement('token'));
    expect(await store.read('forge.example'), 'token');
    expect(calls, 2, reason: 'completed reads are not cached');
  });

  for (final deleting in [false, true]) {
    test(
      '${deleting ? 'delete' : 'write'} invalidates only the older read',
      () async {
        final first = Completer<ProcessResult>();
        final second = Completer<ProcessResult>();
        var reads = 0;
        final store = KeychainSecretStore(
          run: (_, arguments, {input}) {
            if (arguments.first != 'find-generic-password') {
              return Future.value(ProcessResult(1, 0, '', ''));
            }
            return ++reads == 1 ? first.future : second.future;
          },
        );
        final old = store.read('account');
        if (deleting) {
          await store.delete('account');
        } else {
          await store.write('account', 'new');
        }
        final fresh = store.read('account');
        expect(reads, 2);
        first.complete(ProcessResult(1, 0, 'old', ''));
        await old;
        final duplicate = store.read('account');
        expect(reads, 2, reason: 'old completion cannot evict the newer read');
        second.complete(ProcessResult(1, 0, 'new', ''));
        expect(await fresh, 'new');
        expect(await duplicate, 'new');
      },
    );
  }

  test('failed reads can be retried and accounts remain isolated', () async {
    var calls = 0;
    final pending = Completer<ProcessResult>();
    final store = KeychainSecretStore(
      run: (_, _, {input}) {
        calls++;
        if (calls <= 2) return pending.future;
        return Future.value(ProcessResult(1, 0, 'new token\n', ''));
      },
    );
    final first = store.read('forge.one');
    final duplicate = store.read('forge.one');
    final second = store.read('forge.two');
    final checks = [
      for (final read in [first, duplicate, second])
        expectLater(read, throwsA(isA<ProcessException>())),
    ];
    expect(calls, 2);
    pending.completeError(
      const ProcessException('security', [], 'Too many open files', 24),
    );
    await Future.wait(checks);
    expect(await store.read('forge.one'), 'new token');
    expect(calls, 3);
  });
}
