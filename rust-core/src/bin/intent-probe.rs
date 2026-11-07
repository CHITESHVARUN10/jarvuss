//! Offline comparison harness. JSONL requests on stdin; no network or OS actions.
use jarvis_core::native_intent::Engine;
use serde_json::json;
use std::{
    io::{self, BufRead, Write},
    path::Path,
    time::Instant,
};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("usage: intent-probe MODEL_DIRECTORY ORT_LIBRARY".into());
    }
    let start = Instant::now();
    let mut engine = Engine::load(Path::new(&args[1]), Path::new(&args[2]))?;
    eprintln!(
        "{}",
        json!({"load_ms":start.elapsed().as_secs_f64()*1000.0})
    );
    for line in io::stdin().lock().lines() {
        let text: String = serde_json::from_str(&line?)?;
        let start = Instant::now();
        let output = match engine.generate(&text) {
            Ok(g) => {
                json!({"text":text,"generation":g,"elapsed_ms":start.elapsed().as_secs_f64()*1000.0})
            }
            Err(e) => json!({"text":text,"error":e}),
        };
        println!("{output}");
        io::stdout().flush()?;
    }
    Ok(())
}
