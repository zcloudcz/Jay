import 'package:dio/dio.dart';

import '../auth/auth_service.dart';
import 'channel_dtos.dart';
import 'mfa_api.dart' show MfaRequiredException;

/// REST client for the CallType backend API.
///
/// Wraps [Dio] to provide typed methods for every server endpoint the
/// client needs. Each method documents the endpoint it calls and the
/// shape of its response so callers don't need to guess at JSON keys.
///
/// When an [AuthService] is provided, every request carries the device's
/// JWT as a Bearer header (all server endpoints except registration,
/// health, and the auth endpoints themselves require it). A 401 response
/// triggers ONE forced token refresh + retry — this covers token expiry
/// between the local freshness check and the server's validation.
///
/// The base URL is injected via constructor so the app can point at
/// different environments (localhost during dev, staging, production)
/// without rebuilding.
class ApiClient {
  ApiClient({
    required String baseUrl,
    AuthService? authService,
    Dio? dio,
    DateTime Function() now = DateTime.now,
  }) : _dio = dio ?? Dio(BaseOptions(baseUrl: baseUrl)),
       _now = now {
    // Dio runs request interceptors in the order they were added, and the
    // LAST one to write the Authorization header wins. The step-up interceptor
    // therefore goes AFTER the auth one: added first, its header was silently
    // overwritten by the normal device token and every admin call kept
    // answering mfa_required (found by the live E2E run — the contract tests
    // had built the client without an AuthService and could not see it).
    if (authService != null) {
      _dio.interceptors.add(_AuthInterceptor(authService, _dio));
    }
    _dio.interceptors.add(_StepUpInterceptor(this));
  }

  final Dio _dio;
  final DateTime Function() _now;

  Dio get transport => _dio;

  // -- MFA step-up token (N03c) ------------------------------------------
  // Kept IN MEMORY ONLY — never written to SecretStore, never logged. It
  // proves a recent TOTP/backup-code check to org/emergency admin endpoints
  // (MfaAuthHelper.RequireStepUp on the server) and must never reach the
  // SignalR hub, which authenticates with the normal device JWT via
  // AuthService directly and never touches this ApiClient/Dio instance.
  String? _stepUpToken;
  DateTime? _stepUpExpiresAt;

  /// Stashes the step-up token returned by `verifyMfa` so subsequent
  /// requests carry it automatically. [expiresAt] is the server's own
  /// expiry; a small safety margin is applied when deciding whether it is
  /// still usable (see [_StepUpInterceptor]).
  void setStepUpToken(String token, DateTime expiresAt) {
    _stepUpToken = token;
    _stepUpExpiresAt = expiresAt;
  }

  /// Drops the step-up token immediately (explicit logout/step-down, or the
  /// interceptor discovering it has expired).
  void clearStepUp() {
    _stepUpToken = null;
    _stepUpExpiresAt = null;
  }

  /// A small margin before the server-declared expiry, same idea as
  /// [AuthService]'s token refresh margin — never send a token that is
  /// about to be rejected mid-flight.
  static const _stepUpExpiryMargin = Duration(seconds: 30);

  String? get _validStepUpToken {
    final token = _stepUpToken;
    final expiresAt = _stepUpExpiresAt;
    if (token == null || expiresAt == null) return null;
    if (!_now().isBefore(expiresAt.subtract(_stepUpExpiryMargin))) {
      clearStepUp();
      return null;
    }
    return token;
  }

  Future<Map<String, dynamic>> createGroup(
    String name,
    List<String> memberDeviceIds, {
    String? organizationId,
  }) async {
    // Business groups have their own endpoint (E02): the server adds the
    // organization's auditor member atomically and checks enrollment. The
    // anonymous request stays byte-identical to before Business mode existed.
    final response = organizationId == null
        ? await _dio.post<Map<String, dynamic>>(
            '/groups',
            data: {'name': name, 'memberDeviceIds': memberDeviceIds},
          )
        : await _dio.post<Map<String, dynamic>>(
            '/groups/business',
            data: {
              'organizationId': organizationId,
              'memberDeviceIds': memberDeviceIds,
            },
          );
    return response.data!;
  }

