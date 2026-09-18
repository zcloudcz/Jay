//! Minimal MLS (RFC 9420) wrapper around `openmls`, built for the M0
//! feasibility spike (see spikes/mls/REPORT.md). Not production code:
//! error handling is "spike-grade" (String errors, no retries), and the
//! API surface is only what the spike scenario in tests/scenario.rs needs.
//!
//! Why openmls 0.9.0 pinned: that's what `cargo add` resolved against the
//! crates.io index on 2026-09-17; see REPORT.md for the version matrix.

use openmls::prelude::tls_codec::{Deserialize, Serialize};
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;

/// Ciphersuite fixed for the spike — X25519 + AES-128-GCM + SHA-256 + Ed25519.
/// A real client would need to reason about ciphersuite negotiation; out of
/// scope here (see spec 4.3, "Rozhodovací bod").
pub const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

/// One MLS client (= one device, in CallType terms). Bundles the crypto
/// provider (key/state storage) with the identity keys and the group it has
/// joined. A real client would keep the provider's storage on disk
/// (SQLCipher/Drift on the Flutter side); here it's in-memory only.
pub struct MlsClient {
    provider: OpenMlsRustCrypto,
    signature_keys: SignatureKeyPair,
    credential_with_key: CredentialWithKey,
    group: Option<MlsGroup>,
}

fn group_config() -> MlsGroupCreateConfig {
    // use_ratchet_tree_extension(true): ships the full ratchet tree in the
    // Welcome/GroupInfo so a joiner doesn't need an out-of-band tree —
    // simplest option for a spike; a production Directory Service could
    // instead serve the tree separately to shrink Welcome size.
    MlsGroupCreateConfig::builder()
        .ciphersuite(CIPHERSUITE)
        .use_ratchet_tree_extension(true)
        .build()
}

fn join_config() -> MlsGroupJoinConfig {
    MlsGroupJoinConfig::builder()
        .use_ratchet_tree_extension(true)
        .build()
}

impl MlsClient {
    /// Creates a fresh identity (credential + signature key pair). Roughly
    /// equivalent to CallType's today device-identity generation, but for
    /// the MLS signature key instead of the X3DH identity key.
    pub fn new_identity(name: &str) -> Result<Self, String> {
        let provider = OpenMlsRustCrypto::default();
        let signature_keys = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())
            .map_err(|e| format!("keygen failed: {e}"))?;
        signature_keys
            .store(provider.storage())
            .map_err(|e| format!("store signature keys failed: {e:?}"))?;

        let credential_with_key = CredentialWithKey {
            credential: BasicCredential::new(name.as_bytes().to_vec()).into(),
            signature_key: signature_keys.to_public_vec().into(),
        };

