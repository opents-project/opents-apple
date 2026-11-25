//! The wire uses Opus. The Apple adapter supplies mono or stereo 48 kHz PCM in 20 ms
//! frames and pulls interleaved stereo PCM from the per-speaker jitter buffers.
use crate::receive_audio::{ReceiveError, Talker};
use audiopus::{coder::Encoder, Application, Channels, SampleRate};
use std::collections::{hash_map::Entry, HashMap};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex,
};
use std::time::Instant;
use tokio::sync::{mpsc, watch};
use tsclientlib::ClientId;
use tsproto_packets::packets::{AudioData, CodecType, InAudioBuf, OutAudio, OutPacket};

pub const FRAME: usize = 960;

#[derive(Clone, Copy, Default)]
pub(crate) struct DeviceState {
    pub microphone: bool,
    pub output: bool,
    pub mic_muted: bool,
    pub output_muted: bool,
}

impl DeviceState {
    pub fn can_capture(self) -> bool {
        self.microphone && !self.mic_muted
    }
}

#[derive(Clone, Copy, PartialEq, uniffi::Record)]
pub struct SpeakerMix {
    pub gain: f32,
    pub pan: f32,
    pub muted: bool,
}

impl Default for SpeakerMix {
    fn default() -> Self {
        Self {
            gain: 1.0,
            pan: 0.0,
            muted: false,
        }
    }
}

impl SpeakerMix {
    fn add_to(self, samples: &[f32], output: &mut [f32]) {
        if self.muted {
            return;
        }
        // Stereo balance keeps the original Opus stereo image at the centre.
        let left = self.gain * (1.0 - self.pan.max(0.0));
        let right = self.gain * (1.0 + self.pan.min(0.0));
        for (dst, src) in output.chunks_exact_mut(2).zip(samples.chunks_exact(2)) {
            dst[0] += src[0] * left;
            dst[1] += src[1] * right;
        }
    }
}

#[derive(Clone, Copy, Default, uniffi::Record)]
pub struct VoiceDiagnostics {
    pub rx_packets: u64,
    pub rx_gap_slots: u64,
    pub rx_gap_fills: u64,
    pub rx_late: u64,
    pub rx_other_rejected: u64,
    pub rx_longest_interval_ms: u64,
    pub rx_concealed_frames: u64,
    pub rx_recovered_frames: u64,
    pub tx_enqueued: u64,
    pub tx_full: u64,
    pub tx_sent: u64,
}

// A gap is provisional. Reordering can fill it; it does not prove wire loss.
// Track only one talk spurt per source, with bounded history across u16 wrap.
struct Arrival {
    newest: u16,
    missing: Vec<u16>,
    last: Instant,
}

impl Arrival {
    fn record(&mut self, id: u16, now: Instant, stats: &mut VoiceDiagnostics) {
        stats.rx_longest_interval_ms = stats
            .rx_longest_interval_ms
            .max(now.duration_since(self.last).as_millis() as u64);
        self.last = now;
        let forward = id.wrapping_sub(self.newest);
        if forward > 0 && forward < 0x8000 {
            stats.rx_gap_slots += u64::from(forward - 1);
            if forward > 1 || !self.missing.is_empty() {
                // The receive queue accepts at most 50 packets ahead of its playhead.
                // Keep a little more history for reporting a rejected late fill.
                const WINDOW: u16 = 64;
                self.missing.retain(|slot| id.wrapping_sub(*slot) <= WINDOW);
                self.missing
                    .extend((1..=WINDOW.min(forward - 1)).map(|back| id.wrapping_sub(back)));
            }
            self.newest = id;
        } else {
            self.fill_gap(id, stats);
        }
    }

    fn fill_gap(&mut self, id: u16, stats: &mut VoiceDiagnostics) {
        if let Some(index) = self.missing.iter().position(|slot| *slot == id) {
            self.missing.swap_remove(index);
            stats.rx_gap_fills += 1;
        }
    }
}

#[derive(Default)]
struct Playback {
    // Transport IDs distinguish simultaneous connections using one TS identity.
    streams: HashMap<(ClientId, u64), Talker>,
    controls: HashMap<u64, SpeakerMix>,
    arrivals: HashMap<(ClientId, u64), Arrival>,
    stats: VoiceDiagnostics,
}

