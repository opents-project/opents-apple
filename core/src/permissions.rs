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
    pub sets_effective_value: bool,
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

#[derive(Default, uniffi::Record)]
pub struct PermissionOverviewResponse {
    pub overview: Option<PermissionOverview>,
    pub error: Option<String>,
    pub denied: bool,
    pub missing_permission: Option<u32>,
}

use crate::PermissionDefinition;
use std::collections::{BTreeMap, HashMap};
use tsproto_types::PermissionType;

pub(crate) struct WireAssignment {
    pub id: u32,
    pub kind: PermissionType,
    pub id1: u64,
    pub id2: u64,
    pub value: i32,
    pub negated: bool,
    pub skip: bool,
}

#[derive(Default)]
pub(crate) struct OverviewRows(BTreeMap<u32, Vec<PermissionAssignment>>);

impl OverviewRows {
    pub fn push(&mut self, row: WireAssignment) {
        let source = match row.kind {
            PermissionType::ServerGroup => PermissionSource::ServerGroup { group_id: row.id1 },
            PermissionType::GlobalClient => PermissionSource::Client {
                client_db_id: row.id1,
            },
            PermissionType::Channel => PermissionSource::Channel {
                channel_id: row.id1,
            },
            PermissionType::ChannelGroup => PermissionSource::ChannelGroup {
                channel_id: row.id1,
                group_id: row.id2,
            },
            PermissionType::ChannelClient => PermissionSource::ChannelClient {
                channel_id: row.id1,
                client_db_id: row.id2,
            },
        };
        self.0
            .entry(row.id)
            .or_default()
            .push(PermissionAssignment {
                source,
                value: row.value,
                negated: row.negated,
                skip: row.skip,
                sets_effective_value: false,
            });
    }

    pub fn finish(self, client_db_id: u64, channel_id: u64) -> PermissionOverview {
        PermissionOverview {
            client_db_id,
            channel_id,
            permissions: self
                .0
                .into_iter()
                .map(|(id, assignments)| EffectivePermission {
                    id,
                    name: None,
                    effective_value: None,
                    assignments,
                })
                .collect(),
        }
    }
}

impl PermissionOverview {
    pub(crate) fn resolve(&mut self, catalog: &[PermissionDefinition]) {
        let names: HashMap<_, _> = catalog
            .iter()
            .map(|entry| (entry.id, entry.name.as_str()))
            .collect();
        let global_skip = catalog
            .iter()
            .find(|entry| entry.name == "b_client_skip_channelgroup_permissions")
            .and_then(|entry| {
                let Some(permission) = self
                    .permissions
                    .iter()
                    .find(|permission| permission.id == entry.id)
                else {
                    return Some(false);
                };
                let blocked = resolve_assignment(
                    &permission.assignments,
                    self.client_db_id,
                    self.channel_id,
                    Some(true),
                )?;
                let unblocked = resolve_assignment(
                    &permission.assignments,
                    self.client_db_id,
                    self.channel_id,
                    Some(false),
                )?;
                (blocked.0 == unblocked.0).then_some(blocked.0 != 0)
            });
        for permission in &mut self.permissions {
            permission.name = names.get(&permission.id).map(|name| (*name).to_owned());
            if let Some((value, source)) = resolve_assignment(
                &permission.assignments,
                self.client_db_id,
                self.channel_id,
                global_skip,
            ) {
                permission.effective_value = Some(value);
                if let Some(source) = source {
                    permission.assignments[source].sets_effective_value = true;
                }
            }
        }
    }
}

