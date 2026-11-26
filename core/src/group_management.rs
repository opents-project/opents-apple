//! Group permission commands share one ordered request stream. Permission-list notifications
//! identify their group but carry no return code. The command's acknowledgement ends the list.
use super::{GroupKind, ListedGroup, Session};
use tokio::sync::oneshot;
use tsclientlib::messages::c2s::*;
use tsclientlib::prelude::*;
use tsclientlib::{ClientType, Connection, GroupType, InMessage, MessageHandle};
use tsproto_packets::packets::OutCommand;
use tsproto_types::{ChannelGroupId, ChannelId, ClientDbId, ClientId, Permission, ServerGroupId};

pub(crate) fn listed_groups(
    book: &tsclientlib::data::Connection,
    kind: GroupKind,
    assignable_only: bool,
) -> Vec<ListedGroup> {
    let mut groups: Vec<_> = match kind {
        GroupKind::Server => book
            .server_groups
            .values()
            .filter(|group| {
                !assignable_only
                    || (group.group_type == GroupType::Regular
                        && group.id != book.server.default_server_group)
            })
            .map(|group| ListedGroup {
                kind: GroupKind::Server,
                id: group.id.0,
                name: group.name.clone(),
            })
            .collect(),
        GroupKind::Channel => book
            .channel_groups
            .values()
            .filter(|group| !assignable_only || group.group_type == GroupType::Regular)
            .map(|group| ListedGroup {
                kind: GroupKind::Channel,
                id: group.id.0,
                name: group.name.clone(),
            })
            .collect(),
    };
    groups.sort_unstable_by_key(|group| group.id);
    groups
}

#[derive(Clone, uniffi::Record)]
pub struct GroupPermission {
    pub id: u32,
    pub name: Option<String>,
    pub value: i32,
    pub negated: bool,
    pub skip: bool,
}

#[derive(Default, uniffi::Record)]
pub struct GroupPermissionResponse {
    pub groups: Vec<ListedGroup>,
    pub permissions: Vec<GroupPermission>,
    pub error: Option<String>,
}

impl GroupPermissionResponse {
    fn failed(message: impl Into<String>) -> Self {
        Self {
            error: Some(message.into()),
            ..Default::default()
        }
    }
}

enum Action {
    Groups,
    AssignableGroups,
    Read,
    Set(GroupPermission),
    Remove(u32),
    ServerMembership {
        target: MemberTarget,
        member: bool,
    },
    ChannelMembership {
        target: MemberTarget,
        channel: ChannelId,
    },
}

struct MemberTarget {
    client_id: ClientId,
    database_id: ClientDbId,
}

impl MemberTarget {
    fn new(client_id: u16, database_id: u64) -> Self {
        Self {
            client_id: ClientId(client_id),
            database_id: ClientDbId(database_id),
        }
    }

    fn validate(
        &self,
        client: Option<(ClientDbId, ChannelId, ClientType)>,
        expected_channel: Option<ChannelId>,
    ) -> Result<(), &'static str> {
        let Some((database_id, channel, ClientType::Normal)) = client else {
            return Err("Member is no longer available");
        };
        if database_id != self.database_id {
            return Err("Member is no longer available");
        }
        if expected_channel.is_some_and(|expected| expected != channel) {
            return Err("Member changed channels");
        }
        Ok(())
    }
}

pub(crate) struct Request {
    kind: GroupKind,
    group: u64,
    generation: u64,
    action: Action,
    reply: oneshot::Sender<GroupPermissionResponse>,
}

#[uniffi::export]
impl Session {
    pub async fn list_groups(&self, kind: GroupKind, generation: u64) -> GroupPermissionResponse {
        self.group_request(kind, 0, generation, Action::Groups)
            .await
    }

    pub async fn list_assignable_groups(
        &self,
        kind: GroupKind,
        generation: u64,
    ) -> GroupPermissionResponse {
        self.group_request(kind, 0, generation, Action::AssignableGroups)
            .await
    }

