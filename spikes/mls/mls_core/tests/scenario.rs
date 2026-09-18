//! Integration test for the M0 spike scenario (business-mode plan, section
//! 6): A creates a group, adds B and Auditor as an ordinary third member,
//! A sends an application message, B and Auditor both decrypt the SAME
//! ciphertext to the same plaintext (closes KB2's known gap — see plan),
//! B replies, A removes B, B can no longer decrypt a new message, and group
//! state survives an export/import (simulated process restart).

use mls_core::MlsClient;

#[test]
fn business_group_scenario() {
    let mut alice = MlsClient::new_identity("Alice").expect("alice identity");
    let mut bob = MlsClient::new_identity("Bob").expect("bob identity");
    let mut auditor = MlsClient::new_identity("Auditor").expect("auditor identity");

    let bob_kp = bob.create_key_package().expect("bob key package");
    let auditor_kp = auditor.create_key_package().expect("auditor key package");

    alice.create_group().expect("alice creates group");

    // Alice adds Bob and Auditor as two ordinary members of the same group.
    // Two adds each produce their own Commit+Welcome; Bob only needs to
    // process the second Commit (he's not in the group yet for the first).
    let (commit1, welcome_bob) = alice
        .add_member(bob_kp.key_package())
        .expect("alice adds bob");
    let (commit2, welcome_auditor) = alice
        .add_member(auditor_kp.key_package())
        .expect("alice adds auditor");

    bob.join_from_welcome(&welcome_bob)
        .expect("bob joins from welcome (pre-auditor epoch)");
    // Bob must catch up to the epoch where Auditor was added.
    bob.process_incoming(&commit2)
        .expect("bob processes add-auditor commit");
    auditor
        .join_from_welcome(&welcome_auditor)
        .expect("auditor joins from welcome");

    assert_eq!(alice.member_count().unwrap(), 3);
    assert_eq!(bob.member_count().unwrap(), 3);
    assert_eq!(auditor.member_count().unwrap(), 3);
    // commit1 is unused past this point but proves the two-step add works.
    let _ = commit1;

    // === KB2 closure: Alice sends one ciphertext, both Bob and Auditor
    // decrypt it to the identical plaintext. Unlike today's per-recipient
    // fan-out (KB2's known limitation), there is only one ciphertext here —
    // there is no "different content to the auditor" attack surface.
    let ciphertext = alice.encrypt(b"quarterly numbers look good").expect("alice encrypts");

    let bob_plaintext = bob
        .process_incoming(&ciphertext)
        .expect("bob decrypts")
        .expect("expected application message");
    let auditor_plaintext = auditor
        .process_incoming(&ciphertext)
        .expect("auditor decrypts")
        .expect("expected application message");

    assert_eq!(bob_plaintext, b"quarterly numbers look good");
    assert_eq!(auditor_plaintext, b"quarterly numbers look good");
    assert_eq!(bob_plaintext, auditor_plaintext, "auditor and member must see the same content");

    // === Bob replies; Alice and Auditor both decrypt it.
    let reply = bob.encrypt(b"thanks, filing it").expect("bob encrypts reply");
    let alice_saw_reply = alice
        .process_incoming(&reply)
        .expect("alice decrypts reply")
        .expect("expected application message");
    let auditor_saw_reply = auditor
        .process_incoming(&reply)
        .expect("auditor decrypts reply")
        .expect("expected application message");
    assert_eq!(alice_saw_reply, b"thanks, filing it");
    assert_eq!(auditor_saw_reply, b"thanks, filing it");

    // === Alice removes Bob.
    let bob_leaf_index = alice.find_member_leaf_index("Bob").expect("find bob");
    let remove_commit = alice.remove_member(bob_leaf_index).expect("alice removes bob");

    // Auditor processes the removal commit to stay in sync.
    auditor
        .process_incoming(&remove_commit)
        .expect("auditor processes remove commit");
    assert_eq!(alice.member_count().unwrap(), 2);
    assert_eq!(auditor.member_count().unwrap(), 2);

    // Bob is forward-secrecy-locked out: he never processes the remove
    // commit (he's no longer meant to receive group traffic), so his group
    // state is now stale. A subsequent Alice message uses a new epoch key
    // Bob never had — simulate that by having Bob try to process a message
    // encrypted in the new epoch and confirming it fails.
    let post_removal_ciphertext = alice
        .encrypt(b"bob should not see this")
        .expect("alice encrypts post-removal message");
    let bob_result = bob.process_incoming(&post_removal_ciphertext);
    assert!(
        bob_result.is_err(),
        "removed member must not be able to decrypt new-epoch messages, got: {bob_result:?}"
    );

    // === Persistence: export (group id) / import (reload from storage),
    // simulating a client process restart. Auditor's provider storage
    // already holds the up-to-date group state after every operation
    // above; reloading by group id must reproduce a group with the same
    // membership and epoch secrets (checked via decrypting a fresh message).
    let group_id = auditor.group_id().expect("auditor group id");
    auditor
        .reload_group_from_storage(&group_id)
        .expect("auditor reloads group from storage");
    assert_eq!(auditor.member_count().unwrap(), 2, "membership survives reload");

    let post_reload_ciphertext = alice
        .encrypt(b"after auditor reload")
        .expect("alice encrypts after reload");
    let auditor_after_reload = auditor
        .process_incoming(&post_reload_ciphertext)
        .expect("auditor decrypts after reload")
        .expect("expected application message");
    assert_eq!(auditor_after_reload, b"after auditor reload");
}
