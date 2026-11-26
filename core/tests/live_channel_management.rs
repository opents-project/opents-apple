// Run explicitly against a server where disposable temporary channels are allowed.
use opents_core::{
    generate_identity, ChannelChange, ChannelLifetime, ManagedCodec, Session, Snapshot,
};
use std::{io::Read, time::Duration};

async fn wait_for(session: &Session, matches: impl Fn(&Snapshot) -> bool) -> Snapshot {
    tokio::time::timeout(Duration::from_secs(45), async {
        loop {
            let snapshot = session.snapshot();
            assert!(snapshot.error.is_none(), "{:?}", snapshot.error);
            if matches(&snapshot) {
                return snapshot;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .expect("server state transition timed out")
}

async fn verify_description(session: &Session, channel: u64, expected: &str) {
    assert_eq!(
        session
            .change_channel(
                ChannelChange::ReadDescription { channel },
                session.snapshot().audio_generation,
            )
            .await,
        None
    );
    wait_for(session, |snapshot| {
        snapshot
            .rooms
            .iter()
            .any(|room| room.id == channel && room.description.as_deref() == Some(expected))
    })
    .await;
}

#[tokio::test]
#[ignore = "creates an isolated temporary channel on OPENTS_TEST_SERVER"]
async fn create_edit_and_verify_password() {
    let address = std::env::var("OPENTS_TEST_SERVER").expect("specify authorized test server");
    let owner = Session::new(
        address.clone(),
        "OpenTS Channel QA".into(),
        generate_identity(),
    );
    let peer = Session::new(address, "OpenTS Join QA".into(), generate_identity());
    let original = wait_for(&owner, |s| s.current_channel.is_some()).await;
    wait_for(&peer, |s| s.current_channel.is_some()).await;
    let mut random = [0u8; 16];
    std::fs::File::open("/dev/urandom")
        .unwrap()
        .read_exact(&mut random)
        .unwrap();
    let name = format!(
        "OpenTS-QA-{:02x}{:02x}{:02x}{:02x}",
        random[0], random[1], random[2], random[3]
    );
    let password: String = random[4..]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    let set_password_on_edit = std::env::var_os("OPENTS_SET_PASSWORD_ON_EDIT").is_some();
    let failure = owner
        .change_channel(
            ChannelChange::Create {
                parent: 0,
                name: name.clone(),
                lifetime: ChannelLifetime::Temporary,
                codec: None,
                description: "Initial description".into(),
                password: if set_password_on_edit {
                    String::new()
                } else {
                    password.clone()
                },
            },
            original.audio_generation,
        )
        .await;
    assert_eq!(failure, None, "create rejected");
    let snapshot = wait_for(&owner, |s| {
        s.rooms.iter().any(|r| {
            r.name == name
                && r.password_required != set_password_on_edit
                && Some(r.id) == s.current_channel
        })
    })
    .await;
    let id = snapshot.current_channel.unwrap();
    verify_description(&peer, id, "Initial description").await;
    let edited = format!("{name}-edited");
    let failure = owner
        .change_channel(
            ChannelChange::Edit {
                channel: id,
                name: Some(edited.clone()),
                lifetime: None,
                codec: Some(ManagedCodec::Music),
                description: Some("喵喵\nSecond line".into()),
                password: set_password_on_edit.then(|| password.clone()),
            },
            snapshot.audio_generation,
        )
        .await;
    assert_eq!(failure, None, "edit rejected");
    wait_for(&peer, |s| {
        s.rooms.iter().any(|r| {
            r.id == id && r.name == edited && r.password_required && r.codec == "OpusMusic"
        })
    })
    .await;
    verify_description(&peer, id, "喵喵\nSecond line").await;
    assert_eq!(
        owner
            .change_channel(
                ChannelChange::Edit {
                    channel: id,
                    name: None,
                    lifetime: None,
                    codec: None,
                    password: None,
                    description: Some(String::new()),
                },
                owner.snapshot().audio_generation,
            )
            .await,
        None
    );
    verify_description(&peer, id, "").await;
    assert!(peer.join_channel(id, "incorrect".into()).await.is_some());
    assert!(peer.join_channel(id, password).await.is_none());
    peer.disconnect();
    owner.disconnect();
    eprintln!("Created and edited temporary channel {id}; independent client verified codec, descriptions, password rejection and successful join.");
}
