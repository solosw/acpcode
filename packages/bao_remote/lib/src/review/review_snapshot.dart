import 'review_store.dart';

/// Optional workspace discovery, separate from per-conversation edit events.
abstract interface class ReviewSnapshots {
  Future<ReviewSnapshot?> snapshot(String root, {String? previous});
}

/// A path differing between two trees, or between two workspace snapshots.
class ReviewTreeChange {
  const ReviewTreeChange(this.path, this.before, this.after);

  final String path;
  final ReviewBlob? before;
  final ReviewBlob? after;
}

/// Snapshot changes use absolute host paths and the review store's blob ids.
class ReviewSnapshot {
  const ReviewSnapshot(this.tree, this.changes, this.omitted);

  final String tree;
  final List<ReviewTreeChange> changes;
  final Set<String> omitted;

  Map<String, Object?> toJson() => {
    'tree': tree,
    'changes': [
      for (final change in changes)
        [change.path, change.before?.toJson(), change.after?.toJson()],
    ],
    'omitted': omitted.toList(),
  };

  static ReviewSnapshot? fromJson(Object? value) {
    if (value is! Map) return null;
    return ReviewSnapshot(value['tree'] as String, [
      for (final change in value['changes'] as List)
        ReviewTreeChange(
          change[0] as String,
          ReviewBlob.fromJson(change[1]),
          ReviewBlob.fromJson(change[2]),
        ),
    ], (value['omitted'] as List).cast<String>().toSet());
  }
}
