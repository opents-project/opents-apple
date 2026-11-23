use super::*;
use audiopus::{coder::Decoder, packet, Channels, SampleRate};
use tsclientlib::{Codec, MessageHandle};
use tsproto_packets::packets::{Direction, InAudioBuf};

const VOICE: (u64, Codec) = (15, Codec::OpusVoice);
const MUSIC: (u64, Codec) = (26, Codec::OpusMusic);

fn request(
    handle: u16,
    target: u64,
) -> (Option<PendingJoin>, oneshot::Receiver<Option<JoinFailure>>) {
    let (reply, response) = oneshot::channel();
    (
        Some(PendingJoin {
            handle: MessageHandle(handle),
            target,
            accepted: false,
            reply,
        }),
        response,
    )
}

fn observe(io: &mut voice::AudioIo, pending: &mut Option<PendingJoin>, current: (u64, Codec)) {
    io.set_channel(capture_channel(pending, Some(current)))
        .unwrap();
}

// 500 Hz and 1500 Hz each make an integral number of cycles per 20 ms.
// Measure the energy in both tones after decoding, independent of Opus delay.
fn tone_level(samples: &[f32], side: usize, hz: f32) -> f32 {
    let (mut x, mut y) = (0.0, 0.0);
    for (i, lr) in samples.chunks_exact(2).enumerate() {
        let phase = i as f32 * std::f32::consts::TAU * hz / 48_000.0;
        x += lr[side] * phase.cos();
        y += lr[side] * phase.sin();
    }
    x.hypot(y) / voice::FRAME as f32
}

fn verify_signal(io: &mut voice::AudioIo, codec: CodecType, mono_source: bool) {
    let wave = |i: usize, hz: f32| 0.4 * (i as f32 * std::f32::consts::TAU * hz / 48_000.0).sin();
    let mut decoder = Decoder::new(SampleRate::Hz48000, Channels::Stereo).unwrap();
    let mut decoded = vec![0.0; voice::FRAME * 2];
    for _ in 0..12 {
        let samples = if mono_source {
            (0..voice::FRAME).map(|i| wave(i, 500.0)).collect()
        } else {
            (0..voice::FRAME)
                .flat_map(|i| [wave(i, 500.0), wave(i, 1500.0)])
                .collect()
        };
        io.voice.submit_pcm(io.voice.capture_epoch(), samples);
        let frame = io.capture.try_recv().unwrap();
        let (wire, out) = io.packet(frame).unwrap().unwrap();
        assert_eq!(wire, codec);
        let data = InAudioBuf::try_new(Direction::C2S, out.into_vec()).unwrap();
        let AudioData::C2S {
            codec: header,
            data: payload,
            ..
        } = data.data().data()
        else {
            panic!("expected client audio")
        };
        assert_eq!(*header, codec);
        if !mono_source {
            let width = packet::nb_channels((*payload).try_into().unwrap()).unwrap();
            assert_eq!(
                width,
                if codec == CodecType::OpusVoice {
                    Channels::Mono
                } else {
                    Channels::Stereo
                }
            );
        }
        assert_eq!(
            decoder
                .decode_float(
                    Some((*payload).try_into().unwrap()),
                    (&mut decoded).try_into().unwrap(),
                    false
                )
                .unwrap(),
            voice::FRAME
        );
    }
    let levels = |side| {
        (
            tone_level(&decoded, side, 500.0),
            tone_level(&decoded, side, 1500.0),
        )
    };
    let ((ll, lh), (rl, rh)) = (levels(0), levels(1));
    if mono_source {
        assert!(ll > 0.1 && rl > 0.1 && lh < 0.02 && rh < 0.02);
    } else if codec == CodecType::OpusMusic {
        assert!(
            ll > 0.1 && rh > 0.1 && lh < ll / 5.0 && rl < rh / 5.0,
            "{ll} {lh} {rl} {rh}"
        );
    } else {
        assert!(ll > 0.05 && lh > 0.05 && (ll - rl).abs() < 0.001 && (lh - rh).abs() < 0.001);
    }
}

