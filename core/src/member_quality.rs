//! Demand comes from visible member rows. At most one remote query is sent per
//! transport statistics tick, even when a large channel becomes visible at once.
use std::collections::HashMap;
use std::time::{Duration, Instant};
use tsclientlib::events::{Event, PropertyId};
use tsclientlib::prelude::*;
use tsclientlib::{ClientId, Connection, MessageHandle};

use crate::ConnectionQuality;

struct Entry {
    visible: Instant,
    next_request: Option<Instant>,
    pending: Option<MessageHandle>,
    sample: Option<(Instant, ConnectionQuality)>,
}

#[derive(Default)]
pub(crate) struct MemberQuality {
    rows: HashMap<(u16, u64), Entry>,
}

impl MemberQuality {
    pub fn read(&mut self, id: u16, db: u64, now: Instant) -> Option<ConnectionQuality> {
        let row = self.rows.entry((id, db)).or_insert(Entry {
            visible: now,
            next_request: None,
            pending: None,
            sample: None,
        });
        row.visible = now;
        row.sample
            .filter(|(when, _)| now.duration_since(*when) < Duration::from_secs(30))
            .map(|(_, sample)| sample)
    }

    pub fn poll(&mut self, con: &mut Connection, now: Instant) {
        self.rows
            .retain(|_, row| now.duration_since(row.visible) < Duration::from_secs(3));
        let Some((&(id, db), row)) = self
            .rows
            .iter_mut()
            .filter(|(_, row)| row.next_request.is_none_or(|when| when <= now))
            .min_by_key(|(_, row)| row.next_request)
        else {
            return;
        };
        let Ok(book) = con.get_state() else { return };
        let Some(client) = book
            .clients
            .get(&ClientId(id))
            .filter(|c| c.id != book.own_client && c.database_id.0 == db)
        else {
            self.rows.remove(&(id, db));
            return;
        };
        row.next_request = Some(now + Duration::from_secs(5));
        row.pending = client.connection_info().send_with_result(con).ok();
    }

    pub fn reply(&mut self, handle: MessageHandle, failed: bool, now: Instant) {
        if let Some(row) = self.rows.values_mut().find(|r| r.pending == Some(handle)) {
            row.pending = None;
            if failed {
                row.sample = None;
                row.next_request = Some(now + Duration::from_secs(60));
            }
        }
    }

    pub fn observe(&mut self, con: &Connection, events: &[Event], now: Instant) {
        let Ok(book) = con.get_state() else { return };
        for event in events {
            match event {
                Event::PropertyRemoved {
                    id: PropertyId::Client(id),
                    ..
                } => {
                    self.rows.retain(|(clid, _), _| *clid != id.0);
                }
                Event::PropertyChanged {
                    id: PropertyId::ConnectionClientData(id),
                    ..
                } => {
                    let Some(client) = book.clients.get(id) else {
                        continue;
                    };
                    let Some(row) = self.rows.get_mut(&(id.0, client.database_id.0)) else {
                        continue;
                    };
                    let Some(data) = &client.connection_data else {
                        continue;
                    };
                    let sum =
                        |speech: Option<u64>, keepalive: Option<u64>, control: Option<u64>| {
                            speech?.checked_add(keepalive?)?.checked_add(control?)
                        };
                    row.sample = Some((
                        now,
                        ConnectionQuality {
                            ping_ms: data.ping.map(|v| v.as_seconds_f64() * 1000.0),
                            deviation_ms: data.ping_deviation.map(|v| v.as_seconds_f64() * 1000.0),
                            incoming_loss: data.server_to_client_packetloss_total,
                            outgoing_loss: Some(data.client_to_server_packetloss_total),
                            incoming_bytes_per_second: sum(
                                data.bandwidth_received_last_second_speech,
                                data.bandwidth_received_last_second_keepalive,
                                data.bandwidth_received_last_second_control,
                            ),
                            outgoing_bytes_per_second: sum(
                                data.bandwidth_sent_last_second_speech,
                                data.bandwidth_sent_last_second_keepalive,
                                data.bandwidth_sent_last_second_control,
                            ),
                        },
                    ));
                }
                _ => {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn samples_are_scoped_to_the_member_expire_and_clear_on_denial() {
        let now = Instant::now();
        let mut cache = MemberQuality::default();
        assert!(cache.read(12, 90, now).is_none());
        let row = cache.rows.get_mut(&(12, 90)).unwrap();
        row.sample = Some((
            now,
            ConnectionQuality {
                ping_ms: Some(42.0),
                deviation_ms: None,
                incoming_loss: None,
                outgoing_loss: Some(0.01),
                incoming_bytes_per_second: None,
                outgoing_bytes_per_second: None,
            },
        ));
        row.pending = Some(MessageHandle(123));
        assert!(cache.read(12, 91, now).is_none());
        assert_eq!(cache.read(12, 90, now).unwrap().ping_ms, Some(42.0));
        assert!(cache.read(12, 90, now + Duration::from_secs(30)).is_none());
        cache.reply(MessageHandle(123), true, now);
        assert!(cache.read(12, 90, now).is_none());
        assert!(cache.rows[&(12, 90)].next_request.unwrap() > now);
    }
}