  Future<List<String>> getGroupMembers(String groupId) async {
    final response = await _dio.get<List<dynamic>>('/groups/$groupId/members');
    return response.data!
        .map((member) => (member as Map)['deviceId'] as String)
        .toList();
  }

  /// Like [getGroupMembers] but keeps the profile fields the server returns per
  /// member (used for @mention suggestions and sender names in groups).
  ///
  /// `userHandle`, `displayName` and `isBot` are optional on purpose: servers
  /// deployed before they were added return only deviceId/role/joinedAt.
  Future<List<GroupMemberInfo>> getGroupMemberInfos(String groupId) async {
    final response = await _dio.get<List<dynamic>>('/groups/$groupId/members');
    return response.data!.map((member) {
      final m = member as Map;
      return GroupMemberInfo(
        deviceId: m['deviceId'] as String,
        userHandle: m['userHandle'] as String?,
        displayName: m['displayName'] as String?,
        isBot: m['isBot'] == true,
      );
    }).toList();
  }

  // -- Device registration ---------------------------------------------------

  /// Registers a new anonymous device with the server.
  ///
  /// Uploads the device's public identity key, signed pre-key, and a batch
  /// of one-time pre-keys required for X3DH key agreement. The server
  /// assigns a device UUID and a human-readable handle (CT-XXXX-XXXX).
  ///
  /// [oneTimePreKeys] items are `{ keyId: int, publicKey: base64 }` — the
  /// keyId comes back to us later in pre-key messages so we can look up
  /// the matching private key locally.
  ///
  /// POST /devices
  Future<Map<String, dynamic>> registerDevice({
    required String identityKey,
    required String signedPreKey,
    required List<Map<String, dynamic>> oneTimePreKeys,
    String? signingKey,
    String? signature,
    bool? isBot,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/devices',
      data: {
        'identityKey': identityKey,
        'signedPreKey': signedPreKey,
        'oneTimePreKeys': oneTimePreKeys,
        'signingKey': signingKey,
        'signature': signature,
        // Self-declared and immutable server-side; only headless bots send
        // it. Omitted (not false) for the app so its request is unchanged.
        'isBot': ?isBot,
      },
    );
    return response.data!;
  }

