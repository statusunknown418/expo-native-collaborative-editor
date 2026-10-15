macro_rules! reproduce {
    ($engine:ident, $version:literal) => {{
        use $engine::{ClientID, Doc, GetString, OffsetKind, Options, Text, Transact, Update};
        use $engine::updates::decoder::Decode;

        let document = |client_id| {
            Doc::with_options(Options {
                client_id: ClientID::new(client_id),
                offset_kind: OffsetKind::Utf16,
                ..Options::default()
            })
        };
        let source = document(1);
        let text = source.get_or_insert_text("text");
        // Transaction-local updates: no full-state snapshots or cumulative delete sets.
        let insert_abc = {
            let mut txn = source.transact_mut();
            text.insert(&mut txn, 0, "abc");
            txn.encode_update_v1()
        };
        let insert_def = {
            let mut txn = source.transact_mut();
            text.insert(&mut txn, 3, "def");
            txn.encode_update_v1()
        };
        let delete_bcd = {
            let mut txn = source.transact_mut();
            text.remove_range(&mut txn, 1, 3);
            txn.encode_update_v1()
        };
        assert_eq!(text.get_string(&source.transact()), "aef");
        let updates = [insert_abc, insert_def, delete_bcd];
        let mut passed = true;
        for (row, order) in [
            [0, 1, 2], [0, 2, 1], [1, 0, 2],
            [1, 2, 0], [2, 0, 1], [2, 1, 0],
        ].into_iter().enumerate() {
            let receiver = document(row as u64 + 2);
            let received_text = receiver.get_or_insert_text("text");
            // Replay duplicates after measuring initial delivery; later repair must not
            // hide an incorrect result after every unique update has arrived.
            for phase in ["delivery", "replay"] {
                for index in order {
                    let mut txn = receiver.transact_mut();
                    txn.apply_update(Update::decode_v1(&updates[index]).unwrap()).unwrap();
                }
                let actual = received_text.get_string(&receiver.transact());
                let ok = actual == "aef";
                println!(
                    "yrs={} order={}-{}-{} phase={} actual={:?} expected=\"aef\" {}",
                    $version, order[0] + 1, order[1] + 1, order[2] + 1,
                    phase, actual, if ok { "PASS" } else { "FAIL" },
                );
                passed &= ok;
            }
        }
        passed
    }};
}

fn main() -> std::process::ExitCode {
    let mut passed = reproduce!(yrs_bound, "0.27.0@git:ae61429251af410f82e85b8c6577cad585b3585a (SwiftYrs 0.7.0)");
    passed &= reproduce!(yrs_latest, "0.28.0 (latest crates.io release)");
    if passed { std::process::ExitCode::SUCCESS } else { std::process::ExitCode::FAILURE }
}
