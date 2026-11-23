mod voice;
use futures::StreamExt;
use tsclientlib::Identity;

/// The returned private identity belongs only in the platform credential store.
#[uniffi::export]
pub fn generate_identity() -> String {
    let id = Identity::create();
    format!("{}V{}", id.counter(), id.key().to_ts())
}
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use tsclientlib::prelude::*;
use tsclientlib::{Connection, DisconnectOptions, InMessage, StreamItem};
use tsproto_packets::packets::{AudioData, CodecType, OutAudio};
pub use voice::Voice;

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
    pub password_required: bool,
}

#[derive(Clone, Default, uniffi::Record)]
pub struct Snapshot {
    pub server: String,
    pub reconnecting: bool,
    pub rooms: Vec<Room>,
    pub current_channel: Option<u64>,
    pub peer_ids: Vec<u16>,
    pub identity_uid: String,
    pub error: Option<String>,
}

#[derive(uniffi::Enum)]
pub enum JoinFailure {
    PermissionDenied { permission: Option<u32> },
    ServerRejected { code: u32, reason: String },
    Other { message: String },
}

impl From<&str> for JoinFailure {
    fn from(message: &str) -> Self {
        Self::Other {
            message: message.into(),
        }
    }
}

struct JoinRequest {
    channel: u64,
    password: String,
    reply: oneshot::Sender<Option<JoinFailure>>,
}

#[derive(uniffi::Object)]
pub struct Session {
    state: Arc<Mutex<Snapshot>>,
    voice: Arc<Voice>,
    joins: mpsc::Sender<JoinRequest>,
    stop: Mutex<Option<oneshot::Sender<()>>>,
}

#[uniffi::export]
impl Session {
    #[uniffi::constructor]
    pub fn new(address: String, nickname: String, identity: String) -> Arc<Self> {
        let state = Arc::new(Mutex::new(Snapshot::default()));
        let worker = state.clone();
        let io = Voice::pair();
        let voice = io.voice.clone();
        let (joins, requests) = mpsc::channel(1);
        let (stop, closed) = oneshot::channel();
        std::thread::spawn(move || {
            let result = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .map_err(|e| e.to_string())
                .and_then(|rt| {
                    rt.block_on(run(
                        address, nickname, identity, closed, requests, io, &worker,
                    ))
                });
            if let Err(error) = result {
                *worker.lock().unwrap() = Snapshot {
                    error: Some(error),
                    ..Default::default()
                };
            }
        });
        Arc::new(Self {
            state,
            voice,
            joins,
            stop: Mutex::new(Some(stop)),
        })
    }

    pub fn audio(&self) -> Arc<Voice> {
        self.voice.clone()
    }

    pub fn snapshot(&self) -> Snapshot {
        self.state.lock().unwrap().clone()
    }

