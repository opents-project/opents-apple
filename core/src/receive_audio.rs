//! Per-talker Opus playout. All lengths are 48 kHz frames per channel.
use crate::voice::FRAME;
use audiopus::{
    coder::{Decoder, GenericCtl},
    packet, Channels, SampleRate,
};
use std::collections::VecDeque;
use tsproto_packets::packets::{CodecType, InAudioBuf};

pub(crate) enum ReceiveError {
    Late,
    Rejected,
}

#[derive(Default)]
pub(crate) struct Rendered {
    pub samples: usize,
    pub concealed_frames: usize,
    pub recovered_frames: usize,
}

struct Packet {
    wire: InAudioBuf,
    id: u16,
    frames: usize, // zero denotes a TS end-of-speech marker
}

pub(crate) struct Talker {
    decoder: Decoder,
    next: u16,
    packets: VecDeque<Packet>,
    pcm: Vec<f32>,
    packet_frames: usize,
    concealed: usize,
    ended: bool,
    recovery: Recovery,
}

impl Talker {
    pub(crate) fn new(id: u16) -> Result<Self, ReceiveError> {
        Ok(Self {
            decoder: Decoder::new(SampleRate::Hz48000, Channels::Stereo)
                .map_err(|_| ReceiveError::Rejected)?,
            next: id,
            packets: VecDeque::new(),
            pcm: Vec::new(),
            packet_frames: FRAME,
            concealed: 0,
            ended: false,
            recovery: Recovery::default(),
        })
    }

    pub(crate) fn push(&mut self, wire: InAudioBuf) -> Result<(), ReceiveError> {
        let audio = wire.data().data();
        if !matches!(audio.codec(), CodecType::OpusVoice | CodecType::OpusMusic) {
            return Err(ReceiveError::Rejected);
        }
        let id = audio.id();
        let ahead = id.wrapping_sub(self.next) as i16;
        if ahead < 0 {
            return Err(ReceiveError::Late);
        }
        if ahead > 50 || self.packets.len() >= 50 {
            return Err(ReceiveError::Rejected);
        }
        let frames = if audio.data().len() <= 1 {
            0
        } else {
            let payload = audio
                .data()
                .try_into()
                .map_err(|_| ReceiveError::Rejected)?;
            packet::nb_samples(payload, SampleRate::Hz48000).map_err(|_| ReceiveError::Rejected)?
        };
        let pos = self
            .packets
            .partition_point(|p| p.id.wrapping_sub(self.next) < ahead as u16);
        if self.packets.get(pos).is_some_and(|p| p.id == id) {
            return Err(ReceiveError::Rejected);
        }
        self.packets.insert(pos, Packet { id, wire, frames });
        Ok(())
    }

    fn decode(&mut self) -> usize {
        let ahead = self.packets.front().map(|p| p.id.wrapping_sub(self.next));
        // An empty queue can mean a late packet or the end of a transmission.
        // Retain the cursor while concealing so a late original can still play.
        // If a later sequence proves packets really were lost, account for the
        // time already concealed before requesting additional FEC or PLC.
        if let Some(gap) = ahead {
            let covered = usize::from(gap).min(self.concealed / self.packet_frames);
            self.next = self.next.wrapping_add(covered as u16);
            self.concealed -= covered * self.packet_frames;
        }
        // A confirmed sequence jump should not turn a long network outage into
        // seconds of fabricated speech before a packet that is already here.
        if let Some(first) = self.packets.front() {
            let limit = CONCEAL_LIMIT / self.packet_frames;
            if usize::from(first.id.wrapping_sub(self.next)) > limit {
                self.next = first.id.wrapping_sub(limit as u16);
            }
        }
        let gap = self.packets.front().map(|p| p.id.wrapping_sub(self.next));
        let exact = gap == Some(0);
        let packet = if exact {
            self.packets.pop_front()
        } else {
            None
        };
        if packet.as_ref().is_some_and(|p| p.frames == 0) {
            self.next = self.next.wrapping_add(1);
            self.ended = true;
            return 0;
        }
        let fec = gap == Some(1) && self.packets.front().is_some_and(|p| p.frames > 0);
        let source = if fec {
            self.packets.front()
        } else {
            packet.as_ref()
        };
        let payload = source.and_then(|p| p.wire.data().data().data().try_into().ok());
        let frames = packet.as_ref().map_or_else(
            || self.packet_frames.min(CONCEAL_LIMIT - self.concealed),
            |p| p.frames,
        );
        let start = self.pcm.len();
        self.pcm.resize(start + frames * 2, 0.0);
        let out = &mut self.pcm[start..];
        let result = self
            .decoder
            .decode_float(payload, out.try_into().unwrap(), fec);
        let concealment = !exact || result.is_err();
        let decoded = result
            .or_else(|_| {
                self.decoder
                    .decode_float(None, out.try_into().unwrap(), false)
            })
            .unwrap_or(frames);
        self.pcm.truncate(start + decoded * 2);
        if gap.is_some() {
            self.next = self.next.wrapping_add(1);
        }
        if exact {
            self.packet_frames = decoded.max(1);
            self.concealed = 0;
        } else if gap.is_none() {
            self.concealed += frames;
            // Three normal voice frames bridge a short loss. An explicit end
            // marker bypasses this tail, and an absent talker cannot loop forever.
            self.ended = self.concealed >= CONCEAL_LIMIT;
        }
        if concealment {
            decoded
        } else {
            0
        }
    }

