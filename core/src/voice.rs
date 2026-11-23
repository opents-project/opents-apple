//! The wire uses Opus. The Apple adapter supplies mono 48 kHz PCM in 20 ms
//! frames and pulls interleaved stereo PCM from the per-speaker jitter buffers.
use audiopus::{coder::Encoder, Application, Channels, SampleRate};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::sync::{mpsc, watch};
use tsclientlib::{audio::AudioHandler, ClientId};
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

#[derive(Default)]
struct Playback {
    // Transport IDs distinguish simultaneous connections using one TS identity.
    streams: AudioHandler<(ClientId, u64)>,
    controls: HashMap<u64, SpeakerMix>,
}

impl Playback {
    fn render(&mut self) -> Vec<f32> {
        let mut output = vec![0.0; FRAME * 2];
        if self.controls.is_empty() {
            self.streams.fill_buffer(&mut output);
        } else {
            // The upstream processor exposes each decoded stream before its normal sum.
            // Advance every jitter buffer once, including muted speakers.
            let mut scratch = [0.0; FRAME * 2];
            self.streams
                .fill_buffer_with_proc(&mut scratch, |(_, db_id), samples| {
                    self.controls
                        .get(db_id)
                        .copied()
                        .unwrap_or_default()
                        .add_to(samples, &mut output);
                });
        }
        for sample in &mut output {
            *sample = sample.clamp(-1.0, 1.0);
        }
        output
    }
}

#[derive(uniffi::Object)]
pub struct Voice {
    capture: mpsc::Sender<Vec<f32>>,
    enabled: watch::Sender<DeviceState>,
    playback: Mutex<Playback>,
}

pub(crate) struct AudioIo {
    pub capture: mpsc::Receiver<Vec<f32>>,
    pub enabled: watch::Receiver<DeviceState>,
    pub voice: Arc<Voice>,
}

impl Voice {
    pub(crate) fn pair() -> AudioIo {
        let (capture, frames) = mpsc::channel(4);
        let (enabled, changes) = watch::channel(DeviceState::default());
        AudioIo {
            capture: frames,
            enabled: changes,
            voice: Arc::new(Self {
                capture,
                enabled,
                playback: Mutex::default(),
            }),
        }
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
        let _ = playback
            .streams
            .handle_packet((ClientId(from), database_id), packet);
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
            self.playback.lock().unwrap().streams.reset();
        }
    }

    pub fn submit_capture(&self, samples: Vec<f32>) {
        if samples.len() == FRAME && self.enabled.borrow().can_capture() {
            let _ = self.capture.try_send(samples);
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
