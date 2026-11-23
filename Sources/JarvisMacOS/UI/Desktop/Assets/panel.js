const panel = document.getElementById('panel');
let oldHeight = 0;

function measure() {
    const height = Math.ceil(panel.getBoundingClientRect().height);
    if (height && height !== oldHeight) {
        oldHeight = height;
        native('height', {height});
    }
}
new ResizeObserver(measure).observe(panel);

function refreshAnswer({title, text, meta}) {
    panel.innerHTML = `<div class="hud-head"><span class="hud-label">${escapeHTML(title)}</span>
      <button class="btn btn-ghost btn-sm" data-hud="close" aria-label="Close answer">${hudIcon('close')}</button></div>
      <div class="quick-answer-val">${escapeHTML(text)}</div><div class="row-desc">${escapeHTML(meta)}</div>`;
}

panel.onclick = event => { if (event.target.closest('[data-hud="close"]')) native('close'); };
window.addEventListener('keydown', event => { if (event.key === 'Escape') native('close'); });
window.jarvisUI = {answer: refreshAnswer, appearance: applyMaterial};