impl Playback {
    fn render(&mut self) -> Vec<f32> {
        let mut output = vec![0.0; FRAME * 2];
        let mut samples = [0.0; FRAME * 2];
        self.streams.retain(|source, talker| {
            let rendered = talker.render(&mut samples);
            self.stats.rx_concealed_frames += rendered.concealed_frames as u64;
            self.stats.rx_recovered_frames += rendered.recovered_frames as u64;
            self.controls
                .get(&source.1)
                .copied()
                .unwrap_or_default()
                .add_to(&samples[..rendered.samples], &mut output);
            if talker.finished() {
                self.arrivals.remove(source);
                false
            } else {
                true
            }
        });
        for sample in &mut output {
            *sample = sample.clamp(-1.0, 1.0);
        }
        output
    }
}

#[derive(Clone, Copy, uniffi::Record)]
pub struct ConnectionQuality {
    pub ping_ms: Option<f64>,
    pub deviation_ms: f64,
    pub incoming_loss: Option<f32>,
    pub incoming_bytes_per_second: u64,
    pub outgoing_bytes_per_second: u64,
}

#[derive(uniffi::Object)]
pub struct Voice {
    quality: Mutex<Option<(Instant, ConnectionQuality)>>,
    capture: mpsc::Sender<CapturedFrame>,
    capture_epoch: AtomicU64,
    tx_enqueued: AtomicU64,
    tx_full: AtomicU64,
    tx_sent: AtomicU64,
    enabled: watch::Sender<DeviceState>,
    playback: Mutex<Playback>,
}

pub(crate) struct AudioIo {
    pub capture: mpsc::Receiver<CapturedFrame>,
    route: Option<(u64, CodecType)>,
    epoch: u64,
    encoder: Option<Encoder>,
    pub enabled: watch::Receiver<DeviceState>,
    pub voice: Arc<Voice>,
}

pub(crate) struct CapturedFrame {
    epoch: u64,
    samples: Vec<f32>,
}

impl AudioIo {
    pub(crate) fn set_channel(&mut self, route: Option<(u64, CodecType)>) -> Result<bool, String> {
        if route == self.route {
            return Ok(false);
        }
        let encoder = match route.map(|(_, codec)| codec) {
            Some(CodecType::OpusVoice) => Some(encoder()?),
            Some(CodecType::OpusMusic) => Some(
                Encoder::new(SampleRate::Hz48000, Channels::Stereo, Application::Audio)
                    .map_err(|e| e.to_string())?,
            ),
            Some(_) => return Err("Unsupported audio codec".into()),
            None => None,
        };
        self.epoch += 1;
        self.voice.capture_epoch.store(
            if route.is_some() { self.epoch } else { 0 },
            Ordering::Release,
        );
        self.route = route;
        self.encoder = encoder;
        Ok(true)
    }

    pub(crate) fn packet(
        &self,
        frame: CapturedFrame,
    ) -> Result<Option<(CodecType, OutPacket)>, String> {
        let (Some((_, codec)), Some(encoder)) = (self.route, &self.encoder) else {
            return Ok(None);
        };
        if frame.epoch != self.epoch || !self.enabled.borrow().can_capture() {
            return Ok(None);
        }
        let samples = match (codec, frame.samples.len()) {
            (CodecType::OpusVoice, n) if n == FRAME * 2 => frame
                .samples
                .chunks_exact(2)
                .map(|lr| 0.5 * (lr[0] + lr[1]))
                .collect(),
            (CodecType::OpusMusic, FRAME) => frame.samples.iter().flat_map(|s| [*s, *s]).collect(),
            _ => frame.samples,
        };
        Ok(Some((codec, encode(encoder, &samples, codec)?)))
    }
}

impl Voice {
    pub(crate) fn pair() -> AudioIo {
        let (capture, frames) = mpsc::channel(4);
        let (enabled, changes) = watch::channel(DeviceState::default());
        AudioIo {
            capture: frames,
            route: None,
            epoch: 0,
            encoder: None,
            enabled: changes,
            voice: Arc::new(Self {
                capture,
                quality: Mutex::default(),
                capture_epoch: AtomicU64::new(0),
                tx_enqueued: AtomicU64::new(0),
                tx_full: AtomicU64::new(0),
                tx_sent: AtomicU64::new(0),
                enabled,
                playback: Mutex::default(),
            }),
        }
    }

