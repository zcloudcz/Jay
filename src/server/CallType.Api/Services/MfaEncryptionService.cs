// ---------------------------------------------------------------------------
// MfaEncryptionService.cs — AES-256-GCM at rest for TOTP secrets (N03a)
// ---------------------------------------------------------------------------
// The TOTP secret is the only thing an attacker needs to mint valid codes
// forever, so it is not stored as plaintext even though the DB column is
// already access-controlled. Key comes from configuration (Mfa:EncryptionKey,
// base64, 32 bytes) — NOT derived from anything in the database, so a
// leaked/backed-up DB dump alone cannot decrypt it. This does NOT protect
// against a compromised running API process, which holds the key in memory
// to serve MFA requests.
//
// Format: nonce (12 bytes) || ciphertext || tag (16 bytes), all concatenated
// into one column. A fresh random nonce per encryption is mandatory for
// GCM — reuse under the same key breaks confidentiality.
//
// IsConfigured is false when the key is missing or malformed. Callers MUST
// treat "not configured" as "MFA endpoints answer 503, and privileged
// organization endpoints stay locked" — never as "MFA is off".
// ---------------------------------------------------------------------------

using System.Security.Cryptography;

namespace CallType.Api.Services;

public class MfaEncryptionService
{
    private const int NonceBytes = 12;
    private const int TagBytes = 16;

    private readonly byte[]? _key;

    public MfaEncryptionService(IConfiguration configuration)
    {
        var keyBase64 = configuration["Mfa:EncryptionKey"];
        if (string.IsNullOrEmpty(keyBase64)) return;

        try
        {
            var key = Convert.FromBase64String(keyBase64);
            if (key.Length == 32) _key = key;
        }
        catch (FormatException)
        {
            // Malformed key is treated the same as a missing one — IsConfigured
            // stays false rather than throwing at startup.
        }
    }

    public bool IsConfigured => _key is not null;

    public byte[] Encrypt(byte[] plaintext)
    {
        if (_key is null) throw new InvalidOperationException("Mfa:EncryptionKey is not configured.");

        var nonce = RandomNumberGenerator.GetBytes(NonceBytes);
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[TagBytes];

        using var gcm = new AesGcm(_key, TagBytes);
        gcm.Encrypt(nonce, plaintext, ciphertext, tag);

        var result = new byte[NonceBytes + ciphertext.Length + TagBytes];
        nonce.CopyTo(result, 0);
        ciphertext.CopyTo(result, NonceBytes);
        tag.CopyTo(result, NonceBytes + ciphertext.Length);
        return result;
    }

    public byte[] Decrypt(byte[] blob)
    {
        if (_key is null) throw new InvalidOperationException("Mfa:EncryptionKey is not configured.");
        if (blob.Length < NonceBytes + TagBytes) throw new CryptographicException("MFA secret blob is too short.");

        var nonce = blob.AsSpan(0, NonceBytes);
        var tag = blob.AsSpan(blob.Length - TagBytes, TagBytes);
        var ciphertext = blob.AsSpan(NonceBytes, blob.Length - NonceBytes - TagBytes);
        var plaintext = new byte[ciphertext.Length];

        using var gcm = new AesGcm(_key, TagBytes);
        gcm.Decrypt(nonce, ciphertext, tag, plaintext);
        return plaintext;
    }
}
