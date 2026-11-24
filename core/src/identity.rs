use base64::prelude::*;
use sha1::{Digest, Sha1};
use simple_asn1::ASN1Block;
use tsclientlib::Identity;
use tsproto_types::crypto::EccKeyPrivP256;

#[derive(uniffi::Record)]
pub struct ImportedIdentity {
    pub uid: String,
    // Only the platform credential store consumes this value.
    pub credential: String,
}

// The pinned upstream TomCrypt reader rejects positive P-256 scalars whose
// DER integer is shorter than 32 bytes. Reconstruct only this representation
// and check it against the complete public+private key before accepting it.
fn short_der_key(encoded: &str) -> Option<EccKeyPrivP256> {
    let der = BASE64_STANDARD.decode(encoded).ok()?;
    let blocks = simple_asn1::from_der(&der).ok()?;
    let [ASN1Block::Sequence(_, fields)] = blocks.as_slice() else {
        return None;
    };
    let ASN1Block::Integer(_, scalar) = fields.get(4)? else {
        return None;
    };
    let bytes = scalar.to_biguint()?.to_bytes_be();
    if bytes.is_empty() || bytes.len() >= 32 {
        return None;
    }
    let mut padded = [0u8; 32];
    padded[32 - bytes.len()..].copy_from_slice(&bytes);
    let key = EccKeyPrivP256::from_short(&padded).ok()?;
    (key.to_ts() == encoded).then_some(key)
}

fn export_key(payload: &str) -> Option<EccKeyPrivP256> {
    match EccKeyPrivP256::from_ts_obfuscated(payload) {
        Ok(key) => Some(key),
        Err(tsproto_types::crypto::Error::NoShortKey) => {
            // TS3's published identity mask, used on the first 100 bytes.
            let mask = b"b9dfaa7bee6ac57ac7b65f1094a1c155e747327bc2fe5d51c512023fe54a280201004e90ad1daaae1075d53b7d571c30e063";
            let mut data = BASE64_STANDARD.decode(payload).ok()?;
            let tail = data.get(20..)?.split(|byte| *byte == 0).next()?;
            let hash = Sha1::digest(tail);
            for (byte, mask) in data.iter_mut().zip(hash) {
                *byte ^= mask;
            }
            for (byte, mask) in data.iter_mut().zip(mask.iter().take(100)) {
                *byte ^= mask;
            }
            short_der_key(std::str::from_utf8(&data).ok()?)
        }
        Err(_) => None,
    }
}

pub(crate) fn read_stored(credential: &str) -> Option<Identity> {
    Identity::new_from_ts_str(credential).ok().or_else(|| {
        let (counter, der) = credential.split_once('V')?;
        Some(Identity::new(short_der_key(der)?, counter.parse().ok()?))
    })
}

#[uniffi::export]
pub fn stored_identity_uid(credential: &str) -> Option<String> {
    let identity = read_stored(credential)?;
    Some(identity.key().to_pub().get_uid())
}

/// One TS3 desktop identity per INI export. Ignore display metadata and only
/// accept the key in its own section. Errors never contain file contents.
#[uniffi::export]
pub fn parse_identity_export(contents: Vec<u8>) -> Option<ImportedIdentity> {
    if contents.len() > 65536 || contents.contains(&0) {
        return None;
    }
    let text =
        std::str::from_utf8(contents.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&contents)).ok()?;
    let mut in_identity = false;
    let mut credential = None;
    for line in text.lines().map(str::trim) {
        if line.starts_with('[') {
            in_identity = line.eq_ignore_ascii_case("[Identity]");
            continue;
        }
        if !in_identity {
            continue;
        }
        if let Some((name, value)) = line.split_once('=') {
            if !name.trim().eq_ignore_ascii_case("identity") {
                continue;
            }
            if credential.is_some() {
                return None;
            }
            let value = value.trim();
            credential = Some(if value.starts_with('"') {
                value.strip_prefix('"')?.strip_suffix('"')?
            } else {
                value
            });
        }
    }
    let credential = credential?;
    let (offset, payload) = credential.split_once('V')?;
    if payload.len() > 1024 || !offset.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let counter = offset.parse::<u64>().ok()?;
    let key = export_key(payload)?;
    Some(ImportedIdentity {
        uid: key.to_pub().get_uid(),
        credential: format!("{}V{}", counter, key.to_ts()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exported_ini_preserves_public_uid_and_counter() {
        for key in [
            Identity::create().key().clone(),
            EccKeyPrivP256::from_short(&{
                let mut short = [0x42; 32];
                short[0] = 0;
                short
            })
            .unwrap(),
        ] {
            check_export(Identity::new(key, 137));
        }
    }

    fn check_export(id: Identity) {
        let uid = id.key().to_pub().get_uid();
        let credential = format!("{}V{}", id.counter(), id.key().to_ts_obfuscated());
        for (bom, newline, value) in [
            ("", "\n", credential.clone()),
            ("\u{feff}", "\r\n", format!("\"{credential}\"")),
        ] {
            let file = format!("{bom}[Other]{newline}identity=ignored{newline}[Identity]{newline}id=测试{newline}identity={value}{newline}nickname=Alice{newline}");
            let imported = parse_identity_export(file.into_bytes()).unwrap();
            assert_eq!(imported.uid, uid);
            let saved = read_stored(&imported.credential).unwrap();
            assert_eq!(saved.counter(), id.counter());
            assert_eq!(saved.key().to_pub().get_uid(), uid);
            assert_eq!(stored_identity_uid(&imported.credential), Some(uid.clone()));
        }
    }

    #[test]
    fn malformed_or_ambiguous_exports_are_rejected() {
        let id = Identity::create();
        let payload = id.key().to_ts_obfuscated();
        for text in [
            String::new(),
            format!("[Other]\nidentity=12V{payload}"),
            "[Identity]\nid=ok".into(),
            format!("[Identity]\nidentity=\"12V{payload}"),
            format!("[Identity]\nidentity=xV{payload}"),
            format!("[Identity]\nidentity=18446744073709551616V{payload}"),
            "[Identity]\nidentity=1V!bad".into(),
            format!("[Identity]\nidentity=12V{payload}\nidentity=13V{payload}"),
            format!("[Identity]\nidentity=1V{payload}\0"),
        ] {
            assert!(parse_identity_export(text.into_bytes()).is_none());
        }
        assert!(parse_identity_export(vec![b'x'; 65537]).is_none());
        assert!(parse_identity_export(vec![0xff]).is_none());
    }
}