    pub(crate) fn update_quality(&self, stats: &tsclientlib::ConnectionStats) {
        use tsclientlib::PacketStat::*;
        let bytes = stats.get_last_second_bytes();
        let sum = |types: [tsclientlib::PacketStat; 3]| {
            types
                .into_iter()
                .map(|kind| u64::from(bytes[kind as usize]))
                .sum::<u64>()
        };
        let incoming = sum([InSpeech, InKeepalive, InControl]);
        let quality = ConnectionQuality {
            ping_ms: (!stats.rtt.is_zero()).then(|| stats.rtt.as_secs_f64() * 1000.0),
            deviation_ms: stats.rtt_dev.as_secs_f64() * 1000.0,
            incoming_loss: (incoming > 0).then(|| stats.get_packetloss_s2c_total()),
            incoming_bytes_per_second: incoming,
            outgoing_bytes_per_second: sum([OutSpeech, OutKeepalive, OutControl]),
        };
        *self.quality.lock().unwrap() = Some((Instant::now(), quality));
    }

    pub(crate) fn receive(&self, packet: InAudioBuf, database_id: u64) {
        let mut playback = self.playback.lock().unwrap();
        let devices = *self.enabled.borrow();
        if !devices.output || devices.output_muted {
            return;
        }
        let from = match packet.data().data() {
            AudioData::S2C { from, .. } | AudioData::S2CWhisper { from, .. } => *from,
            _ => return,
        };
        let source = (ClientId(from), database_id);
        let id = packet.data().data().id();
        let end = packet.data().data().data().len() <= 1;
        let now = Instant::now();
        let playback = &mut *playback;
        let result = match playback.streams.entry(source) {
            Entry::Occupied(mut entry) => entry.get_mut().push(packet),
            Entry::Vacant(_) if end => Ok(()),
            Entry::Vacant(entry) => Talker::new(id).and_then(|mut talker| {
                talker.push(packet)?;
                entry.insert(talker);
                Ok(())
            }),
        };
        if !end {
            playback.stats.rx_packets += 1;
        }
        match result {
            Ok(_) if end => {
                playback.arrivals.remove(&source);
            }
            Ok(_) => {
                if let Some(arrival) = playback.arrivals.get_mut(&source) {
                    arrival.record(id, now, &mut playback.stats);
                } else {
                    playback.arrivals.insert(
                        source,
                        Arrival {
                            newest: id,
                            missing: Vec::new(),
                            last: now,
                        },
                    );
                }
            }
            Err(ReceiveError::Late) => {
                playback.stats.rx_late += 1;
                if !end {
                    if let Some(arrival) = playback.arrivals.get_mut(&source) {
                        arrival.fill_gap(id, &mut playback.stats);
                    }
                }
            }
            Err(_) => playback.stats.rx_other_rejected += 1,
        }
    }

    pub(crate) fn audio_sent(&self) {
        self.tx_sent.fetch_add(1, Ordering::Relaxed);
    }
}

#[uniffi::export]
impl Voice {
    pub fn set_devices(&self, microphone: bool, output: bool, mic_muted: bool, output_muted: bool) {
        self.enabled.send_replace(DeviceState {
            microphone,
            output,
            mic_muted,
            output_muted,
        });
        if !output || output_muted {
            let mut playback = self.playback.lock().unwrap();
            playback.streams.clear();
            playback.arrivals.clear();
        }
    }

    pub fn submit_capture(&self, samples: Vec<f32>) {
        if samples.len() == FRAME {
            self.submit_pcm(self.capture_epoch(), samples);
        }
    }

    pub fn capture_epoch(&self) -> u64 {
        self.capture_epoch.load(Ordering::Acquire)
    }

    pub fn submit_pcm(&self, epoch: u64, samples: Vec<f32>) {
        if epoch != 0
            && epoch == self.capture_epoch()
            && (samples.len() == FRAME || samples.len() == 2 * FRAME)
            && self.enabled.borrow().can_capture()
        {
            match self.capture.try_send(CapturedFrame { epoch, samples }) {
                Ok(()) => {
                    self.tx_enqueued.fetch_add(1, Ordering::Relaxed);
                }
                Err(mpsc::error::TrySendError::Full(_)) => {
                    self.tx_full.fetch_add(1, Ordering::Relaxed);
                }
                Err(mpsc::error::TrySendError::Closed(_)) => {}
            }
        }
    }

