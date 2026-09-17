import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'api_client.dart';

extension BackupApi on ApiClient {
  Future<void> uploadBackup(String accountId, Uint8List payload) async {
    await transport.post(
      '/backups/$accountId',
      data: FormData.fromMap({
        'file': MultipartFile.fromBytes(payload, filename: 'backup.enc'),
      }),
    );
  }

  Future<List<Map<String, dynamic>>> listBackups(String accountId) async {
    final response = await transport.get<List<dynamic>>('/backups/$accountId');
    return response.data!.cast<Map<String, dynamic>>();
  }

  Future<Uint8List> downloadBackup(String accountId, int backupId) async {
    final response = await transport.get<List<int>>(
      '/backups/$accountId/$backupId',
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(response.data!);
  }

  Future<void> deleteBackup(String accountId, int backupId) async {
    await transport.delete('/backups/$accountId/$backupId');
  }

  Future<void> linkAccountDevice(
    String accountId,
    String deviceId,
    String authKey,
  ) async {
    await transport.post(
      '/accounts/$accountId/devices/$deviceId',
      data: {'authKey': authKey},
    );
  }
}
