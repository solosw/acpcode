import 'package:baocode/chat/composer/suggestion_menu.dart';
import 'package:baocode/stash/stash_actions.dart';
import 'package:baocode/stash/stash_disk.dart';
import 'package:baocode/stash/stash_note.dart';
import 'package:baocode/stash/stash_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../sidebar_test.dart' show KeptCatalog, kept, keptThread, pumpKept;
import 'session_mentions_test.dart' show inMenu, pressKey, typeText;

void main() {
  late StashStore store;

  Future<void> loadStore() async {
    store = StashStore(MemoryStashDisk());
    await store.load();
  }

  tearDown(() => store.dispose());

  test(
    'stash suggestions isolate projects, hosts and workspace folders',
    () async {
      await loadStore();
      final a = await store.create(body: 'A', project: '/code/app');
      final b = await store.create(body: 'B', project: '/else/app');
      final remote = await store.create(
        body: 'Remote',
        project: 'ssh://host/code/app',
      );
      final unassigned = await store.create(body: 'Unassigned');
      final done = await store.create(body: 'Done', project: '/code/app');
      await store.update(done.id, (note) => note.status = StashStatus.done);
      await store.create(body: '', project: '/code/app');
      List<String> ids(String? project, {List<String> folders = const []}) => [
        for (final suggestion in stashSuggestions(
          store,
          'Stash',
          project: project,
          folders: folders,
        ))
          suggestion.id,
      ];
      expect(ids('/code/app'), ['${a.id}']);
      expect(ids('/else/app'), ['${b.id}']);
      expect(ids('ssh://host/code/app'), ['${remote.id}']);
      expect(ids(null), ['${unassigned.id}']);
      expect(ids('/unknown'), isEmpty);
      expect(
        ids('/workspace', folders: ['/code/app', '/else/app']),
        unorderedEquals(['${a.id}', '${b.id}']),
      );
    },
  );

  testWidgets('@ only offers stashes belonging to the selected chat project', (
    tester,
  ) async {
    await loadStore();
    final previous = StashStore.current;
    StashStore.current = store;
    addTearDown(() => StashStore.current = previous);
    final a = await store.create(body: 'Stash alpha', project: '/tmp/a');
    final b = await store.create(body: 'Stash beta', project: '/tmp/b');
    await store.create(body: 'Stash unassigned');
    final workspace = await pumpKept(
      tester,
      KeptCatalog([kept('a', '/tmp/a', 1), kept('b', '/tmp/b', 2)]),
    );
    workspace.select(keptThread(workspace, 'a'));
    await tester.pump();
    await typeText(tester, '@Stash');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SuggestionMenu), findsOneWidget);
    expect(inMenu(find.text('#${a.id} Stash alpha')), findsOneWidget);
    expect(inMenu(find.text('#${b.id} Stash beta')), findsNothing);
    expect(inMenu(find.textContaining('Stash unassigned')), findsNothing);
    await pressKey(tester, LogicalKeyboardKey.escape);
    workspace.select(keptThread(workspace, 'b'));
    await tester.pump();
    await typeText(tester, '@Stash');
    await tester.pump(const Duration(milliseconds: 300));
    expect(inMenu(find.text('#${b.id} Stash beta')), findsOneWidget);
    expect(inMenu(find.text('#${a.id} Stash alpha')), findsNothing);
    await pressKey(tester, LogicalKeyboardKey.escape);
  });
}
