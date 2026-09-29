import 'package:calltype/shared/identity/peer_directory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fallback directory shows handle, else the shortened id', () {
    final directory = FallbackPeerDirectory(
      handles: {'11111111-2222': 'CT-AAAA-0001'},
    );
    expect(directory.displayName('11111111-2222'), 'CT-AAAA-0001');
    expect(directory.displayName('abcdef0123456789'), 'abcdef01');
    expect(directory.displayName('short'), 'short');
    expect(directory.handle('abcdef0123456789'), isNull);
    expect(directory.isBlocked('x'), isFalse);
    expect(directory.isContact('x'), isFalse);
    expect(directory.avatarThumb('x'), isNull);
    expect(directory.identityState('x'), IdentityState.unverified);
    expect(IdentityState.values, hasLength(4));
  });
}
