mod app_metadata;
mod channel_management;
mod chat;
pub use channel_management::{ChannelChange, ChannelLifetime, ManagedCodec};
mod files;
pub use files::{ChannelFileJob, ChannelFileResult, RemoteChannelFile};
mod identity;
pub use identity::{parse_identity_export, stored_identity_uid, ImportedIdentity};
mod group_management;
pub use group_management::{
    GroupPermission, GroupPermissionResponse, PermissionDefinition, ServerGroupMember,
};
mod member_quality;
mod permissions;
pub use permissions::{
    EffectivePermission, GroupKind, ListedGroup, PermissionAssignment, PermissionOverview,
    PermissionSource,
};
mod receive_audio;
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
use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot, watch};
use tsclientlib::prelude::*;
use tsclientlib::{Connection, DisconnectOptions, InMessage, StreamItem};
use tsproto_packets::packets::{AudioData, CodecType, OutAudio};
pub use voice::{ConnectionQuality, SpeakerMix, Voice, VoiceDiagnostics};

uniffi::setup_scaffolding!();

#[derive(Clone, uniffi::Record)]
pub struct RoomMember {
    pub client_id: u16,
    pub database_id: u64,
    pub name: String,
    pub is_self: bool,
    pub uid: Option<String>,
    pub away_message: Option<String>,
    pub server_groups: Vec<ListedGroup>,
    pub channel_group: Option<ListedGroup>,
    pub client_version: Option<String>,
    pub opents_version: Option<String>,
    pub client_platform: Option<String>,
    pub connected_seconds: Option<u64>,
    pub inherited_channel_group_from: Option<u64>,
    pub microphone_enabled: bool,
    pub microphone_muted: bool,
    pub output_enabled: bool,
    pub output_muted: bool,
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
    pub description: Option<String>,
}