  Future<Map<String, dynamic>> findDeviceByHandle(String handle) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/devices/by-handle/${Uri.encodeComponent(handle)}',
    );
    return response.data!;
  }

  // -- Key bundle ------------------------------------------------------------

  /// Fetches the X3DH key bundle for a remote device.
  ///
  /// The bundle contains the identity key, signed pre-key, and one
  /// one-time pre-key (consumed on use). The initiating device uses
  /// this bundle to perform X3DH and establish a Double Ratchet session
  /// without requiring the recipient to be online.
  ///
  /// GET /devices/{deviceId}/key-bundle
  Future<Map<String, dynamic>> getKeyBundle(String deviceId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/devices/$deviceId/key-bundle',
    );
    return response.data!;
  }

  // -- TURN credentials ------------------------------------------------------

  /// Fetches time-limited TURN relay credentials for WebRTC calls.
  ///
  /// TURN is needed when direct peer-to-peer connections fail due to
  /// symmetric NATs or restrictive firewalls. The credentials expire
  /// after [ttlSeconds] to limit abuse.
  ///
  /// GET /turn/credentials?deviceId={deviceId}
  Future<Map<String, dynamic>> getTurnCredentials(String deviceId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/turn/credentials',
      queryParameters: {'deviceId': deviceId},
    );
    return response.data!;
  }

  // -- Account (optional registration) ---------------------------------------

  /// Registers an optional account for cloud backup and multi-device sync.
  ///
  /// The [authKey] is derived client-side from the user's passphrase via
  /// Argon2id — the server only ever sees the derived key, never the raw
  /// passphrase. Registration is optional; the app works fully without it.
  ///
  /// POST /accounts
  Future<Map<String, dynamic>> registerAccount({
    required String email,
    required String authKey,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/accounts',
      data: {'email': email, 'authKey': authKey},
    );
    return response.data!;
  }

  /// Authenticates an existing account.
  ///
  /// Returns an account ID on success. Used when setting up a new device
  /// on an existing account (multi-device) or restoring from backup.
  ///
  /// POST /accounts/login
  Future<Map<String, dynamic>> login({
    required String email,
    required String authKey,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/accounts/login',
      data: {'email': email, 'authKey': authKey},
    );
    return response.data!;
  }

  // -- Push notifications -----------------------------------------------------

  /// Registers or updates the device's push notification token on the server.
  ///
  /// Called at app startup and whenever the FCM token refreshes. The server
  /// uses this token to send data-only push notifications when messages arrive
  /// while the app is not connected via SignalR.
  ///
  /// PUT /devices/{deviceId}/push-token
  Future<void> updatePushToken({
    required String deviceId,
    required String token,
    required String platform,
  }) async {
    await _dio.put(
      '/devices/$deviceId/push-token',
      data: {'token': token, 'platform': platform},
    );
  }

  // -- Profile -----------------------------------------------------------------

  /// Sets (or clears, with null) the device's own display name.
  ///
  /// Optional, anonymous-friendly: contacts see the handle until the device
  /// owner sets a name here. Same trust level as the handle — plaintext
  /// discovery metadata the server stores, never message content.
  ///
  /// PUT /devices/{deviceId}/profile
  Future<void> updateDisplayName({
    required String deviceId,
    required String? displayName,
  }) async {
    await _dio.put(
      '/devices/$deviceId/profile',
      data: {'displayName': displayName},
    );
  }

  // -- Channels ---------------------------------------------------------------
  // Public one-way broadcast channels. Unlike everything above, channel
  // content is plaintext on the server (NOT end-to-end encrypted). All JSON
  // field names are kept in channel_dtos.dart — do not inline them here.

  /// POST /channels → 201 with the full channel profile. 403
  /// `account_required` when the device has no linked registered account,
  /// 409 `channel_limit_reached` over the per-account limit.
  Future<ChannelInfo> createChannel(String name, String description) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/channels',
      data: createChannelBody(name, description),
    );
    return ChannelInfo.fromJson(response.data!);
  }

  /// PATCH /channels/{id} (owner/admin) — null = leave unchanged. Returns
  /// the updated profile.
  Future<ChannelInfo> updateChannel(
    String channelId, {
    String? name,
    String? description,
  }) async {
    final response = await _dio.patch<Map<String, dynamic>>(
      '/channels/$channelId',
      data: updateChannelBody(name: name, description: description),
    );
    return ChannelInfo.fromJson(response.data!);
  }

  /// DELETE /channels/{id} (owner) — soft delete; followers get the
  /// `ChannelDeleted` hub event.
  Future<void> deleteChannel(String channelId) =>
      _dio.delete<void>('/channels/$channelId');

  /// GET /channels/{idOrHandle} — public profile, never a follower list.
  Future<ChannelInfo> getChannel(String idOrHandle) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/channels/${Uri.encodeComponent(idOrHandle)}',
    );
    return ChannelInfo.fromJson(response.data!);
  }

  /// GET /channels/mine — followed + administered channels with unread counts.
  Future<List<ChannelInfo>> getMyChannels() async {
    final response = await _dio.get<dynamic>('/channels/mine');
    return parseList(response.data).map(ChannelInfo.fromJson).toList();
  }

  /// POST /channels/{id}/follow — idempotent.
  Future<void> followChannel(String channelId) =>
      _dio.post<void>('/channels/$channelId/follow');

  /// DELETE /channels/{id}/follow — idempotent.
  Future<void> unfollowChannel(String channelId) =>
      _dio.delete<void>('/channels/$channelId/follow');

  /// GET /channels/{id}/posts — [before] / [after] are UTC ISO-8601 cursors.
  Future<List<ChannelPostDto>> getChannelPosts(
    String channelId, {
    String? before,
    String? after,
    int? limit,
  }) async {
    final response = await _dio.get<dynamic>(
      '/channels/$channelId/posts',
      queryParameters: postsQuery(before: before, after: after, limit: limit),
    );
    return parseList(response.data)
        .map((json) => ChannelPostDto.fromJson(json, channelId: channelId))
        .toList();
  }

  /// POST /channels/{id}/posts → the stored post (201). Repeating the same
  /// [postId] answers 200 with the ALREADY stored post, so a retry after a
  /// timeout cannot publish twice and still learns the server's createdAt.
  Future<ChannelPostDto> createChannelPost(
    String channelId, {
    required String postId,
    required String kind,
    required String body,
    String? attachmentBlobPath,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/channels/$channelId/posts',
      data: createPostBody(
        postId: postId,
        kind: kind,
        body: body,
        attachmentBlobPath: attachmentBlobPath,
      ),
    );
    return ChannelPostDto.fromJson(response.data!, channelId: channelId);
  }

  /// DELETE /channels/{id}/posts/{postId} — admin soft delete (tombstone).
  Future<void> deleteChannelPost(String channelId, String postId) =>
      _dio.delete<void>('/channels/$channelId/posts/$postId');

  /// PUT / DELETE /channels/{id}/posts/{postId}/reaction — null removes it.
  /// Returns the post's fresh totals.
  Future<ChannelPostTotals> setChannelReaction(
    String channelId,
    String postId,
    String? emoji,
  ) async {
    final path = '/channels/$channelId/posts/$postId/reaction';
    final response = emoji == null
        ? await _dio.delete<Map<String, dynamic>>(path)
        : await _dio.put<Map<String, dynamic>>(path, data: reactionBody(emoji));
    return ChannelPostTotals.fromJson(response.data!);
  }

  /// PUT /channels/{id}/posts/{postId}/vote → the post's fresh totals.
  Future<ChannelPostTotals> voteChannelPoll(
    String channelId,
    String postId,
    int optionIndex,
  ) async {
    final response = await _dio.put<Map<String, dynamic>>(
      '/channels/$channelId/posts/$postId/vote',
      data: voteBody(optionIndex),
    );
    return ChannelPostTotals.fromJson(response.data!);
  }

  /// POST /channels/{id}/attachments (multipart field `file`) → blob path.
  Future<String> uploadChannelAttachment(
    String channelId,
    List<int> bytes,
    String fileName,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/channels/$channelId/attachments',
      data: FormData.fromMap({
        // The server whitelists on this part's content type (415 otherwise);
        // without it dio would send application/octet-stream.
        'file': MultipartFile.fromBytes(
          bytes,
          filename: fileName,
          contentType: switch (channelImageContentType(fileName)) {
            final type? => DioMediaType.parse(type),
            null => null,
          },
        ),
      }),
    );
    return parseUploadedBlobPath(response.data!);
  }

  /// GET /channels/{id}/attachments/{name} — needs the Bearer header, so the
  /// UI cannot simply hand the URL to an image widget.
  Future<List<int>> getChannelAttachment(
    String channelId,
    String blobPath,
  ) async {
    // The route takes the file name; the post carries the full blob path.
    final name = blobPath.split('/').last;
    final response = await _dio.get<List<int>>(
      '/channels/$channelId/attachments/${Uri.encodeComponent(name)}',
      options: Options(responseType: ResponseType.bytes),
    );
    return response.data!;
  }

  /// POST /channels/{id}/report → 204. The reporter's identity is never
  /// shown to the channel's admins.
  Future<void> reportChannel(
    String channelId,
    String reason, {
    String? postId,
  }) => _dio.post<void>(
    '/channels/$channelId/report',
    data: reportBody(reason, postId: postId),
  );

  /// GET /channels/{id}/admins — owner only (403 otherwise).
  Future<List<ChannelAdminDto>> getChannelAdmins(String channelId) async {
    final response = await _dio.get<dynamic>('/channels/$channelId/admins');
    return parseList(response.data).map(ChannelAdminDto.fromJson).toList();
  }

  /// PUT / DELETE /channels/{id}/admins/{deviceId} — owner only.
  Future<void> setChannelAdmin(
    String channelId,
    String deviceId, {
    required bool admin,
  }) {
    final path = '/channels/$channelId/admins/$deviceId';
    return admin ? _dio.put<void>(path) : _dio.delete<void>(path);
  }
}

