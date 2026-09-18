//! Thin flutter_rust_bridge wrapper around `mls_core::MlsClient`.
//!
//! Wraps rather than exposes `MlsClient` directly: frb parses source in
//! this crate, and keeping the wire-level (String/Vec<u8>) surface here
//! means mls_core stays a plain Rust crate usable from the Rust
//! integration test (tests/scenario.rs) without any FFI-shaped types
//! leaking into it.
use mls_core::MlsClient as CoreClient;

pub struct MlsClientHandle(CoreClient);

impl MlsClientHandle {
    /// Named constructor -> frb generates `MlsClientHandle.newIdentity(name)`.
    pub fn new_identity(name: String) -> Result<MlsClientHandle, String> {
        CoreClient::new_identity(&name).map(MlsClientHandle)
    }

    pub fn create_key_package_bytes(&self) -> Result<Vec<u8>, String> {
        self.0.create_key_package_bytes()
    }

    pub fn create_group(&mut self) -> Result<(), String> {
        self.0.create_group()
    }

    pub fn add_member_from_bytes(
        &mut self,
        key_package_bytes: Vec<u8>,
    ) -> Result<AddMemberResult, String> {
        let (commit, welcome) = self.0.add_member_from_bytes(&key_package_bytes)?;
        Ok(AddMemberResult { commit, welcome })
    }

    pub fn join_from_welcome(&mut self, welcome_bytes: Vec<u8>) -> Result<(), String> {
        self.0.join_from_welcome(&welcome_bytes)
    }

    pub fn encrypt(&mut self, plaintext: Vec<u8>) -> Result<Vec<u8>, String> {
        self.0.encrypt(&plaintext)
    }

    /// Returns `None` when the incoming message was a Commit (handshake),
    /// `Some(plaintext)` when it was an application message.
    pub fn process_incoming(&mut self, wire_bytes: Vec<u8>) -> Result<Option<Vec<u8>>, String> {
        self.0.process_incoming(&wire_bytes)
    }

    pub fn member_count(&self) -> Result<usize, String> {
        self.0.member_count()
    }
}

/// Commit + Welcome pair a Delivery Service must route separately (Commit
/// to existing members, Welcome only to the new joiner) — see plan M0
/// "server implications".
pub struct AddMemberResult {
    pub commit: Vec<u8>,
    pub welcome: Vec<u8>,
}
