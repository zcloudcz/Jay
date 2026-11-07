import 'package:drift/drift.dart';

import '../../core/storage/database.dart';
import 'media_message.dart';
import 'media_service.dart';

/// Deletes the local copy of the media in [body] (a `media` row that was
/// just removed or tombstoned) unless another message still references the
/// same media id: a forwarded copy shares the file (contract 4.3, "Delete
/// for me also deletes the local file when no other message references the
/// same media id"). Best effort: a failure leaves a file, never breaks the
/// delete itself.
Future<void> deleteUnreferencedMedia(
  AppDatabase db,
  MediaService media,
  String? body,
  String removedMessageId,
) async {
  final info = MediaInfo.tryDecode(body);
  if (info == null) return;
  try {
    if (info.isDraft) {
      await media.deleteLocal(MediaService.uploadFolder(removedMessageId));
      return;
    }
    // Bodies are canonical jsonEncode output, so the id appears exactly as
    // `"id":"<guid>"`; the decode below rules out a caption that merely
    // contains that text.
    final others =
        await (db.select(db.messages)..where(
              (m) =>
                  m.type.equals('media') &
                  m.id.equals(removedMessageId).not() &
                  m.body.like('%"id":"${info.id}"%'),
            ))
            .get();
    final referenced = others.any(
      (m) => MediaInfo.tryDecode(m.body)?.id == info.id,
    );
    if (!referenced) await media.deleteLocal(info.id);
  } catch (_) {}
}
