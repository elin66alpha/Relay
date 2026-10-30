import 'dart:async';

class WorkdirInfo {
  const WorkdirInfo({
    required this.dir,
    this.exists = true,
    this.isDirectory = true,
    this.busy = false,
    this.created = false,
  });

  factory WorkdirInfo.fromJson(Map<String, Object?> json) {
    return WorkdirInfo(
      dir: json['dir'] as String? ?? '',
      exists: json['exists'] as bool? ?? true,
      isDirectory: json['isDirectory'] as bool? ?? true,
      busy: json['busy'] as bool? ?? false,
      created: json['created'] as bool? ?? false,
    );
  }

  final String dir;
  final bool exists;
  final bool isDirectory;
  final bool busy;
  final bool created;
}

class FsEntry {
  const FsEntry({
    required this.name,
    required this.path,
    required this.absolutePath,
    required this.type,
    required this.size,
    required this.modifiedAt,
  });

  factory FsEntry.fromJson(Map<String, Object?> json) {
    return FsEntry(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      absolutePath: json['absolutePath'] as String? ?? '',
      type: json['type'] as String? ?? 'other',
      size: (json['size'] as num?)?.toInt() ?? 0,
      modifiedAt: json['modifiedAt'] as String? ?? '',
    );
  }

  final String name;
  final String path;
  final String absolutePath;
  final String type;
  final int size;
  final String modifiedAt;

  bool get isDirectory => type == 'directory';
  bool get isFile => type == 'file';
}

class FsListing {
  const FsListing({
    required this.root,
    required this.path,
    required this.absolutePath,
    required this.entries,
    this.parentPath,
  });

  factory FsListing.fromJson(Map<String, Object?> json) {
    final List<Object?> rawEntries = json['entries'] is List
        ? (json['entries'] as List).cast<Object?>()
        : const <Object?>[];
    return FsListing(
      root: json['root'] as String? ?? '',
      path: json['path'] as String? ?? '',
      absolutePath: json['absolutePath'] as String? ?? '',
      parentPath: json['parentPath'] as String?,
      entries: rawEntries
          .whereType<Map>()
          .map((Map entry) => FsEntry.fromJson(entry.cast<String, Object?>()))
          .toList(growable: false),
    );
  }

  final String root;
  final String path;
  final String absolutePath;
  final String? parentPath;
  final List<FsEntry> entries;
}

/// An in-progress file download: response metadata plus the live byte stream.
/// The caller consumes [bytes] straight to its destination (a file on native, a
/// blob on web) so a large download is never buffered whole in memory.
class FsDownloadStream {
  const FsDownloadStream({
    required this.fileName,
    required this.total,
    required this.bytes,
  });

  final String fileName;

  /// Total bytes when the server announced a Content-Length, else null.
  final int? total;

  final Stream<List<int>> bytes;
}
