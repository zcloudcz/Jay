import 'media_store.dart';
import 'media_store_memory.dart';

/// Neither dart:io nor the browser: only for analysis of a pure Dart build.
MediaStore createMediaStore() => MemoryMediaStore();