// TeamSpeak's server permissiondoc.txt defines five ordered tiers. Server groups merge
// using the maximum, or the minimum among Negated rows. Skip shields tiers 1–2 from
// tiers 3–4. A channel-client value can still override them.
fn resolve_assignment(
    rows: &[PermissionAssignment],
    database_id: u64,
    channel_id: u64,
    global_skip: Option<bool>,
) -> Option<(i32, Option<usize>)> {
    let mut tiers: [Vec<usize>; 5] = Default::default();
    for (index, row) in rows.iter().enumerate() {
        let tier = match row.source {
            PermissionSource::ServerGroup { .. } => 0,
            PermissionSource::Client { client_db_id } if client_db_id == database_id => 1,
            PermissionSource::Channel { channel_id: id } if id == channel_id => 2,
            // A single channel group row can describe a group inherited from a parent.
            PermissionSource::ChannelGroup { .. } => 3,
            PermissionSource::ChannelClient {
                channel_id: id,
                client_db_id,
            } if id == channel_id && client_db_id == database_id => 4,
            _ => return None,
        };
        if (tier != 0 && row.negated) || (tier >= 2 && row.skip) {
            return None;
        }
        tiers[tier].push(index);
    }
    let tier_value = |tier: &[usize]| {
        let &first = tier.first()?;
        let value = rows[first].value;
        tier.iter()
            .all(|&index| rows[index].value == value)
            .then_some((value, (tier.len() == 1).then_some(first)))
    };
    if !tiers[4].is_empty() {
        return tier_value(&tiers[4]);
    }
    let groups = &tiers[0];
    let server_value = groups
        .iter()
        .copied()
        .filter(|&index| rows[index].negated)
        .map(|index| rows[index].value)
        .min()
        .or_else(|| groups.iter().map(|&index| rows[index].value).max());
    let server_source = server_value.and_then(|value| {
        let negated = groups.iter().any(|&index| rows[index].negated);
        let mut matching = groups
            .iter()
            .copied()
            .filter(|&index| rows[index].value == value && rows[index].negated == negated);
        let first = matching.next()?;
        matching.next().is_none().then_some(first)
    });
    let base = if tiers[1].is_empty() {
        (server_value.unwrap_or(0), server_source)
    } else {
        tier_value(&tiers[1])?
    };
    let Some(channel_tier) = [&tiers[3], &tiers[2]]
        .into_iter()
        .find(|tier| !tier.is_empty())
    else {
        return (!rows.is_empty()).then_some(base);
    };
    // The published rule does not specify how mixed server-group Skip flags merge,
    // or whether a clear client flag cancels an earlier server-group Skip.
    if global_skip == Some(true)
        || (!tiers[1].is_empty() && tiers[1].iter().all(|&index| rows[index].skip))
        || (tiers[1].is_empty()
            && !groups.is_empty()
            && groups.iter().all(|&index| rows[index].skip))
    {
        return Some(base);
    }
    let channel = tier_value(channel_tier)?;
    if global_skip == Some(false) && tiers[..2].iter().flatten().all(|&index| !rows[index].skip) {
        return Some(channel);
    }
    (base.0 == channel.0).then_some((base.0, None))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assignment(
        source: PermissionSource,
        value: i32,
        negated: bool,
        skip: bool,
    ) -> PermissionAssignment {
        PermissionAssignment {
            source,
            value,
            negated,
            skip,
            sets_effective_value: false,
        }
    }

    #[test]
    fn member_permissions_resolve_documented_tiers_and_preserve_uncertainty() {
        let group = |group_id, value, negated, skip| {
            assignment(
                PermissionSource::ServerGroup { group_id },
                value,
                negated,
                skip,
            )
        };
        let client = |value, skip| {
            assignment(
                PermissionSource::Client { client_db_id: 902 },
                value,
                false,
                skip,
            )
        };
        let channel = assignment(
            PermissionSource::Channel { channel_id: 54 },
            10,
            false,
            false,
        );
        let channel_group = assignment(
            PermissionSource::ChannelGroup {
                channel_id: 13,
                group_id: 9,
            },
            15,
            false,
            false,
        );
        let mut rows = vec![
            group(6, 50, false, false),
            group(7, -1, true, false),
            group(8, -3, true, false),
        ];
        let resolve = |rows: &[PermissionAssignment], skip| resolve_assignment(rows, 902, 54, skip);
        assert_eq!(resolve(&rows[..1], None), Some((50, Some(0))));
        assert_eq!(resolve(&rows, None), Some((-3, Some(2))));
        rows.push(client(40, false));
        assert_eq!(resolve(&rows, None), Some((40, Some(3))));
        rows.extend([channel, channel_group]);
        assert_eq!(resolve(&rows, Some(false)), Some((15, Some(5))));
        assert_eq!(resolve(&rows, Some(true)), Some((40, Some(3))));
        assert_eq!(resolve(&rows, None), None);
        rows[3].skip = true;
        assert_eq!(resolve(&rows, None), Some((40, Some(3))));
        rows[3].skip = false;
        rows[0].skip = true;
        assert_eq!(resolve(&rows, Some(false)), None);
        rows[5].skip = true;
        assert_eq!(resolve(&rows, Some(false)), None);
    }

    #[test]
    fn member_permissions_use_the_server_catalog_for_global_skip() {
        let group = PermissionSource::ServerGroup { group_id: 6 };
        let channel = PermissionSource::Channel { channel_id: 54 };
        let mut overview = PermissionOverview {
            client_db_id: 902,
            channel_id: 54,
            permissions: vec![
                EffectivePermission {
                    id: 42,
                    name: None,
                    effective_value: None,
                    assignments: vec![assignment(group.clone(), 1, false, false)],
                },
                EffectivePermission {
                    id: 51,
                    name: None,
                    effective_value: None,
                    assignments: vec![
                        assignment(group, 50, false, false),
                        assignment(channel, 20, false, false),
                    ],
                },
            ],
        };
        overview.resolve(&[
            PermissionDefinition {
                id: 42,
                name: "b_client_skip_channelgroup_permissions".into(),
                description: None,
            },
            PermissionDefinition {
                id: 51,
                name: "i_client_talk_power".into(),
                description: None,
            },
        ]);
        let talk_power = &overview.permissions[1];
        assert_eq!(talk_power.name.as_deref(), Some("i_client_talk_power"));
        assert_eq!(talk_power.effective_value, Some(50));
        assert!(talk_power.assignments[0].sets_effective_value);
        assert!(!talk_power.assignments[1].sets_effective_value);
    }
}
