//! Read-only records shared by the native permission inspectors.
#[derive(Clone, uniffi::Enum)]
pub enum GroupKind {
    Server,
    Channel,
}

#[derive(Clone, uniffi::Record)]
pub struct ListedGroup {
    pub kind: GroupKind,
    pub id: u64,
    pub name: String,
}

#[derive(Clone, uniffi::Enum)]
pub enum PermissionSource {
    ServerGroup { group_id: u64 },
    Client { client_db_id: u64 },
    Channel { channel_id: u64 },
    ChannelGroup { channel_id: u64, group_id: u64 },
    ChannelClient { channel_id: u64, client_db_id: u64 },
}

#[derive(Clone, uniffi::Record)]
pub struct PermissionAssignment {
    pub source: PermissionSource,
    pub value: i32,
    pub negated: bool,
    pub skip: bool,
}

#[derive(Clone, uniffi::Record)]
pub struct EffectivePermission {
    pub id: u32,
    pub name: Option<String>,
    // A source assignment alone cannot establish the resolved value.
    pub effective_value: Option<i32>,
    pub assignments: Vec<PermissionAssignment>,
}

#[derive(Clone, uniffi::Record)]
pub struct PermissionOverview {
    pub client_db_id: u64,
    pub channel_id: u64,
    pub permissions: Vec<EffectivePermission>,
}
