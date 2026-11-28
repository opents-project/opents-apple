use super::Session;
use tokio::sync::oneshot;
use tsclientlib::messages::{c2s::OutLogViewPart, s2c::InServerLog};
use tsclientlib::prelude::*;
use tsclientlib::{CommandError, Connection, MessageHandle};

const PAGE_SIZE: u32 = 100;

#[derive(Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ServerLogResponse {
    Page {
        lines: Vec<String>,
        older_cursor: Option<u64>,
    },
    PermissionDenied {
        permission: Option<u32>,
    },
    Failed {
        message: String,
    },
}

impl ServerLogResponse {
    fn failed(message: impl Into<String>) -> Self {
        Self::Failed {
            message: message.into(),
        }
    }
}

pub(crate) struct Request {
    cursor: Option<u64>,
    generation: u64,
    reply: oneshot::Sender<ServerLogResponse>,
}

#[uniffi::export]
impl Session {
    pub async fn read_server_log(&self, cursor: Option<u64>, generation: u64) -> ServerLogResponse {
        let (reply, received) = oneshot::channel();
        if self
            .log_requests
            .send(Request {
                cursor,
                generation,
                reply,
            })
            .await
            .is_err()
        {
            return ServerLogResponse::failed("Connection closed");
        }
        received
            .await
            .unwrap_or_else(|_| ServerLogResponse::failed("Connection closed"))
    }
}

fn command(cursor: Option<u64>) -> OutLogViewPart {
    OutLogViewPart {
        lines: Some(PAGE_SIZE),
        reverse: Some(true),
        instance_log: Some(false),
        offset: Some(cursor.unwrap_or(0)),
    }
}

pub(crate) struct Pending {
    pub handle: MessageHandle,
    cursor: Option<u64>,
    metadata: Option<(u64, u64)>,
    lines: Vec<String>,
    reply: Option<oneshot::Sender<ServerLogResponse>>,
}

impl Pending {
    pub fn start(
        request: Request,
        con: &mut Connection,
        ready: bool,
        generation: u64,
        pending: &mut Option<Self>,
    ) {
        let result = if !ready || request.generation != generation {
            Err("Connection interrupted".into())
        } else if pending.is_some() {
            Err("The previous server log request is still pending".into())
        } else {
            command(request.cursor)
                .send_with_result(con)
                .map_err(|error| error.to_string())
        };
        match result {
            Ok(handle) => {
                *pending = Some(Self {
                    handle,
                    cursor: request.cursor,
                    metadata: None,
                    lines: Vec::new(),
                    reply: Some(request.reply),
                });
            }
            Err(error) => {
                let _ = request.reply.send(ServerLogResponse::failed(error));
            }
        }
    }

    pub fn waiting(&self) -> bool {
        self.reply.is_some()
    }

    pub fn fail(&mut self, message: &str) {
        if let Some(reply) = self.reply.take() {
            let _ = reply.send(ServerLogResponse::failed(message));
        }
    }

    pub fn observe(&mut self, page: &InServerLog) {
        // Some servers omit the return code on data packets, so only one log
        // request can be outstanding until its tagged command result arrives.
        if !self.waiting()
            || page
                .return_code
                .as_deref()
                .is_some_and(|code| code.parse::<u16>() != Ok(self.handle.0))
        {
            return;
        }
        for part in page {
            if part.last_offset > part.file_size
                || self.cursor.is_some_and(|cursor| cursor > part.file_size)
                || self
                    .metadata
                    .is_some_and(|(_, size)| size != part.file_size)
            {
                self.fail("The server log changed. Refresh to read the newest entries.");
                return;
            }
            let cursor = self
                .metadata
                .map_or(part.last_offset, |(offset, _)| offset.min(part.last_offset));
            self.metadata = Some((cursor, part.file_size));
            if !part.log.trim().is_empty() {
                if self.lines.len() == PAGE_SIZE as usize {
                    self.fail("The server returned more log entries than requested");
                    return;
                }
                self.lines.push(part.log.clone());
            }
        }
    }

