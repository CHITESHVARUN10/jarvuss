#!/usr/bin/env python3
"""Render the expanded interactive benchmark report (charts + glossary)."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from render_benchmark_html import build_payload, load


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", required=True)
    parser.add_argument("--after", required=True)
    parser.add_argument("--voice-before")
    parser.add_argument("--voice-after")
    parser.add_argument("--old-bytes", type=int, default=1300369374)
    parser.add_argument("--new-bytes", type=int, default=316429228)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    payload = build_payload(
        load(args.before),
        load(args.after),
        load(args.voice_before) if args.voice_before else None,
        load(args.voice_after) if args.voice_after else None,
    )
    old_mib = args.old_bytes / 1048576
    new_mib = args.new_bytes / 1048576
    payload["installed"] = {
        "old_bytes": args.old_bytes,
        "new_bytes": args.new_bytes,
        "old_mib": round(old_mib, 1),
        "new_mib": round(new_mib, 1),
        "saved_mib": round(old_mib - new_mib, 1),
        "saved_percent": round((1 - args.new_bytes / args.old_bytes) * 100, 1),
    }
    payload["migration"] = {
        "swift_deleted": 987,
        "swift_added": 84,
        "rust_added": 1763,
        "rust_tests": 111,
        "rust_ignored": 1,
        "swift_tests": 393,
        "swift_skipped": 13,
        "files": [
            ["TranscriptFormatter.swift", 509],
            ["DictationPolisher.swift", 158],
            ["OpenTargetResolver.swift", 140],
            ["ProjectLocations.swift", 63],
            ["PostgresProvisioner.swift", 31],
            ["StringDistance.swift", 30],
            ["FastPathRouter.swift", 21],
            ["DotEnvLoader.swift", 19],
            ["ActionPlanner+Rules.swift", 16],
        ],
        "modules": [
            ["dictation.rs", 911, "Dictation rules, list directive, polish guards"],
            ["project_policy.rs", 340, "Bounded project traversal and alias matching"],
            ["open_target.rs", 213, "Site, browser and local-dev URL resolution"],
            ["postgres_sql.rs", 178, "SQL builders, validation, redaction"],
            ["text_distance.rs", 64, "Grapheme Levenshtein and similarity"],
            ["env_policy.rs", 57, ".env parsing and quoting"],
        ],
        "build_fixes": [
            ["SwiftPM", "Package/tests use --build-system native to avoid duplicate module.map with two static xcframeworks."],
            ["Rust", "[profile.release.build-override] strip = \"none\" avoids a corrupt pest_derive proc-macro dylib."],
        ],
    }
    payload["glossary"] = [
        ["Bundle", "The .app folder on disk.", "Everything inside Jarvis.app: executable, Rust/UniFFI code, ONNX intent model, voice assets, fonts and resources. It is storage size, not RAM. It is not a compressed download size either."],
        ["Application size", "The installed app's disk footprint.", "Same as bundle size once copied to /Applications. The old app was 1.30 GB because it bundled a Python runtime; the new app is 301.8 MiB of regular files."],
        ["Intent warm median", "What a real intent request costs after warm-up.", "The middle end-to-end time in the test runner's Intent mode: request → tokenizer → native ONNX/T5 decode → mapped actions. 'Warm' means the model is already resident; the first request (cold) also pays model load."],
        ["Intent model median", "The model's own inference time.", "The latency reported inside the intent response, excluding most test-runner/HTTP overhead. If it is close to the warm median, the model dominates; a gap is transport or mapping work."],
        ["Plan warm median", "The full planner's decision time.", "Plan mode runs fast paths, rules and (only when needed) the learned model, but never executes actions. Most commands hit a ~0–2 ms fast path; compound/ambiguous ones pay ~100–200 ms for the intent model, so the median is 1 ms while the tail is much larger."],
        ["Intent-loaded footprint", "Physical memory after the intent model is loaded.", "The app process's memory once the native intent model and ONNX runtime are resident, after inference. It includes weights, runtime and the ORT memory arena, not just the 193 MiB model files."],
        ["Idle footprint", "Memory before any model is loaded.", "App process after launch with UI, Swift/UniFFI code and resources but no intent/Whisper model. This is the baseline cost of the shell."],
        ["RSS", "Resident Set Size.", "Pages currently resident in memory. It includes shared pages, so adding process RSS can double-count frameworks and is an upper bound."],
        ["Physical footprint", "The OS's physical-memory attribution.", "Taken with footprint(1). It is usually a better answer to 'how much RAM does this process really cost' than RSS, though there is still shared-page nuance."],
        ["Voice helper RSS", "Memory of the separate voice process.", "JarvisBackend loads the speaker encoder (5.4 MiB on disk) and holds enrolled profiles. It is a separate process from the app, so its memory is reported separately."],
        ["Whisper peak footprint", "Peak memory while STT runs.", "The standalone STT-core process loads Whisper large-v3-turbo (1.55 GiB on disk) and transcribes a synthetic clip. Peak includes model weights, buffers and inference workspace."],
        ["Qwen RSS", "Memory of the local LLM process.", "Ollama serves qwen2.5:1.5b-instruct through a llama-server process. Its RSS is the model plus KV cache/runtime, not Jarvis app RSS. It is only resident when Ollama has the model loaded."],
        ["Cold vs warm", "First request vs later requests.", "Cold includes loading weights from disk and initializing the runtime. Warm reuses the resident model, so it is the right number for 'how fast is the next command'."],
        ["Median", "The middle measurement.", "Sort the samples and take the middle. It is less distorted by one slow outlier than an average. The report also shows the observed range where the spread matters."],
        ["MiB vs MB", "Two different units.", "MiB = 1024² bytes. MB = 1000² bytes. The report uses MiB for bundle/model memory and MB only where a model's decimal size is quoted. A 301.8 MiB bundle is about 316 MB."],
        ["Bundle composition", "What the disk number is made of.", "MacOS/executable bytes, Resources (intent model, native voice runtime, fonts), and signatures. The intent model alone is 196.2 MiB; that is why the bundle cannot shrink to a few megabytes."],
        ["Model disk vs memory", "Two different costs.", "Disk is the artifact size (e.g. 193 MiB of ONNX files). Memory is the process footprint after loading; ORT/llama.cpp allocate runtime, KV/activation and arena memory beyond the file size."],
        ["Rust migration", "What actually moved.", "Pure policies moved behind typed UniFFI calls: dictation text rules, string distance, URL/browser resolution, .env parsing, PostgreSQL SQL/validation and project traversal. Swift keeps UI, Apple APIs, permissions, Keychain and async orchestration."],
        ["Native adapter", "Thin Swift code around Rust.", "Swift still calls AppKit/CoreAudio/Accessibility/Keychain and passes plain values into Rust. The adapter converts types and performs OS effects; the Rust module owns the decision."],
    ]

    html = TEMPLATE.replace("__DATA__", json.dumps(payload, indent=2))
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_text(html)
    print(args.output)


TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Jarvis runtime report</title>
<style>
:root{
  --bg:#08090b;--panel:#101216;--panel2:#15181d;--line:#262b33;--text:#f2f4f7;
  --muted:#8b93a1;--accent:#7dd3fc;--accent2:#c4b5fd;--good:#4ade80;
  --warn:#fbbf24;--bad:#fb7185;--grid:#20242b;
}
*{box-sizing:border-box}
body{margin:0;background:radial-gradient(1200px 700px at 12% -10%,#17202b 0,var(--bg) 58%);
  color:var(--text);font:14px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",Inter,sans-serif;
  padding:30px 26px 54px}
h1{font-size:30px;letter-spacing:-.035em;margin:0 0 6px;font-weight:650}
.sub{color:var(--muted);margin:0 0 22px;max-width:760px}
.mono{font-family:"SF Mono",ui-monospace,Menlo,monospace;font-variant-numeric:tabular-nums}
.wrap{max-width:1180px;margin:0 auto}
.cards{display:grid;grid-template-columns:repeat(5,1fr);gap:11px;margin-bottom:22px}
.card{background:linear-gradient(180deg,var(--panel2),var(--panel));border:1px solid var(--line);
  border-radius:13px;padding:14px 15px;min-height:94px}
.card .k{color:var(--muted);font-size:10.5px;text-transform:uppercase;letter-spacing:.08em}
.card .v{font-size:25px;font-weight:650;letter-spacing:-.03em;margin-top:6px}
.card .d{font-size:10.5px;color:var(--muted);margin-top:3px;line-height:1.35}
.tabs{display:flex;gap:6px;flex-wrap:wrap;margin:0 0 15px}
button{background:var(--panel);color:var(--muted);border:1px solid var(--line);border-radius:8px;
  padding:7px 12px;font:inherit;font-size:12px;cursor:pointer;transition:.15s}
button:hover{color:var(--text);border-color:#3a4250}
button.on{background:#1b2530;color:var(--accent);border-color:#2d5a73}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:15px;
  padding:18px 18px 13px;margin-bottom:16px}
.panel h2{font-size:14px;font-weight:600;margin:0 0 2px;letter-spacing:-.01em}
.panel .hint{color:var(--muted);font-size:11.5px;margin:0 0 14px;max-width:980px}
svg{width:100%;display:block;overflow:visible}
.bar-label{fill:var(--text);font-size:11px}
.bar-value{fill:var(--muted);font-size:10.5px;font-variant-numeric:tabular-nums}
.grid-line{stroke:var(--grid);stroke-width:1}
.axis{fill:var(--muted);font-size:10px}
.legend{display:flex;gap:14px;color:var(--muted);font-size:11px;margin-top:8px;flex-wrap:wrap}
.dot{display:inline-block;width:9px;height:9px;border-radius:3px;margin-right:5px;vertical-align:1px}
table{width:100%;border-collapse:collapse;font-size:12px}
th{color:var(--muted);text-align:left;font-weight:500;padding:7px 8px;border-bottom:1px solid var(--line);
  font-size:10.5px;text-transform:uppercase;letter-spacing:.05em}
td{padding:8px;border-bottom:1px solid #1b1f25;vertical-align:top}
td.num{text-align:right;font-variant-numeric:tabular-nums;font-family:"SF Mono",ui-monospace,monospace}
tr:last-child td{border-bottom:0}
.note{color:var(--muted);font-size:11px;line-height:1.65;border-top:1px solid var(--line);
  margin-top:16px;padding-top:12px}
.tooltip{position:fixed;pointer-events:none;background:#0c0f13;border:1px solid #333b47;
  border-radius:8px;padding:7px 9px;font-size:11px;color:#e8edf4;box-shadow:0 8px 28px #0008;
  opacity:0;transition:opacity .1s;z-index:9;max-width:300px}
.tag{display:inline-block;font-size:10px;padding:2px 7px;border-radius:999px;
  border:1px solid var(--line);color:var(--muted);margin-left:5px}
.delta-up{color:var(--bad)}.delta-down{color:var(--good)}.delta-flat{color:var(--muted)}
.gloss{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:12px}
.gloss .item{background:var(--panel2);border:1px solid var(--line);border-radius:11px;padding:12px 13px}
.gloss .term{font-weight:600;font-size:12.5px}
.gloss .short{color:var(--accent);font-size:11px;margin-top:2px}
.gloss .detail{color:var(--muted);font-size:11.5px;line-height:1.55;margin-top:6px}
input{background:var(--panel2);border:1px solid var(--line);color:var(--text);border-radius:8px;
  padding:8px 10px;font:inherit;font-size:12px;width:280px;max-width:100%}
@media(max-width:900px){.cards{grid-template-columns:repeat(2,1fr)}.gloss{grid-template-columns:1fr}}
</style>
</head>
<body>
<div class="wrap">
  <h1>Jarvis runtime report</h1>
  <p class="sub" id="sub"></p>
  <div class="cards" id="cards"></div>
  <div class="tabs" id="tabs"></div>
  <div id="views"></div>
  <div class="note" id="note"></div>
</div>
<div class="tooltip" id="tip"></div>
<script>
const DATA = __DATA__;
const fmt=(n,d=1)=>n==null?'—':Number(n).toLocaleString(undefined,{maximumFractionDigits:d});
const mib=b=>b==null?null:b/1048576;
const before=DATA.before, after=DATA.after, inst=DATA.installed, mig=DATA.migration;
let view='overview', metric='footprint', orientation='vertical';
document.getElementById('sub').innerHTML =
  `Baseline vs post-migration · ${before.timestamp} · source <span class="mono">${before.revision?.slice(0,12)}</span> · installed <span class="mono">${'B53D17A3'}</span> · no Execute-mode actions`;
function card(k,v,d){return `<div class="card"><div class="k">${k}</div><div class="v mono">${v}</div><div class="d">${d||''}</div></div>`}
function cards(){
  document.getElementById('cards').innerHTML=[
    ['Installed app','1.30 GB → 0.32 GB',`${fmt(inst.saved_mib,0)} MiB saved (${fmt(inst.saved_percent,1)}%)`],
    ['Intent warm median',`${fmt(before.summary.intent_warm_median_ms,0)} → ${fmt(after.summary.intent_warm_median_ms,0)} ms`,'warm request-to-actions'],
    ['Intent model median',`${fmt(before.summary.intent_model_median_ms,0)} → ${fmt(after.summary.intent_model_median_ms,0)} ms`,'model inference itself'],
    ['Plan median','1 → 1 ms','fast paths dominate'],
    ['Tests','393 / 111','Swift / Rust, zero failures'],
  ].map(x=>card(...x)).join('');
}
const tabs=[['overview','Overview'],['memory','Memory'],['latency','Latency'],['models','Models'],['migration','Migration'],['glossary','Glossary']];
document.getElementById('tabs').innerHTML=tabs.map(([k,l])=>`<button data-v="${k}" class="${view===k?'on':''}">${l}</button>`).join('')+
  `<span style="flex:1"></span><button id="metric">Memory: ${metric==='footprint'?'physical footprint':'RSS'}</button>`+
  `<button id="orientation">Latency: ${orientation==='vertical'?'vertical':'horizontal'}</button>`;
document.getElementById('tabs').addEventListener('click',e=>{
  const b=e.target.closest('button'); if(!b)return;
  if(b.id==='metric'){metric=metric==='footprint'?'median':'footprint';render();return}
  if(b.id==='orientation'){orientation=orientation==='vertical'?'horizontal':'vertical';render();return}
  view=b.dataset.v;document.querySelectorAll('#tabs button[data-v]').forEach(x=>x.classList.toggle('on',x.dataset.v===view));render();
});
const tip=document.getElementById('tip');
function showTip(ev,html){tip.innerHTML=html;tip.style.opacity=1;tip.style.left=Math.min(ev.clientX+14,innerWidth-310)+'px';tip.style.top=(ev.clientY+16)+'px'}
function hideTip(){tip.style.opacity=0}
function attachTips(){document.querySelectorAll('[data-tip]').forEach(el=>{el.addEventListener('mousemove',e=>showTip(e,el.dataset.tip));el.addEventListener('mouseleave',hideTip)})}
function hbars(rows,opts={}){
  const W=980,labelW=opts.labelW||245,valW=105,rowH=opts.rowH||29,gap=7;
  const H=rows.length*(rowH+gap)+8;
  const max=Math.max(...rows.flatMap(r=>r.values.map(v=>v.value||0)),1);
  const chartW=W-labelW-valW;
  let s='';
  for(let i=0;i<=5;i++){const x=labelW+chartW*i/5;s+=`<line class="grid-line" x1="${x}" y1="0" x2="${x}" y2="${H-8}"/><text class="axis" x="${x}" y="${H-2}" text-anchor="middle">${fmt(max*i/5,0)}</text>`}
  rows.forEach((row,i)=>{
    const y=i*(rowH+gap);
    s+=`<text class="bar-label" x="0" y="${y+rowH/2+4}">${row.label}</text>`;
    const per=(chartW-(row.values.length-1)*4)/row.values.length;
    row.values.forEach((v,j)=>{
      const w=Math.max(0,(v.value||0)/max*per),x=labelW+j*(per+4);
      s+=`<rect x="${x}" y="${y}" width="${w}" height="${rowH}" rx="5" fill="${v.color}" opacity=".9" data-tip="${v.tip||''}" class="bar"/>`;
      s+=`<text class="bar-value" x="${x+w+6}" y="${y+rowH/2+4}">${v.text}</text>`;
    });
  });
  return `<svg viewBox="0 0 ${W} ${H}">${s}</svg>`;
}
function vbars(labels,series,opts={}){
  const W=1000,H=opts.height||360,padL=58,padR=18,padT=16,padB=92;
  const chartW=W-padL-padR,chartH=H-padT-padB;
  const all=series.flatMap(s=>s.values);
  const max=Math.max(...all,1);
  let s='';
  for(let i=0;i<=5;i++){const y=padT+chartH-chartH*i/5;s+=`<line class="grid-line" x1="${padL}" y1="${y}" x2="${W-padR}" y2="${y}"/><text class="axis" x="${padL-8}" y="${y+3}" text-anchor="end">${fmt(max*i/5,0)}</text>`}
  const groupW=chartW/labels.length, barW=Math.min(22,(groupW-8)/series.length);
  labels.forEach((label,i)=>{
    series.forEach((ser,j)=>{
      const v=ser.values[i]||0, h=chartH*v/max;
      const x=padL+i*groupW+(groupW-barW*series.length)/2+j*barW;
      s+=`<rect x="${x}" y="${padT+chartH-h}" width="${barW}" height="${Math.max(h,1)}" rx="3" fill="${ser.color}" opacity=".92" data-tip="${ser.name} · ${label}: ${fmt(v,0)} ms" class="bar"/>`;
    });
    const x=padL+i*groupW+groupW/2;
    s+=`<text class="axis" transform="translate(${x},${padT+chartH+10}) rotate(-35)" text-anchor="end">${label.length>28?label.slice(0,26)+'…':label}</text>`;
  });
  return `<svg viewBox="0 0 ${W} ${H}">${s}</svg>`;
}
function stacked(rows,opts={}){
  const W=980,labelW=150,valW=110,rowH=34,gap=16;
  const H=rows.length*(rowH+gap)+8, chartW=W-labelW-valW;
  const totals=rows.map(r=>r.values.reduce((a,b)=>a+b.value,0));
  const max=Math.max(...totals,1);
  let s='';
  rows.forEach((row,i)=>{
    const y=i*(rowH+gap);let x=labelW;
    s+=`<text class="bar-label" x="0" y="${y+rowH/2+4}">${row.label}</text>`;
    row.values.forEach(v=>{
      const w=chartW*v.value/max;
      if(w>0)s+=`<rect x="${x}" y="${y}" width="${w}" height="${rowH}" fill="${v.color}" opacity=".9" data-tip="${v.name}: ${fmt(v.value,1)} MiB" class="bar"/>`;
      x+=w;
    });
    s+=`<text class="bar-value" x="${x+7}" y="${y+rowH/2+4}">${fmt(totals[i],1)} MiB</text>`;
  });
  return `<svg viewBox="0 0 ${W} ${H}">${s}</svg>`;
}
function lineChart(series,labels,opts={}){
  const W=980,H=250,padL=52,padR=18,padT=16,padB=36;
  const cw=W-padL-padR,ch=H-padT-padB;
  const all=series.flatMap(s=>s.values);
  const max=Math.max(...all,1)*1.1;
  let s='';
  for(let i=0;i<=4;i++){const y=padT+ch-ch*i/4;s+=`<line class="grid-line" x1="${padL}" y1="${y}" x2="${W-padR}" y2="${y}"/><text class="axis" x="${padL-8}" y="${y+3}" text-anchor="end">${fmt(max*i/4,0)}</text>`}
  labels.forEach((label,i)=>{const x=padL+cw*i/(labels.length-1);s+=`<text class="axis" x="${x}" y="${H-10}" text-anchor="middle">${label}</text>`});
  series.forEach(ser=>{
    const points=ser.values.map((v,i)=>[padL+cw*i/(labels.length-1),padT+ch-ch*v/max]);
    s+=`<polyline points="${points.map(p=>p.join(',')).join(' ')}" fill="none" stroke="${ser.color}" stroke-width="2.5" stroke-linejoin="round"/>`;
    points.forEach((p,i)=>{s+=`<circle cx="${p[0]}" cy="${p[1]}" r="4" fill="${ser.color}" data-tip="${ser.name} · run ${i+1}: ${fmt(ser.values[i],1)} ms" class="bar"/>`});
  });
  return `<svg viewBox="0 0 ${W} ${H}">${s}</svg>`;
}
function delta(b,a){if(a==null||b==null)return['','delta-flat'];const d=a-b;const pct=b?d/b*100:0;return [`${d>0?'+':''}${fmt(d,1)} ms (${d>0?'+':''}${fmt(pct,0)}%)`,d>2?'delta-up':d<-2?'delta-down':'delta-flat']}
function overview(){
  const b=before,a=after;
  const bundleRows=[
    {label:'Old installed app',values:[{value:inst.old_mib,text:fmt(inst.old_mib,0)+' MiB',color:'var(--bad)'}],tip:'The previous /Applications/Jarvis.app, including its bundled Python environment'},
    {label:'New installed app',values:[{value:inst.new_mib,text:fmt(inst.new_mib,0)+' MiB',color:'var(--good)'}],tip:'The rebuilt app after the Rust cutovers; no Python runtime is shipped'},
    {label:'Candidate bundle',values:[{value:mib(b.bundle.total?.bytes),text:fmt(mib(b.bundle.total?.bytes),1)+' MiB',color:'var(--accent)'}],tip:'The .build/Jarvis.app bundle used for the benchmark'},
  ];
  const summary=[
    {label:'Intent warm median',values:[{value:b.summary.intent_warm_median_ms,text:fmt(b.summary.intent_warm_median_ms,0)+' ms',color:'var(--accent)'},{value:a.summary.intent_warm_median_ms,text:fmt(a.summary.intent_warm_median_ms,0)+' ms',color:'var(--accent2)'}],tip:'Request-to-actions after warm-up; before vs after'},
    {label:'Intent model median',values:[{value:b.summary.intent_model_median_ms,text:fmt(b.summary.intent_model_median_ms,1)+' ms',color:'var(--accent)'},{value:a.summary.intent_model_median_ms,text:fmt(a.summary.intent_model_median_ms,1)+' ms',color:'var(--accent2)'}],tip:'Model-reported inference only'},
    {label:'Plan warm median',values:[{value:b.summary.plan_warm_median_ms,text:fmt(b.summary.plan_warm_median_ms,1)+' ms',color:'var(--accent)'},{value:a.summary.plan_warm_median_ms,text:fmt(a.summary.plan_warm_median_ms,1)+' ms',color:'var(--accent2)'}],tip:'Planner decision only; no actions executed'},
  ];
  return `<div class="panel"><h2>Installed size: the headline</h2><p class="hint">The .app folder on disk. The old build shipped a Python runtime; the new build ships native Rust services and no Python. This is storage, not RAM.</p>${hbars(bundleRows,{labelW:170})}
  <div class="legend"><span><i class="dot" style="background:var(--bad)"></i>Old app</span><span><i class="dot" style="background:var(--good)"></i>New app</span><span><i class="dot" style="background:var(--accent)"></i>Benchmark bundle</span></div></div>
  <div class="panel"><h2>Inference: unchanged where it should be</h2><p class="hint">Intent and Plan are not on the migrated text/policy paths, so the medians are expected to match. Bars: before (blue) and after (violet).</p>${hbars(summary,{labelW:170})}
  <div class="legend"><span><i class="dot" style="background:var(--accent)"></i>Before</span><span><i class="dot" style="background:var(--accent2)"></i>After</span></div></div>
  <div class="panel"><h2>What changed</h2><p class="hint">987 Swift lines removed; six Rust policy modules added. The app still owns UI, Apple APIs, permissions, Keychain and async orchestration.</p>
  <table><thead><tr><th>Area</th><th class="num">Removed</th><th class="num">Rust</th><th>Status</th></tr></thead><tbody>
  <tr><td>Dictation rules + polish guards</td><td class="num">667</td><td class="num">911</td><td>Parity tests green</td></tr>
  <tr><td>Open target / browser resolution</td><td class="num">177</td><td class="num">213</td><td>Parity tests green</td></tr>
  <tr><td>Project traversal</td><td class="num">63</td><td class="num">340</td><td>Filesystem tests green</td></tr>
  <tr><td>PostgreSQL SQL/validation</td><td class="num">31</td><td class="num">178</td><td>Unit tests green</td></tr>
  <tr><td>String distance / .env</td><td class="num">49</td><td class="num">121</td><td>Unit tests green</td></tr>
  </tbody></table></div>`;
}
function memoryView(){
  const b=before,a=after;
  const idle=b.rss_idle?.[metric+'_bytes'],load=b.rss_loaded?.[metric+'_bytes'];
  const aidle=a.rss_idle?.[metric+'_bytes'],aload=a.rss_loaded?.[metric+'_bytes'];
  const voice=b.voice?.native?.rss_median_bytes,avoice=a.voice?.native?.rss_median_bytes;
  const whisper=b.whisper?.peak_footprint_bytes||b.whisper?.max_rss_bytes;
  const awhisper=a.whisper?.peak_footprint_bytes||a.whisper?.max_rss_bytes;
  const qwen=(b.ollama||[]).find(o=>o.model.includes('1.5b'));const aqwen=(a.ollama||[]).find(o=>o.model.includes('1.5b'));
  const qr=qwen?Math.max(...qwen.processes.map(p=>p.rss_bytes)):null, aqr=aqwen?Math.max(...aqwen.processes.map(p=>p.rss_bytes)):null;
  const rows=[
    {label:'App idle',values:[{value:mib(idle),text:fmt(mib(idle),1)+' MiB',color:'var(--good)'},{value:mib(aidle),text:fmt(mib(aidle),1)+' MiB',color:'var(--good)'}],tip:'No model loaded'},
    {label:'App + intent',values:[{value:mib(load),text:fmt(mib(load),1)+' MiB',color:'var(--warn)'},{value:mib(aload),text:fmt(mib(aload),1)+' MiB',color:'var(--warn)'}],tip:'Intent model + ORT runtime resident'},
    {label:'Voice helper',values:[{value:mib(voice),text:fmt(mib(voice),1)+' MiB',color:'var(--accent)'},{value:mib(avoice),text:fmt(mib(avoice),1)+' MiB',color:'var(--accent)'}],tip:'Separate JarvisBackend process'},
    {label:'Whisper peak',values:[{value:mib(whisper),text:fmt(mib(whisper),1)+' MiB',color:'var(--bad)'},{value:mib(awhisper),text:fmt(mib(awhisper),1)+' MiB',color:'var(--bad)'}],tip:'Peak STT-core process footprint'},
    {label:'Qwen 1.5B',values:[{value:mib(qr),text:fmt(mib(qr),1)+' MiB',color:'var(--accent2)'},{value:mib(aqr),text:fmt(mib(aqr),1)+' MiB',color:'var(--accent2)'}],tip:'Ollama llama-server process, not Jarvis RSS'},
  ];
  const stack=[
    {label:'Before',values:[
      {name:'App idle',value:mib(idle),color:'#4ade80'},
      {name:'Intent delta',value:mib((load||0)-(idle||0)),color:'#fbbf24'},
      {name:'Voice',value:mib(voice),color:'#7dd3fc'},
      {name:'Whisper',value:mib(whisper),color:'#fb7185'},
      {name:'Qwen 1.5B',value:mib(qr),color:'#c4b5fd'},
    ]},
    {label:'After',values:[
      {name:'App idle',value:mib(aidle),color:'#4ade80'},
      {name:'Intent delta',value:mib((aload||0)-(aidle||0)),color:'#fbbf24'},
      {name:'Voice',value:mib(avoice),color:'#7dd3fc'},
      {name:'Whisper',value:mib(awhisper),color:'#fb7185'},
      {name:'Qwen 1.5B',value:mib(aqr),color:'#c4b5fd'},
    ]},
  ];
  return `<div class="panel"><h2>Memory by state (${metric==='footprint'?'physical footprint':'RSS'})</h2><p class="hint">App states are the same process; voice, Whisper and Ollama are separate processes. Physical footprint is the OS attribution; RSS includes shared pages. The left/right pair in each row is before/after.</p>${hbars(rows,{labelW:170})}
  <div class="legend"><span><i class="dot" style="background:var(--accent)"></i>Before</span><span><i class="dot" style="background:var(--accent2)"></i>After</span></div></div>
  <div class="panel"><h2>All components resident: upper-bound composition</h2><p class="hint">Stacked sum of app idle + intent delta + voice helper + Whisper peak + Qwen 1.5B. Separate-process sums can double-count shared pages; treat this as a ceiling, not one measured process.</p>${stacked(stack)}
  <div class="legend">${stack[0].values.map(v=>`<span><i class="dot" style="background:${v.color}"></i>${v.name}</span>`).join('')}</div></div>`;
}
function latencyView(){
  const b=before,a=after,cmds=b.intent_commands||[];
  const labels=cmds;
  const series=[
    {name:'Before',color:'#7dd3fc',values:cmds.map(c=>b.intent_median[c]||0)},
    {name:'After',color:'#c4b5fd',values:cmds.map(c=>a.intent_median[c]||0)},
  ];
  const rows=cmds.map(c=>({label:c,values:[
    {value:b.intent_median[c],text:fmt(b.intent_median[c],0)+' ms',color:'var(--accent)'},
    {value:a.intent_median[c],text:fmt(a.intent_median[c],0)+' ms',color:'var(--accent2)'},
  ],tip:`${c} · before ${fmt(b.intent_median[c],0)} ms / after ${fmt(a.intent_median[c],0)} ms`}));
  const table=cmds.map(c=>{const [txt,cls]=delta(b.intent_median[c],a.intent_median[c]);return `<tr><td>${c}</td><td class="num">${fmt(b.intent_median[c],0)}</td><td class="num">${fmt(a.intent_median[c],0)}</td><td class="num ${cls}">${txt}</td></tr>`}).join('');
  return `<div class="panel"><h2>Intent latency by command (${orientation})</h2><p class="hint">Warm end-to-end in the test runner's Intent mode: request → native T5/ONNX decode → mapped actions. ${orientation==='vertical'?'Vertical grouped bars.':'Horizontal grouped bars.'} These paths were not modified by the migration.</p>${orientation==='vertical'?vbars(labels,series):hbars(rows,{labelW:265})}
  <div class="legend"><span><i class="dot" style="background:#7dd3fc"></i>Before</span><span><i class="dot" style="background:#c4b5fd"></i>After</span></div></div>
  <div class="panel"><h2>Per-command delta</h2><p class="hint">Differences of a few milliseconds are normal run-to-run spread, not a regression.</p>
  <table><thead><tr><th>Command</th><th class="num">Before</th><th class="num">After</th><th class="num">Delta</th></tr></thead><tbody>${table}</tbody></table></div>`;
}
function modelsView(){
  const b=before,a=after;
  const modelRows=[
    ['Intent T5-small', b.models.intent_encoder+b.models.intent_decoder, (b.rss_loaded?.footprint_bytes||0)-(b.rss_idle?.footprint_bytes||0), 'ONNX encoder + merged decoder; memory delta includes the ORT arena'],
    ['Voice encoder', b.models.voice_encoder, b.voice?.native?.rss_median_bytes, 'Separate helper RSS after loading the speaker encoder'],
    ['Whisper large-v3-turbo', b.models.whisper, b.whisper?.peak_footprint_bytes||b.whisper?.max_rss_bytes, `load ${b.whisper?.load_ms||'—'} ms · transcribe ${b.whisper?.transcribe_ms||'—'} ms / ${b.whisper?.audio_seconds}s`],
  ];
  (b.ollama||[]).forEach(o=>modelRows.push([o.model,o.model_bytes,Math.max(...o.processes.map(p=>p.rss_bytes)),`cold ${fmt(o.cold_ms,0)} ms · warm ${fmt(o.warm_median_ms,0)} ms`]));
  const table=modelRows.map(r=>`<tr><td>${r[0]}</td><td class="num">${fmt(mib(r[1]),1)} MiB</td><td class="num">${fmt(mib(r[2]),1)} MiB</td><td style="color:var(--muted)">${r[3]}</td></tr>`).join('');
  const qb=(b.ollama||[]).find(o=>o.model.includes('1.5b')),qa=(a.ollama||[]).find(o=>o.model.includes('1.5b'));
  const line=qb&&qa?lineChart([
    {name:'Before',color:'#7dd3fc',values:qb.warm_samples_ms||[]},
    {name:'After',color:'#c4b5fd',values:qa.warm_samples_ms||[]},
  ],['run 1','run 2','run 3','run 4','run 5']):'<p class="hint">No Ollama samples in both reports.</p>';
  const cold=[];const warm=[];
  (b.ollama||[]).forEach((o,i)=>{const p=(a.ollama||[])[i];cold.push({label:o.model,values:[{value:o.cold_ms,text:fmt(o.cold_ms,0),color:'var(--accent)'},{value:p?.cold_ms,text:fmt(p?.cold_ms,0),color:'var(--accent2)'}],tip:`Cold load · ${o.model}`});warm.push({label:o.model,values:[{value:o.warm_median_ms,text:fmt(o.warm_median_ms,0),color:'var(--accent)'},{value:p?.warm_median_ms,text:fmt(p?.warm_median_ms,0),color:'var(--accent2)'}],tip:`Warm completion · ${o.model}`})});
  return `<div class="panel"><h2>Model disk vs memory</h2><p class="hint">Disk is the artifact; memory is the process footprint after loading. Runtime/KV/arena allocations can exceed the file size.</p>
  <table><thead><tr><th>Model</th><th class="num">Disk</th><th class="num">Memory</th><th>Notes</th></tr></thead><tbody>${table}</tbody></table></div>
  <div class="panel"><h2>Ollama Qwen 1.5B: warm run-to-run</h2><p class="hint">Five consecutive generations after a cold load. The ~9 ms shift is small and appears alongside a system-wide slowdown in the voice benchmark.</p>${line}<div class="legend"><span><i class="dot" style="background:#7dd3fc"></i>Before</span><span><i class="dot" style="background:#c4b5fd"></i>After</span></div></div>
  <div class="panel"><h2>Ollama cold vs warm</h2><p class="hint">Cold includes loading weights; warm reuses the resident model. The 4B model is not wired into Jarvis; it is shown as an alternative-size reference.</p>
  <h3 style="font-size:12px;color:var(--muted);margin:4px 0 6px">Cold load (ms)</h3>${hbars(cold,{labelW:210})}
  <h3 style="font-size:12px;color:var(--muted);margin:14px 0 6px">Warm median (ms)</h3>${hbars(warm,{labelW:210})}
  <div class="legend"><span><i class="dot" style="background:var(--accent)"></i>Before</span><span><i class="dot" style="background:var(--accent2)"></i>After</span></div></div>
  <div class="panel"><h2>Whisper STT</h2><p class="hint">Standalone STT-core process, same Rust engine as the app, 3.22 s synthetic clip.</p>
  ${hbars([
    {label:'Model load',values:[{value:b.whisper?.load_ms,text:fmt(b.whisper?.load_ms,0)+' ms',color:'var(--accent)'},{value:a.whisper?.load_ms,text:fmt(a.whisper?.load_ms,0)+' ms',color:'var(--accent2)'}],tip:'Cold model load'},
    {label:'Transcribe',values:[{value:b.whisper?.transcribe_ms,text:fmt(b.whisper?.transcribe_ms,0)+' ms',color:'var(--accent)'},{value:a.whisper?.transcribe_ms,text:fmt(a.whisper?.transcribe_ms,0)+' ms',color:'var(--accent2)'}],tip:'3.22 s audio'},
    {label:'Peak footprint',values:[{value:mib(b.whisper?.peak_footprint_bytes),text:fmt(mib(b.whisper?.peak_footprint_bytes),0)+' MiB',color:'var(--accent)'},{value:mib(a.whisper?.peak_footprint_bytes),text:fmt(mib(a.whisper?.peak_footprint_bytes),0)+' MiB',color:'var(--accent2)'}],tip:'Peak process memory'},
  ],{labelW:170})}</div>`;
}
function migrationView(){
  const del=mig.files.map(([name,n])=>({label:name,values:[{value:n,text:String(n),color:'var(--bad)'}],tip:`${n} Swift lines removed`}));
  const add=mig.modules.map(([name,n,note])=>({label:name,values:[{value:n,text:String(n),color:'var(--good)'}],tip:`${n} Rust lines · ${note}`}));
  return `<div class="panel"><h2>Migration at a glance</h2><p class="hint">${mig.swift_deleted} Swift lines removed; ${mig.rust_added} Rust lines added (including tests). The Rust side is a single typed UniFFI surface.</p>
  <div class="cards" style="grid-template-columns:repeat(3,1fr);margin-bottom:0">${card('Swift deleted',String(mig.swift_deleted),'across 9 files')}${card('Rust added',String(mig.rust_added),'6 policy modules')}${card('Tests','393 / 111','Swift / Rust')}</div></div>
  <div class="panel"><h2>Swift lines removed by file</h2>${hbars(del,{labelW:230})}</div>
  <div class="panel"><h2>Rust modules added</h2>${hbars(add,{labelW:180})}
  <table style="margin-top:14px"><thead><tr><th>Module</th><th>Responsibility</th></tr></thead><tbody>${mig.modules.map(m=>`<tr><td class="mono">${m[0]}</td><td style="color:var(--muted)">${m[2]}</td></tr>`).join('')}</tbody></table></div>
  <div class="panel"><h2>Build fixes found while doing this</h2><table><tbody>${mig.build_fixes.map(x=>`<tr><td style="width:90px;color:var(--accent)">${x[0]}</td><td style="color:var(--muted)">${x[1]}</td></tr>`).join('')}</tbody></table></div>
  <div class="panel"><h2>Still native by design</h2><p class="hint">SwiftUI/AppKit, Accessibility, AppleScript, CoreAudio, DisplayServices, Spotlight/MDQuery, TCC, Keychain, security-scoped bookmarks, model HTTP/Task cancellation and process execution. The full Rust action contract and pre-model planner orchestration remain the largest future project.</p></div>`;
}
function glossaryView(){
  return `<div class="panel"><h2>Plain-language glossary</h2><p class="hint">Filter the terms below. These definitions are the exact interpretation used by the numbers in this report.</p>
  <input id="filter" placeholder="Filter terms…" oninput="filterGlossary(this.value)">
  <div class="gloss" id="gloss">${DATA.glossary.map(g=>`<div class="item" data-term="${g[0].toLowerCase()} ${g[1].toLowerCase()} ${g[2].toLowerCase()}"><div class="term">${g[0]}</div><div class="short">${g[1]}</div><div class="detail">${g[2]}</div></div>`).join('')}</div></div>`;
}
function filterGlossary(q){q=q.toLowerCase();document.querySelectorAll('#gloss .item').forEach(el=>{el.style.display=el.dataset.term.includes(q)?'':'none'})}
function render(){
  cards();
  const v={overview,memory:memoryView,latency:latencyView,models:modelsView,migration:migrationView,glossary:glossaryView}[view];
  document.getElementById('views').innerHTML=v();
  attachTips();
  document.querySelectorAll('#tabs button[data-v]').forEach(x=>x.classList.toggle('on',x.dataset.v===view));
  const m=document.getElementById('metric');if(m)m.textContent=`Memory: ${metric==='footprint'?'physical footprint':'RSS'}`;
  const o=document.getElementById('orientation');if(o)o.textContent=`Latency: ${orientation==='vertical'?'vertical':'horizontal'}`;
}
document.getElementById('note').innerHTML = `Method: baseline is the pre-migration HEAD rebuilt in a separate worktree and launched through LaunchServices; post-migration is the rebuilt working tree. Intent/Plan modes only; no Execute actions, voice capture, Spotify, database or file operations. Memory is RSS and/or physical footprint; shared pages can be counted in more than one process, so component sums are upper bounds. Intent and Plan were not on the migrated paths; the equal medians are the expected result, not a benchmark failure. Whisper and Ollama are separate processes and not part of Jarvis RSS.`;
render();
</script>
</body>
</html>
"""

if __name__ == "__main__":
    main()
