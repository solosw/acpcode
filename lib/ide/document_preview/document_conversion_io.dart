import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'document_conversion.dart';

typedef DocumentCommandResult = ({int exitCode, String output});
typedef DocumentCommandRunner = Future<DocumentCommandResult> Function(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required String input,
});

/// App-owned runtime paths, independent of the document's host or PATH.
String bundledLatexDirectory(
  String executable, {
  required bool macOS,
  p.Context? paths,
}) {
  final context = paths ?? p.context;
  final directory = context.dirname(executable);
  return macOS
      ? context.normalize(context.join(directory, '..', 'Resources', 'latex'))
      : context.join(directory, 'latex');
}

class LocalDocumentConverter implements DocumentConverter {
  LocalDocumentConverter({
    String? runtimeDirectory,
    this.run,
    this.timeout = const Duration(minutes: 2),
  }) : runtimeDirectory = runtimeDirectory ?? _runtimeDirectory();

  final String runtimeDirectory;
  final DocumentCommandRunner? run;
  final Duration timeout;

  @override
  Future<DocumentConversion> latex(String path, String source) async {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      throw const DocumentConversionException(
        DocumentConversionFailure.unavailable,
      );
    }
    final executable = p.join(
      runtimeDirectory,
      Platform.isWindows ? 'tectonic.exe' : 'tectonic',
    );
    final bundle = Directory(p.join(runtimeDirectory, 'bundle'));
    if (!await File(executable).exists() ||
        !await File(p.join(bundle.path, 'SHA256SUM')).exists()) {
      throw const DocumentConversionException(
        DocumentConversionFailure.missingTex,
      );
    }
    final temporary = await Directory.systemTemp.createTemp('baocode-latex-');
    try {
      final arguments = [
        '--bundle',
        bundle.uri.toString(),
        '--only-cached',
        '--untrusted',
        '--keep-logs',
        '--print',
        '--color',
        'never',
        '--outdir',
        temporary.path,
        '-',
      ];
      // stdin compiles the editor's snapshot without changing the source path
      // or redirecting relative \input / image lookup to the temporary folder.
      final result = run != null
          ? await run!(
              executable,
              arguments,
              workingDirectory: p.dirname(path),
              input: source,
            )
          : await _command(executable, arguments, p.dirname(path), source);
      final pdf = File(p.join(temporary.path, 'texput.pdf'));
      if (result.exitCode != 0 || !await pdf.exists()) {
        throw DocumentConversionException(
          DocumentConversionFailure.failed,
          result.output,
        );
      }
      final bytes = await pdf.readAsBytes();
      if (bytes.length < 5 ||
          ascii.decode(bytes.sublist(0, 5), allowInvalid: true) != '%PDF-') {
        throw DocumentConversionException(
          DocumentConversionFailure.failed,
          result.output,
        );
      }
      return DocumentConversion(bytes, result.output);
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  Future<DocumentCommandResult> _command(
    String executable,
    List<String> arguments,
    String directory,
    String source,
  ) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: directory,
    );
    final output = StringBuffer();
    void collect(String text) {
      final remaining = 65536 - output.length;
      if (remaining > 0) {
        output.write(text.substring(0, text.length.clamp(0, remaining)));
      }
    }

    final stdout = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(collect);
    final stderr = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(collect);
    final drained = Future.wait([
      stdout.asFuture<void>(),
      stderr.asFuture<void>(),
    ]);
    try {
      final exitCode = await (() async {
        process.stdin.add(utf8.encode(source));
        await process.stdin.close();
        final code = await process.exitCode;
        await drained;
        return code;
      })().timeout(timeout);
      return (exitCode: exitCode, output: output.toString());
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      throw DocumentConversionException(
        DocumentConversionFailure.timeout,
        output.toString(),
      );
    } finally {
      await stdout.cancel();
      await stderr.cancel();
    }
  }
}

String _runtimeDirectory() {
  // Development explicitly opts into a prepared runtime; production never
  // loads a compiler from a project directory or an environment override.
  if (!const bool.fromEnvironment('dart.vm.product')) {
    final override = Platform.environment['BAOCODE_LATEX_RUNTIME'];
    if (override != null && p.isAbsolute(override)) return override;
  }
  return bundledLatexDirectory(
    Platform.resolvedExecutable,
    macOS: Platform.isMacOS,
  );
}