    pub async fn set_member_server_group(
        &self,
        group: u64,
        client_id: u16,
        database_id: u64,
        member: bool,
        generation: u64,
    ) -> GroupPermissionResponse {
        self.group_request(
            GroupKind::Server,
            group,
            generation,
            Action::ServerMembership {
                target: MemberTarget::new(client_id, database_id),
                member,
            },
        )
        .await
    }

    pub async fn set_member_channel_group(
        &self,
        group: u64,
        client_id: u16,
        database_id: u64,
        channel: u64,
        generation: u64,
    ) -> GroupPermissionResponse {
        self.group_request(
            GroupKind::Channel,
            group,
            generation,
            Action::ChannelMembership {
                target: MemberTarget::new(client_id, database_id),
                channel: ChannelId(channel),
            },
        )
        .await
    }

    pub async fn list_group_permissions(
        &self,
        kind: GroupKind,
        group: u64,
        generation: u64,
    ) -> GroupPermissionResponse {
        self.group_request(kind, group, generation, Action::Read)
            .await
    }

    pub async fn set_group_permission(
        &self,
        kind: GroupKind,
        group: u64,
        permission: GroupPermission,
        generation: u64,
    ) -> GroupPermissionResponse {
        self.group_request(kind, group, generation, Action::Set(permission))
            .await
    }

    pub async fn remove_group_permission(
        &self,
        kind: GroupKind,
        group: u64,
        permission_id: u32,
        generation: u64,
    ) -> GroupPermissionResponse {
        self.group_request(kind, group, generation, Action::Remove(permission_id))
            .await
    }
}

impl Session {
    async fn group_request(
        &self,
        kind: GroupKind,
        group: u64,
        generation: u64,
        action: Action,
    ) -> GroupPermissionResponse {
        let (reply, received) = oneshot::channel();
        if self
            .group_requests
            .send(Request {
                kind,
                group,
                generation,
                action,
                reply,
            })
            .await
            .is_err()
        {
            return GroupPermissionResponse::failed("Connection closed");
        }
        received
            .await
            .unwrap_or_else(|_| GroupPermissionResponse::failed("Connection closed"))
    }
}

