//! Compatible NumPy enrollment storage and weighted speaker scoring.
use fs2::FileExt;
use npyz::{DType, TypeChar, WriterBuilder};
use serde_json::{json, Value};
use std::{
    fs,
    io::{Cursor, Read, Write},
    os::unix::fs::OpenOptionsExt,
    path::Path,
};
type Result<T> = std::result::Result<T, String>;
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
pub fn load(path: &Path) -> Result<Vec<Vec<f32>>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let mut bytes = Vec::new();
    fs::File::open(path)
        .map_err(err)?
        .take(32 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(err)?;
    if bytes.len() > 32 * 1024 * 1024 {
        return Err("voice profile exceeds size limit".into());
    }
    let file = npyz::NpyFile::new(Cursor::new(&bytes)).map_err(err)?;
    let shape = file.shape().to_vec();
    let rows = match shape.as_slice() {
        [256] => 1,
        [rows, 256] => usize::try_from(*rows).map_err(err)?,
        _ => return Err("Invalid voice profile shape".into()),
    };
    if rows > 32768 {
        return Err("Voice profile exceeds enrollment limit".into());
    }
    let order = file.order();
    let dtype = file.dtype();
    macro_rules! numeric {
        ($t:ty) => {
            npyz::NpyFile::new(Cursor::new(&bytes))
                .map_err(err)?
                .into_vec::<$t>()
                .map_err(err)?
                .into_iter()
                .map(|v| v as f32)
                .collect::<Vec<_>>()
        };
    }
    let data = match dtype {
        DType::Plain(ts) => match (ts.type_char(), ts.size_field()) {
            (TypeChar::Float, 4) => numeric!(f32),
            (TypeChar::Float, 8) => numeric!(f64),
            (TypeChar::Int, 1) => numeric!(i8),
            (TypeChar::Int, 2) => numeric!(i16),
            (TypeChar::Int, 4) => numeric!(i32),
            (TypeChar::Int, 8) => numeric!(i64),
            (TypeChar::Uint, 1) => numeric!(u8),
            (TypeChar::Uint, 2) => numeric!(u16),
            (TypeChar::Uint, 4) => numeric!(u32),
            (TypeChar::Uint, 8) => numeric!(u64),
            _ => return Err("Unsupported voice profile data".into()),
        },
        _ => return Err("Unsupported voice profile data".into()),
    };
    if data.len() != rows.checked_mul(256).ok_or("Invalid profile dimensions")?
        || data.iter().any(|v| !v.is_finite())
    {
        return Err("Invalid voice profile data".into());
    }
    if order == npyz::Order::Fortran && shape.len() == 2 {
        Ok((0..rows)
            .map(|row| (0..256).map(|column| data[column * rows + row]).collect())
            .collect())
    } else {
        Ok(data.chunks_exact(256).map(<[f32]>::to_vec).collect())
    }
}
pub fn save(path: &Path, profiles: &[Vec<f32>]) -> Result<()> {
    let parent = path.parent().ok_or("Invalid voice profile path")?;
    fs::create_dir_all(parent).map_err(err)?;
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(parent.join("voice_profiles.lock"))
        .map_err(err)?;
    lock.lock_exclusive().map_err(err)?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent).map_err(err)?;
    let mut writer = npyz::WriteOptions::new()
        .default_dtype()
        .shape(&[profiles.len() as u64, 256])
        .writer(&mut temporary)
        .begin_nd()
        .map_err(err)?;
    for profile in profiles {
        if profile.len() != 256 || profile.iter().any(|v| !v.is_finite()) {
            return Err("Invalid voice profile".into());
        }
        for value in profile {
            writer.push(value).map_err(err)?;
        }
    }
    writer.finish().map_err(err)?;
    temporary.flush().map_err(err)?;
    temporary.as_file().sync_all().map_err(err)?;
    temporary.persist(path).map_err(err)?;
    Ok(())
}
pub fn cosine(a: &[f32], b: &[f32]) -> f64 {
    let denominator = (a.iter().map(|v| v * v).sum::<f32>().sqrt()
        * b.iter().map(|v| v * v).sum::<f32>().sqrt()) as f64;
    if denominator == 0.0 {
        return 0.0;
    }
    a.iter().zip(b).map(|(x, y)| x * y).sum::<f32>() as f64 / denominator
}
pub fn score(similarities: &[f64]) -> Value {
    if similarities.is_empty() {
        return json!({"similarity":0.0,"max_similarity":0.0,"avg_similarity":0.0,"confidence":"none","samples_compared":0});
    }
    let max = similarities
        .iter()
        .copied()
        .fold(f64::NEG_INFINITY, f64::max);
    let avg = similarities.iter().sum::<f64>() / similarities.len() as f64;
    let final_score = 0.6 * max + 0.4 * avg;
    let round = |n: f64| (n * 10000.0).round_ties_even() / 10000.0;
    json!({"similarity":round(final_score),"max_similarity":round(max),"avg_similarity":round(avg),"confidence":if final_score>=0.75{"strong"}else if final_score>=0.65{"low"}else{"rejected"},"samples_compared":similarities.len()})
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_float64_fortran_and_single_row_profiles_are_readable() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("voice.npy");
        let mut bytes = Vec::new();
        let mut writer = npyz::WriteOptions::new()
            .default_dtype()
            .shape(&[2, 256])
            .order(npyz::Order::Fortran)
            .writer(&mut bytes)
            .begin_nd()
            .unwrap();
        for _ in 0..256 {
            writer.push(&0.1f64).unwrap();
            writer.push(&0.2f64).unwrap();
        }
        writer.finish().unwrap();
        fs::write(&path, &bytes).unwrap();
        let loaded = load(&path).unwrap();
        assert_eq!(loaded, vec![vec![0.1f32; 256], vec![0.2f32; 256]]);
        let mut bytes = Vec::new();
        let mut writer = npyz::WriteOptions::new()
            .default_dtype()
            .shape(&[256])
            .writer(&mut bytes)
            .begin_nd()
            .unwrap();
        for _ in 0..256 {
            writer.push(&0.3f32).unwrap();
        }
        writer.finish().unwrap();
        fs::write(&path, bytes).unwrap();
        assert_eq!(load(&path).unwrap(), vec![vec![0.3f32; 256]]);
    }
    #[test]
    fn atomic_numpy_roundtrip_preserves_profile_shape() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("embeddings.npy");
        let v = vec![vec![0.1f32; 256], vec![0.2f32; 256]];
        save(&p, &v).unwrap();
        assert_eq!(load(&p).unwrap(), v);
        save(&p, &[]).unwrap();
        assert!(load(&p).unwrap().is_empty());
    }
    #[test]
    fn missing_user_profile_never_adopts_a_neighboring_source_profile() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("backend/embeddings.npy");
        save(&source, &vec![vec![0.1f32; 256]; 63]).unwrap();
        let user = dir.path().join("user/embeddings.npy");
        assert!(load(&user).unwrap().is_empty());
        assert_eq!(load(&source).unwrap().len(), 63);
    }
    #[test]
    fn scoring_retains_thresholds_and_weighting() {
        for (score_value, label) in [
            (0.64999, "rejected"),
            (0.65, "low"),
            (0.74999, "low"),
            (0.75, "strong"),
        ] {
            assert_eq!(score(&[score_value])["confidence"], label);
        }
        assert_eq!(score(&[0.8, 0.6])["similarity"], 0.76);
        assert_eq!(score(&[])["confidence"], "none");
        assert_eq!(cosine(&[0.0; 256], &[1.0; 256]), 0.0);
    }
}