    pub fn connection_quality(&self) -> Option<ConnectionQuality> {
        self.quality
            .lock()
            .unwrap()
            .as_ref()
            .filter(|(when, _)| when.elapsed().as_secs() < 3)
            .map(|(_, quality)| *quality)
    }

    pub fn diagnostics(&self) -> VoiceDiagnostics {
        VoiceDiagnostics {
            tx_enqueued: self.tx_enqueued.load(Ordering::Relaxed),
            tx_full: self.tx_full.load(Ordering::Relaxed),
            tx_sent: self.tx_sent.load(Ordering::Relaxed),
            ..self.playback.lock().unwrap().stats
        }
    }

    pub fn speaker_mix(&self, database_id: u64) -> SpeakerMix {
        self.playback
            .lock()
            .unwrap()
            .controls
            .get(&database_id)
            .copied()
            .unwrap_or_default()
    }

    pub fn set_speaker_mix(&self, database_id: u64, mix: SpeakerMix) {
        if database_id == 0 || !mix.gain.is_finite() || !mix.pan.is_finite() {
            return;
        }
        let mix = SpeakerMix {
            gain: mix.gain.clamp(0.0, 2.0),
            pan: mix.pan.clamp(-1.0, 1.0),
            muted: mix.muted,
        };
        let mut playback = self.playback.lock().unwrap();
        if mix == SpeakerMix::default() {
            playback.controls.remove(&database_id);
        } else {
            playback.controls.insert(database_id, mix);
        }
    }

    pub fn playback_frame(&self) -> Vec<f32> {
        self.playback.lock().unwrap().render()
    }
}

pub(crate) fn encoder() -> Result<Encoder, String> {
    Encoder::new(SampleRate::Hz48000, Channels::Mono, Application::Voip).map_err(|e| e.to_string())
}

