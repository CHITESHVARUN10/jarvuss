//! Narrow bindings to the same libsndfile and libsoxr implementations used by
//! the Python reference. Keep libraries alive for every borrowed function.
use libloading::Library;
use std::{
    ffi::{c_char, c_int, c_void, CString},
    io::Write,
    path::Path,
};
type Result<T> = std::result::Result<T, String>;
#[repr(C)]
#[derive(Default)]
struct SoundInfo {
    frames: i64,
    samplerate: c_int,
    channels: c_int,
    format: c_int,
    sections: c_int,
    seekable: c_int,
}
#[repr(C)]
struct IoSpec {
    input: c_int,
    output: c_int,
    scale: f64,
    reserved: *mut c_void,
    flags: libc::c_ulong,
}
#[repr(C)]
struct Quality {
    precision: f64,
    phase: f64,
    passband: f64,
    stopband: f64,
    reserved: *mut c_void,
    flags: libc::c_ulong,
}
type Open = unsafe extern "C" fn(*const c_char, c_int, *mut SoundInfo) -> *mut c_void;
type Read = unsafe extern "C" fn(*mut c_void, *mut f32, i64) -> i64;
type Close = unsafe extern "C" fn(*mut c_void) -> c_int;
type Io = unsafe extern "C" fn(c_int, c_int) -> IoSpec;
type Q = unsafe extern "C" fn(libc::c_ulong, libc::c_ulong) -> Quality;
type Create = unsafe extern "C" fn(
    f64,
    f64,
    u32,
    *mut *const c_char,
    *const IoSpec,
    *const Quality,
    *const c_void,
) -> *mut c_void;
type Process = unsafe extern "C" fn(
    *mut c_void,
    *const c_void,
    usize,
    *mut usize,
    *mut c_void,
    usize,
    *mut usize,
) -> *const c_char;
type Delete = unsafe extern "C" fn(*mut c_void);
pub struct AudioLibraries {
    _sound: Library,
    _soxr: Library,
    open: Open,
    read: Read,
    close: Close,
    io: Io,
    quality: Q,
    create: Create,
    process: Process,
    delete: Delete,
}
impl AudioLibraries {
    pub fn load(folder: &Path) -> Result<Self> {
        // Explicit bundle paths only; never search cwd or load a user-supplied
        // audio filename as code. Model/data paths never choose these libraries.
        unsafe {
            let sound = Library::new(folder.join("libsndfile_arm64.dylib"))
                .map_err(|_| "audio decoder unavailable")?;
            let soxr = Library::new(folder.join("libsoxr.dylib"))
                .map_err(|_| "audio resampler unavailable")?;
            Ok(Self {
                open: *sound
                    .get(b"sf_open\0")
                    .map_err(|_| "missing decoder interface")?,
                read: *sound
                    .get(b"sf_readf_float\0")
                    .map_err(|_| "missing decoder interface")?,
                close: *sound
                    .get(b"sf_close\0")
                    .map_err(|_| "missing decoder interface")?,
                io: *soxr
                    .get(b"soxr_io_spec\0")
                    .map_err(|_| "missing resampler interface")?,
                quality: *soxr
                    .get(b"soxr_quality_spec\0")
                    .map_err(|_| "missing resampler interface")?,
                create: *soxr
                    .get(b"soxr_create\0")
                    .map_err(|_| "missing resampler interface")?,
                process: *soxr
                    .get(b"soxr_process\0")
                    .map_err(|_| "missing resampler interface")?,
                delete: *soxr
                    .get(b"soxr_delete\0")
                    .map_err(|_| "missing resampler interface")?,
                _sound: sound,
                _soxr: soxr,
            })
        }
    }
    pub fn decode(&self, audio: &[u8]) -> Result<Vec<f32>> {
        if audio.is_empty() || audio.len() > 10 * 1024 * 1024 {
            return Err("Invalid audio size".into());
        }
        let mut temporary =
            tempfile::NamedTempFile::new().map_err(|_| "Could not prepare audio")?;
        temporary
            .write_all(audio)
            .map_err(|_| "Could not prepare audio")?;
        temporary.flush().map_err(|_| "Could not prepare audio")?;
        let path = CString::new(temporary.path().as_os_str().as_encoded_bytes())
            .map_err(|_| "Invalid audio path")?;
        let mut info = SoundInfo::default();
        // A decoded handle is confined to this scope and always closed.
        let handle = unsafe { (self.open)(path.as_ptr(), 0x10, &mut info) };
        if handle.is_null() {
            return Err("Unsupported or invalid audio file".into());
        }
        let result = (|| {
            if info.frames <= 0
                || info.frames > 100_000_000
                || info.channels <= 0
                || info.channels > 32
                || info.samplerate <= 0
                || info.samplerate > 384000
            {
                return Err("Invalid audio dimensions".into());
            }
            let frames = info.frames as usize;
            let channels = info.channels as usize;
            let size = frames
                .checked_mul(channels)
                .filter(|n| *n <= 100_000_000)
                .ok_or("Audio exceeds decoded size limit")?;
            let mut samples = vec![0f32; size];
            let read = unsafe { (self.read)(handle, samples.as_mut_ptr(), info.frames) };
            if read != info.frames {
                return Err("Could not decode complete audio".into());
            }
            let mono = if channels == 1 {
                samples
            } else {
                samples
                    .chunks_exact(channels)
                    .map(|frame| frame.iter().sum::<f32>() / channels as f32)
                    .collect()
            };
            if mono.iter().any(|v| !v.is_finite()) {
                return Err("Invalid audio samples".into());
            }
            if info.samplerate == 16000 {
                return Ok(mono);
            }
            self.resample(&mono, info.samplerate as f64)
        })();
        unsafe {
            (self.close)(handle);
        }
        result
    }
    fn resample(&self, input: &[f32], rate: f64) -> Result<Vec<f32>> {
        // Match python-soxr's mono split-channel, divided processing and HQ.
        let needed = (input.len() as f64 * 16000.0 / rate).ceil() as usize;
        if needed > 32_000_000 {
            return Err("Audio exceeds resampled size limit".into());
        }
        let mut output = vec![0f32; needed + 1];
        let mut error = std::ptr::null();
        let io = unsafe { (self.io)(4, 4) };
        let quality = unsafe { (self.quality)(4, 0) };
        let handle = unsafe {
            (self.create)(
                rate,
                16000.0,
                1,
                &mut error,
                &io,
                &quality,
                std::ptr::null(),
            )
        };
        if handle.is_null() || !error.is_null() {
            if !handle.is_null() {
                unsafe { (self.delete)(handle) }
            }
            return Err("Could not initialize audio resampling".into());
        }
        let result = (|| {
            let chunk = (48000.0 * rate / 16000.0).max(1000.0) as usize;
            let mut offset = 0;
            for frame in input.chunks(chunk) {
                let source = [frame.as_ptr()];
                let mut dest = [unsafe { output.as_mut_ptr().add(offset) }];
                let mut done = 0;
                let e = unsafe {
                    (self.process)(
                        handle,
                        source.as_ptr().cast(),
                        frame.len(),
                        std::ptr::null_mut(),
                        dest.as_mut_ptr().cast(),
                        output.len() - offset,
                        &mut done,
                    )
                };
                if !e.is_null() || done > output.len() - offset {
                    return Err("Audio resampling failed".into());
                }
                offset += done;
            }
            let mut dest = [unsafe { output.as_mut_ptr().add(offset) }];
            let mut done = 0;
            let e = unsafe {
                (self.process)(
                    handle,
                    std::ptr::null(),
                    0,
                    std::ptr::null_mut(),
                    dest.as_mut_ptr().cast(),
                    output.len() - offset,
                    &mut done,
                )
            };
            if !e.is_null() || done > output.len() - offset {
                return Err("Audio resampling failed".into());
            }
            offset += done;
            output.truncate(offset);
            // librosa fixes length to ceil(source_len * ratio), zero-padding.
            output.resize(needed, 0.0);
            Ok(output)
        })();
        unsafe {
            (self.delete)(handle);
        }
        result
    }
}
