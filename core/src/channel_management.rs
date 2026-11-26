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
    Create {
        parent: u64,
        name: String,
        lifetime: ChannelLifetime,
        codec: Option<ManagedCodec>,
        password: String,
    },
    Edit {
        channel: u64,
        name: Option<String>,
        lifetime: Option<ChannelLifetime>,
        codec: Option<ManagedCodec>,
        // None preserves the password. An empty value explicitly clears it.
        password: Option<String>,
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
            Self::Create {
                parent,
                name,
                lifetime,
                codec,
                password,
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
                book.server.add_channel(options)
            }
            Self::Edit {
                channel,
                name,
                lifetime,
                codec,
                password,
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
                update.to_packet()
            }
        };
        command
            .send_with_result(con)
            .map_err(|error| error.to_string())
    }
}