pub(crate) fn encode(
    encoder: &Encoder,
    samples: &[f32],
    codec: CodecType,
) -> Result<OutPacket, String> {
    let mut encoded = [0u8; 1275];
    let len = encoder
        .encode_float(samples, &mut encoded)
        .map_err(|e| e.to_string())?;
    Ok(OutAudio::new(&AudioData::C2S {
        id: 0,
        codec,
        data: &encoded[..len],
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tsproto_packets::packets::Direction;

    #[test]
    fn pcm_balance_preserves_stereo_at_center_and_scales_each_side() {
        let input = [0.25, -0.5, -0.25, 0.5];
        for (gain, pan, expected) in [
            (1.0, 0.0, input),
            (2.0, -1.0, [0.5, 0.0, -0.5, 0.0]),
            (0.5, 1.0, [0.0, -0.25, 0.0, 0.25]),
            (1.0, 0.5, [0.125, -0.5, -0.125, 0.5]),
            (0.0, 0.0, [0.0; 4]),
        ] {
            let mut out = [0.0; 4];
            SpeakerMix {
                gain,
                pan,
                muted: false,
            }
            .add_to(&input, &mut out);
            assert_eq!(out, expected);
        }
    }

    fn tone_packet(enc: &Encoder, id: u16, from: u16, hz: f32) -> Vec<u8> {
        let samples: Vec<_> = (0..FRAME)
            .map(|i| {
                let t = (usize::from(id) * FRAME + i) as f32 / 48000.0;
                (t * std::f32::consts::TAU * hz).sin() * 0.95
            })
            .collect();
        let packet = encode(enc, &samples, CodecType::OpusVoice).unwrap();
        let source = InAudioBuf::try_new(Direction::C2S, packet.into_vec()).unwrap();
        OutAudio::new(&AudioData::S2C {
            id,
            from,
            codec: CodecType::OpusVoice,
            data: source.data().data().data(),
        })
        .into_vec()
    }

    fn deliver(voice: &Voice, packet: Vec<u8>, db_id: u64) {
        voice.receive(InAudioBuf::try_new(Direction::S2C, packet).unwrap(), db_id)
    }

    fn channel_rms(frame: &[f32], channel: usize) -> f64 {
        let mut power = 0.0_f64;
        let mut count = 0;
        for &sample in frame.iter().skip(channel).step_by(2) {
            power += f64::from(sample).powi(2);
            count += 1;
        }
        (power / count as f64).sqrt()
    }

    fn measured_frequency(frames: &[Vec<f32>], channel: usize) -> f64 {
        let mut crossings = 0usize;
        let mut previous = frames[0][channel];
        for frame in frames {
            for &sample in frame.iter().skip(channel).step_by(2) {
                if previous < 0.0 && sample >= 0.0 {
                    crossings += 1;
                }
                previous = sample;
            }
        }
        crossings as f64 * 48_000.0 / (frames.len() * FRAME) as f64
    }

    fn marker_onset(frames: &[Vec<f32>], channel: usize, from_tick: usize) -> usize {
        const WINDOW: usize = 240; // 5 ms, below the 10 ms phase-period tolerance.
        const STEP: usize = 24;
        let samples: Vec<_> = frames
            .iter()
            .flat_map(|frame| frame.iter().skip(channel).step_by(2).copied())
            .collect();
        let search_start = from_tick * FRAME - 10 * FRAME;
        let search_end = (from_tick + 10) * FRAME;
        let mut start = search_start;
        while start + WINDOW <= search_end {
            let mut re = 0.0_f64;
            let mut im = 0.0_f64;
            for (i, &sample) in samples[start..start + WINDOW].iter().enumerate() {
                let phase = i as f64 * std::f64::consts::TAU * 2_000.0 / 48_000.0;
                re += f64::from(sample) * phase.cos();
                im += f64::from(sample) * phase.sin();
            }
            let strength = 2.0 * re.hypot(im) / WINDOW as f64;
            if strength > 0.2 {
                return start;
            }
            start += STEP;
        }
        panic!("2 kHz marker not found near tick {from_tick}")
    }

    #[test]
    fn arrival_diagnostics_distinguish_reordering_missing_and_late_packets() {
        let io = Voice::pair();
        io.voice.set_devices(false, true, false, false);
        let enc = encoder().unwrap();
        for id in [100, 102] {
            deliver(&io.voice, tone_packet(&enc, id, 7, 440.0), 10);
        }
        assert_eq!(io.voice.diagnostics().rx_gap_slots, 1);
        deliver(&io.voice, tone_packet(&enc, 101, 7, 440.0), 10);
        assert_eq!(io.voice.diagnostics().rx_gap_fills, 1);
        deliver(&io.voice, tone_packet(&enc, 104, 7, 440.0), 10);
        for _ in 0..5 {
            io.voice.playback_frame();
        }
        let before = io.voice.diagnostics();
        assert_eq!(
            (before.rx_gap_slots, before.rx_gap_fills, before.rx_late),
            (2, 1, 0)
        );
        deliver(&io.voice, tone_packet(&enc, 103, 7, 440.0), 10);
        let after = io.voice.diagnostics();
        assert_eq!(
            (after.rx_packets, after.rx_gap_fills, after.rx_late),
            (5, 2, 1)
        );
        assert_eq!((after.tx_full, after.rx_other_rejected), (0, 0));
        // Simultaneous source, wrap-around, and a new talk spurt after mute.
        for id in [65534, 0, 65535] {
            deliver(&io.voice, tone_packet(&enc, id, 8, 440.0), 11);
        }
        assert_eq!(
            (
                io.voice.diagnostics().rx_gap_slots,
                io.voice.diagnostics().rx_gap_fills
            ),
            (3, 3)
        );
        io.voice.set_devices(false, false, false, true);
        io.voice.set_devices(false, true, false, false);
        deliver(&io.voice, tone_packet(&enc, 220, 7, 440.0), 10);
        assert_eq!(io.voice.diagnostics().rx_gap_slots, 3);
    }

    #[test]
    fn receive_recovers_after_two_missing_ticks_without_delaying_other_speaker() {
        const TICKS: u16 = 250; // 5 s at 20 ms per playback tick.
        const MARKER_TICK: u16 = 200;
        const LONG_GAP_TICK: u16 = 220;
        let normal = Voice::pair();
        let delayed = Voice::pair();
        for voice in [&normal.voice, &delayed.voice] {
            voice.set_devices(false, true, false, false);
            voice.set_speaker_mix(
                10,
                SpeakerMix {
                    pan: -1.0,
                    ..Default::default()
                },
            );
            voice.set_speaker_mix(
                11,
                SpeakerMix {
                    pan: 1.0,
                    ..Default::default()
                },
            );
        }
        let (a, b) = (encoder().unwrap(), encoder().unwrap());
        let mut held = [None, None];
        let mut normal_frames = Vec::with_capacity(usize::from(TICKS));
        let mut delayed_frames = Vec::with_capacity(usize::from(TICKS));
        let mut short_gap_nonzero = 0;
        let mut prolonged_nonzero = 0;
        let mut recovered_ms = Vec::new();

        for id in 0..TICKS {
            let hz = if id == MARKER_TICK { 2_000.0 } else { 440.0 };
            let delayed_a_packet = tone_packet(&a, id, 7, hz);
            let b_packet = tone_packet(&b, id, 8, hz);
            deliver(&normal.voice, delayed_a_packet.clone(), 10);
            deliver(&normal.voice, b_packet.clone(), 11);
            deliver(&delayed.voice, b_packet, 11);

            match id {
                40 | 41 => held[usize::from(id - 40)] = Some(delayed_a_packet),
                42 => {
                    deliver(&delayed.voice, held[0].take().unwrap(), 10);
                    deliver(&delayed.voice, held[1].take().unwrap(), 10);
                    deliver(&delayed.voice, delayed_a_packet, 10);
                }
                LONG_GAP_TICK.. => {}
                _ => deliver(&delayed.voice, delayed_a_packet, 10),
            }

            normal_frames.push(normal.voice.playback_frame());
            let delayed_frame = delayed.voice.playback_frame();
            if (40..42).contains(&id) && channel_rms(&delayed_frame, 0) >= 0.001 {
                short_gap_nonzero += 1;
            }
            if id >= LONG_GAP_TICK && channel_rms(&delayed_frame, 0) >= 0.001 {
                prolonged_nonzero += 1;
            }
            assert!(delayed_frame.iter().skip(1).step_by(2).eq(normal_frames
                .last()
                .unwrap()
                .iter()
                .skip(1)
                .step_by(2)));
            if matches!(id, 42 | 67 | 92 | 142 | 199) {
                recovered_ms.push(delayed.voice.diagnostics().rx_recovered_frames as f64 / 48.0);
            }
            delayed_frames.push(delayed_frame);
        }

        let normal_a_marker = marker_onset(&normal_frames, 0, usize::from(MARKER_TICK));
        let normal_b_marker = marker_onset(&normal_frames, 1, usize::from(MARKER_TICK));
        let delayed_a_marker = marker_onset(&delayed_frames, 0, usize::from(MARKER_TICK));
        let delayed_b_marker = marker_onset(&delayed_frames, 1, usize::from(MARKER_TICK));
        let baseline_skew = normal_a_marker as isize - normal_b_marker as isize;
        let recovered_skew = delayed_a_marker as isize - delayed_b_marker as isize;
        let recovery_delay_samples = recovered_skew - baseline_skew;
        let recovered_hz = measured_frequency(&delayed_frames[60..190], 0);
        let other_hz = measured_frequency(&delayed_frames[60..190], 1);
        let prolonged_tail_silent = delayed_frames[240..]
            .iter()
            .all(|frame| channel_rms(frame, 0) < 0.001);
        let other_marker_shift = delayed_b_marker as isize - normal_b_marker as isize;

        eprintln!(
            "gap PLC={short_gap_nonzero}/2 frames, marker recovery delay={recovery_delay_samples} samples ({:.2} ms), other marker shift={other_marker_shift} samples, recovered={recovered_hz:.2} Hz, other={other_hz:.2} Hz, long-gap nonzero={prolonged_nonzero}/30, final silence={prolonged_tail_silent}",
            recovery_delay_samples as f64 * 1000.0 / 48_000.0
        );
        eprintln!("Recovered ms at 0, 0.5, 1, 2 and 3.14 seconds: {recovered_ms:?}");
        assert_eq!(short_gap_nonzero, 2);
        assert_eq!(recovered_ms[0], 0.0);
        assert!(recovered_ms.windows(2).all(|step| step[0] <= step[1]));
        assert!(0.0 < recovered_ms[2] && recovered_ms[2] < recovered_ms[3]);
        assert!((30.0..=40.0).contains(&recovered_ms[4]));
        assert_eq!(normal.voice.diagnostics().rx_recovered_frames, 0);
        assert!(recovery_delay_samples.abs() <= 480);
        assert!(
            other_marker_shift.abs() <= 480,
            "other stream marker shifted by {other_marker_shift} samples"
        );
        assert!(
            (430.0..=450.0).contains(&recovered_hz),
            "{recovered_hz:.2} Hz"
        );
        assert!((430.0..=450.0).contains(&other_hz), "{other_hz:.2} Hz");
        assert!(prolonged_nonzero > 0 && prolonged_nonzero < 30);
        assert!(prolonged_tail_silent);
    }

    #[test]
    fn receive_tone_is_stable_for_uniform_and_three_packet_bursts() {
        // This is a deterministic offline comparison: each case receives the same
        // ordered Opus stream and renders one frame per packet. It does not model
        // wall-clock network jitter or a real 20 ms audio callback.
        fn measure(batch: u16) -> (f64, usize, usize, VoiceDiagnostics) {
            const FRAMES: u16 = 660;
            const WARMUP: u16 = 60;
            let io = Voice::pair();
            io.voice.set_devices(false, true, false, false);
            let enc = encoder().unwrap();
            let mut crossings = 0;
            let mut previous = 0.0;
            let mut silent_frames = 0;
            let mut clipped_samples = 0;
            for first in (0..FRAMES).step_by(usize::from(batch)) {
                for id in first..first + batch {
                    deliver(&io.voice, tone_packet(&enc, id, 7, 1_000.0), 10);
                }
                for id in first..first + batch {
                    let frame = io.voice.playback_frame();
                    if id < WARMUP {
                        continue;
                    }
                    let mut power = 0.0;
                    for &sample in frame.iter().step_by(2) {
                        power += f64::from(sample).powi(2);
                        crossings += usize::from(previous < 0.0 && sample >= 0.0);
                        previous = sample;
                        clipped_samples += usize::from(sample.abs() >= 0.999);
                    }
                    silent_frames += usize::from((power / FRAME as f64).sqrt() < 0.001);
                }
            }
            let seconds = f64::from(FRAMES - WARMUP) * FRAME as f64 / 48_000.0;
            (
                crossings as f64 / seconds,
                silent_frames,
                clipped_samples,
                io.voice.diagnostics(),
            )
        }

        let uniform = measure(1);
        let burst = measure(3);
        for (label, (hz, silent, clipped, stats)) in
            [("uniform", uniform), ("three-packet burst", burst)]
        {
            eprintln!(
                "{label}: {hz:.2} Hz, {silent} silent frames, {clipped} clipped samples, {} received packets, {} missing slots, {} late packets",
                stats.rx_packets, stats.rx_gap_slots, stats.rx_late
            );
            assert!((999.0..=1_001.0).contains(&hz), "{label}: {hz:.2} Hz");
            assert_eq!(silent, 0, "{label}: silent frames");
            assert_eq!(clipped, 0, "{label}: clipped samples");
            assert_eq!(stats.rx_packets, 660, "{label}: packet count");
            assert_eq!(stats.rx_gap_slots, 0, "{label}: missing slots");
            assert_eq!(stats.rx_late, 0, "{label}: late packets");
        }
    }

    #[test]
    fn full_capture_queue_counts_only_eligible_frames() {
        let mut io = Voice::pair();
        io.set_channel(Some((1, CodecType::OpusVoice))).unwrap();
        io.voice.set_devices(true, true, false, false);
        for _ in 0..7 {
            io.voice.submit_capture(vec![0.1; FRAME]);
        }
        let stats = io.voice.diagnostics();
        assert_eq!((stats.tx_enqueued, stats.tx_full, stats.tx_sent), (4, 3, 0));
        io.capture.try_recv().unwrap();
        io.voice.submit_capture(vec![0.1; FRAME]);
        io.voice.set_devices(true, true, true, false);
        io.voice.submit_capture(vec![0.1; FRAME]);
        let stats = io.voice.diagnostics();
        assert_eq!(
            (stats.tx_enqueued, stats.tx_full, stats.rx_packets),
            (5, 3, 0)
        );
    }

    #[test]
    fn two_speaker_mute_gain_clip_and_session_isolation() {
        let mut io = Voice::pair();
        let original = io.voice.clone();
        let current = Mutex::new(original.clone());
        let reference = Voice::pair().voice;
        for voice in [&original, &reference] {
            voice.set_devices(false, true, false, false);
        }
        original.set_speaker_mix(
            81,
            SpeakerMix {
                muted: true,
                ..Default::default()
            },
        );
        let a = encoder().unwrap();
        let b = encoder().unwrap();
        let mut audible = false;
        let mut clipped = false;
        for id in 0..120 {
            let second = tone_packet(&b, id, 9, 700.0);
            deliver(&reference, second.clone(), 82);
            deliver(&original, second, 82);
            deliver(&original, tone_packet(&a, id, 7, 440.0), 81);
            if id == 80 {
                original.set_speaker_mix(
                    82,
                    SpeakerMix {
                        gain: 2.0,
                        pan: -1.0,
                        muted: false,
                    },
                );
            }
            let mixed = original.playback_frame();
            let other = reference.playback_frame();
            if id < 80 {
                assert_eq!(mixed, other);
                audible |= other.iter().any(|x| x.abs() > 0.1);
            } else {
                for (actual, baseline) in mixed.chunks_exact(2).zip(other.chunks_exact(2)) {
                    assert_eq!(actual[0], (2.0 * baseline[0]).clamp(-1.0, 1.0));
                    assert_eq!(actual[1], 0.0);
                    clipped |= actual[0].abs() == 1.0;
                }
            }
        }
        assert!(audible && clipped);
        io = crate::replace_audio(&io, &current);
        io.voice.set_devices(false, true, false, false);
        original.set_devices(false, true, false, false);
        for id in 120..155 {
            deliver(&original, tone_packet(&a, id, 7, 440.0), 81);
            assert!(io.voice.playback_frame().iter().all(|x| *x == 0.0));
        }
        assert!(io.voice.speaker_mix(81) == SpeakerMix::default());
        let other_server = Voice::pair().voice;
        other_server.set_devices(false, true, false, false);
        let fresh_encoder = encoder().unwrap();
        let mut new_speaker_audible = false;
        for id in 0..40 {
            deliver(&original, tone_packet(&a, id + 155, 7, 440.0), 81);
            if id < 10 {
                assert!(other_server.playback_frame().iter().all(|x| *x == 0.0));
            } else {
                deliver(&other_server, tone_packet(&fresh_encoder, id, 7, 330.0), 81);
                new_speaker_audible |= other_server.playback_frame().iter().any(|x| x.abs() > 0.1);
            }
        }
        assert!(new_speaker_audible);
    }

    #[test]
    fn opus_voice_round_trip_and_output_mute() {
        let io = Voice::pair();
        let encoder = encoder().unwrap();
        io.voice.set_devices(true, true, false, false);
        let mut power = 0.0_f64;
        let mut crossings = 0;
        let mut previous = 0.0;
        for id in 0..80u16 {
            let samples: Vec<f32> = (0..FRAME)
                .map(|n| {
                    let t = (usize::from(id) * FRAME + n) as f32 / 48_000.0;
                    (t * std::f32::consts::TAU * 440.0).sin() * 0.2
                })
                .collect();
            let outgoing = encode(&encoder, &samples, CodecType::OpusVoice).unwrap();
            let outgoing = InAudioBuf::try_new(Direction::C2S, outgoing.into_vec()).unwrap();
            let forwarded = OutAudio::new(&AudioData::S2C {
                id,
                from: 7,
                codec: CodecType::OpusVoice,
                data: outgoing.data().data().data(),
            });
            io.voice.receive(
                InAudioBuf::try_new(Direction::S2C, forwarded.into_vec()).unwrap(),
                77,
            );
            let decoded = io.voice.playback_frame();
            if id >= 30 {
                for &sample in decoded.iter().step_by(2) {
                    if previous < 0.0 && sample >= 0.0 {
                        crossings += 1;
                    }
                    previous = sample;
                    power += f64::from(sample).powi(2);
                }
            }
        }
        // The final 50 frames represent one second of decoded audio.
        assert!((425..=455).contains(&crossings), "{crossings} Hz");
        assert!((power / 48000.0).sqrt() > 0.05);
        io.voice.set_devices(true, true, true, true);
        assert!(io.voice.playback_frame().iter().all(|s| *s == 0.0));
    }
}
