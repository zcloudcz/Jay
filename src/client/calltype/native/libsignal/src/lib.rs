// ---------------------------------------------------------------------------
// calltype_signal — Scaffold FFI bridge for libsignal
// ---------------------------------------------------------------------------
// This crate provides C-ABI functions that the Dart/Flutter layer calls via
// FFI (mobile) or WASM (web) to perform Signal Protocol operations.
//
// PLACEHOLDER IMPLEMENTATION: All key material generated here is random bytes,
// NOT real Signal Protocol keys. This scaffold exists so the Dart crypto layer
// can develop and test its FFI plumbing before the real libsignal-protocol
// crate is integrated. Real integration requires:
//   1. Pinning a specific libsignal-protocol version
//   2. Implementing IdentityKeyStore, PreKeyStore, etc.
//   3. Wiring up X3DH key agreement and Double Ratchet sessions
//
// Every public function follows the same pattern:
//   - Allocate a JSON string on the heap via CString
//   - Return a *mut c_char to the caller
//   - The caller MUST free the string via signal_free_string()
// ---------------------------------------------------------------------------

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use libc::c_char;
use rand::Rng;
use std::ffi::CString;

/// Generates a placeholder identity key pair (random 32-byte keys).
///
/// Returns a JSON string: {"publicKey":"base64...","privateKey":"base64..."}
///
/// # Safety
/// The returned pointer must be freed by calling `signal_free_string`.
#[no_mangle]
pub extern "C" fn signal_generate_identity_key_pair() -> *mut c_char {
    let mut rng = rand::thread_rng();

    let mut public_key = [0u8; 32];
    let mut private_key = [0u8; 32];
    rng.fill(&mut public_key);
    rng.fill(&mut private_key);

    let json = serde_json::json!({
        "publicKey": BASE64.encode(public_key),
        "privateKey": BASE64.encode(private_key),
    });

    // unwrap is safe here — the JSON contains only ASCII/base64 characters,
    // so it cannot contain interior null bytes.
    CString::new(json.to_string()).unwrap().into_raw()
}

/// Generates a batch of placeholder pre-keys starting at `start_id`.
///
/// Returns a JSON array: [{"keyId":1,"publicKey":"base64...","privateKey":"base64..."}, ...]
///
/// # Safety
/// The returned pointer must be freed by calling `signal_free_string`.
#[no_mangle]
pub extern "C" fn signal_generate_pre_keys(start_id: u32, count: u32) -> *mut c_char {
    let mut rng = rand::thread_rng();
    let mut keys = Vec::with_capacity(count as usize);

    for i in 0..count {
        let mut public_key = [0u8; 32];
        let mut private_key = [0u8; 32];
        rng.fill(&mut public_key);
        rng.fill(&mut private_key);

        keys.push(serde_json::json!({
            "keyId": start_id + i,
            "publicKey": BASE64.encode(public_key),
            "privateKey": BASE64.encode(private_key),
        }));
    }

    let json = serde_json::Value::Array(keys);
    CString::new(json.to_string()).unwrap().into_raw()
}

/// Frees a string that was allocated by one of the signal_* functions.
///
/// # Safety
/// `ptr` must be a pointer previously returned by a signal_* function
/// and must not have been freed already (double-free is UB).
#[no_mangle]
pub unsafe extern "C" fn signal_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        // Reconstruct the CString so Rust's allocator can free it properly.
        // This is the standard pattern for returning heap-allocated strings
        // across FFI boundaries.
        drop(CString::from_raw(ptr));
    }
}
