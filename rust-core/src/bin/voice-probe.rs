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
    if args.len() != 3 && args.len() != 4 {
        return Err("usage: voice-probe MODEL_DIRECTORY ORT_LIBRARY [cpu|coreml]".into());
    }
    let provider = args.get(3).map(String::as_str).unwrap_or("cpu");
    let load = Instant::now();
    let mut engine = VoiceEngine::load_with_provider(Path::new(&args[1]), Path::new(&args[2]), provider)?;
    eprintln!("{}", json!({"provider":provider,"load_ms":load.elapsed().as_secs_f64()*1000.0}));
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