    pub(crate) fn render(&mut self, out: &mut [f32; FRAME * 2]) -> Rendered {
        let mut result = Rendered::default();
        if self.ended && self.pcm.is_empty() {
            if let Some(first) = self.packets.front() {
                // Another talk spurt can already be queued beyond the end marker.
                if self.decoder.reset_state().is_err() {
                    self.packets.clear();
                    return result;
                }
                self.next = first.id;
                self.packet_frames = FRAME;
                self.concealed = 0;
                self.recovery = Recovery::default();
                self.ended = false;
            }
        }
        let available = self.pcm.len() / 2
            + self
                .packets
                .iter()
                .take_while(|p| p.frames != 0)
                .map(|p| p.frames)
                .sum::<usize>();
        let allowance = self.recovery.allowance(available);
        while self.pcm.len() < FRAME * 2 && !self.ended {
            result.concealed_frames += self.decode();
        }
        let frames = FRAME.min(self.pcm.len() / 2);
        let mut skip = 0;
        if frames == FRAME && allowance >= MIN_SHIFT {
            if let Some(candidate) = matching_period(&self.pcm[..FRAME * 2], allowance) {
                // Do not synthesize extra audio merely to accelerate. Only take
                // additional samples from contiguous packets already in hand.
                while self.pcm.len() / 2 < FRAME + candidate
                    && !self.ended
                    && self
                        .packets
                        .front()
                        .is_some_and(|p| p.id == self.next && p.frames > 0)
                {
                    result.concealed_frames += self.decode();
                }
                if self.pcm.len() / 2 >= FRAME + candidate {
                    skip = candidate;
                }
            }
        }
        if allowance >= MIN_SHIFT && skip == 0 {
            // Wait for fresh credit before retrying on a transient or a gap.
            self.recovery.credit = 0.0;
        }
        out[..frames * 2].copy_from_slice(&self.pcm[..frames * 2]);
        if skip != 0 {
            // Overlap matching waveform phases; use one offset and envelope for
            // both channels so stereo position is preserved.
            for i in 0..OVERLAP {
                let weight = i as f32 / (OVERLAP - 1) as f32;
                for side in 0..2 {
                    let index = 2 * (SPLICE + i) + side;
                    out[index] += (self.pcm[index + skip * 2] - out[index]) * weight;
                }
            }
            let tail = 2 * (SPLICE + OVERLAP);
            out[tail..].copy_from_slice(&self.pcm[tail + skip * 2..(FRAME + skip) * 2]);
            self.recovery.credit -= skip as f32;
        }
        self.pcm.drain(..(frames + skip) * 2);
        result.samples = frames * 2;
        result.recovered_frames = skip;
        result
    }

    pub(crate) fn finished(&self) -> bool {
        self.ended && self.pcm.is_empty() && self.packets.is_empty()
    }
}

const CONCEAL_LIMIT: usize = 3 * FRAME;
const SPLICE: usize = 192;
const OVERLAP: usize = 240;
const MIN_SHIFT: usize = 48;
const MAX_SHIFT: usize = 480;

/// Compare both channels without summing them (opposed stereo can cancel).
fn matching_period(pcm: &[f32], limit: usize) -> Option<usize> {
    // Leave isolated attacks alone: e.g. a click between two quiet windows
    // would otherwise appear to be a perfect splice.
    let mut total = 0.0_f32;
    let mut peak = 0.0_f32;
    for window in pcm[SPLICE * 2..(SPLICE + OVERLAP + MAX_SHIFT) * 2].chunks(96 * 2) {
        let power = window.iter().map(|s| s * s).sum::<f32>() / window.len() as f32;
        total += power;
        peak = peak.max(power);
    }
    if peak > 0.5 * total {
        return None;
    }
    let error_at = |shift: usize| {
        let mut error = 0.0;
        for i in (SPLICE..SPLICE + OVERLAP).step_by(3) {
            let n = i * 2;
            let m = (i + shift) * 2;
            error += (pcm[n] - pcm[m]).powi(2) + (pcm[n + 1] - pcm[m + 1]).powi(2);
        }
        error
    };
    let mut best = MIN_SHIFT;
    let mut best_error = f32::INFINITY;
    for shift in (MIN_SHIFT..=limit).step_by(4) {
        let error = error_at(shift);
        if error < best_error {
            best = shift;
            best_error = error;
        }
    }
    for shift in MIN_SHIFT.max(best - 3)..=limit.min(best + 3) {
        let error = error_at(shift);
        if error < best_error {
            best = shift;
            best_error = error;
        }
    }
    // If the remaining excess is shorter than a good period, leave that
    // fraction for a quieter frame instead of splicing out of phase.
    if limit < MAX_SHIFT && best_error > total * 3.0 {
        None
    } else {
        Some(best)
    }
}

