// Build-time preparation only. No runtime downloads or system TeX dependency.
// dart run tool/prepare_latex.dart --platform macos-arm64 --out build/latex/macos-arm64
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const tectonicVersion = '0.17.0';
const _texBundle = 'https://relay.fullyjustified.net/default_bundle_v33.tar';
const _texBundleDigest =
    '6ffe055852f8faf66c0acbe1a7fb27f87b869a90bad1204f3bf4d9683f597c7c';
const _release =
    'https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic%400.17.0/';
const tectonicBuilds = {
  'macos-arm64': (
    file: 'tectonic-0.17.0-aarch64-apple-darwin.tar.gz',
    sha: 'a3f1cac7c5678f01661a92212f58480ae3b0634115d880dbc59e2953ded45667',
  ),
  'macos-x64': (
    file: 'tectonic-0.17.0-x86_64-apple-darwin.tar.gz',
    sha: '7c90ef5b6ddb1eb1937e4337add5237b79338e4b9676459fa91187d24d6cdf80',
  ),
  'windows-x64': (
    file: 'tectonic-0.17.0-x86_64-pc-windows-msvc.zip',
    sha: 'f61ce51f0b0ade1015b7de7ef368541c5424e9756ecbd0d7af97d6d48030845f',
  ),
  // The upstream has no Windows ARM64 executable. Windows 11's x64 support
  // runs this helper independently of the app's native ARM64 process.
  'windows-arm64': (
    file: 'tectonic-0.17.0-x86_64-pc-windows-msvc.zip',
    sha: 'f61ce51f0b0ade1015b7de7ef368541c5424e9756ecbd0d7af97d6d48030845f',
  ),
};

Future<void> main(List<String> arguments) async {
  String? option(String name) {
    final index = arguments.indexOf(name);
    return index < 0 || index + 1 >= arguments.length
        ? null
        : arguments[index + 1];
  }

  final platform = option('--platform');
  if (!tectonicBuilds.containsKey(platform)) {
    throw ArgumentError(
      '--platform is one of ${tectonicBuilds.keys.join(', ')}',
    );
  }
  final root = File.fromUri(Platform.script).parent.parent;
  final output = Directory(
    p.absolute(
      option('--out') ?? p.join(root.path, 'build', 'latex', platform!),
    ),
  );
  final engine = await prepareEngine(root, output, platform!);
  if (arguments.contains('--engine-only')) return;
  await prepareBundle(root, output, engine);
}

Future<String> prepareEngine(
  Directory root,
  Directory output,
  String platform,
) async {
  final spec = tectonicBuilds[platform]!;
  final cache = File(p.join(root.path, 'build', 'latex-downloads', spec.file));
  if (!await cache.exists() ||
      sha256.convert(await cache.readAsBytes()).toString() != spec.sha) {
    await download(Uri.parse('$_release${spec.file}'), cache);
  }
  if (sha256.convert(await cache.readAsBytes()).toString() != spec.sha) {
    throw StateError('Tectonic archive checksum mismatch: ${cache.path}');
  }
  final bytes = await cache.readAsBytes();
  final archive = spec.file.endsWith('.zip')
      ? ZipDecoder().decodeBytes(bytes)
      : TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
  await output.create(recursive: true);
  for (final entry in archive) {
    if (!entry.isFile || entry.isSymbolicLink) continue;
    final name = p.posix.basename(entry.name);
    if (name == '.' || name == '..' || name.isEmpty) continue;
    await File(p.join(output.path, name)).writeAsBytes(entry.content);
  }
  final executable = p.join(
    output.path,
    platform.startsWith('windows') ? 'tectonic.exe' : 'tectonic',
  );
  if (!await File(executable).exists()) {
    throw StateError('Missing engine in release archive');
  }
  if (!platform.startsWith('windows')) {
    await checked('chmod', ['755', executable]);
  }
  await File(p.join(output.path, 'engine.json')).writeAsString(
    jsonEncode({
      'version': tectonicVersion,
      'platform': platform,
      'archive': spec.file,
      'sha256': spec.sha,
    }),
  );
  stdout.writeln(
    'Prepared Tectonic $tectonicVersion for $platform at ${output.path}',
  );
  return executable;
}

Future<void> download(Uri uri, File target) async {
  await target.parent.create(recursive: true);
  final partial = File('${target.path}.part');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  stdout.writeln('Downloading $uri');
  try {
    final request = await client.getUrl(uri);
    request.headers.set('User-Agent', 'BaoCode-build');
    final existing = await partial.exists() ? await partial.length() : 0;
    if (existing > 0) request.headers.set('Range', 'bytes=$existing-');
    final response = await request.close().timeout(const Duration(minutes: 2));
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    await response
        .pipe(
          partial.openWrite(
            mode: response.statusCode == 206 ? FileMode.append : FileMode.write,
          ),
        )
        .timeout(const Duration(minutes: 10));
    if (await target.exists()) await target.delete();
    await partial.rename(target.path);
  } finally {
    client.close(force: true);
    if (await partial.exists()) await partial.delete();
  }
}

