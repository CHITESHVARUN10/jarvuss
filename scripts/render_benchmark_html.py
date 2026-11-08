#!/usr/bin/env python3
"""Render runtime benchmark JSON as a self-contained interactive HTML report."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

MIB = 1024 * 1024


def mib(value):
    return round(value / MIB, 1) if value else 0


def load(path):
    return json.loads(Path(path).read_text())


def build_payload(before, after=None, voice_before=None, voice_after=None):
    def report(value, voice):
        if not value:
            return None
        runner = value.get("runner", {})
        intent = runner.get("intent", [])
        plan = runner.get("plan", [])
        commands = []
        seen = set()
        for row in intent:
            if row["command"] not in seen:
                seen.add(row["command"])
                commands.append(row["command"])

        def median_by(rows, key):
            grouped = {}
            for row in rows:
                if key in row and row[key] is not None:
                    grouped.setdefault(row["command"], []).append(row[key])
            result = {}
            for command, values in grouped.items():
                values.sort()
                result[command] = values[len(values) // 2]
            return result

        return {
            "label": value.get("label"),
            "timestamp": value.get("timestamp"),
            "revision": value.get("source_revision"),
            "bundle": value.get("bundle", {}),
            "models": value.get("model_files", {}),
            "rss_idle": value.get("rss_idle", {}).get("app", {}),
            "rss_loaded": value.get("rss_loaded", {}).get("app", {}),
            "summary": runner.get("summary", {}),
            "intent_commands": commands,
            "intent_median": median_by(intent if value.get("merged") else intent[1:], "elapsed_ms"),
            "plan_median": median_by(plan, "elapsed_ms"),
            "whisper": value.get("whisper"),
            "ollama": value.get("ollama", []),
            "voice": (voice or {}).get("summary", {}),
            "voice_cases": (voice or {}).get("measured_requests_per_runtime"),
        }

    return {
        "before": report(before, voice_before),
        "after": report(after, voice_after) if after else None,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", required=True)
    parser.add_argument("--after")
    parser.add_argument("--voice-before")
    parser.add_argument("--voice-after")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    payload = build_payload(
        load(args.before),
        load(args.after) if args.after else None,
        load(args.voice_before) if args.voice_before else None,
        load(args.voice_after) if args.voice_after else None,
    )
    html = TEMPLATE.replace("__DATA__", json.dumps(payload, indent=2))
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_text(html)
    print(args.output)


TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Jarvis runtime benchmark</title>
<style>
:root{
  --bg:#08090b; --panel:#101216; --panel2:#15181d; --line:#262b33;
  --text:#f2f4f7; --muted:#8b93a1; --accent:#7dd3fc; --accent2:#c4b5fd;
  --good:#4ade80; --warn:#fbbf24; --bad:#fb7185; --grid:#20242b;
}
*{box-sizing:border-box}
body{margin:0;background:radial-gradient(1200px 700px at 15% -10%,#17202b 0,var(--bg) 55%);
  color:var(--text);font:14px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",Inter,sans-serif;
  padding:34px 28px 60px}
h1{font-size:28px;letter-spacing:-.03em;margin:0 0 6px;font-weight:650}
.sub{color:var(--muted);margin:0 0 26px}
.mono{font-family:"SF Mono",ui-monospace,Menlo,monospace;font-variant-numeric:tabular-nums}
.wrap{max-width:1180px;margin:0 auto}
.cards{display:grid;grid-template-columns:repeat(5,1fr);gap:12px;margin-bottom:26px}
.card{background:linear-gradient(180deg,var(--panel2),var(--panel));border:1px solid var(--line);
  border-radius:14px;padding:15px 16px;min-height:96px}
.card .k{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.09em}
.card .v{font-size:27px;font-weight:650;letter-spacing:-.03em;margin-top:7px}
.card .d{font-size:11px;color:var(--muted);margin-top:3px}
.tabs{display:flex;gap:6px;flex-wrap:wrap;margin:0 0 16px}
button{background:var(--panel);color:var(--muted);border:1px solid var(--line);
  border-radius:9px;padding:8px 13px;font:inherit;font-size:12px;cursor:pointer;transition:.15s}
button:hover{color:var(--text);border-color:#3a4250}
button.on{background:#1b2530;color:var(--accent);border-color:#2d5a73}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:20px 20px 14px;margin-bottom:18px}
.panel h2{font-size:14px;font-weight:600;margin:0 0 2px;letter-spacing:-.01em}
.panel .hint{color:var(--muted);font-size:11.5px;margin:0 0 16px}
svg{width:100%;display:block;overflow:visible}
.bar-label{fill:var(--text);font-size:11.5px}
.bar-value{fill:var(--muted);font-size:11px;font-variant-numeric:tabular-nums}
.grid-line{stroke:var(--grid);stroke-width:1}
.axis{fill:var(--muted);font-size:10.5px}
.legend{display:flex;gap:16px;color:var(--muted);font-size:11.5px;margin-top:8px;flex-wrap:wrap}
.dot{display:inline-block;width:9px;height:9px;border-radius:3px;margin-right:6px;vertical-align:1px}
table{width:100%;border-collapse:collapse;font-size:12px}
th{color:var(--muted);text-align:left;font-weight:500;padding:7px 8px;border-bottom:1px solid var(--line);
  font-size:11px;text-transform:uppercase;letter-spacing:.06em}
td{padding:9px 8px;border-bottom:1px solid #1b1f25}
td.num{text-align:right;font-variant-numeric:tabular-nums;font-family:"SF Mono",ui-monospace,monospace}
tr:last-child td{border-bottom:0}
.note{color:var(--muted);font-size:11px;line-height:1.65;border-top:1px solid var(--line);
  margin-top:18px;padding-top:14px}
.hidden{display:none}
.tooltip{position:fixed;pointer-events:none;background:#0c0f13;border:1px solid #333b47;
  border-radius:9px;padding:8px 10px;font-size:11.5px;color:#e8edf4;box-shadow:0 8px 30px #0008;
  opacity:0;transition:opacity .1s;z-index:9;max-width:280px}
.tag{display:inline-block;font-size:10px;padding:2px 7px;border-radius:999px;border:1px solid var(--line);
  color:var(--muted);margin-left:6px;vertical-align:1px}
@media(max-width:900px){.cards{grid-template-columns:repeat(2,1fr)}}
</style>
</head>
<body>
<div class="wrap">
  <h1>Jarvis runtime benchmark</h1>
  <p class="sub" id="sub"></p>
  <div class="cards" id="cards"></div>
  <div class="tabs" id="tabs"></div>
  <div id="views"></div>
  <div class="note" id="note"></div>
</div>
<div class="tooltip" id="tip"></div>
<script>
const DATA = __DATA__;
const fmt = (n,d=1)=> n==null?'—':Number(n).toLocaleString(undefined,{maximumFractionDigits:d});
const mib = (b)=> b==null?null:b/1048576;
let view = 'memory';
let metric = 'footprint';

const before = DATA.before, after = DATA.after;
const sub = document.getElementById('sub');
sub.innerHTML = `Measured ${before.timestamp} · source <span class="mono">${before.revision?.slice(0,12)||'—'}</span>` +
  (after?` · comparison <span class="mono">${after.revision?.slice(0,12)||'—'}</span>`:'') +
  ` · no Execute-mode actions`;

function card(k,v,d){return `<div class="card"><div class="k">${k}</div><div class="v mono">${v}</div><div class="d">${d||''}</div></div>`}
function cards(){
  const b=before, a=after;
  const bIdle=mib(b.rss_idle?.[`${metric}_bytes`]), bLoad=mib(b.rss_loaded?.[`${metric}_bytes`]);
  const aIdle=a?mib(a.rss_idle?.[`${metric}_bytes`]):null, aLoad=a?mib(a.rss_loaded?.[`${metric}_bytes`]):null;
  const items=[
    ['Bundle', fmt(mib(b.bundle.total?.bytes),1)+' MiB', a?`→ ${fmt(mib(a.bundle.total?.bytes),1)} MiB`:'signed candidate'],
    ['App idle', fmt(bIdle,1)+' MiB', a?`→ ${fmt(aIdle,1)} MiB`:(metric==='median'?'RSS':'physical footprint')],
    ['Intent loaded', fmt(bLoad,1)+' MiB', a?`→ ${fmt(aLoad,1)} MiB`:metric],
    ['Intent median', fmt(b.summary.intent_warm_median_ms,0)+' ms', a?`→ ${fmt(a.summary.intent_warm_median_ms,0)} ms`:'warm end-to-end'],
    ['Plan median', fmt(b.summary.plan_warm_median_ms,1)+' ms', a?`→ ${fmt(a.summary.plan_warm_median_ms,1)} ms`:'fast-path dominated'],
  ];
  document.getElementById('cards').innerHTML=items.map(x=>card(...x)).join('');
}
const tabs=[
  ['memory','Memory'],['size','Size'],['latency','Inference latency'],['models','Models'],['raw','Raw table']
];
document.getElementById('tabs').innerHTML = tabs.map(([k,l])=>`<button data-v="${k}" class="${view===k?'on':''}">${l}</button>`).join('') +
  `<span style="flex:1"></span><button id="metric">Metric: ${metric==='footprint'?'physical footprint':'RSS'}</button>`;
document.getElementById('tabs').addEventListener('click',e=>{
  const b=e.target.closest('button'); if(!b) return;
  if(b.id==='metric'){metric=metric==='footprint'?'median':'footprint';cards();render();return}
  view=b.dataset.v; document.querySelectorAll('#tabs button[data-v]').forEach(x=>x.classList.toggle('on',x.dataset.v===view)); render();
});

const tip=document.getElementById('tip');
function showTip(ev,html){tip.innerHTML=html;tip.style.opacity=1;tip.style.left=Math.min(ev.clientX+14,innerWidth-300)+'px';tip.style.top=(ev.clientY+16)+'px'}
function hideTip(){tip.style.opacity=0}

function svg(width,height,inner){return `<svg viewBox="0 0 ${width} ${height}" role="img">${inner}</svg>`}
function hbars(rows,opts={}){
  const W=opts.width||980, labelW=opts.labelW||250, valW=110, rowH=opts.rowH||30, gap=8;
  const H=rows.length*(rowH+gap)+8;
  const max=Math.max(...rows.flatMap(r=>r.values.map(v=>v.value||0)),1);
  const chartW=W-labelW-valW;
  let s='';
  const ticks=5;
  for(let i=0;i<=ticks;i++){const x=labelW+chartW*i/ticks;s+=`<line class="grid-line" x1="${x}" y1="0" x2="${x}" y2="${H-8}"/><text class="axis" x="${x}" y="${H-2}" text-anchor="middle">${fmt(max*i/ticks,0)}</text>`}
  rows.forEach((row,i)=>{
    const y=i*(rowH+gap);
    s+=`<text class="bar-label" x="0" y="${y+rowH/2+4}">${row.label}</text>`;
    const per=(chartW-(row.values.length-1)*4)/row.values.length;
    row.values.forEach((v,j)=>{
      const w=Math.max(0,(v.value||0)/max*per);
      const x=labelW+j*(per+4);
      s+=`<rect x="${x}" y="${y}" width="${w}" height="${rowH}" rx="5" fill="${v.color}" opacity="${v.dim?0.5:0.9}" data-tip="${v.tip||''}" class="bar"/>`;
      s+=`<text class="bar-value" x="${x+w+7}" y="${y+rowH/2+4}">${v.text}</text>`;
    });
  });
  return svg(W,H,s);
}

function sizeView(){
  const b=before, a=after;
  const rows=[
    {label:'Bundle total',values:[{value:mib(b.bundle.total?.bytes),text:fmt(mib(b.bundle.total?.bytes),1)+' MiB',color:'var(--accent)'}].concat(a?[{value:mib(a.bundle.total?.bytes),text:fmt(mib(a.bundle.total?.bytes),1)+' MiB',color:'var(--accent2)'}]:[]),tip:'Signed .app regular-file inventory'},
    {label:'MacOS binaries',values:[{value:mib(b.bundle.macos?.bytes),text:fmt(mib(b.bundle.macos?.bytes),1)+' MiB',color:'var(--accent)'}].concat(a?[{value:mib(a.bundle.macos?.bytes),text:fmt(mib(a.bundle.macos?.bytes),1)+' MiB',color:'var(--accent2)'}]:[]),tip:'Jarvis + JarvisBackend + start script'},
    {label:'Resources',values:[{value:mib(b.bundle.resources?.bytes),text:fmt(mib(b.bundle.resources?.bytes),1)+' MiB',color:'var(--accent)'}].concat(a?[{value:mib(a.bundle.resources?.bytes),text:fmt(mib(a.bundle.resources?.bytes),1)+' MiB',color:'var(--accent2)'}]:[]),tip:'Intent model, voice assets, fonts, runner HTML'},
    {label:'Intent model',values:[{value:mib(b.bundle.intent_model?.bytes),text:fmt(mib(b.bundle.intent_model?.bytes),1)+' MiB',color:'var(--accent)'}].concat(a?[{value:mib(a.bundle.intent_model?.bytes),text:fmt(mib(a.bundle.intent_model?.bytes),1)+' MiB',color:'var(--accent2)'}]:[]),tip:'Quantized T5-small encoder + merged decoder'},
    {label:'Native voice',values:[{value:mib(b.bundle.native_voice?.bytes),text:fmt(mib(b.bundle.native_voice?.bytes),1)+' MiB',color:'var(--accent)'}].concat(a?[{value:mib(a.bundle.native_voice?.bytes),text:fmt(mib(a.bundle.native_voice?.bytes),1)+' MiB',color:'var(--accent2)'}]:[]),tip:'Speaker encoder, libsndfile, libsoxr'},
  ];
  return `<div class="panel"><h2>Bundle composition</h2><p class="hint">Regular-file bytes, not compressed download size.</p>${hbars(rows,{labelW:210})}
    <div class="legend"><span><i class="dot" style="background:var(--accent)"></i>Before</span>${after?'<span><i class="dot" style="background:var(--accent2)"></i>After</span>':''}</div></div>`;
}

function memoryView(){
  const b=before,a=after;
  const idle=b.rss_idle?.[`${metric}_bytes`], load=b.rss_loaded?.[`${metric}_bytes`];
  const voice=b.voice?.native?.rss_median_bytes, whisper=b.whisper?.peak_footprint_bytes||b.whisper?.max_rss_bytes;
  const qwen=(b.ollama||[]).find(o=>o.model.includes('1.5b'));
  const qwenRss=qwen?Math.max(...qwen.processes.map(p=>p.rss_bytes)):null;
  const rows=[
    {label:'App idle',values:[{value:mib(idle),text:fmt(mib(idle),1)+' MiB',color:'var(--good)'}],tip:'Candidate app after launch, before any model load'},
    {label:'App + intent model',values:[{value:mib(load),text:fmt(mib(load),1)+' MiB',color:'var(--warn)'}],tip:'After native ORT intent inference; includes model + arena'},
    {label:'Voice helper',values:[{value:mib(voice),text:fmt(mib(voice),1)+' MiB',color:'var(--accent)'}],tip:'JarvisBackend RSS with speaker encoder loaded'},
    {label:'Whisper STT core',values:[{value:mib(whisper),text:fmt(mib(whisper),1)+' MiB',color:'var(--bad)'}],tip:'Standalone STT-core process peak footprint (same Rust engine; not in-app attribution)'},
    {label:'Qwen 1.5B (Ollama)',values:[{value:mib(qwenRss),text:fmt(mib(qwenRss),1)+' MiB',color:'var(--accent2)'}],tip:'llama-server RSS while qwen2.5:1.5b-instruct is resident'},
  ];
  const sum=[idle,voice,whisper,qwenRss].reduce((x,y)=>x+(y||0),0);
  return `<div class="panel"><h2>Memory by model state</h2><p class="hint">App states are the same process; voice, Whisper and Ollama are separate processes. ${metric==='median'?'RSS includes shared pages.':'Physical footprint from <code>footprint(1)</code> where available.'}</p>
    ${hbars(rows,{labelW:210})}
    <div class="legend"><span>Sum of app idle + voice + Whisper + Qwen ≈ <b class="mono">${fmt(mib(sum),1)} MiB</b></span><span>App + intent + voice + Whisper + Qwen ≈ <b class="mono">${fmt(mib((load||0)+(voice||0)+(whisper||0)+(qwenRss||0)),1)} MiB</b></span></div>
    </div>`;
}

function latencyView(){
  const b=before,a=after;
  const cmds=b.intent_commands||[];
  const rows=cmds.map(c=>({label:c,values:[{value:b.intent_median[c],text:fmt(b.intent_median[c],0)+' ms',color:'var(--accent)'}].concat(a?[{value:a.intent_median[c],text:fmt(a.intent_median[c],0)+' ms',color:'var(--accent2)'}]:[]),tip:`Intent mode · ${c}`}));
  return `<div class="panel"><h2>Intent inference, warm end-to-end</h2><p class="hint">Test-runner round trip: HTTP request → native ORT decode → mapped actions. Median of two warm rounds.</p>${hbars(rows,{labelW:270})}
  <div class="legend"><span><i class="dot" style="background:var(--accent)"></i>Before</span>${after?'<span><i class="dot" style="background:var(--accent2)"></i>After</span>':''}<span>Plan-mode medians: ${Object.entries(b.plan_median).map(([k,v])=>`${k} ${fmt(v,0)}ms`).slice(0,4).join(' · ')}…</span></div></div>`;
}

function modelsView(){
  const b=before;
  const rows=[];
  const add=(name,disk,rss,note)=>rows.push({name,disk,rss,note});
  add('Intent T5-small', b.models.intent_encoder+b.models.intent_decoder, (b.rss_loaded?.[`${metric}_bytes`]||0)-(b.rss_idle?.[`${metric}_bytes`]||0), 'encoder + decoder; RSS delta includes ORT arena');
  add('Voice encoder', b.models.voice_encoder, b.voice?.native?.rss_median_bytes, 'loaded helper RSS');
  add('Whisper large-v3-turbo', b.models.whisper, b.whisper?.peak_footprint_bytes||b.whisper?.max_rss_bytes, `load ${b.whisper?.load_ms||'—'} ms · transcribe ${b.whisper?.transcribe_ms||'—'} ms / ${b.whisper?.audio_seconds}s`);
  (b.ollama||[]).forEach(o=>{
    const rss=Math.max(...(o.processes||[]).map(p=>p.rss_bytes),0);
    add(o.model, o.model_bytes, rss, `cold ${fmt(o.cold_ms,0)} ms · warm ${fmt(o.warm_median_ms,0)} ms`);
  });
  return `<div class="panel"><h2>Model footprint and speed</h2><p class="hint">Disk is the model artifact; memory is process RSS/footprint, not an isolated weight delta.</p>
  <table><thead><tr><th>Model</th><th class="num">Disk</th><th class="num">Memory</th><th>Notes</th></tr></thead><tbody>
  ${rows.map(r=>`<tr><td>${r.name}</td><td class="num">${fmt(mib(r.disk),1)} MiB</td><td class="num">${fmt(mib(r.rss),1)} MiB</td><td style="color:var(--muted)">${r.note}</td></tr>`).join('')}
  </tbody></table></div>`;
}

function rawView(){
  return `<div class="panel"><h2>Raw summary</h2><p class="hint">Numbers exactly as recorded in the JSON reports.</p>
  <table><thead><tr><th>Metric</th><th class="num">Before</th><th class="num">After</th></tr></thead><tbody>
  ${[
    ['Bundle (MiB)',mib(before.bundle.total?.bytes),after?mib(after.bundle.total?.bytes):null],
    ['App idle RSS (MiB)',mib(before.rss_idle?.median_bytes),after?mib(after.rss_idle?.median_bytes):null],
    ['App loaded RSS (MiB)',mib(before.rss_loaded?.median_bytes),after?mib(after.rss_loaded?.median_bytes):null],
    ['App idle footprint (MiB)',mib(before.rss_idle?.footprint_bytes),after?mib(after.rss_idle?.footprint_bytes):null],
    ['App loaded footprint (MiB)',mib(before.rss_loaded?.footprint_bytes),after?mib(after.rss_loaded?.footprint_bytes):null],
    ['Intent median (ms)',before.summary.intent_warm_median_ms,after?after.summary.intent_warm_median_ms:null],
    ['Plan median (ms)',before.summary.plan_warm_median_ms,after?after.summary.plan_warm_median_ms:null],
    ['Voice warm median (ms)',before.voice?.native?.warm_median_ms,after?after.voice?.native?.warm_median_ms:null],
    ['Voice helper RSS (MiB)',mib(before.voice?.native?.rss_median_bytes),after?mib(after.voice?.native?.rss_median_bytes):null],
    ['Whisper load (ms)',before.whisper?.load_ms,after?after.whisper?.load_ms:null],
    ['Whisper transcribe (ms)',before.whisper?.transcribe_ms,after?after.whisper?.transcribe_ms:null],
    ['Whisper peak footprint (MiB)',mib(before.whisper?.peak_footprint_bytes),after?mib(after.whisper?.peak_footprint_bytes):null],
  ].map(([k,b,a])=>`<tr><td>${k}</td><td class="num">${fmt(b,1)}</td><td class="num">${after?fmt(a,1):'—'}</td></tr>`).join('')}
  </tbody></table></div>`;
}

function render(){
  cards();
  const v={memory:memoryView,size:sizeView,latency:latencyView,models:modelsView,raw:rawView}[view];
  document.getElementById('views').innerHTML=v();
  document.querySelectorAll('.bar').forEach(el=>{
    el.addEventListener('mousemove',e=>showTip(e,el.dataset.tip));
    el.addEventListener('mouseleave',hideTip);
  });
}
document.getElementById('note').innerHTML = `Method: candidate bundle built from the recorded source revision; test runner in Plan/Intent modes only (no Execute actions). Intent numbers are warm medians after one warm-up round. Memory is RSS and/or physical footprint; shared pages can be counted in more than one process, so the combined figure is an upper-bound attribution, not a single measured total. Whisper is measured in the standalone STT-core process using the same Rust engine and model. Ollama models are Ollama app processes, not Jarvis RSS. No voice, microphone, Spotify, database or file actions were executed.`;
render();
</script>
</body>
</html>
"""

if __name__ == "__main__":
    main()
