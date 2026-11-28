use tokio::sync::oneshot;
use tsclientlib::data::ChannelOptions;
use tsclientlib::prelude::*;
use tsclientlib::{ChannelId, ChannelType, Codec, Connection, MessageHandle};

#[derive(uniffi::Enum)]
pub enum ChannelLifetime {
    Temporary,
    SemiPermanent,
    Permanent,
}

impl From<ChannelLifetime> for ChannelType {
    fn from(value: ChannelLifetime) -> Self {
        match value {
            ChannelLifetime::Temporary => Self::Temporary,
            ChannelLifetime::SemiPermanent => Self::SemiPermanent,
            ChannelLifetime::Permanent => Self::Permanent,
        }
    }
}

#[derive(uniffi::Enum)]
pub enum ManagedCodec {
    Voice,
    Music,
}

impl From<ManagedCodec> for Codec {
    fn from(value: ManagedCodec) -> Self {
        match value {
            ManagedCodec::Voice => Self::OpusVoice,
            ManagedCodec::Music => Self::OpusMusic,
        }
    }
}

#[derive(uniffi::Enum)]
pub enum ChannelChange {
    ReadDescription {
        channel: u64,
    },
    Create {
        parent: u64,
        name: String,
        lifetime: ChannelLifetime,
        codec: Option<ManagedCodec>,
        password: String,
        description: String,
    },
    Edit {
        channel: u64,
        name: Option<String>,
        lifetime: Option<ChannelLifetime>,
        codec: Option<ManagedCodec>,
        // None preserves the password. An empty value explicitly clears it.
        password: Option<String>,
        description: Option<String>,
    },
    Move {
        channel: u64,
        parent: u64,
        predecessor: u64,
    },
    Delete {
        channel: u64,
    },
}

pub struct Request {
    pub change: ChannelChange,
    pub generation: u64,
    pub reply: oneshot::Sender<Option<String>>,
}

impl ChannelChange {
    pub fn send(self, con: &mut Connection) -> Result<MessageHandle, String> {
        let book = con.get_state().map_err(|error| error.to_string())?;
        let command = match self {
            Self::ReadDescription { channel } => {
                if !book.channels.contains_key(&ChannelId(channel)) {
                    return Err("Channel is unavailable.".into());
                }
                return ts_bookkeeping::messages::c2s::OutChannelDescriptionRequestPart {
                    channel_id: ChannelId(channel),
                }
                .send_with_result(con)
                .map_err(|error| error.to_string());
            }
            Self::Create {
                parent,
                name,
                lifetime,
                codec,
                password,
                description,
            } => {
                if name.trim().is_empty() {
                    return Err("Enter a channel name.".into());
                }
                if parent != 0 && !book.channels.contains_key(&ChannelId(parent)) {
                    return Err("The parent channel is unavailable.".into());
                }
                let mut options = ChannelOptions::new(&name)
                    .parent_id(ChannelId(parent))
                    .channel_type(lifetime.into());
                if let Some(codec) = codec {
                    options = options.codec(codec.into());
                }
                if !password.is_empty() {
                    options = options.password(&password);
                }
                if !description.is_empty() {
                    options = options.description(&description);
                }
                book.server.add_channel(options)
            }
            Self::Edit {
                channel,
                name,
                lifetime,
                codec,
                password,
                description,
            } => {
                let room = book
                    .channels
                    .get(&ChannelId(channel))
                    .ok_or("Channel is unavailable.")?;
                let mut update = room.edit();
                if let Some(name) = &name {
                    if name.trim().is_empty() {
                        return Err("Enter a channel name.".into());
                    }
                    update = update.set_name(name);
                }
                if let Some(lifetime) = lifetime {
                    update = update.set_channel_type(lifetime.into());
                }
                if let Some(codec) = codec {
                    update = update.set_codec(codec.into());
                }
                if let Some(password) = &password {
                    update =
                        update.set_password((!password.is_empty()).then_some(password.as_str()));
                }
                if let Some(description) = &description {
                    update = update.set_description(description);
                }
                update.to_packet()
            }
            Self::Move {
                channel,
                parent,
                predecessor,
            } => {
                let channel = ChannelId(channel);
                let parent = ChannelId(parent);
                let predecessor = ChannelId(predecessor);
                let room = book
                    .channels
                    .get(&channel)
                    .ok_or("Channel is unavailable.")?;
                let mut ancestor = parent;
                for _ in 0..=book.channels.len() {
                    if ancestor == ChannelId(0) {
                        break;
                    }
                    if ancestor == channel {
                        return Err("A channel cannot be moved inside itself.".into());
                    }
                    ancestor = book
                        .channels
                        .get(&ancestor)
                        .ok_or("The parent channel is unavailable.")?
                        .parent;
                }
                if ancestor != ChannelId(0) {
                    return Err("The parent channel is unavailable.".into());
                }
                if predecessor != ChannelId(0)
                    && (predecessor == channel
                        || !book
                            .channels
                            .get(&predecessor)
                            .is_some_and(|sibling| sibling.parent == parent))
                {
                    return Err("The selected channel position is unavailable.".into());
                }
                if room.parent == parent {
                    room.edit().set_order(predecessor).to_packet()
                } else {
                    ts_bookkeeping::messages::c2s::OutChannelMovePart {
                        channel_id: channel,
                        parent_id: parent,
                        order: Some(predecessor),
                    }
                    .to_packet()
                }
            }
            Self::Delete { channel } => {
                let channel = ChannelId(channel);
                if !book.channels.contains_key(&channel) {
                    return Err("Channel is unavailable.".into());
                }
                ts_bookkeeping::messages::c2s::OutChannelDeletePart {
                    channel_id: channel,
                    force: false,
                }
                .to_packet()
            }
        };
        command
            .send_with_result(con)
            .map_err(|error| error.to_string())
    }
}
