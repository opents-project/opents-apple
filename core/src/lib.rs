mod chat;
mod permissions;
pub use permissions::{
    EffectivePermission, GroupKind, ListedGroup, PermissionAssignment, PermissionOverview,
    PermissionSource,
};
mod voice;
pub use chat::{ChatLine, ChatScope};
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
pub use voice::{SpeakerMix, Voice};

uniffi::setup_scaffolding!();

#[derive(Clone, uniffi::Record)]
pub struct RoomMember {
    pub client_id: u16,
    pub database_id: u64,
    pub name: String,
    pub is_self: bool,
}

#[derive(Clone, uniffi::Record)]
pub struct Room {
    pub id: u64,
    pub parent: u64,
    pub predecessor: u64,
    pub name: String,
    pub codec: String,
    pub audio_supported: bool,
    pub kind: String,
    pub members: Vec<String>,
    pub member_details: Vec<RoomMember>,
    pub subscribed: bool,
    pub password_required: bool,
}

#[derive(Clone, Default, uniffi::Record)]
pub struct Snapshot {
    pub server: String,
    pub reconnecting: bool,
    pub audio_generation: u64,
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
    voice: Arc<Mutex<Arc<Voice>>>,
    inbox: Arc<Mutex<chat::Inbox>>,
    messages: mpsc::Sender<chat::SendRequest>,
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
        let voice = Arc::new(Mutex::new(io.voice.clone()));
        let current_voice = voice.clone();
        let inbox = Arc::new(Mutex::new(chat::Inbox::default()));
        let worker_inbox = inbox.clone();
        let (messages, chat_requests) = mpsc::channel(1);
        let (joins, requests) = mpsc::channel(1);
        let (stop, closed) = oneshot::channel();
        std::thread::spawn(move || {
            let result = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .map_err(|e| e.to_string())
                .and_then(|rt| {
                    rt.block_on(run(
                        address,
                        nickname,
                        identity,
                        closed,
                        requests,
                        chat_requests,
                        &worker_inbox,
                        io,
                        &current_voice,
                        &worker,
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
            inbox,
            messages,
            joins,
            stop: Mutex::new(Some(stop)),
        })
    }

    pub fn audio(&self) -> Arc<Voice> {
        self.voice.lock().unwrap().clone()
    }

    pub fn snapshot(&self) -> Snapshot {
        self.state.lock().unwrap().clone()
    }

    pub fn take_chat(&self) -> Vec<ChatLine> {
        self.inbox.lock().unwrap().drain()
    }

    pub async fn send_chat(
        &self,
        scope: ChatScope,
        text: String,
        generation: u64,
    ) -> Option<String> {
        if text.trim().is_empty() {
            return Some("Enter a message.".into());
        }
        let (reply, result) = oneshot::channel();
        if self
            .messages
            .try_send(chat::SendRequest {
                scope,
                text,
                generation,
                reply,
            })
            .is_err()
        {
            return Some("Unable to queue the message.".into());
        }
        result
            .await
            .unwrap_or_else(|_| Some("Connection closed".into()))
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

struct PendingJoin {
    handle: tsclientlib::MessageHandle,
    target: u64,
    accepted: bool,
    reply: oneshot::Sender<Option<JoinFailure>>,
}

impl PendingJoin {
    fn finish_with_error(pending: &mut Option<Self>, error: JoinFailure) {
        if let Some(join) = pending.take() {
            let _ = join.reply.send(Some(error));
        }
    }

    fn result(
        pending: &mut Option<Self>,
        handle: tsclientlib::MessageHandle,
        error: Option<JoinFailure>,
    ) {
        let Some(join) = pending.as_mut().filter(|join| join.handle == handle) else {
            return;
        };
        if let Some(error) = error {
            Self::finish_with_error(pending, error);
        } else {
            join.accepted = true;
        }
    }
}

fn supported_codec(codec: tsclientlib::Codec) -> Option<CodecType> {
    match codec {
        tsclientlib::Codec::OpusVoice => Some(CodecType::OpusVoice),
        tsclientlib::Codec::OpusMusic => Some(CodecType::OpusMusic),
        _ => None,
    }
}

// Command results and the own-client channel update can arrive in either order.
fn capture_channel(
    pending: &mut Option<PendingJoin>,
    current: Option<(u64, tsclientlib::Codec)>,
) -> Option<(u64, CodecType)> {
    if let Some(join) = pending {
        if !join.accepted || current.map(|c| c.0) != Some(join.target) {
            return None;
        }
        let _ = pending.take().unwrap().reply.send(None);
    }
    let (id, codec) = current?;
    Some((id, supported_codec(codec)?))
}

const CONNECTION_TIMEOUT: Duration = Duration::from_secs(35);

async fn stop_or_timeout(
    closed: &mut oneshot::Receiver<()>,
    deadline: std::pin::Pin<&mut tokio::time::Sleep>,
    ready: bool,
) -> Result<(), String> {
    tokio::select! {
        biased;
        _ = closed => Ok(()),
        _ = deadline, if !ready => Err("Server connection timed out".into()),
    }
}

async fn run(
    address: String,
    nickname: String,
    identity: String,
    mut closed: oneshot::Receiver<()>,
    mut requests: mpsc::Receiver<JoinRequest>,
    mut chat_requests: mpsc::Receiver<chat::SendRequest>,
    inbox: &Mutex<chat::Inbox>,
    mut io: voice::AudioIo,
    current_voice: &Mutex<Arc<Voice>>,
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
    let deadline = tokio::time::sleep(CONNECTION_TIMEOUT);
    tokio::pin!(deadline);
    let mut last_codec = None;
    let end_talk = tokio::time::sleep(Duration::ZERO);
    tokio::pin!(end_talk);
    let mut ready = false;
    let mut audio_generation = 0;
    let mut pending_chat: Option<(tsclientlib::MessageHandle, chat::SendRequest, String)> = None;
    let chat_deadline = tokio::time::sleep(Duration::ZERO);
    tokio::pin!(chat_deadline);
    let mut pending = None;
    let join_deadline = tokio::time::sleep(Duration::ZERO);
    tokio::pin!(join_deadline);
    loop {
        let current = if ready {
            let book = con.get_state().map_err(|e| e.to_string())?;
            book.clients
                .get(&book.own_client)
                .and_then(|me| book.channels.get(&me.channel))
                .map(|room| (room.id.0, room.codec))
        } else {
            None
        };
        if io.set_channel(capture_channel(&mut pending, current))? {
            last_codec = None;
        }
        let event = tokio::select! {
            stop = stop_or_timeout(&mut closed, deadline.as_mut(), ready) => { stop?; break; },
            frame = io.capture.recv(), if ready => {
                let Some(frame) = frame else { break };
                if !con.can_send_audio() { continue; }
                if let Some((codec, packet)) = io.packet(frame)? {
                    con.send_audio(packet).map_err(|e| e.to_string())?;
                    last_codec = Some(codec);
                    end_talk.as_mut().reset(tokio::time::Instant::now() + Duration::from_millis(65));
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
                PendingJoin::finish_with_error(&mut pending, "Channel change timed out".into());
                continue;
            }
            _ = &mut chat_deadline, if pending_chat.is_some() => {
                if let Some((_, request, _)) = pending_chat.take() {
                    let _ = request.reply.send(Some("The server did not confirm delivery.".into()));
                }
                continue;
            }
            request = chat_requests.recv(), if pending_chat.is_none() => {
                let Some(request) = request else { break };
                let sent = (|| {
                    if !ready || request.generation != audio_generation { return Err("Connection interrupted".into()); }
                    let book = con.get_state().map_err(|e| e.to_string())?;
                    let me = book.clients.get(&book.own_client).ok_or("Client is not ready")?;
                    let target = request.scope.target(Some(me.channel.0))?;
                    let sender = me.name.clone();
                    let handle = book.send_message(target, &request.text).send_with_result(&mut con).map_err(|e| e.to_string())?;
                    Ok((handle, sender))
                })();
                match sent {
                    Ok((handle,sender)) => {
                        pending_chat = Some((handle, request, sender));
                        chat_deadline.as_mut().reset(tokio::time::Instant::now() + Duration::from_secs(10));
                    }
                    Err(error) => { let _ = request.reply.send(Some(error)); }
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
                        pending = Some(PendingJoin { handle, target: request.channel, accepted: false, reply: request.reply });
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
                let from = match packet.data().data() {
                    AudioData::S2C { from, .. } | AudioData::S2CWhisper { from, .. } => *from,
                    _ => continue,
                };
                let db_id = con
                    .get_state()
                    .ok()
                    .and_then(|book| book.clients.get(&tsclientlib::ClientId(from)))
                    .map_or(0, |client| client.database_id.0);
                io.voice.receive(packet, db_id);
                continue;
            }
            StreamItem::MessageResult(handle, result)
                if pending.as_ref().is_some_and(|join| join.handle == handle) =>
            {
                let error = result.err().map(|e| match e.error {
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
                PendingJoin::result(&mut pending, handle, error);
            }
            StreamItem::MessageResult(handle, result)
                if pending_chat.as_ref().is_some_and(|p| p.0 == handle) =>
            {
                if let Some((_, request, sender)) = pending_chat.take() {
                    let failure = result.err().map(|e| match e.error {
                        tsclientlib::TsError::PermissionsClientInsufficient => {
                            "You lack permission to send this message.".into()
                        }
                        _ => e.to_string(),
                    });
                    inbox.lock().unwrap().finish(request, sender, failure);
                }
                continue;
            }
            StreamItem::BookEvents(events) if ready => {
                let book = con.get_state().map_err(|e| e.to_string())?;
                let current = book.clients.get(&book.own_client).map(|me| me.channel.0);
                inbox
                    .lock()
                    .unwrap()
                    .receive(events, book.own_client, current);
            }
            StreamItem::DisconnectedTemporarily(_) => {
                if ready {
                    deadline
                        .as_mut()
                        .reset(tokio::time::Instant::now() + CONNECTION_TIMEOUT);
                }
                ready = false;
                last_codec = None;
                PendingJoin::finish_with_error(&mut pending, "Connection interrupted".into());
                if let Some((_, request, _)) = pending_chat.take() {
                    let _ = request.reply.send(Some("Connection interrupted".into()));
                }
                io = replace_audio(&io, current_voice);
                audio_generation += 1;
                *state.lock().unwrap() = Snapshot {
                    reconnecting: true,
                    audio_generation,
                    ..Default::default()
                };
                continue;
            }
            _ => continue,
        }
        let book = con.get_state().map_err(|e| e.to_string())?;
        let mut members = std::collections::HashMap::<_, Vec<RoomMember>>::new();
        for client in book.clients.values() {
            members.entry(client.channel).or_default().push(RoomMember {
                client_id: client.id.0,
                database_id: client.database_id.0,
                name: client.name.clone(),
                is_self: client.id == book.own_client,
            });
        }
        for names in members.values_mut() {
            names.sort_by(|a, b| a.name.cmp(&b.name).then(a.client_id.cmp(&b.client_id)));
        }
        let rooms = book
            .channels
            .values()
            .map(|room| {
                let member_details = members.remove(&room.id).unwrap_or_default();
                Room {
                    id: room.id.0,
                    parent: room.parent.0,
                    predecessor: room.order.0,
                    name: room.name.clone(),
                    codec: format!("{:?}", room.codec),
                    audio_supported: supported_codec(room.codec).is_some(),
                    kind: format!("{:?}", room.channel_type),
                    members: member_details
                        .iter()
                        .map(|member| member.name.clone())
                        .collect(),
                    member_details,
                    subscribed: room.subscribed,
                    password_required: room.has_password.unwrap_or(false),
                }
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
            audio_generation,
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

fn replace_audio(previous: &voice::AudioIo, current: &Mutex<Arc<Voice>>) -> voice::AudioIo {
    previous.voice.set_devices(false, false, false, false);
    let next = Voice::pair();
    *current.lock().unwrap() = next.voice.clone();
    next
}

#[cfg(test)]
mod reconnect_tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn recovery_expires_but_manual_disconnect_stops_immediately() {
        let (cancel, mut closed) = oneshot::channel();
        let deadline = tokio::time::sleep(CONNECTION_TIMEOUT);
        tokio::pin!(deadline);
        tokio::time::advance(CONNECTION_TIMEOUT - Duration::from_secs(1)).await;
        assert!(futures::poll!(Box::pin(stop_or_timeout(
            &mut closed,
            deadline.as_mut(),
            false
        )))
        .is_pending());
        tokio::time::advance(Duration::from_secs(1)).await;
        assert!(stop_or_timeout(&mut closed, deadline.as_mut(), false)
            .await
            .is_err());
        assert!(futures::poll!(Box::pin(stop_or_timeout(
            &mut closed,
            deadline.as_mut(),
            true
        )))
        .is_pending());
        cancel.send(()).unwrap();
        assert!(stop_or_timeout(&mut closed, deadline.as_mut(), false)
            .await
            .is_ok());
    }

    #[test]
    fn old_microphone_cannot_send_on_reconnected_session() {
        let mut io = Voice::pair();
        let old = io.voice.clone();
        let current = Mutex::new(old.clone());
        io.set_channel(Some((1, CodecType::OpusVoice))).unwrap();
        old.set_devices(true, true, false, false);
        old.submit_capture(vec![0.25; voice::FRAME]);
        io = replace_audio(&io, &current);
        old.set_devices(true, true, false, false);
        old.submit_capture(vec![0.5; voice::FRAME]);
        io.set_channel(Some((1, CodecType::OpusVoice))).unwrap();
        let new = current.lock().unwrap().clone();
        new.submit_capture(vec![0.75; voice::FRAME]);
        assert!(io.capture.try_recv().is_err());
        new.set_devices(true, true, false, false);
        new.submit_capture(vec![1.0; voice::FRAME]);
        let frame = io.capture.try_recv().unwrap();
        assert!(io.packet(frame).unwrap().is_some());
    }
}

#[cfg(test)]
mod channel_audio_tests;