    pub async fn join_channel(&self, channel: u64, password: String) -> Option<JoinFailure> {
        let (reply, result) = oneshot::channel();
        if self
            .joins
            .send(JoinRequest {
                channel,
                password,
                reply,
            })
            .await
            .is_err()
        {
            return Some("Connection closed".into());
        }
        result
            .await
            .unwrap_or_else(|_| Some("Connection closed".into()))
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
    identity: String,
    mut closed: oneshot::Receiver<()>,
    mut requests: mpsc::Receiver<JoinRequest>,
    mut io: voice::AudioIo,
    state: &Mutex<Snapshot>,
) -> Result<(), String> {
    let identity = Identity::new_from_ts_str(&identity)
        .map_err(|_| "Saved OpenTS identity is invalid".to_string())?;
    let identity_uid = identity.key().to_pub().get_uid();
    let mut con = Connection::build(address)
        .identity(identity)
        .name(nickname)
        .input_hardware_enabled(false)
        .output_hardware_enabled(false)
        .connect()
        .map_err(|e| e.to_string())?;
    let deadline = tokio::time::sleep(Duration::from_secs(35));
    tokio::pin!(deadline);
    let encoder = voice::encoder()?;
    let mut last_codec = None;
    let end_talk = tokio::time::sleep(Duration::ZERO);
    tokio::pin!(end_talk);
    let mut ready = false;
    let mut pending = None;
    let join_deadline = tokio::time::sleep(Duration::ZERO);
    tokio::pin!(join_deadline);
    loop {
        let event = tokio::select! {
            _ = &mut closed => break,
            _ = &mut deadline, if !ready => return Err("Server connection timed out".into()),
            frame = io.capture.recv(), if ready => {
                if let Some(samples) = frame {
                    if con.can_send_audio() && io.enabled.borrow().can_capture() {
                        let book = con.get_state().map_err(|e| e.to_string())?;
                        let codec = book.clients.get(&book.own_client).and_then(|c| book.channels.get(&c.channel)).map(|c| c.codec);
                        let codec = match codec {
                            Some(tsclientlib::Codec::OpusVoice) => CodecType::OpusVoice,
                            Some(tsclientlib::Codec::OpusMusic) => CodecType::OpusMusic,
                            _ => continue,
                        };
                        con.send_audio(voice::encode(&encoder, &samples, codec)?).map_err(|e| e.to_string())?;
                        last_codec = Some(codec);
                        end_talk.as_mut().reset(tokio::time::Instant::now() + Duration::from_millis(65));
                    }
                }
                continue;
            }
            _ = &mut end_talk, if last_codec.is_some() => {
                if let Some(codec) = last_codec.take() {
                    con.send_audio(OutAudio::new(&AudioData::C2S { id: 0, codec, data: &[] })).map_err(|e| e.to_string())?;
                }
                continue;
            }
            Ok(()) = io.enabled.changed(), if ready => {
                let devices = *io.enabled.borrow_and_update();
                let cmd = con.get_state().map_err(|e| e.to_string())?.client_update()
                    .set_input_hardware_enabled(devices.microphone).set_output_hardware_enabled(devices.output)
                    .set_input_muted(devices.mic_muted).set_output_muted(devices.output_muted);
                cmd.send(&mut con).map_err(|e| e.to_string())?;
                continue;
            }
            _ = &mut join_deadline, if pending.is_some() => {
                if let Some((_, reply)) = pending.take() {
                    let reply: oneshot::Sender<Option<JoinFailure>> = reply;
                    let _ = reply.send(Some("Channel change timed out".into()));
                }
                continue;
            }
            request = requests.recv(), if pending.is_none() => {
                let Some(request) = request else { break };
                let sent = con.get_state().map_err(|e| e.to_string()).and_then(|book| {
                    let me = book.clients.get(&book.own_client).ok_or("Client is not ready")?;
                    let cmd = me.client_move(tsclientlib::ChannelId(request.channel));
                    Ok(if request.password.is_empty() { cmd } else { cmd.set_password(&request.password) })
                }).and_then(|cmd| cmd.send_with_result(&mut con).map_err(|e| e.to_string()));
                match sent {
                    Ok(handle) => {
                        pending = Some((handle, request.reply));
                        join_deadline.as_mut().reset(tokio::time::Instant::now() + Duration::from_secs(10));
                    }
                    Err(error) => { let _ = request.reply.send(Some(JoinFailure::Other { message: error })); }
                }
                continue;
            }
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
            StreamItem::Audio(packet) => {
                io.voice.receive(packet);
                continue;
            }
            StreamItem::MessageResult(handle, result)
                if pending
                    .as_ref()
                    .is_some_and(|(expected, _)| *expected == handle) =>
            {
                if let Some((_, reply)) = pending.take() {
                    let reason = result.err().map(|e| match e.error {
                        tsclientlib::TsError::PermissionsClientInsufficient => {
                            JoinFailure::PermissionDenied {
                                permission: e.missing_permission.map(|p| p.0),
                            }
                        }
                        other => JoinFailure::ServerRejected {
                            code: other as u32,
                            reason: other.to_string(),
                        },
                    });
                    let _ = reply.send(reason);
                }
            }
            StreamItem::BookEvents(_) if ready => (),
            StreamItem::DisconnectedTemporarily(_) => {
                ready = false;
                last_codec = None;
                if let Some((_, reply)) = pending.take() {
                    let _ = reply.send(Some("Connection interrupted".into()));
                }
                io.voice.set_devices(false, false, false, false);
                while io.capture.try_recv().is_ok() {}
                *state.lock().unwrap() = Snapshot {
                    reconnecting: true,
                    ..Default::default()
                };
                deadline
                    .as_mut()
                    .reset(tokio::time::Instant::now() + Duration::from_secs(35));
                continue;
            }
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
                password_required: room.has_password.unwrap_or(false),
            })
            .collect();
        let current_channel = book.clients.get(&book.own_client).map(|me| me.channel);
        let mut peer_ids: Vec<_> = book
            .clients
            .values()
            .filter(|client| {
                client.id != book.own_client && Some(client.channel) == current_channel
            })
            .map(|client| client.id.0)
            .collect();
        peer_ids.sort_unstable();
        *state.lock().unwrap() = Snapshot {
            server: book.server.name.clone(),
            identity_uid: identity_uid.clone(),
            reconnecting: false,
            rooms,
            current_channel: current_channel.map(|channel| channel.0),
            peer_ids,
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
