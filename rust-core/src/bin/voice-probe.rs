//! Experimental offline audio comparison. No enrollment/profile writes.
use jarvis_core::native_voice::VoiceEngine;
use serde_json::json;
use std::{
    io::{self, BufRead, Write},
    path::Path,
    time::Instant,
};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("usage: voice-probe MODEL_DIRECTORY ORT_LIBRARY".into());
    }
    let mut engine = VoiceEngine::load(Path::new(&args[1]), Path::new(&args[2]))?;
    for line in io::stdin().lock().lines() {
        let path: String = serde_json::from_str(&line?)?;
        let start = Instant::now();
        let result = match std::fs::read(&path)
            .map_err(|e| e.to_string())
            .and_then(|audio| engine.embed(&audio))
        {
            Ok(v) => json!({"result":v,"elapsed_ms":start.elapsed().as_secs_f64()*1000.0}),
            Err(e) => json!({"error":e}),
        };
        println!("{result}");
        io::stdout().flush()?;
    }
    Ok(())
}
