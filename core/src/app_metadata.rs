use serde::{Deserialize, Serialize};
use tsproto_packets::packets::{Direction, Flags, OutCommand, PacketType};

const SCHEMA: &str = "opents";
const LEGACY_PREFIX: &str = "OpenTS/";
const MAX_VERSION_LENGTH: usize = 64 - LEGACY_PREFIX.len();
const MAX_METADATA_LENGTH: usize = 4096;

#[derive(Serialize, Deserialize)]
struct Metadata<T> {
    schema: T,
    version: T,
}

fn valid_version(version: &str) -> bool {
    version.len() <= MAX_VERSION_LENGTH
        && version.as_bytes().first().is_some_and(u8::is_ascii_digit)
        && version
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'-' | b'+'))
}

pub(crate) fn announcement(version: &str) -> Option<OutCommand> {
    if !valid_version(version) {
        return None;
    }
    let metadata = serde_json::to_string(&Metadata {
        schema: SCHEMA,
        version,
    })
    .ok()?;
    let mut command = OutCommand::new(
        Direction::C2S,
        Flags::empty(),
        PacketType::Command,
        "clientupdate",
    );
    command.write_arg("client_meta_data", &metadata);
    Some(command)
}

pub(crate) fn version(metadata: &str) -> Option<String> {
    if metadata.len() > MAX_METADATA_LENGTH {
        return None;
    }
    if let Some(version) = metadata.strip_prefix(LEGACY_PREFIX) {
        return valid_version(version).then(|| version.to_owned());
    }
    if !metadata.trim_start().starts_with('{') {
        return None;
    }
    let metadata: Metadata<String> = serde_json::from_str(metadata).ok()?;
    (metadata.schema == SCHEMA && valid_version(&metadata.version)).then_some(metadata.version)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn advertises_a_recognizable_version_in_native_client_metadata() {
        let command = announcement("0.1.0").unwrap();
        assert_eq!(
            command.0.content(),
            br#"clientupdate client_meta_data={"schema":"opents","version":"0.1.0"}"#
        );
        assert_eq!(
            version(r#"{"schema":"opents","version":"0.1.0-rc.1+42"}"#).as_deref(),
            Some("0.1.0-rc.1+42")
        );
    }

    #[test]
    fn accepts_legacy_versions_and_json_extensions() {
        assert_eq!(version("OpenTS/0.1.0").as_deref(), Some("0.1.0"));
        assert_eq!(
            version(r#"{"feature":{"flag":true},"version":"0\u002e1.0","schema":"opents"}"#)
                .as_deref(),
            Some("0.1.0")
        );
    }

    #[test]
    fn unknown_or_malformed_metadata_does_not_claim_an_opents_version() {
        let too_long = "1".repeat(MAX_VERSION_LENGTH + 1);
        for invalid in ["", "unknown", "0.1.0|x=1", "1.0 beta", "1.0.全", &too_long] {
            assert!(announcement(invalid).is_none());
            assert!(version(&format!("{LEGACY_PREFIX}{invalid}")).is_none());
            let metadata = serde_json::to_string(&Metadata {
                schema: SCHEMA,
                version: invalid,
            })
            .unwrap();
            assert!(version(&metadata).is_none());
        }
        for invalid in [
            "AnotherClient/0.1.0",
            r#"{"schema":"other","version":"0.1.0"}"#,
            r#"{"version":"0.1.0"}"#,
            r#"{"schema":"opents"}"#,
            r#"{"schema":"opents","version":1}"#,
            r#"{"schema":"opents","version":"0.1.0""#,
            r#"["opents","0.1.0"]"#,
            r#"{"schema":"opents","schema":"other","version":"0.1.0"}"#,
        ] {
            assert!(version(invalid).is_none());
        }
        let oversized = format!(
            r#"{{"schema":"opents","version":"0.1.0","extra":"{}"}}"#,
            "a".repeat(MAX_METADATA_LENGTH)
        );
        assert!(version(&oversized).is_none());
    }
}