    pub fn finish(mut self, result: Result<(), CommandError>) {
        let Some(reply) = self.reply.take() else {
            return;
        };
        let result = match result {
            Ok(()) => ServerLogResponse::Page {
                lines: self.lines,
                older_cursor: self
                    .metadata
                    .map(|(offset, _)| offset)
                    .filter(|&offset| offset > 0),
            },
            Err(error) if error.error == tsclientlib::TsError::PermissionsClientInsufficient => {
                ServerLogResponse::PermissionDenied {
                    permission: error.missing_permission.map(|permission| permission.0),
                }
            }
            Err(error) => ServerLogResponse::failed(error.to_string()),
        };
        let _ = reply.send(result);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tsclientlib::InMessage;
    use tsproto_packets::packets::{Direction, InHeader, PacketType};

    fn pending(cursor: Option<u64>) -> (Pending, oneshot::Receiver<ServerLogResponse>) {
        let (reply, response) = oneshot::channel();
        (
            Pending {
                handle: MessageHandle(55),
                cursor,
                metadata: None,
                lines: Vec::new(),
                reply: Some(reply),
            },
            response,
        )
    }

    fn notification(pending: &mut Pending, wire: &[u8]) {
        let mut bytes = [0u8; 11];
        bytes[10] = PacketType::Command as u8;
        let header = InHeader::new(Direction::S2C, &bytes);
        let InMessage::ServerLog(page) = InMessage::new(&header, wire).unwrap() else {
            panic!("not a server log notification");
        };
        pending.observe(&page);
    }

    #[test]
    fn log_requests_are_paginated_and_virtual_server_only() {
        for (cursor, offset) in [(None, 0), (Some(500), 500)] {
            assert_eq!(
                command(cursor).to_packet().0.content(),
                format!("logview lines=100 reverse=1 instance=0 begin_pos={offset}").as_bytes()
            );
        }
    }

    #[test]
    fn page_buffers_matching_rows_until_command_success() {
        let (mut pending, mut response) = pending(Some(500));
        notification(
            &mut pending,
            b"notifyserverlog last_pos=400 file_size=800 l=Unrelated return_code=54",
        );
        notification(&mut pending, br"notifyserverlog last_pos=340 file_size=800 l=2026-11-28\s09:00:00\pINFO\pServer\p1\pNewer|l=Older");
        assert!(response.try_recv().is_err());
        pending.finish(Ok(()));
        assert_eq!(
            response.try_recv().unwrap(),
            ServerLogResponse::Page {
                lines: vec![
                    "2026-11-28 09:00:00|INFO|Server|1|Newer".into(),
                    "Older".into()
                ],
                older_cursor: Some(340),
            },
        );
    }

    #[test]
    fn success_without_data_and_permission_denial_are_distinct() {
        let (page, mut response) = pending(None);
        page.finish(Ok(()));
        assert_eq!(
            response.try_recv().unwrap(),
            ServerLogResponse::Page {
                lines: Vec::new(),
                older_cursor: None
            }
        );
        let (mut page, mut response) = pending(None);
        notification(
            &mut page,
            b"notifyserverlog last_pos=2 file_size=30 l=Private",
        );
        page.finish(Err(CommandError {
            error: tsclientlib::TsError::PermissionsClientInsufficient,
            missing_permission: Some(tsproto_types::Permission(24)),
        }));
        assert_eq!(
            response.try_recv().unwrap(),
            ServerLogResponse::PermissionDenied {
                permission: Some(24)
            }
        );
    }

    #[test]
    fn a_shorter_log_invalidates_the_old_cursor() {
        let (mut page, mut response) = pending(Some(500));
        notification(
            &mut page,
            b"notifyserverlog last_pos=12 file_size=300 l=Rotated",
        );
        assert!(matches!(
            response.try_recv().unwrap(),
            ServerLogResponse::Failed { .. }
        ));
        assert!(!page.waiting());
        notification(
            &mut page,
            b"notifyserverlog last_pos=10 file_size=800 l=Late",
        );
        assert!(page.lines.is_empty());
        page.finish(Ok(()));
    }
}