impl Request {
    fn validate(&self) -> Result<(), &'static str> {
        if !matches!(self.action, Action::Groups | Action::AssignableGroups) && self.group == 0 {
            return Err("Invalid group ID");
        }
        match &self.action {
            Action::Set(p) if p.id == 0 => Err("Invalid permission ID"),
            Action::Remove(0) => Err("Invalid permission ID"),
            Action::Set(p) if matches!(self.kind, GroupKind::Channel) && (p.negated || p.skip) => {
                Err("Channel group permissions do not support Negated or Skip")
            }
            Action::ServerMembership { target, .. } | Action::ChannelMembership { target, .. }
                if target.client_id.0 == 0 || target.database_id.0 == 0 =>
            {
                Err("Invalid member ID")
            }
            Action::ChannelMembership {
                channel: ChannelId(0),
                ..
            } => Err("Invalid channel ID"),
            _ => Ok(()),
        }
    }

    fn validate_assignment(&self, con: &Connection) -> Result<(), String> {
        let (target, channel) = match &self.action {
            Action::ServerMembership { target, .. } => (target, None),
            Action::ChannelMembership { target, channel } => (target, Some(*channel)),
            _ => return Ok(()),
        };
        let book = con.get_state().map_err(|e| e.to_string())?;
        let client = book
            .clients
            .get(&target.client_id)
            .map(|client| (client.database_id, client.channel, client.client_type));
        target.validate(client, channel)?;
        let assignable = match self.kind {
            GroupKind::Server => book
                .server_groups
                .get(&ServerGroupId(self.group))
                .is_some_and(|g| {
                    g.group_type == GroupType::Regular && g.id != book.server.default_server_group
                }),
            GroupKind::Channel => book
                .channel_groups
                .get(&ChannelGroupId(self.group))
                .is_some_and(|g| g.group_type == GroupType::Regular),
        };
        if !assignable {
            return Err("Group is no longer available for assignment".into());
        }
        Ok(())
    }

    fn command(&self) -> Result<OutCommand, String> {
        self.validate()?;
        let server_group_id = ServerGroupId(self.group);
        let channel_group = ChannelGroupId(self.group);
        Ok(match (&self.kind, &self.action) {
            (GroupKind::Server, Action::Groups | Action::AssignableGroups) => {
                OutServerGroupListRequestMessage::new()
            }
            (GroupKind::Channel, Action::Groups | Action::AssignableGroups) => {
                OutChannelGroupListRequestMessage::new()
            }
            (GroupKind::Server, Action::Read) => {
                OutServerGroupPermListRequestPart { server_group_id }.to_packet()
            }
            (GroupKind::Channel, Action::Read) => {
                OutChannelGroupPermListRequestPart { channel_group }.to_packet()
            }
            (GroupKind::Server, Action::Set(p)) => OutServerGroupAddPermPart {
                server_group_id,
                permission_id: Some(Permission(p.id)),
                permission_name_id: None,
                permission_value: p.value,
                permission_negated: p.negated,
                permission_skip: p.skip,
            }
            .to_packet(),
            (GroupKind::Channel, Action::Set(p)) => OutChannelGroupAddPermPart {
                channel_group,
                permission_id: Some(Permission(p.id)),
                permission_name_id: None,
                permission_value: p.value,
            }
            .to_packet(),
            (GroupKind::Server, Action::Remove(id)) => OutServerGroupDelPermPart {
                server_group_id,
                permission_id: Some(Permission(*id)),
                permission_name_id: None,
            }
            .to_packet(),
            (GroupKind::Channel, Action::Remove(id)) => OutChannelGroupDelPermPart {
                channel_group,
                permission_id: Some(Permission(*id)),
                permission_name_id: None,
            }
            .to_packet(),
            (
                _,
                Action::ServerMembership {
                    target,
                    member: true,
                },
            ) => OutServerGroupAddClientPart {
                server_group_id,
                client_db_id: target.database_id,
            }
            .to_packet(),
            (
                _,
                Action::ServerMembership {
                    target,
                    member: false,
                },
            ) => OutServerGroupDelClientPart {
                server_group_id,
                client_db_id: target.database_id,
            }
            .to_packet(),
            (_, Action::ChannelMembership { target, channel }) => OutSetClientChannelGroupPart {
                channel_group,
                channel_id: *channel,
                client_db_id: target.database_id,
            }
            .to_packet(),
        })
    }
}

