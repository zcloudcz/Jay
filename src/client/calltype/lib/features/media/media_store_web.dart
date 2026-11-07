import 'media_store.dart';
import 'media_store_memory.dart';

/// Web: no file system, the session keeps media in memory (contract M13).
MediaStore createMediaStore() => MemoryMediaStore();
