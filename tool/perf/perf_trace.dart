// The timeline of each phase, read from the perf app's own VM service and
// written as a Chrome trace (open it in https://ui.perfetto.dev): the
// frames, the builds of the app's widgets in them (with [detail], every
// widget's, and every layout and paint), the Dart events and the GC. Costs time itself: a run with traces is for
// finding where it goes, not for its figures.

import 'dart:convert';
import 'dart:developer' show Service;
import 'dart:io';
import 'dart:isolate' as isolates show Isolate;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

class PerfTrace {
  PerfTrace._(this._service, this.directory);

  final VmService _service;
  final String directory;

  /// Connects to the app's VM service (profile builds have one), and has
  /// the timeline record what the frames are made of.
  static Future<PerfTrace?> connect(
    String directory, {
    bool detail = false,
  }) async {
    var info = await Service.getInfo();
    info = info.serverUri == null
        ? await Service.controlWebServer(enable: true)
        : info;
    final uri = info.serverWebSocketUri;
    if (uri == null) {
      stderr.writeln('BAOCODE_PERF_LOG no VM service: no traces');
      return null;
    }
    final service = await vmServiceConnectUri(uri.toString());
    await service.setVMTimelineFlags(['Dart', 'Embedder', 'GC']);
    // The app's own widgets' builds; with [detail], the framework's too.
    debugProfileBuildsEnabledUserWidgets = true;
    debugProfileBuildsEnabled = detail;
    debugProfileLayoutsEnabled = detail;
    debugProfilePaintsEnabled = detail;
    Directory(directory).createSync(recursive: true);
    return PerfTrace._(service, directory);
  }

  Future<void> begin() => _service.clearVMTimeline();

  /// Writes what the timeline recorded since [begin] to [name].json.
  Future<String> end(String name) async {
    final timeline = await _service.getVMTimeline();
    final path = '$directory/$name.json';
    File(path).writeAsStringSync(
      jsonEncode({
        'traceEvents': [
          for (final event in timeline.traceEvents ?? const []) event.json,
        ],
      }),
    );
    return path;
  }
}

/// With BAOCODE_PERF_HEAP set, what the Dart heaps hold after each phase,
/// logged: each isolate's heap and external memory (what Dart objects hold
/// outside the heap: images, the engine's paragraphs and pictures), and the
/// main isolate's classes holding most, after a full GC.
abstract final class PerfHeap {
  static final bool enabled = Platform.environment.containsKey(
    'BAOCODE_PERF_HEAP',
  );
  static VmService? _service;

  static Future<void> log(String label) async {
    if (!enabled) return;
    try {
      final service = _service ??= await _connect();
      if (service == null) return;
      final vm = await service.getVM();
      final main = Service.getIsolateId(isolates.Isolate.current);
      final lines = <String>[];
      for (final isolate in [...?vm.isolates, ...?vm.systemIsolates]) {
        final usage = await service.getMemoryUsage(isolate.id!);
        lines.add(
          '${isolate.name}: heap ${_mb(usage.heapUsage)}/${_mb(usage.heapCapacity)} '
          'external ${_mb(usage.externalUsage)}',
        );
      }
      if (main != null) {
        final profile = await service.getAllocationProfile(main, gc: true);
        final members = [
          ...?profile.members,
        ]..sort((a, b) => (b.bytesCurrent ?? 0).compareTo(a.bytesCurrent ?? 0));
        lines.add(
          'top: ${[for (final m in members.take(20)) '${m.classRef?.name}${m.classRef?.library?.uri == null ? '' : ''} ${_mb(m.bytesCurrent)} (${m.instancesCurrent})'].join(', ')}',
        );
      }
      stderr.writeln('BAOCODE_PERF_LOG heap $label: ${lines.join(' | ')}');
    } on Object catch (error) {
      stderr.writeln('BAOCODE_PERF_LOG heap: $error');
    }
  }

  static String _mb(int? bytes) =>
      '${((bytes ?? 0) / 1048576).toStringAsFixed(1)}MB';

  static Future<VmService?> _connect() async {
    var info = await Service.getInfo();
    info = info.serverUri == null
        ? await Service.controlWebServer(enable: true)
        : info;
    final uri = info.serverWebSocketUri;
    return uri == null ? null : vmServiceConnectUri(uri.toString());
  }
}
