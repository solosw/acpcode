import 'package:baocode/chat/panels/health_banner.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, KernelHealth health) =>
      tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: HealthBanner(
              health: health,
              kernelName: 'Claude Code',
              onRetry: () {},
            ),
          ),
        ),
      );

  testWidgets('a project folder that is gone is said in the user\'s '
      'language', (tester) async {
    await pump(
      tester,
      const KernelHealth(
        KernelHealthStatus.failed,
        message: 'The project folder is gone: ~/code/app',
        missingFolder: '~/code/app',
      ),
    );
    expect(find.text('项目文件夹不存在：~/code/app'), findsOneWidget);
    expect(find.textContaining('is gone'), findsNothing);
  });

  testWidgets('another failure shows its message', (tester) async {
    await pump(
      tester,
      const KernelHealth(
        KernelHealthStatus.failed,
        message: 'Claude Code is not installed',
      ),
    );
    expect(find.text('Claude Code is not installed'), findsOneWidget);
  });
}