pub(crate) struct Pending {
    pub handle: MessageHandle,
    kind: GroupKind,
    group: u64,
    action: Action,
    rows: Vec<GroupPermission>,
    reply: Option<oneshot::Sender<GroupPermissionResponse>>,
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
            Err("A permission request is still pending".into())
        } else {
            request
                .command()
                .and_then(|cmd| {
                    request.validate_assignment(con)?;
                    Ok(cmd)
                })
                .and_then(|cmd| cmd.send_with_result(con).map_err(|e| e.to_string()))
        };
        match result {
            Ok(handle) => {
                *pending = Some(Self {
                    handle,
                    kind: request.kind,
                    group: request.group,
                    action: request.action,
                    rows: Vec::new(),
                    reply: Some(request.reply),
                })
            }
            Err(e) => {
                let _ = request.reply.send(GroupPermissionResponse::failed(e));
            }
        }
    }

    pub fn waiting(&self) -> bool {
        self.reply.is_some()
    }

    pub fn fail(&mut self, reason: &str) {
        if let Some(reply) = self.reply.take() {
            let _ = reply.send(GroupPermissionResponse::failed(reason));
        }
    }

    fn matches_return_code(&self, code: Option<&str>) -> bool {
        code.is_none_or(|code| code.parse::<u16>() == Ok(self.handle.0))
    }

    pub fn observe(&mut self, message: &InMessage) {
        if !self.waiting() {
            return;
        }
        if !matches!(self.action, Action::Read) {
            return;
        }
        match (&self.kind, message) {
            (GroupKind::Server, InMessage::ServerGroupPermList(list))
                if self.matches_return_code(list.return_code.as_deref()) =>
            {
                for p in list.iter().filter(|p| p.server_group_id.0 == self.group) {
                    if let Some(id) = p.permission_id {
                        self.rows.push(GroupPermission {
                            id: id.0,
                            name: p.permission_name_id.clone(),
                            value: p.permission_value,
                            negated: p.permission_negated,
                            skip: p.permission_skip,
                        });
                    }
                }
            }
            (GroupKind::Channel, InMessage::ChannelGroupPermList(list))
                if self.matches_return_code(list.return_code.as_deref()) =>
            {
                for p in list.iter().filter(|p| p.channel_group.0 == self.group) {
                    if let Some(id) = p.permission_id {
                        self.rows.push(GroupPermission {
                            id: id.0,
                            name: p.permission_name_id.clone(),
                            value: p.permission_value,
                            negated: p.permission_negated,
                            skip: p.permission_skip,
                        });
                    }
                }
            }
            _ => {}
        }
    }

    pub fn finish(self, con: &Connection, result: Result<(), tsclientlib::CommandError>) {
        let Some(reply) = self.reply else {
            return;
        };
        let mut response = GroupPermissionResponse::default();
        match result {
            Err(e)
                if matches!(
                    self.action,
                    Action::Read | Action::Groups | Action::AssignableGroups
                ) && matches!(
                    e.error,
                    tsclientlib::TsError::DatabaseEmptyResult
                        | tsclientlib::TsError::PermissionEmptyResult
                ) => {}
            Err(e) => {
                response.error = Some(match e.missing_permission {
                    Some(p) => format!("{} (#{})", e.error, p.0),
                    None => e.to_string(),
                })
            }
            Ok(()) if matches!(self.action, Action::Groups | Action::AssignableGroups) => {
                match con.get_state() {
                    Ok(book) => {
                        let assignable_only = matches!(self.action, Action::AssignableGroups);
                        response.groups = listed_groups(book, self.kind, assignable_only);
                    }
                    Err(e) => response.error = Some(e.to_string()),
                }
            }
            Ok(()) => {
                response.permissions = self.rows;
                response.permissions.sort_by_key(|p| p.id);
            }
        }
        let _ = reply.send(response);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tsproto_packets::packets::{Direction, InHeader, PacketType};

    fn request(kind: GroupKind, action: Action) -> Request {
        Request {
            kind,
            group: 17,
            generation: 1,
            action,
            reply: oneshot::channel().0,
        }
    }

    fn wire(request: Request) -> String {
        String::from_utf8(request.command().unwrap().0.content().to_vec()).unwrap()
    }

    #[test]
    fn member_assignments_use_native_database_and_channel_ids() {
        assert_eq!(
            wire(request(GroupKind::Server, Action::AssignableGroups)),
            "servergrouplist"
        );
        assert_eq!(
            wire(request(GroupKind::Channel, Action::AssignableGroups)),
            "channelgrouplist"
        );
        for (member, expected) in [
            (true, "servergroupaddclient sgid=17 cldbid=902"),
            (false, "servergroupdelclient sgid=17 cldbid=902"),
        ] {
            assert_eq!(
                wire(request(
                    GroupKind::Server,
                    Action::ServerMembership {
                        target: MemberTarget::new(7, 902),
                        member,
                    }
                )),
                expected
            );
        }
        assert_eq!(
            wire(request(
                GroupKind::Channel,
                Action::ChannelMembership {
                    target: MemberTarget::new(7, 902),
                    channel: ChannelId(54),
                }
            )),
            "setclientchannelgroup cgid=17 cid=54 cldbid=902"
        );
    }

    #[test]
    fn assignments_reject_invalid_or_stale_targets() {
        for (client_id, database_id, channel) in [(0, 902, 54), (7, 0, 54), (7, 902, 0)] {
            assert!(request(
                GroupKind::Channel,
                Action::ChannelMembership {
                    target: MemberTarget::new(client_id, database_id),
                    channel: ChannelId(channel),
                }
            )
            .command()
            .is_err());
        }
        let target = MemberTarget::new(7, 902);
        let visible = Some((ClientDbId(902), ChannelId(54), ClientType::Normal));
        assert_eq!(target.validate(visible, Some(ChannelId(54))), Ok(()));
        assert_eq!(target.validate(visible, None), Ok(()));
        assert_eq!(
            target.validate(visible, Some(ChannelId(55))),
            Err("Member changed channels")
        );
        for stale in [
            None,
            Some((ClientDbId(903), ChannelId(54), ClientType::Normal)),
            Some((
                ClientDbId(902),
                ChannelId(54),
                ClientType::Query { admin: false },
            )),
        ] {
            assert_eq!(
                target.validate(stale, None),
                Err("Member is no longer available")
            );
        }
    }

    #[test]
    fn writes_use_exact_group_and_only_supported_flags() {
        let mut permission = GroupPermission {
            id: 52,
            name: None,
            value: -3,
            negated: true,
            skip: true,
        };
        assert_eq!(
            wire(request(GroupKind::Server, Action::Set(permission.clone()))),
            "servergroupaddperm sgid=17 permid=52 permvalue=-3 permnegated=1 permskip=1"
        );
        assert!(request(GroupKind::Channel, Action::Set(permission.clone()))
            .command()
            .is_err());
        permission.negated = false;
        permission.skip = false;
        assert_eq!(
            wire(request(GroupKind::Channel, Action::Set(permission))),
            "channelgroupaddperm cgid=17 permid=52 permvalue=-3"
        );
        assert_eq!(
            wire(request(GroupKind::Server, Action::Remove(52))),
            "servergroupdelperm sgid=17 permid=52"
        );
        assert_eq!(
            wire(request(GroupKind::Channel, Action::Remove(52))),
            "channelgroupdelperm cgid=17 permid=52"
        );
        assert!(request(GroupKind::Server, Action::Remove(0))
            .command()
            .is_err());
    }

    #[test]
    fn only_matching_notifications_fill_the_current_query() {
        let mut bytes = [0u8; 11];
        bytes[10] = PacketType::Command as u8;
        let header = InHeader::new(Direction::S2C, &bytes);
        let (reply, mut receiver) = oneshot::channel();
        let mut pending = Pending {
            handle: MessageHandle(55),
            kind: GroupKind::Server,
            group: 17,
            action: Action::Read,
            rows: Vec::new(),
            reply: Some(reply),
        };
        for wire in [
            "notifychannelgrouppermlist cgid=17 permid=1 permvalue=2 permnegated=0 permskip=0",
            "notifyservergrouppermlist sgid=9 permid=1 permvalue=2 permnegated=0 permskip=0",
            "notifyservergrouppermlist sgid=17 permid=1 permvalue=2 permnegated=0 permskip=0 return_code=54",
            "notifyservergrouppermlist sgid=17 permid=24 permvalue=-3 permnegated=1 permskip=0|permid=25 permvalue=50 permnegated=0 permskip=1",
        ] {
            pending.observe(&InMessage::new(&header,wire.as_bytes()).unwrap());
        }
        assert_eq!(
            pending
                .rows
                .iter()
                .map(|p| (p.id, p.value, p.negated, p.skip))
                .collect::<Vec<_>>(),
            vec![(24, -3, true, false), (25, 50, false, true)]
        );
        pending.fail("Permission request timed out");
        assert!(receiver.try_recv().unwrap().error.is_some());
        pending.observe(
            &InMessage::new(
                &header,
                b"notifyservergrouppermlist sgid=17 permid=9 permvalue=7 permnegated=0 permskip=0",
            )
            .unwrap(),
        );
        assert_eq!(pending.rows.len(), 2);
    }
}