/// Dio interceptor that attaches a valid step-up token (if any) as Bearer,
/// overriding the normal device JWT for that one request, and turns a 403
/// `mfa_required` response into a typed [MfaRequiredException] so callers
/// can catch it instead of poking at raw Dio error bodies (see `withMfa` in
/// mfa_api.dart).
class _StepUpInterceptor extends Interceptor {
  _StepUpInterceptor(this._client);

  final ApiClient _client;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = _client._validStepUpToken;
    if (token != null) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final body = err.response?.data;
    if (err.response?.statusCode == 403 &&
        body is Map &&
        body['code'] == 'mfa_required') {
      handler.reject(
        DioException(
          requestOptions: err.requestOptions,
          response: err.response,
          type: err.type,
          error: const MfaRequiredException(),
        ),
      );
      return;
    }
    handler.next(err);
  }
}

/// Dio interceptor that attaches the device JWT and retries once on 401.
///
/// Request flow:
///   - Ask [AuthService] for a token. Null (device not registered yet) means
///     the request goes out unauthenticated — registration and health checks
///     must work without credentials.
///   - On 401: force-refresh the token and replay the request exactly once.
///     The `_retriedFlag` in request extras prevents infinite retry loops
///     when credentials are genuinely invalid (e.g. device deleted server-side).
class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._authService, this._dio);

  final AuthService _authService;
  final Dio _dio;

  /// Marker in RequestOptions.extra so a replayed request is never
  /// retried a second time.
  static const _retriedFlag = 'auth_retried';

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // The auth endpoints themselves must never carry a Bearer header —
    // they ARE the mechanism that issues tokens.
    if (!options.path.startsWith('/auth/')) {
      final token = await _authService.getToken();
      if (token != null) {
        options.headers['Authorization'] = 'Bearer $token';
      }
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final alreadyRetried = options.extra[_retriedFlag] == true;

    if (err.response?.statusCode != 401 ||
        alreadyRetried ||
        options.path.startsWith('/auth/')) {
      handler.next(err);
      return;
    }

    // The server rejected our token even though the local cache considered
    // it fresh (clock skew, server restart with new signing key, …).
    // Refresh once and replay.
    try {
      final token = await _authService.getToken(forceRefresh: true);
      if (token == null) {
        handler.next(err);
        return;
      }

      options.headers['Authorization'] = 'Bearer $token';
      options.extra[_retriedFlag] = true;
      if (options.data is FormData) {
        options.data = (options.data as FormData).clone();
      }

      final response = await _dio.fetch<dynamic>(options);
      handler.resolve(response);
    } on DioException catch (retryErr) {
      // The retry itself failed — surface the NEW error (it carries the
      // fresher status code / message).
      handler.next(retryErr);
    }
  }
}

/// One member of a group as reported by `GET /groups/{id}/members`.
class GroupMemberInfo {
  const GroupMemberInfo({
    required this.deviceId,
    this.userHandle,
    this.displayName,
    this.isBot = false,
  });

  final String deviceId;

  /// `CT-XXXX-XXXX`; null when talking to an older server.
  final String? userHandle;

  /// The member's own (server-side) profile name, not a local contact rename.
  final String? displayName;
  final bool isBot;
}