#[test]
fn voice_music_voice_requires_both_confirmations_and_encodes_actual_channels() {
    let mut io = Voice::pair();
    io.voice.set_devices(true, true, false, false);
    observe(&mut io, &mut None, VOICE);
    verify_signal(&mut io, CodecType::OpusVoice, false);
    for (handle, old, next, ack_first) in [(1, VOICE, MUSIC, true), (2, MUSIC, VOICE, false)] {
        let old_epoch = io.voice.capture_epoch();
        io.voice.submit_pcm(old_epoch, vec![0.25; 960]);
        let queued = io.capture.try_recv().unwrap();
        let (mut join, mut response) = request(handle, next.0);
        observe(&mut io, &mut join, old);
        assert_eq!(io.voice.capture_epoch(), 0);
        if ack_first {
            PendingJoin::result(&mut join, MessageHandle(handle), None);
            observe(&mut io, &mut join, old);
        } else {
            observe(&mut io, &mut join, next);
        }
        assert_eq!(io.voice.capture_epoch(), 0);
        io.voice.submit_pcm(0, vec![0.5; 1920]);
        assert!(io.capture.try_recv().is_err());
        assert!(matches!(
            response.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        PendingJoin::result(&mut join, MessageHandle(handle), None);
        observe(&mut io, &mut join, next);
        assert!(response.try_recv().unwrap().is_none());
        assert!(io.packet(queued).unwrap().is_none());
        io.voice.submit_pcm(old_epoch, vec![0.5; 1920]);
        assert!(io.capture.try_recv().is_err());
        let codec = supported_codec(next.1).unwrap();
        verify_signal(&mut io, codec, false);
        if codec == CodecType::OpusMusic {
            verify_signal(&mut io, codec, true);
        }
    }
}

#[test]
fn failed_moves_resume_confirmed_channel_and_late_results_cannot_complete_retry() {
    let mut io = Voice::pair();
    io.voice.set_devices(true, true, false, false);
    observe(&mut io, &mut None, VOICE);
    let (mut join, mut rejected) = request(7, MUSIC.0);
    observe(&mut io, &mut join, VOICE);
    PendingJoin::result(
        &mut join,
        MessageHandle(7),
        Some(JoinFailure::PermissionDenied {
            permission: Some(139),
        }),
    );
    assert!(matches!(
        rejected.try_recv(),
        Ok(Some(JoinFailure::PermissionDenied {
            permission: Some(139)
        }))
    ));
    observe(&mut io, &mut join, VOICE);
    verify_signal(&mut io, CodecType::OpusVoice, false);
    let (mut join, mut expired) = request(8, MUSIC.0);
    observe(&mut io, &mut join, VOICE);
    PendingJoin::finish_with_error(&mut join, "Channel change timed out".into());
    assert!(matches!(
        expired.try_recv(),
        Ok(Some(JoinFailure::Other { .. }))
    ));
    observe(&mut io, &mut join, VOICE);
    verify_signal(&mut io, CodecType::OpusVoice, false);
    let (mut retry, mut response) = request(9, MUSIC.0);
    observe(&mut io, &mut retry, VOICE);
    PendingJoin::result(&mut retry, MessageHandle(8), None);
    PendingJoin::result(&mut retry, MessageHandle(7), Some("Late error".into()));
    observe(&mut io, &mut retry, MUSIC);
    assert_eq!(io.voice.capture_epoch(), 0);
    assert!(matches!(
        response.try_recv(),
        Err(oneshot::error::TryRecvError::Empty)
    ));
    PendingJoin::result(&mut retry, MessageHandle(9), None);
    observe(&mut io, &mut retry, MUSIC);
    assert!(response.try_recv().unwrap().is_none());
    verify_signal(&mut io, CodecType::OpusMusic, false);
    for legacy in [
        Codec::SpeexNarrowband,
        Codec::SpeexWideband,
        Codec::SpeexUltrawideband,
        Codec::CeltMono,
    ] {
        observe(&mut io, &mut retry, (32, legacy));
        io.voice.submit_capture(vec![0.25; 960]);
        assert_eq!(io.voice.capture_epoch(), 0);
        assert!(io.capture.try_recv().is_err());
    }
}
