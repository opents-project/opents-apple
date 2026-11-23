//! The wire uses Opus. The Apple adapter supplies mono 48 kHz PCM in 20 ms
//! frames and pulls interleaved stereo PCM from the per-speaker jitter buffers.
use audiopus::{coder::Encoder, Application, Channels, SampleRate};
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

#[derive(uniffi::Object)]
pub struct Voice {
    capture: mpsc::Sender<Vec<f32>>,
    enabled: watch::Sender<DeviceState>,
    playback: Mutex<AudioHandler<ClientId>>,
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

    pub(crate) fn receive(&self, packet: InAudioBuf) {
        let devices = *self.enabled.borrow();
        if !devices.output || devices.output_muted {
            return;
        }
        let from = match packet.data().data() {
            AudioData::S2C { from, .. } | AudioData::S2CWhisper { from, .. } => *from,
            _ => return,
        };
        let _ = self
            .playback
            .lock()
            .unwrap()
            .handle_packet(ClientId(from), packet);
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
            *self.playback.lock().unwrap() = AudioHandler::new();
        }
    }

    pub fn submit_capture(&self, samples: Vec<f32>) {
        if samples.len() == FRAME && self.enabled.borrow().can_capture() {
            let _ = self.capture.try_send(samples);
        }
    }

    pub fn playback_frame(&self) -> Vec<f32> {
        let mut frame = vec![0.0; FRAME * 2];
        self.playback.lock().unwrap().fill_buffer(&mut frame);
        frame
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
            io.voice
                .receive(InAudioBuf::try_new(Direction::S2C, forwarded.into_vec()).unwrap());
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