#[derive(Default)]
struct Recovery {
    recent_extra: [usize; 8],
    cursor: usize,
    rate: f32,
    credit: f32,
}

impl Recovery {
    fn allowance(&mut self, available: usize) -> usize {
        // A burst that will drain on its own, or one long Opus packet, does
        // not warrant acceleration. Observe at least 160 ms of excess first.
        self.recent_extra[self.cursor] = available.saturating_sub(FRAME);
        self.cursor = (self.cursor + 1) % self.recent_extra.len();
        let extra = *self.recent_extra.iter().min().unwrap();
        if extra < MIN_SHIFT {
            self.rate = 0.0;
            self.credit = 0.0;
            return 0;
        }
        let target = (extra as f32 / 48_000.0).clamp(0.005, 0.05);
        self.rate += (target - self.rate).clamp(-0.0025, 0.0025);
        self.credit = (self.credit + self.rate * FRAME as f32).min(MAX_SHIFT as f32);
        let limit = extra.min(MAX_SHIFT);
        if self.credit >= limit as f32 {
            limit
        } else {
            0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use audiopus::{coder::Encoder, Application};
    use tsproto_packets::packets::{AudioData, Direction, OutAudio};

    fn packet(id: u16, bytes: &[u8]) -> InAudioBuf {
        let wire = OutAudio::new(&AudioData::S2C {
            id,
            from: 1,
            codec: CodecType::OpusMusic,
            data: bytes,
        });
        InAudioBuf::try_new(Direction::S2C, wire.into_vec()).unwrap()
    }

    #[test]
    fn short_opus_packets_wrap_and_next_spurt_survives_queued_end() {
        let enc = Encoder::new(SampleRate::Hz48000, Channels::Stereo, Application::Audio).unwrap();
        let mut talker = Talker::new(65534).ok().unwrap();
        let mut encoded = [0; 1275];
        for id in [65534, 65535, 0, 1, 2] {
            if id == 0 {
                assert!(talker.push(packet(id, &[])).is_ok());
            } else {
                let pcm: Vec<f32> = (0..FRAME / 2)
                    .flat_map(|i| {
                        let t = (i as f32 * std::f32::consts::TAU / 48.0).sin();
                        [0.35 * t, 0.15 * t]
                    })
                    .collect();
                let len = enc.encode_float(&pcm, &mut encoded).unwrap();
                assert!(talker.push(packet(id, &encoded[..len])).is_ok());
            }
        }
        let mut out = [0.0; FRAME * 2];
        assert_eq!(talker.render(&mut out).samples, FRAME * 2);
        assert_eq!(talker.render(&mut out).samples, 0);
        assert!(!talker.finished());
        assert_eq!(talker.render(&mut out).samples, FRAME * 2);
        assert!(out.iter().any(|v| v.abs() > 0.1));
    }

    #[test]
    fn sustained_backlog_ramps_up_but_short_bursts_do_not_accelerate() {
        let mut control = Recovery::default();
        for tick in 0..90 {
            // Three 20 ms packets arrive together every 60 ms.
            assert_eq!(control.allowance((3 - tick % 3) * FRAME), 0);
        }
        let mut previous = 0.0;
        for _ in 0..80 {
            control.allowance(11 * FRAME);
            assert!(control.rate >= previous && control.rate - previous <= 0.00251);
            assert!(control.rate <= 0.05);
            previous = control.rate;
        }
        assert_eq!(control.rate, 0.05);
        let mut accumulated = 0;
        for _ in 0..50 {
            let available = control.allowance(11 * FRAME);
            if available >= 120 {
                accumulated += 120;
                control.credit -= 120.0;
            }
        }
        assert!(accumulated <= 2_400 + MAX_SHIFT);
        assert_eq!(control.allowance(FRAME), 0);
        assert_eq!(control.credit, 0.0);
    }

    #[test]
    fn stereo_splice_matches_opposed_channels_and_defers_at_impulses() {
        let mut pcm = [0.0; FRAME * 2];
        for (i, lr) in pcm.chunks_exact_mut(2).enumerate() {
            let value = (i as f32 * std::f32::consts::TAU / 120.0).sin();
            lr.copy_from_slice(&[value, -value]);
        }
        let period = matching_period(&pcm, MAX_SHIFT).unwrap();
        assert_eq!(period % 120, 0);
        pcm.fill(0.0);
        pcm[2 * 500 + 1] = 0.9;
        assert_eq!(matching_period(&pcm, MAX_SHIFT), None);
    }
}
