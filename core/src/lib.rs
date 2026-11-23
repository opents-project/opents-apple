use futures::StreamExt;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::oneshot;
use tsclientlib::prelude::*;
use tsclientlib::{Connection, DisconnectOptions, InMessage, StreamItem};

uniffi::setup_scaffolding!();

#[derive(Clone, uniffi::Record)]
pub struct Room {
    pub id: u64,
    pub parent: u64,
    pub predecessor: u64,
    pub name: String,
    pub codec: String,
    pub kind: String,
    pub members: Vec<String>,
    pub subscribed: bool,
}

#[derive(Clone, Default, uniffi::Record)]
pub struct Snapshot {
    pub server: String,
    pub rooms: Vec<Room>,
    pub error: Option<String>,
}

#[derive(uniffi::Object)]
pub struct Session {
    state: Arc<Mutex<Snapshot>>,
    stop: Mutex<Option<oneshot::Sender<()>>>,
}

#[uniffi::export]
impl Session {
    #[uniffi::constructor]
    pub fn new(address: String, nickname: String) -> Arc<Self> {
        let state = Arc::new(Mutex::new(Snapshot::default()));
        let worker = state.clone();
        let (stop, closed) = oneshot::channel();
        std::thread::spawn(move || {
            let result = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .map_err(|e| e.to_string())
                .and_then(|rt| rt.block_on(run(address, nickname, closed, &worker)));
            if let Err(error) = result {
                *worker.lock().unwrap() = Snapshot {
                    error: Some(error),
                    ..Default::default()
                };
            }
        });
        Arc::new(Self {
            state,
            stop: Mutex::new(Some(stop)),
        })
    }

    pub fn snapshot(&self) -> Snapshot {
        self.state.lock().unwrap().clone()
    }

    pub fn disconnect(&self) {
        if let Some(sender) = self.stop.lock().unwrap().take() {
            let _ = sender.send(());
        }
    }
}

async fn run(
    address: String,
    nickname: String,
    mut closed: oneshot::Receiver<()>,
    state: &Mutex<Snapshot>,
) -> Result<(), String> {
    let mut con = Connection::build(address)
        .name(nickname)
        .input_hardware_enabled(false)
        .output_hardware_enabled(false)
        .connect()
        .map_err(|e| e.to_string())?;
    let deadline = tokio::time::sleep(Duration::from_secs(35));
    tokio::pin!(deadline);
    let mut ready = false;
    loop {
        let event = tokio::select! {
            _ = &mut closed => break,
            _ = &mut deadline, if !ready => return Err("Server connection timed out".into()),
            event = async { con.events().next().await } => event,
        };
        match event
            .ok_or("Connection closed")?
            .map_err(|e| e.to_string())?
        {
            StreamItem::MessageEvent(InMessage::ChannelListFinished(_)) => {
                ready = true;
                let subscription = con
                    .get_state()
                    .map_err(|e| e.to_string())?
                    .server
                    .set_subscribed(true);
                subscription.send(&mut con).map_err(|e| e.to_string())?;
            }
            StreamItem::BookEvents(_) if ready => (),
            StreamItem::DisconnectedTemporarily(_) => return Err("Connection interrupted".into()),
            _ => continue,
        }
        let book = con.get_state().map_err(|e| e.to_string())?;
        let mut members = std::collections::HashMap::<_, Vec<String>>::new();
        for client in book.clients.values() {
            members
                .entry(client.channel)
                .or_default()
                .push(client.name.clone());
        }
        for names in members.values_mut() {
            names.sort();
        }
        let rooms = book
            .channels
            .values()
            .map(|room| Room {
                id: room.id.0,
                parent: room.parent.0,
                predecessor: room.order.0,
                name: room.name.clone(),
                codec: format!("{:?}", room.codec),
                kind: format!("{:?}", room.channel_type),
                members: members.remove(&room.id).unwrap_or_default(),
                subscribed: room.subscribed,
            })
            .collect();
        *state.lock().unwrap() = Snapshot {
            server: book.server.name.clone(),
            rooms,
            error: None,
        };
    }
    if con.get_state().is_ok() {
        con.disconnect(DisconnectOptions::new())
            .map_err(|e| e.to_string())?;
        let _ = tokio::time::timeout(Duration::from_secs(2), async {
            while con.events().next().await.is_some() {}
        })
        .await;
    }
    Ok(())
}