#[derive(Clone, Default, uniffi::Record)]
pub struct Snapshot {
    pub server: String,
    pub server_key: Option<String>,
    pub reconnecting: bool,
    pub audio_generation: u64,
    pub rooms: Vec<Room>,
    pub channel_groups: Vec<ListedGroup>,
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

#[derive(Clone, Copy)]
struct MemberDetailsRequest {
    client_id: u16,
    database_id: u64,
    generation: u64,
}

impl MemberDetailsRequest {
    fn send(self, con: &mut Connection) {
        let Ok(book) = con.get_state() else { return };
        let Some(client) = book
            .clients
            .get(&tsclientlib::ClientId(self.client_id))
            .filter(|c| c.database_id.0 == self.database_id)
        else {
            return;
        };
        let variables = client.variables();
        let connection_info = client.connection_info();
        // The book records whichever details the server makes available.
        let _ = variables.send(con);
        let _ = connection_info.send(con);
    }
}

#[derive(uniffi::Object)]
pub struct Session {
    state: Arc<Mutex<Snapshot>>,
    voice: Arc<Mutex<Arc<Voice>>>,
    inbox: Arc<Mutex<chat::Inbox>>,
    messages: mpsc::Sender<chat::SendRequest>,
    group_requests: mpsc::Sender<group_management::Request>,
    member_details: watch::Sender<Option<MemberDetailsRequest>>,
    file_requests: mpsc::Sender<files::Request>,
    joins: mpsc::Sender<JoinRequest>,
    channel_changes: mpsc::Sender<channel_management::Request>,
    stop: Mutex<Option<oneshot::Sender<()>>>,
}

#[uniffi::export]
impl Session {
    #[uniffi::constructor]
    pub fn new(
        address: String,
        nickname: String,
        identity: String,
        app_version: Option<String>,
    ) -> Arc<Self> {
        let state = Arc::new(Mutex::new(Snapshot::default()));
        let worker = state.clone();
        let io = Voice::pair();
        let voice = Arc::new(Mutex::new(io.voice.clone()));
        let current_voice = voice.clone();
        let inbox = Arc::new(Mutex::new(chat::Inbox::default()));
        let worker_inbox = inbox.clone();
        let (messages, chat_requests) = mpsc::channel(1);
        let (channel_changes, changes) = mpsc::channel(1);
        let (group_requests, group_receiver) = mpsc::channel(1);
        let (member_details, member_details_rx) = watch::channel(None);
        let (file_requests, file_rx) = mpsc::channel(4);
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
                        app_version,
                        closed,
                        requests,
                        changes,
                        chat_requests,
                        group_receiver,
                        member_details_rx,
                        file_rx,
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
            group_requests,
            member_details,
            file_requests,
            joins,
            channel_changes,
            stop: Mutex::new(Some(stop)),
        })
    }

    pub fn channel_file_job(&self, channel: u64, password: String) -> Arc<ChannelFileJob> {
        files::job(
            channel,
            password,
            self.state.lock().unwrap().audio_generation,
            self.file_requests.clone(),
        )
    }

    pub fn audio(&self) -> Arc<Voice> {
        self.voice.lock().unwrap().clone()
    }

    pub fn snapshot(&self) -> Snapshot {
        self.state.lock().unwrap().clone()
    }

    pub fn request_member_details(&self, client_id: u16, database_id: u64, generation: u64) {
        if client_id != 0 && database_id != 0 {
            // Keep the newest selection if several arrive before the worker can send.
            self.member_details.send_replace(Some(MemberDetailsRequest {
                client_id,
                database_id,
                generation,
            }));
        }
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

    pub async fn change_channel(&self, change: ChannelChange, generation: u64) -> Option<String> {
        let (reply, result) = oneshot::channel();
        if self
            .channel_changes
            .try_send(channel_management::Request {
                change,
                generation,
                reply,
            })
            .is_err()
        {
            return Some("Unable to queue the channel change.".into());
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
    app_version: Option<String>,
    mut closed: oneshot::Receiver<()>,
    mut requests: mpsc::Receiver<JoinRequest>,
    mut changes: mpsc::Receiver<channel_management::Request>,
    mut chat_requests: mpsc::Receiver<chat::SendRequest>,
    mut group_receiver: mpsc::Receiver<group_management::Request>,
    mut member_details_rx: watch::Receiver<Option<MemberDetailsRequest>>,
    mut file_rx: mpsc::Receiver<files::Request>,
    inbox: &Mutex<chat::Inbox>,
    mut io: voice::AudioIo,
    current_voice: &Mutex<Arc<Voice>>,
    state: &Mutex<Snapshot>,
) -> Result<(), String> {
    let identity = identity::read_stored(&identity)
        .ok_or_else(|| "Saved OpenTS identity is invalid".to_string())?;
    let identity_uid = identity.key().to_pub().get_uid();
    let options = Connection::build(address)
        .identity(identity)
        .name(nickname)
        .input_hardware_enabled(false)
        .output_hardware_enabled(false);
    // Keep the signed TS3 compatibility version and report the actual Apple platform.
    #[cfg(target_os = "macos")]
    let options = options.version(tsproto_types::versions::Version::OS_X_3_X_X);
    #[cfg(target_os = "ios")]
    let options = options.version(tsproto_types::versions::Version::iOS_3_X_X);
    let mut con = options.connect().map_err(|e| e.to_string())?;
    let deadline = tokio::time::sleep(CONNECTION_TIMEOUT);
    tokio::pin!(deadline);
    let mut files = files::Worker::default();
    let mut last_codec = None;
    let end_talk = tokio::time::sleep(Duration::ZERO);
    tokio::pin!(end_talk);
    let mut ready = false;
    let mut server_key = None;
    let mut audio_generation = 0;
    let mut pending_group: Option<group_management::Pending> = None;
    let mut deleted_channel_groups = HashSet::new();
    let group_deadline = tokio::time::sleep(Duration::ZERO);
    tokio::pin!(group_deadline);
    let mut pending_chat: Option<(tsclientlib::MessageHandle, chat::SendRequest, String)> = None;
    let chat_deadline = tokio::time::sleep(Duration::ZERO);
    tokio::pin!(chat_deadline);
    let mut editing: Option<(tsclientlib::MessageHandle, oneshot::Sender<Option<String>>)> = None;
    let edit_deadline = tokio::time::sleep(Duration::ZERO);
    tokio::pin!(edit_deadline);
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
                    io.voice.audio_sent();
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
            _ = &mut group_deadline, if pending_group.as_ref().is_some_and(|p| p.waiting()) => {
                if let Some(p) = &mut pending_group { p.fail("Permission request timed out"); }
                continue;
            }
            request = group_receiver.recv() => {
                let Some(request) = request else { break };
                let idle = pending_group.is_none();
                group_management::Pending::start(request, &mut con, ready, audio_generation, &mut pending_group);
                if idle {
                    group_deadline.as_mut().reset(tokio::time::Instant::now() + Duration::from_secs(10));
                }
                continue;
            }
            Ok(()) = member_details_rx.changed() => {
                let request = *member_details_rx.borrow_and_update();
                if let Some(request) = request.filter(|r| ready && r.generation == audio_generation) {
                    request.send(&mut con);
                }
                continue;
            }
            request = chat_requests.recv(), if pending_chat.is_none() => {
                let Some(request) = request else { break };
                let sent = (|| {
                    if !ready || request.generation != audio_generation { return Err("Connection interrupted".into()); }
                    let book = con.get_state().map_err(|e| e.to_string())?;
                    let me = book.clients.get(&book.own_client).ok_or("Client is not ready")?;
                    let uid = match &request.scope {
                        ChatScope::Direct { client_id, .. } => book.clients.get(&tsclientlib::ClientId(*client_id))
                            .and_then(|client| client.uid.as_ref()).map(|uid| uid.to_string()),
                        _ => None,
                    };
                    let target = request.scope.target(Some(me.channel.0), uid.as_deref())?;
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
            _ = &mut edit_deadline, if editing.is_some() => {
                if let Some((_, reply)) = editing.take() {
                    let _ = reply.send(Some("No confirmation. Check the channel list before retrying.".into()));
                }
                continue;
            }
            request = changes.recv(), if editing.is_none() => {
                let Some(request) = request else { break };
                if !ready || request.generation != audio_generation {
                    let _ = request.reply.send(Some("Connection interrupted".into()));
                    continue;
                }
                match request.change.send(&mut con) {
                    Ok(handle) => {
                        editing = Some((handle, request.reply));
                        edit_deadline.as_mut().reset(tokio::time::Instant::now() + Duration::from_secs(10));
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
            Some(request) = file_rx.recv() => {
                files.start(request, &mut con, ready, audio_generation);
                continue;
            }
            _ = files.poll() => continue,
            event = async { con.events().next().await } => event,
        };
        let event = event
            .ok_or("Connection closed")?
            .map_err(|e| e.to_string())?;
        let Some(event) = files.observe(event) else {
            continue;
        };
        match event {
            StreamItem::MessageEvent(InMessage::ChannelListFinished(_)) => {
                if !ready {
                    if let Some(command) =
                        app_version.as_deref().and_then(app_metadata::announcement)
                    {
                        let _ = command.send(&mut con);
                    }
                }
                ready = true;
                let server = &con.get_state().map_err(|e| e.to_string())?.server;
                // The handshake key and virtual server ID are independent of its address and name.
                server_key = Some(format!("ts3:{}:{}", server.public_key.get_uid(), server.id));
                let subscription = server.set_subscribed(true);
                subscription.send(&mut con).map_err(|e| e.to_string())?;
            }
            StreamItem::MessageEvent(
                message @ (InMessage::ServerGroupPermList(_)
                | InMessage::ChannelGroupPermList(_)
                | InMessage::ServerGroupClientList(_)
                | InMessage::PermList(_)),
            ) => {
                if let Some(p) = &mut pending_group {
                    p.observe(&message);
                }
                continue;
            }
            StreamItem::MessageResult(handle, result)
                if pending_group.as_ref().is_some_and(|p| p.handle == handle) =>
            {
                if let Some(p) = pending_group.take() {
                    if let Some(group) = p.confirmed_channel_deletion(&result) {
                        deleted_channel_groups.insert(group);
                        state.lock().unwrap().channel_groups.retain(|entry| entry.id != group);
                    }
                    p.finish(&con, result);
                }
                continue;
            }
            StreamItem::NetworkStatsUpdated => {
                if let Ok(stats) = con.get_network_stats() {
                    io.voice.update_quality(stats);
                    io.voice
                        .member_quality
                        .lock()
                        .unwrap()
                        .poll(&mut con, std::time::Instant::now());
                }
                continue;
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
            StreamItem::MessageResult(handle, result)
                if editing.as_ref().is_some_and(|e| e.0 == handle) =>
            {
                if let Some((_, reply)) = editing.take() {
                    let failure = result.err().map(|error| match error.missing_permission {
                        Some(permission) => {
                            format!("{} (permission {})", error.error, permission.0)
                        }
                        None => error.to_string(),
                    });
                    let _ = reply.send(failure);
                }
                continue;
            }
            StreamItem::MessageResult(handle, result) => {
                io.voice.member_quality.lock().unwrap().reply(
                    handle,
                    result.is_err(),
                    std::time::Instant::now(),
                );
                continue;
            }
            StreamItem::BookEvents(events) if ready => {
                if let Some(p) = &mut pending_group {
                    p.observe_book_events(&events);
                }
                io.voice.member_quality.lock().unwrap().observe(
                    &con,
                    &events,
                    std::time::Instant::now(),
                );
                let book = con.get_state().map_err(|e| e.to_string())?;
                let current = book.clients.get(&book.own_client).map(|me| me.channel.0);
                inbox.lock().unwrap().receive(events, book.own_client, current, |id| {
                    book.clients.get(&id)
                        .and_then(|client| client.uid.as_ref())
                        .map(|uid| uid.to_string())
                });
            }
            StreamItem::DisconnectedTemporarily(_) => {
                files.disconnected();
                if ready {
                    deadline
                        .as_mut()
                        .reset(tokio::time::Instant::now() + CONNECTION_TIMEOUT);
                }
                if let Some((_, reply)) = editing.take() {
                    let _ = reply.send(Some("Connection interrupted".into()));
                }
                if let Some(mut p) = pending_group.take() {
                    p.fail("Connection interrupted");
                }
                deleted_channel_groups.clear();
                ready = false;
                last_codec = None;
                PendingJoin::finish_with_error(&mut pending, "Connection interrupted".into());
                if let Some((_, request, _)) = pending_chat.take() {
                    let _ = request.reply.send(Some("Connection interrupted".into()));
                }
                io = replace_audio(&io, current_voice);
                audio_generation += 1;
                *state.lock().unwrap() = Snapshot {
                    server_key: server_key.clone(),
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
            let mut server_groups: Vec<_> = client
                .server_groups
                .iter()
                .map(|id| ListedGroup {
                    kind: GroupKind::Server,
                    id: id.0,
                    name: book.server_groups.get(id).map_or_else(
                        || format!("#{}", id.0),
                        |group| group.name.clone(),
                    ),
                })
                .collect();
            server_groups.sort_unstable_by_key(|group| group.id);
            let channel_group = client.channel_group;
            let inherited_from = client.inherited_channel_group_from_channel.0;
            members.entry(client.channel).or_default().push(RoomMember {
                client_id: client.id.0,
                database_id: client.database_id.0,
                name: client.name.clone(),
                is_self: client.id == book.own_client,
                uid: client.uid.as_ref().map(|uid| uid.to_string()),
                away_message: client.away_message.clone(),
                server_groups,
                channel_group: (channel_group.0 != 0).then(|| ListedGroup {
                    kind: GroupKind::Channel,
                    id: channel_group.0,
                    name: book.channel_groups.get(&channel_group).map_or_else(
                        || format!("#{}", channel_group.0),
                        |group| group.name.clone(),
                    ),
                }),
                client_version: client
                    .optional_data
                    .as_ref()
                    .map(|data| &data.version)
                    .filter(|value| !value.trim().is_empty())
                    .cloned(),
                opents_version: app_metadata::version(&client.metadata),
                client_platform: client
                    .optional_data
                    .as_ref()
                    .map(|data| &data.platform)
                    .filter(|value| !value.trim().is_empty())
                    .cloned(),
                connected_seconds: client
                    .connection_data
                    .as_ref()
                    .and_then(|data| data.connected_time)
                    .filter(|duration| !duration.is_negative())
                    .map(|duration| duration.whole_seconds() as u64),
                inherited_channel_group_from: (inherited_from != 0
                    && inherited_from != client.channel.0)
                    .then_some(inherited_from),
                microphone_enabled: client.input_hardware_enabled,
                microphone_muted: client.input_muted,
                output_enabled: client.output_hardware_enabled,
                output_muted: client.output_muted || client.output_only_muted,
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
                    description: room.optional_data.as_ref().map(|data| data.description.clone()),
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
        let mut channel_groups = group_management::listed_groups(book, GroupKind::Channel, true);
        // The pinned bookkeeping library keeps old list entries until reconnect.
        channel_groups.retain(|group| !deleted_channel_groups.contains(&group.id));
        *state.lock().unwrap() = Snapshot {
            server: book.server.name.clone(),
            server_key: server_key.clone(),
            identity_uid: identity_uid.clone(),
            reconnecting: false,
            audio_generation,
            rooms,
            channel_groups,
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
