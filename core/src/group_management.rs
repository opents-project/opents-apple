//! Group permission commands share one ordered request stream. Permission-list notifications
//! identify their group but carry no return code. The command's acknowledgement ends the list.
use super::{GroupKind, ListedGroup, Session};
use std::collections::{BTreeMap, HashMap, HashSet};
use tokio::sync::oneshot;
use tsclientlib::events::{Event, PropertyId};
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
    project_groups(book, kind, assignable_only, assignable_only)
}

fn project_groups(
    book: &tsclientlib::data::Connection,
    kind: GroupKind,
    regular_only: bool,
    exclude_default: bool,
) -> Vec<ListedGroup> {
    let mut groups: Vec<_> = match kind {
        GroupKind::Server => book
            .server_groups
            .values()
            .filter(|group| {
                (!regular_only || group.group_type == GroupType::Regular)
                    && (!exclude_default || group.id != book.server.default_server_group)
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
            .filter(|group| !regular_only || group.group_type == GroupType::Regular)
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
    pub definitions: Vec<PermissionDefinition>,
    pub default_group: Option<u64>,
    pub members: Vec<ServerGroupMember>,
    pub error: Option<String>,
}

#[derive(uniffi::Record)]
pub struct ServerGroupMember {
    pub database_id: u64,
    pub name: String,
    pub is_self: bool,
}

#[derive(uniffi::Record)]
pub struct PermissionDefinition {
    pub id: u32,
    pub name: String,
    pub description: Option<String>,
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
    DirectoryGroups,
    ListServerGroupMembers,
    RemoveServerGroupMember(ClientDbId),
    Create(String),
    Rename(String),
    Copy(String),
    Delete,
    Catalog,
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
    pub async fn list_permission_directory_groups(
        &self,
        kind: GroupKind,
        generation: u64,
    ) -> GroupPermissionResponse {
        self.group_request(kind, 0, generation, Action::DirectoryGroups)
            .await
    }

    pub async fn list_server_group_members(
        &self,
        group: u64,
        generation: u64,
    ) -> GroupPermissionResponse {
        self.group_request(
            GroupKind::Server,
            group,
            generation,
            Action::ListServerGroupMembers,
        )
        .await
    }

    pub async fn remove_server_group_member(
        &self,
        group: u64,
        database_id: u64,
        generation: u64,
    ) -> GroupPermissionResponse {
        self.group_request(
            GroupKind::Server,
            group,
            generation,
            Action::RemoveServerGroupMember(ClientDbId(database_id)),
        )
        .await
    }

    pub async fn create_group(
        &self,
        kind: GroupKind,
        name: String,
        generation: u64,
    ) -> GroupPermissionResponse {
        self.group_request(kind, 0, generation, Action::Create(name))
            .await
    }

    pub async fn rename_group(
        &self,
        kind: GroupKind,
        group: u64,
        name: String,
        generation: u64,
    ) -> GroupPermissionResponse {
        self.group_request(kind, group, generation, Action::Rename(name))
            .await
    }

    pub async fn copy_group(
        &self,
        kind: GroupKind,
        group: u64,
        name: String,
        generation: u64,
    ) -> GroupPermissionResponse {
        self.group_request(kind, group, generation, Action::Copy(name))
            .await
    }

    pub async fn delete_group(
        &self,
        kind: GroupKind,
        group: u64,
        generation: u64,
    ) -> GroupPermissionResponse {
        self.group_request(kind, group, generation, Action::Delete)
            .await
    }

    pub async fn permission_catalog(&self, generation: u64) -> GroupPermissionResponse {
        self.group_request(GroupKind::Server, 0, generation, Action::Catalog)
            .await
    }

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
        if !matches!(
            self.action,
            Action::Groups
                | Action::AssignableGroups
                | Action::DirectoryGroups
                | Action::Catalog
                | Action::Create(_)
        ) && self.group == 0
        {
            return Err("Invalid group ID");
        }
        match &self.action {
            Action::Create(name) | Action::Rename(name) | Action::Copy(name)
                if name.trim().is_empty()
                    || name.chars().any(char::is_control)
                    || name.chars().count() > 30 =>
            {
                Err("Group name must contain 1 to 30 characters")
            }
            Action::RemoveServerGroupMember(ClientDbId(0)) => Err("Invalid member ID"),
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

    fn needs_server_command(&self, con: &Connection) -> Result<bool, String> {
        if !matches!(
            self.action,
            Action::ListServerGroupMembers
                | Action::RemoveServerGroupMember(_)
                | Action::Rename(_)
                | Action::Copy(_)
                | Action::Delete
        ) {
            return Ok(true);
        }
        let book = con.get_state().map_err(|error| error.to_string())?;
        let (regular, default) = match self.kind {
            GroupKind::Server => (
                book.server_groups
                    .get(&ServerGroupId(self.group))
                    .is_some_and(|group| group.group_type == GroupType::Regular),
                self.group == book.server.default_server_group.0,
            ),
            GroupKind::Channel => (
                book.channel_groups
                    .get(&ChannelGroupId(self.group))
                    .is_some_and(|group| group.group_type == GroupType::Regular),
                self.group == book.server.default_channel_group.0
                    || book
                        .server
                        .optional_data
                        .as_ref()
                        .is_some_and(|data| data.default_channel_admin_group.0 == self.group),
            ),
        };
        if default && matches!(self.action, Action::ListServerGroupMembers) {
            // Default server-group membership is implicit, with no explicit roster.
            return Ok(false);
        }
        if !regular {
            return Err("Group is no longer available".into());
        }
        if default
            && matches!(
                self.action,
                Action::Delete | Action::RemoveServerGroupMember(_)
            )
        {
            return Err("The default group cannot be removed or have members removed".into());
        }
        Ok(true)
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
            (_, Action::Catalog) => OutPermListRequestMessage::new(),
            (
                GroupKind::Server,
                Action::Groups | Action::AssignableGroups | Action::DirectoryGroups,
            ) => OutServerGroupListRequestMessage::new(),
            (
                GroupKind::Channel,
                Action::Groups | Action::AssignableGroups | Action::DirectoryGroups,
            ) => OutChannelGroupListRequestMessage::new(),
            (_, Action::ListServerGroupMembers) => {
                let mut command =
                    OutServerGroupClientListRequestPart { server_group_id }.to_packet();
                command.write_arg("-names", &"");
                command
            }
            (_, Action::RemoveServerGroupMember(client_db_id)) => OutServerGroupDelClientPart {
                server_group_id,
                client_db_id: *client_db_id,
            }
            .to_packet(),
            (GroupKind::Server, Action::Create(name)) => OutServerGroupAddPart {
                name: name.trim().into(),
                group_type: Some(GroupType::Regular),
            }
            .to_packet(),
            (GroupKind::Channel, Action::Create(name)) => OutChannelGroupAddPart {
                name: name.trim().into(),
                group_type: Some(GroupType::Regular),
            }
            .to_packet(),
            (GroupKind::Server, Action::Rename(name)) => OutServerGroupRenamePart {
                server_group_id,
                name: name.trim().into(),
            }
            .to_packet(),
            (GroupKind::Channel, Action::Rename(name)) => OutChannelGroupRenamePart {
                channel_group,
                name: name.trim().into(),
            }
            .to_packet(),
            (GroupKind::Server, Action::Copy(name)) => OutServerGroupCopyPart {
                source_server_group_id: server_group_id,
                target_server_group_id: ServerGroupId(0),
                name: name.trim().into(),
                group_type: GroupType::Regular,
            }
            .to_packet(),
            (GroupKind::Channel, Action::Copy(name)) => OutChannelGroupCopyPart {
                source_channel_group_id: channel_group,
                target_channel_group_id: ChannelGroupId(0),
                name: name.trim().into(),
                group_type: GroupType::Regular,
            }
            .to_packet(),
            (GroupKind::Server, Action::Delete) => OutServerGroupDelPart {
                server_group_id,
                force: false,
            }
            .to_packet(),
            (GroupKind::Channel, Action::Delete) => OutChannelGroupDelPart {
                channel_group,
                force: false,
            }
            .to_packet(),
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
    definitions: Vec<PermissionDefinition>,
    next_permission_id: u32,
    directory_ids: HashSet<u64>,
    members: BTreeMap<u64, Option<String>>,
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
            request.command().and_then(|cmd| {
                request.validate_assignment(con)?;
                if request.needs_server_command(con)? {
                    cmd.send_with_result(con)
                        .map(Some)
                        .map_err(|error| error.to_string())
                } else {
                    Ok(None)
                }
            })
        };
        match result {
            Ok(Some(handle)) => {
                *pending = Some(Self {
                    handle,
                    kind: request.kind,
                    group: request.group,
                    action: request.action,
                    rows: Vec::new(),
                    definitions: Vec::new(),
                    next_permission_id: 1,
                    directory_ids: HashSet::new(),
                    members: BTreeMap::new(),
                    reply: Some(request.reply),
                })
            }
            Ok(None) => {
                let _ = request.reply.send(GroupPermissionResponse::default());
            }
            Err(e) => {
                let _ = request.reply.send(GroupPermissionResponse::failed(e));
            }
        }
    }

    pub fn waiting(&self) -> bool {
        self.reply.is_some()
    }

    pub fn confirmed_channel_deletion(
        &self,
        result: &Result<(), tsclientlib::CommandError>,
    ) -> Option<u64> {
        (result.is_ok()
            && matches!(
                (&self.kind, &self.action),
                (GroupKind::Channel, Action::Delete)
            ))
        .then_some(self.group)
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
        if matches!(self.action, Action::ListServerGroupMembers) {
            if let InMessage::ServerGroupClientList(list) = message {
                if self.matches_return_code(list.return_code.as_deref()) {
                    let first = list.iter().next();
                    for row in list.iter().filter(|row| {
                        row.server_group_id.0 == self.group && row.client_db_id.0 != 0
                    }) {
                        // Missing names and UIDs inherit the first row in the pinned parser.
                        // A distinct UID lets genuinely same-named members keep their name.
                        let name = row.name.as_ref().filter(|name| {
                            !name.trim().is_empty()
                                && !first.is_some_and(|first| {
                                    row.client_db_id != first.client_db_id
                                        && first.name.as_ref() == Some(*name)
                                        && !row
                                            .uid
                                            .as_ref()
                                            .zip(first.uid.as_ref())
                                            .is_some_and(|(uid, first_uid)| uid != first_uid)
                                })
                        });
                        let member = self.members.entry(row.client_db_id.0).or_default();
                        if member.is_none() {
                            *member = name.cloned();
                        }
                    }
                }
            }
            return;
        }
        if matches!(self.action, Action::Catalog) {
            if let InMessage::PermList(list) = message {
                if self.matches_return_code(list.return_code.as_deref()) {
                    for row in list.iter() {
                        let Some(name) =
                            row.permission_name.as_ref().filter(|name| !name.is_empty())
                        else {
                            continue;
                        };
                        // TS3 sends unnamed group boundaries before the indexed permission rows.
                        let id = row.permission_id.map_or(self.next_permission_id, |id| id.0);
                        self.next_permission_id = id.saturating_add(1);
                        if id > 0 {
                            self.definitions.push(PermissionDefinition {
                                id,
                                name: name.clone(),
                                description: row.permission_description.clone(),
                            });
                        }
                    }
                }
            }
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

    pub fn observe_book_events(&mut self, events: &[Event]) {
        if !self.waiting() || !matches!(self.action, Action::DirectoryGroups) {
            return;
        }
        // tsclientlib consumes notify{server,channel}grouplist into BookEvents but retains
        // previously known IDs. Record the IDs from this query so deletions are visible.
        for event in events {
            if let Event::PropertyAdded { id, .. } = event {
                match (&self.kind, id) {
                    (GroupKind::Server, PropertyId::ServerGroup(id)) => {
                        self.directory_ids.insert(id.0);
                    }
                    (GroupKind::Channel, PropertyId::ChannelGroup(id)) => {
                        self.directory_ids.insert(id.0);
                    }
                    _ => {}
                }
            }
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
                    Action::Read
                        | Action::Groups
                        | Action::AssignableGroups
                        | Action::DirectoryGroups
                        | Action::ListServerGroupMembers
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
            Ok(()) if matches!(self.action, Action::Catalog) => {
                response.definitions = self.definitions
            }
            Ok(()) if matches!(self.action, Action::DirectoryGroups) => match con.get_state() {
                Ok(book) => {
                    let default = match self.kind {
                        GroupKind::Server => book.server.default_server_group.0,
                        GroupKind::Channel => book.server.default_channel_group.0,
                    };
                    response.default_group = (default != 0).then_some(default);
                    response.groups = project_groups(book, self.kind, true, false);
                    response
                        .groups
                        .retain(|group| self.directory_ids.contains(&group.id));
                }
                Err(error) => response.error = Some(error.to_string()),
            },
            Ok(()) if matches!(self.action, Action::ListServerGroupMembers) => {
                match con.get_state() {
                    Ok(book) => {
                        let own_db = book
                            .clients
                            .get(&book.own_client)
                            .map(|client| client.database_id.0);
                        let visible_names: HashMap<_, _> = book
                            .clients
                            .values()
                            .map(|client| (client.database_id.0, client.name.as_str()))
                            .collect();
                        response.members = self
                            .members
                            .into_iter()
                            .map(|(database_id, name)| ServerGroupMember {
                                database_id,
                                name: name
                                    .or_else(|| {
                                        visible_names
                                            .get(&database_id)
                                            .map(|name| (*name).to_owned())
                                    })
                                    .unwrap_or_else(|| format!("#{database_id}")),
                                is_self: own_db == Some(database_id),
                            })
                            .collect();
                    }
                    Err(error) => response.error = Some(error.to_string()),
                }
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
    fn group_directory_uses_native_roster_and_non_forced_group_commands() {
        assert_eq!(
            wire(request(GroupKind::Server, Action::DirectoryGroups)),
            "servergrouplist"
        );
        assert_eq!(
            wire(request(GroupKind::Channel, Action::DirectoryGroups)),
            "channelgrouplist"
        );
        assert_eq!(
            wire(request(GroupKind::Server, Action::ListServerGroupMembers)),
            "servergroupclientlist sgid=17 -names"
        );
        assert_eq!(
            wire(request(
                GroupKind::Server,
                Action::RemoveServerGroupMember(ClientDbId(903))
            )),
            "servergroupdelclient sgid=17 cldbid=903"
        );
        assert!(request(
            GroupKind::Server,
            Action::RemoveServerGroupMember(ClientDbId(0))
        )
        .command()
        .is_err());
        for (kind, create, rename, copy, delete) in [
            (
                GroupKind::Server,
                "servergroupadd name=QA\\sGroup type=1",
                "servergrouprename sgid=17 name=QA\\sGroup",
                "servergroupcopy ssgid=17 tsgid=0 name=QA\\sGroup type=1",
                "servergroupdel sgid=17 force=0",
            ),
            (
                GroupKind::Channel,
                "channelgroupadd name=QA\\sGroup type=1",
                "channelgrouprename cgid=17 name=QA\\sGroup",
                "channelgroupcopy scgid=17 tcgid=0 name=QA\\sGroup type=1",
                "channelgroupdel cgid=17 force=0",
            ),
        ] {
            assert_eq!(
                wire(request(kind.clone(), Action::Create(" QA Group ".into()))),
                create
            );
            assert_eq!(
                wire(request(kind.clone(), Action::Rename("QA Group".into()))),
                rename
            );
            assert_eq!(
                wire(request(kind.clone(), Action::Copy("QA Group".into()))),
                copy
            );
            assert_eq!(wire(request(kind, Action::Delete)), delete);
        }
        assert!(request(GroupKind::Server, Action::Create(" ".into()))
            .command()
            .is_err());
        assert!(request(GroupKind::Channel, Action::Rename("字".repeat(31)))
            .command()
            .is_err());
    }

    #[test]
    fn roster_only_collects_the_selected_group_and_matching_reply() {
        let mut bytes = [0u8; 11];
        bytes[10] = PacketType::Command as u8;
        let header = InHeader::new(Direction::S2C, &bytes);
        let (reply, _response) = oneshot::channel();
        let mut pending = Pending {
            handle: MessageHandle(55),
            kind: GroupKind::Server,
            group: 17,
            action: Action::ListServerGroupMembers,
            rows: Vec::new(),
            definitions: Vec::new(),
            next_permission_id: 1,
            directory_ids: HashSet::new(),
            members: BTreeMap::new(),
            reply: Some(reply),
        };
        for wire in [
            "notifyservergroupclientlist sgid=21 cldbid=3 client_nickname=Wrong",
            "notifyservergroupclientlist sgid=17 cldbid=3 client_nickname=Old return_code=54",
            concat!(
                "notifyservergroupclientlist sgid=17 cldbid=2 client_nickname=Member\\s2 client_unique_identifier=uA0U7t4PBxdJ5TLnarsOHQh4\\/tY=",
                "|cldbid=9|cldbid=11 client_nickname=Member\\s2 client_unique_identifier=b+P0CqXms5I0C+A66HZ4Sbu\\/PNw=",
                "|cldbid=0 return_code=55",
            ),
        ] {
            pending.observe(&InMessage::new(&header, wire.as_bytes()).unwrap());
        }
        assert_eq!(
            pending.members,
            BTreeMap::from([
                (2, Some("Member 2".into())),
                (9, None),
                (11, Some("Member 2".into()))
            ])
        );
        pending.fail("Permission request timed out");
        pending.observe(
            &InMessage::new(&header, b"notifyservergroupclientlist sgid=17 cldbid=10").unwrap(),
        );
        assert_eq!(pending.members.len(), 3);
    }

    #[test]
    fn only_confirmed_local_channel_group_deletions_change_the_menu() {
        let mut pending = Pending {
            handle: MessageHandle(55),
            kind: GroupKind::Channel,
            group: 17,
            action: Action::Delete,
            rows: Vec::new(),
            definitions: Vec::new(),
            next_permission_id: 1,
            directory_ids: HashSet::new(),
            members: BTreeMap::new(),
            reply: None,
        };
        assert_eq!(pending.confirmed_channel_deletion(&Ok(())), Some(17));
        assert_eq!(
            pending.confirmed_channel_deletion(&Err(tsclientlib::CommandError {
                error: tsclientlib::TsError::PermissionsClientInsufficient,
                missing_permission: None,
            })),
            None
        );
        pending.kind = GroupKind::Server;
        assert_eq!(pending.confirmed_channel_deletion(&Ok(())), None);
        pending.kind = GroupKind::Channel;
        pending.action = Action::Rename("New name".into());
        assert_eq!(pending.confirmed_channel_deletion(&Ok(())), None);
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
    fn catalogs_resolve_native_positional_and_explicit_ids() {
        assert_eq!(
            wire(request(GroupKind::Server, Action::Catalog)),
            "permissionlist"
        );
        let mut bytes = [0u8; 11];
        bytes[10] = PacketType::Command as u8;
        let header = InHeader::new(Direction::S2C, &bytes);
        let mut pending = Pending {
            handle: MessageHandle(55),
            kind: GroupKind::Server,
            group: 0,
            action: Action::Catalog,
            rows: Vec::new(),
            definitions: Vec::new(),
            next_permission_id: 1,
            directory_ids: HashSet::new(),
            members: BTreeMap::new(),
            reply: Some(oneshot::channel().0),
        };
        let message = InMessage::new(&header, br"notifypermissionlist group_id_end=0|group_id_end=2|permname=b_first permdesc=First\spermission|permname=i_second|permid=40 permname=b_explicit return_code=55").unwrap();
        pending.observe(&message);
        assert_eq!(
            pending
                .definitions
                .iter()
                .map(|p| (p.id, p.name.as_str(), p.description.as_deref()))
                .collect::<Vec<_>>(),
            vec![
                (1, "b_first", Some("First permission")),
                (2, "i_second", None),
                (40, "b_explicit", None)
            ]
        );
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
            definitions: Vec::new(),
            next_permission_id: 1,
            directory_ids: HashSet::new(),
            members: BTreeMap::new(),
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