        Ok(Self {
            provider,
            signature_keys,
            credential_with_key,
            group: None,
        })
    }

    /// Publishes a KeyPackage — the thing a Directory Service would store
    /// so others can add this client to a group without it being online
    /// (mirrors today's OneTimePreKey, see plan section "Server implications").
    pub fn create_key_package(&self) -> Result<KeyPackageBundle, String> {
        KeyPackage::builder()
            .build(
                CIPHERSUITE,
                &self.provider,
                &self.signature_keys,
                self.credential_with_key.clone(),
            )
            .map_err(|e| format!("key package build failed: {e:?}"))
    }

    /// Creates a brand-new group with only this client as a member.
    pub fn create_group(&mut self) -> Result<(), String> {
        let group = MlsGroup::new(
            &self.provider,
            &self.signature_keys,
            &group_config(),
            self.credential_with_key.clone(),
        )
        .map_err(|e| format!("group creation failed: {e:?}"))?;
        self.group = Some(group);
        Ok(())
    }

    /// Serializes this client's KeyPackage to wire bytes — what a Directory
    /// Service would actually store/hand out (see plan M0 "server
    /// implications"), rather than a live Rust object. This is also the
    /// shape the FFI boundary (flutter_rust_bridge) needs: plain bytes in,
    /// plain bytes out, no openmls types crossing the boundary.
    pub fn create_key_package_bytes(&self) -> Result<Vec<u8>, String> {
        let bundle = self.create_key_package()?;
        bundle
            .key_package()
            .tls_serialize_detached()
            .map_err(|e| format!("key package serialize failed: {e:?}"))
    }

    /// Adds a member from a wire-format KeyPackage (as fetched from a
    /// Directory Service). Validates the KeyPackage's signature/lifetime
    /// before use, same as a real client must never trust an unverified
    /// KeyPackage.
    pub fn add_member_from_bytes(
        &mut self,
        key_package_bytes: &[u8],
    ) -> Result<(Vec<u8>, Vec<u8>), String> {
        let kp_in = KeyPackageIn::tls_deserialize_exact(key_package_bytes)
            .map_err(|e| format!("key package deserialize failed: {e:?}"))?;
        let key_package = kp_in
            .validate(self.provider.crypto(), ProtocolVersion::Mls10)
            .map_err(|e| format!("key package validation failed: {e:?}"))?;
        self.add_member(&key_package)
    }

    /// Adds a member (by KeyPackage) to the group this client belongs to.
    /// Returns the serialized Commit (to broadcast to existing members) and
    /// the serialized Welcome (to deliver only to the new member) — this is
    /// the pair the Delivery Service has to route (see plan KB2/M0 server
    /// implications).
    pub fn add_member(&mut self, key_package: &KeyPackage) -> Result<(Vec<u8>, Vec<u8>), String> {
        let group = self.group.as_mut().ok_or("not in a group")?;
        let (commit, welcome, _group_info) = group
            .add_members(&self.provider, &self.signature_keys, &[key_package.clone()])
            .map_err(|e| format!("add_members failed: {e:?}"))?;
        group
            .merge_pending_commit(&self.provider)
            .map_err(|e| format!("merge_pending_commit failed: {e:?}"))?;

        let commit_bytes = commit
            .tls_serialize_detached()
            .map_err(|e| format!("commit serialize failed: {e:?}"))?;
        let welcome_bytes = welcome
            .tls_serialize_detached()
            .map_err(|e| format!("welcome serialize failed: {e:?}"))?;
        Ok((commit_bytes, welcome_bytes))
    }

    /// Removes a member by their leaf index in the (pre-removal) member list.
    /// Returns the serialized Commit to broadcast.
    pub fn remove_member(&mut self, leaf_index: u32) -> Result<Vec<u8>, String> {
        let group = self.group.as_mut().ok_or("not in a group")?;
        let (commit, _welcome, _group_info) = group
            .remove_members(
                &self.provider,
                &self.signature_keys,
                &[LeafNodeIndex::new(leaf_index)],
            )
            .map_err(|e| format!("remove_members failed: {e:?}"))?;
        group
            .merge_pending_commit(&self.provider)
            .map_err(|e| format!("merge_pending_commit failed: {e:?}"))?;
        commit
            .tls_serialize_detached()
            .map_err(|e| format!("commit serialize failed: {e:?}"))
    }

    /// Finds a member's leaf index by their credential identity (name).
    /// A real client would key this off DeviceId, not a display name.
    pub fn find_member_leaf_index(&self, identity: &str) -> Result<u32, String> {
        let group = self.group.as_ref().ok_or("not in a group")?;
        group
            .members()
            .find(|m| m.credential.serialized_content() == identity.as_bytes())
            .map(|m| m.index.u32())
            .ok_or_else(|| format!("member '{identity}' not found"))
    }

    /// Joins a group from a serialized Welcome message (received out of
    /// band, e.g. via the Delivery Service — see plan "welcome delivery").
    pub fn join_from_welcome(&mut self, welcome_bytes: &[u8]) -> Result<(), String> {
        let welcome_msg = MlsMessageIn::tls_deserialize_exact(welcome_bytes)
            .map_err(|e| format!("welcome deserialize failed: {e:?}"))?;
        let welcome = match welcome_msg.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => return Err("message is not a Welcome".into()),
        };
        let staged_join =
            StagedWelcome::new_from_welcome(&self.provider, &join_config(), welcome, None)
                .map_err(|e| format!("staged welcome failed: {e:?}"))?;
        let group = staged_join
            .into_group(&self.provider)
            .map_err(|e| format!("join from welcome failed: {e:?}"))?;
        self.group = Some(group);
        Ok(())
    }

    /// Encrypts an application message for the current group epoch.
    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, String> {
        let group = self.group.as_mut().ok_or("not in a group")?;
        let msg = group
            .create_message(&self.provider, &self.signature_keys, plaintext)
            .map_err(|e| format!("create_message failed: {e:?}"))?;
        msg.tls_serialize_detached()
            .map_err(|e| format!("message serialize failed: {e:?}"))
    }

    /// Processes an incoming wire message: an application message returns
    /// `Some(plaintext)`; a Commit is merged in place and returns `None`.
    /// This is the single entry point a real client's message-receive loop
    /// would call for anything MLS-shaped (application data or handshake).
    pub fn process_incoming(&mut self, wire_bytes: &[u8]) -> Result<Option<Vec<u8>>, String> {
        let group = self.group.as_mut().ok_or("not in a group")?;
        let msg_in = MlsMessageIn::tls_deserialize_exact(wire_bytes)
            .map_err(|e| format!("message deserialize failed: {e:?}"))?;
        let protocol_message: ProtocolMessage = msg_in
            .try_into_protocol_message()
            .map_err(|e| format!("not a protocol message: {e:?}"))?;
        let processed = group
            .process_message(&self.provider, protocol_message)
            .map_err(|e| format!("process_message failed: {e:?}"))?;

        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(app_msg) => {
                Ok(Some(app_msg.into_bytes()))
            }
            ProcessedMessageContent::StagedCommitMessage(staged_commit) => {
                group
                    .merge_staged_commit(&self.provider, *staged_commit)
                    .map_err(|e| format!("merge_staged_commit failed: {e:?}"))?;
                Ok(None)
            }
            ProcessedMessageContent::ProposalMessage(_) => {
                Err("bare proposals not handled by this spike".into())
            }
            ProcessedMessageContent::ExternalJoinProposalMessage(_) => {
                Err("external join proposals not handled by this spike".into())
            }
            // Both variants only occur when processing a message this same
            // client authored itself (own pending commit / own ciphertext
            // echoed back) — doesn't happen in this spike's message flow.
            other => Err(format!("unhandled message content: {other:?}")),
        }
    }

    /// Exports the group state so it can be persisted (Drift/secure storage
    /// on the client) and later reloaded — see plan M0 "perzistence stavu
    /// skupiny". `openmls`'s storage provider already persists incrementally
    /// as operations happen; this method demonstrates the export/import
    /// round trip by re-loading the group from the (in-memory) storage
    /// keyed by group id, which is the same code path a disk-backed
    /// storage provider would use after a process restart.
    pub fn group_id(&self) -> Result<Vec<u8>, String> {
        Ok(self
            .group
            .as_ref()
            .ok_or("not in a group")?
            .group_id()
            .as_slice()
            .to_vec())
    }

    /// Drops the in-memory `MlsGroup` handle (simulating "app restarted")
    /// and reloads it from the provider's storage by group id.
    pub fn reload_group_from_storage(&mut self, group_id_bytes: &[u8]) -> Result<(), String> {
        let group_id = GroupId::from_slice(group_id_bytes);
        self.group = None;
        let group = MlsGroup::load(self.provider.storage(), &group_id)
            .map_err(|e| format!("group load failed: {e:?}"))?
            .ok_or("group not found in storage")?;
        self.group = Some(group);
        Ok(())
    }

    pub fn member_count(&self) -> Result<usize, String> {
        Ok(self.group.as_ref().ok_or("not in a group")?.members().count())
    }
}
