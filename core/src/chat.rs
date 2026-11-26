use std::collections::VecDeque;
use tokio::sync::oneshot;
use tsclientlib::{events::Event, ClientId, MessageTarget};

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum ChatScope {
    Server,
    Channel { id: u64 },
    Direct { client_id: u16, uid: String },
}

impl ChatScope {
    pub(crate) fn target(
        &self,
        current: Option<u64>,
        peer_uid: Option<&str>,
    ) -> Result<MessageTarget, String> {
        match self {
            Self::Server => Ok(MessageTarget::Server),
            Self::Channel { id } if current == Some(*id) => Ok(MessageTarget::Channel),
            Self::Direct { client_id, uid }
                if !uid.is_empty() && peer_uid == Some(uid.as_str()) =>
            {
                Ok(MessageTarget::Client(ClientId(*client_id)))
            }
            Self::Direct { .. } => Err("The recipient is no longer available.".into()),
            Self::Channel { .. } => Err("Your current channel has changed.".into()),
        }
    }
}

#[derive(Clone, uniffi::Record)]
pub struct ChatLine {
    pub id: u64,
    pub scope: ChatScope,
    pub sender: String,
    pub text: String,
}

pub(crate) struct SendRequest {
    pub scope: ChatScope,
    pub text: String,
    pub generation: u64,
    pub reply: oneshot::Sender<Option<String>>,
}

#[derive(Default)]
pub(crate) struct Inbox {
    sequence: u64,
    lines: VecDeque<ChatLine>,
}

impl Inbox {
    fn append(&mut self, scope: ChatScope, sender: String, text: String) {
        self.sequence += 1;
        if self.lines.len() == 500 {
            self.lines.pop_front();
        }
        self.lines.push_back(ChatLine {
            id: self.sequence,
            scope,
            sender,
            text,
        });
    }

    pub fn receive(
        &mut self,
        events: Vec<Event>,
        own: ClientId,
        channel: Option<u64>,
        peer_uid: impl Fn(ClientId) -> Option<String>,
    ) {
        for event in events {
            if let Event::Message {
                target,
                invoker,
                message,
            } = event
            {
                if invoker.id == own {
                    continue;
                }
                let scope = match (target, channel) {
                    (MessageTarget::Server, _) => ChatScope::Server,
                    (MessageTarget::Channel, Some(id)) => ChatScope::Channel { id },
                    (MessageTarget::Client(to), _) if to == own => {
                        let Some(uid) = invoker
                            .uid
                            .as_ref()
                            .map(|u| u.to_string())
                            .or_else(|| peer_uid(invoker.id))
                        else {
                            continue;
                        };
                        ChatScope::Direct {
                            client_id: invoker.id.0,
                            uid,
                        }
                    }
                    _ => continue,
                };
                self.append(scope, invoker.name, message);
            }
        }
    }

    pub fn finish(&mut self, request: SendRequest, sender: String, failure: Option<String>) {
        if failure.is_none() {
            self.append(request.scope, sender, request.text);
        }
        let _ = request.reply.send(failure);
    }

    pub fn drain(&mut self) -> Vec<ChatLine> {
        self.lines.drain(..).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tsclientlib::Invoker;

    fn message(target: MessageTarget, from: u16) -> Event {
        Event::Message {
            target,
            invoker: Invoker {
                name: "Guest".into(),
                id: ClientId(from),
                uid: None,
            },
            message: "测试 text".into(),
        }
    }

    #[test]
    fn incoming_targets_stay_separate_and_own_echo_is_ignored() {
        let mut inbox = Inbox::default();
        inbox.receive(
            vec![
                message(MessageTarget::Server, 2),
                message(MessageTarget::Channel, 2),
                message(MessageTarget::Client(ClientId(1)), 2),
                message(MessageTarget::Channel, 1),
            ],
            ClientId(1),
            Some(42),
            |_| Some("peer".into()),
        );
        inbox.receive(
            vec![message(MessageTarget::Channel, 2)],
            ClientId(1),
            Some(7),
            |_| None,
        );
        let lines = inbox.drain();
        assert_eq!(
            lines
                .iter()
                .map(|line| line.scope.clone())
                .collect::<Vec<_>>(),
            vec![
                ChatScope::Server,
                ChatScope::Channel { id: 42 },
                ChatScope::Direct {
                    client_id: 2,
                    uid: "peer".into()
                },
                ChatScope::Channel { id: 7 }
            ]
        );
        assert_eq!(lines[2].text, "测试 text");
        assert!(inbox.drain().is_empty());
    }

    #[test]
    fn send_confirmed_or_rejected_by_mock_server() {
        let scope = ChatScope::Channel { id: 42 };
        assert!(scope.target(Some(7), None).is_err());
        assert!(matches!(
            scope.target(Some(42), None),
            Ok(MessageTarget::Channel)
        ));
        assert!(matches!(
            ChatScope::Server.target(None, None),
            Ok(MessageTarget::Server)
        ));
        let direct = ChatScope::Direct {
            client_id: 2,
            uid: "peer".into(),
        };
        assert!(direct.target(None, Some("reused")).is_err());
        assert!(matches!(
            direct.target(None, Some("peer")),
            Ok(MessageTarget::Client(ClientId(2)))
        ));
        let mut inbox = Inbox::default();
        for failure in [None, Some("Insufficient permissions".to_owned())] {
            let (reply, mut result) = oneshot::channel();
            inbox.finish(
                SendRequest {
                    scope: scope.clone(),
                    text: "hello".into(),
                    generation: 0,
                    reply,
                },
                "self".into(),
                failure.clone(),
            );
            assert_eq!(result.try_recv().unwrap(), failure);
        }
        let lines = inbox.drain();
        assert_eq!(lines.len(), 1);
        assert_eq!(
            (lines[0].scope.clone(), lines[0].text.as_str()),
            (scope, "hello")
        );
    }
}
