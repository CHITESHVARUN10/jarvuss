//! Same immutable-release contract as backend/intent_model_store.py.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};

pub const REQUIRED: &[&str] = &[
    "encoder_model_quantized.onnx",
    "decoder_model_merged_quantized.onnx",
    "config.json",
    "added_tokens.json",
    "spiece.model",
    "model_meta.json",
];
const ALLOWED: &[&str] = &[
    "encoder_model_quantized.onnx",
    "decoder_model_merged_quantized.onnx",
    "config.json",
    "generation_config.json",
    "added_tokens.json",
    "spiece.model",
    "special_tokens_map.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "model_meta.json",
    "LICENSE",
    "NOTICE",
];

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub struct Receipt {
    pub commit: String,
    pub directory: String,
    pub version: String,
    pub manifest_sha256: String,
    pub generation: String,
}
fn hex(s: &str, n: usize) -> bool {
    s.len() == n
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn read_bounded(path: &Path, limit: u64) -> Result<Vec<u8>, String> {
    let mut data = Vec::new();
    fs::File::open(path)
        .map_err(|e| e.to_string())?
        .take(limit + 1)
        .read_to_end(&mut data)
        .map_err(|e| e.to_string())?;
    if data.len() as u64 > limit {
        return Err("file exceeds limit".into());
    }
    Ok(data)
}
pub fn receipt(root: &Path, name: &str) -> Option<Receipt> {
    let r: Receipt = serde_json::from_slice(&read_bounded(&root.join(name), 8192).ok()?).ok()?;
    if !hex(&r.commit, 40)
        || !hex(&r.manifest_sha256, 64)
        || r.directory.len() != 73
        || !r.directory.starts_with(&format!("{}-", r.commit))
        || !hex(&r.directory[41..], 32)
    {
        return None;
    }
    Some(r)
}
pub fn fingerprint(path: &Path) -> Result<String, String> {
    let mut f = fs::File::open(path).map_err(|e| e.to_string())?;
    let mut hash = Sha256::new();
    let mut buf = [0; 65536];
    loop {
        let n = f.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        hash.update(&buf[..n]);
    }
    Ok(format!("{:x}", hash.finalize()))
}
pub fn verify(root: &Path, selected: &Receipt) -> Result<PathBuf, String> {
    // Receipts can also be supplied by callers/tests: validate before any join.
    if !hex(&selected.commit, 40)
        || selected.directory.len() != 73
        || !selected
            .directory
            .starts_with(&format!("{}-", selected.commit))
        || !hex(&selected.directory[41..], 32)
        || !hex(&selected.manifest_sha256, 64)
    {
        return Err("invalid receipt".into());
    }
    let versions = root.join("versions");
    let folder = versions.join(&selected.directory);
    if fs::symlink_metadata(&folder)
        .map_err(|e| e.to_string())?
        .file_type()
        .is_symlink()
        || folder.canonicalize().map_err(|e| e.to_string())?.parent()
            != Some(
                versions
                    .canonicalize()
                    .map_err(|e| e.to_string())?
                    .as_path(),
            )
    {
        return Err("invalid model location".into());
    }
    let manifest_path = folder.join("model-release.json");
    if fs::symlink_metadata(&manifest_path)
        .map_err(|e| e.to_string())?
        .file_type()
        .is_symlink()
    {
        return Err("invalid manifest".into());
    }
    let data = read_bounded(&manifest_path, 64000)?;
    if format!("{:x}", Sha256::digest(&data)) != selected.manifest_sha256 {
        return Err("manifest checksum mismatch".into());
    }
    let m: Value = serde_json::from_slice(&data).map_err(|e| e.to_string())?;
    if m["format_version"].as_u64() != Some(1)
        || m["runtime"] != "jarvis-t5-onnx-v1"
        || m["version"].as_str() != Some(selected.version.as_str())
        || !m["intent_schema_version"]
            .as_u64()
            .is_some_and(|n| (1..=5).contains(&n))
        || m["max_source_len"].as_u64() != Some(128)
        || m["max_target_len"].as_u64() != Some(448)
    {
        return Err("incompatible model manifest".into());
    }
    let files = m["files"].as_array().ok_or("invalid file list")?;
    if !(6..=12).contains(&files.len()) {
        return Err("invalid file count".into());
    }
    let names: HashSet<_> = files.iter().filter_map(|v| v["name"].as_str()).collect();
    if names.len() != files.len()
        || !REQUIRED.iter().all(|n| names.contains(n))
        || !names.iter().all(|n| ALLOWED.contains(n))
        || (m["license"] == "apache-2.0"
            && (!names.contains("LICENSE") || !names.contains("NOTICE")))
    {
        return Err("invalid model files".into());
    }
    let mut total = 0;
    for file in files {
        let size = file["size_bytes"]
            .as_u64()
            .filter(|n| (1..=256000000).contains(n))
            .ok_or("invalid file size")?;
        total += size;
        if total > 350000000 {
            return Err("model exceeds limit".into());
        }
        let digest = file["sha256"]
            .as_str()
            .filter(|s| hex(s, 64))
            .ok_or("invalid checksum")?;
        let path = folder.join(file["name"].as_str().ok_or("invalid file name")?);
        let meta = fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
        if !meta.file_type().is_file() || meta.len() != size || fingerprint(&path)? != digest {
            return Err("model file verification failed".into());
        }
    }
    Ok(folder)
}
pub fn remember_good(root: &Path, selected: &Receipt) -> Result<(), String> {
    fs::create_dir_all(root).map_err(|e| e.to_string())?;
    // Unique same-directory temporary file; never collide with another helper.
    let mut file = tempfile::NamedTempFile::new_in(root).map_err(|e| e.to_string())?;
    serde_json::to_writer(&mut file, selected).map_err(|e| e.to_string())?;
    file.flush().map_err(|e| e.to_string())?;
    file.persist(root.join("last-good.json"))
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn fixture(root: &Path) -> (Receipt, PathBuf) {
        let mut r = Receipt {
            commit: "a".repeat(40),
            directory: format!("{}-{}", "a".repeat(40), "b".repeat(32)),
            version: "1.0.2".into(),
            manifest_sha256: String::new(),
            generation: "test".into(),
        };
        let folder = root.join("versions").join(&r.directory);
        fs::create_dir_all(&folder).unwrap();
        let mut files = Vec::new();
        for name in REQUIRED {
            let data = b"test model data";
            fs::write(folder.join(name), data).unwrap();
            files.push(json!({"name":name,"size_bytes":data.len(),"sha256":format!("{:x}",Sha256::digest(data))}));
        }
        let m = json!({"format_version":1,"runtime":"jarvis-t5-onnx-v1","version":r.version,"intent_schema_version":5,"max_source_len":128,"max_target_len":448,"files":files});
        fs::write(folder.join("model-release.json"), m.to_string()).unwrap();
        r.manifest_sha256 = fingerprint(&folder.join("model-release.json")).unwrap();
        fs::write(root.join("current.json"), serde_json::to_vec(&r).unwrap()).unwrap();
        (r, folder)
    }
    #[test]
    fn valid_receipt_and_last_good() {
        let dir = tempfile::tempdir().unwrap();
        let (r, folder) = fixture(dir.path());
        assert_eq!(receipt(dir.path(), "current.json"), Some(r.clone()));
        assert_eq!(verify(dir.path(), &r).unwrap(), folder);
        remember_good(dir.path(), &r).unwrap();
        assert_eq!(receipt(dir.path(), "last-good.json"), Some(r));
    }
    #[test]
    fn reject_tampered_files_and_manifest() {
        let dir = tempfile::tempdir().unwrap();
        let (r, folder) = fixture(dir.path());
        fs::write(folder.join("config.json"), "damaged").unwrap();
        assert!(verify(dir.path(), &r).is_err());
        let (r, folder) = fixture(dir.path());
        fs::write(folder.join("model-release.json"), "{}").unwrap();
        assert!(verify(dir.path(), &r).is_err());
    }
    #[test]
    fn reject_traversal_and_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let (mut r, folder) = fixture(dir.path());
        r.directory = "../../elsewhere".into();
        assert!(verify(dir.path(), &r).is_err());
        let (r, _) = fixture(dir.path());
        fs::remove_file(folder.join("spiece.model")).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(folder.join("config.json"), folder.join("spiece.model"))
            .unwrap();
        assert!(verify(dir.path(), &r).is_err());
    }
    #[test]
    fn reject_unknown_schema_and_oversized_receipt() {
        let dir = tempfile::tempdir().unwrap();
        let (mut r, folder) = fixture(dir.path());
        let path = folder.join("model-release.json");
        let mut m: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        m["intent_schema_version"] = json!(6);
        fs::write(&path, m.to_string()).unwrap();
        r.manifest_sha256 = fingerprint(&path).unwrap();
        assert!(verify(dir.path(), &r).is_err());
        fs::write(dir.path().join("current.json"), " ".repeat(8193)).unwrap();
        assert!(receipt(dir.path(), "current.json").is_none());
    }
}
