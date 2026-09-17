//! Native timing measurement for the M0 report (section 4, "Měření").
//! Not a benchmark harness (no warmup/statistics) — a spike-grade single-shot
//! timing, run with `cargo run --release --example timing`.

use std::time::Instant;

use mls_core::MlsClient;

fn measure_group_of_size(n: usize) {
    let t0 = Instant::now();
    let mut creator = MlsClient::new_identity("creator").expect("creator identity");
    creator.create_group().expect("create group");
    let t_create = t0.elapsed();

    // Pre-generate n-1 other members' key packages (not timed — this is
    // the "someone else already published a KeyPackage" case).
    let mut members: Vec<MlsClient> = Vec::with_capacity(n - 1);
    for i in 0..n - 1 {
        members.push(MlsClient::new_identity(&format!("member{i}")).expect("member identity"));
    }
    let key_packages: Vec<_> = members
        .iter()
        .map(|m| m.create_key_package().expect("key package"))
        .collect();

    // add_member() one at a time mirrors how the plan's group creation
    // flow would work (each add is its own Commit); timing the full
    // "get to N members" cost, not a hypothetical single N-way add.
    let t1 = Instant::now();
    let mut welcomes = Vec::new();
    for kp in &key_packages {
        let (_commit, welcome) = creator.add_member(kp.key_package()).expect("add member");
        welcomes.push(welcome);
    }
    let t_add_all = t1.elapsed();
    let t_add_avg = t_add_all / (n as u32 - 1).max(1);

    for (member, welcome) in members.iter_mut().zip(welcomes.iter()) {
        member.join_from_welcome(welcome).expect("join from welcome");
        // NB: in this simplified timing harness each joiner only processes
        // its own Welcome, not the subsequent adds' Commits — good enough to
        // time create/add/encrypt/decrypt in isolation, not a full protocol
        // simulation (see scenario.rs for the correctness-focused version
        // that does track every member through every epoch).
    }

    let plaintext = b"quarterly numbers look good, this is a representative message payload";
    let t2 = Instant::now();
    let ciphertext = creator.encrypt(plaintext).expect("encrypt");
    let t_encrypt = t2.elapsed();

    // Decrypt with the most recently joined member (last one has the
    // freshest epoch state matching the ciphertext above).
    let last_member = members.last_mut().expect("at least one member");
    let t3 = Instant::now();
    let decrypted = last_member.process_incoming(&ciphertext).expect("decrypt");
    let t_decrypt = t3.elapsed();
    assert_eq!(decrypted.as_deref(), Some(plaintext.as_slice()));

    println!(
        "n={n:>4}  create={t_create:>10.2?}  add_avg={t_add_avg:>10.2?} (add_total={t_add_all:>10.2?})  encrypt={t_encrypt:>10.2?}  decrypt={t_decrypt:>10.2?}"
    );
}

fn main() {
    println!("MLS timing spike (native, release build, single-shot — no warmup/statistics)");
    for n in [3usize, 50, 250] {
        measure_group_of_size(n);
    }
}