Future<void> checked(
  String executable,
  List<String> arguments, {
  String? directory,
  Map<String, String>? environment,
  String? input,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: directory,
    environment: environment,
  );
  final out = process.stdout.transform(utf8.decoder).listen(stdout.write);
  final err = process.stderr.transform(utf8.decoder).listen(stderr.write);
  final drained = Future.wait([out.asFuture<void>(), err.asFuture<void>()]);
  try {
    final code = await (() async {
      if (input != null) process.stdin.write(input);
      await process.stdin.close();
      final code = await process.exitCode;
      await drained;
      return code;
    })().timeout(const Duration(minutes: 15));
    if (code != 0) throw StateError('$executable exited $code');
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    throw StateError('$executable timed out');
  } finally {
    await out.cancel();
    await err.cancel();
  }
}

Future<void> prepareBundle(
  Directory root,
  Directory output,
  String engine,
) async {
  // A prepared resource set is platform-independent; reuse it for the other
  // architecture without running an Intel helper on Apple silicon or vice versa.
  final shared = Directory(p.join(root.path, 'build', 'latex-resources'));
  final sources =
      Directory(p.join(root.path, 'tool', 'latex'))
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tex'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final seed = sha256.convert([
    ...utf8.encode('$tectonicVersion $_texBundleDigest'),
    for (final source in sources) ...source.readAsBytesSync(),
  ]).toString();
  final marker = File(p.join(shared.path, 'manifest.json'));
  var ready = false;
  if (await marker.exists()) {
    final manifest =
        jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
    ready = manifest['seed'] == seed;
    if (ready) {
      for (final entry in (manifest['files'] as Map<String, dynamic>).entries) {
        final file = File(p.join(shared.path, 'bundle', entry.key));
        if (!await file.exists() ||
            sha256.convert(await file.readAsBytes()).toString() !=
                entry.value) {
          ready = false;
          break;
        }
      }
    }
  }
  if (!ready) {
    final cache = Directory(
      p.join(root.path, 'build', 'latex-bootstrap-cache'),
    );
    await cache.create(recursive: true);
    final work = await Directory.systemTemp.createTemp(
      'baocode-tex-bootstrap-',
    );
    try {
      for (final source in sources) {
        await checked(
          engine,
          [
            '--bundle',
            _texBundle,
            '--untrusted',
            '--keep-logs',
            '--print',
            '--outdir',
            work.path,
            '-',
          ],
          directory: work.path,
          environment: {'TECTONIC_CACHE_DIR': cache.path},
          input: await source.readAsString(),
        );
      }
      final hashes = Directory(p.join(cache.path, 'bundles', 'hashes'))
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tar'))
          .toList();
      if (hashes.isEmpty ||
          hashes.any((f) => f.readAsStringSync().trim() != _texBundleDigest)) {
        throw StateError(
          'The upstream TeX resource snapshot changed. Review its digest before releasing.',
        );
      }
      final data = Directory(
        p.join(cache.path, 'bundles', 'data', _texBundleDigest),
      );
      if (!await data.exists()) {
        throw StateError('Bootstrap produced no cached TeX resources');
      }
      final destination = Directory(p.join(shared.path, 'bundle'));
      if (await destination.exists()) await destination.delete(recursive: true);
      await destination.create(recursive: true);
      final files = <String, String>{};
      final entries = data.listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in entries) {
        final name = p.basename(file.path);
        if (name == 'SHA256SUM') continue;
        await file.copy(p.join(destination.path, name));
        files[name] = sha256.convert(await file.readAsBytes()).toString();
      }
      // A directory bundle's fingerprint is the digest of its exact contents,
      // not the fingerprint of the upstream full multi-gigabyte distribution.
      final fingerprint = sha256
          .convert(utf8.encode(jsonEncode(files)))
          .toString();
      await File(p.join(destination.path, 'SHA256SUM'))
          .writeAsString(fingerprint);
      files['SHA256SUM'] = sha256.convert(utf8.encode(fingerprint)).toString();
      // Prove a clean machine can compile without a global TeX cache or network.
      final cold = Directory(p.join(work.path, 'cold-cache'));
      for (final source in sources) {
        await checked(
          engine,
          [
            '--bundle',
            destination.uri.toString(),
            '--only-cached',
            '--untrusted',
            '--outdir',
            work.path,
            '-',
          ],
          directory: work.path,
          environment: {'TECTONIC_CACHE_DIR': cold.path},
          input: await source.readAsString(),
        );
      }
      await marker.writeAsString(
        jsonEncode({
          'engine': tectonicVersion,
          'upstreamBundle': _texBundleDigest,
          'seed': seed,
          'files': files,
        }),
      );
    } finally {
      await work.delete(recursive: true);
    }
  }
  final target = Directory(p.join(output.path, 'bundle'));
  if (await target.exists()) await target.delete(recursive: true);
  await target.create(recursive: true);
  for (final file in Directory(
    p.join(shared.path, 'bundle'),
  ).listSync().whereType<File>()) {
    await file.copy(p.join(target.path, p.basename(file.path)));
  }
  await marker.copy(p.join(output.path, 'bundle-manifest.json'));
  for (final file in Directory(
    p.join(root.path, 'tool', 'latex', 'licenses'),
  ).listSync().whereType<File>()) {
    await file.copy(p.join(output.path, p.basename(file.path)));
  }
  stdout.writeln(
    'Bundled ${target.listSync().length} offline TeX resources in ${output.path}',
  );
}
