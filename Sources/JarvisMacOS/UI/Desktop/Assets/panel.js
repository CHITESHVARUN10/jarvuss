const panel = document.getElementById('panel');
let state;
let original = false;
let copiedOriginal = false;
let kind = '';
let previous = '';
let oldHeight = 0;

function measure() {
    const height = Math.ceil(panel.getBoundingClientRect().height);
    if (height && height !== oldHeight) {
        oldHeight = height;
        native('height', {height});
    }
}
new ResizeObserver(measure).observe(panel);

function refreshHud(next) {
    if (state?.phase !== next.phase || state?.text !== next.text) {
        original = false;
        copiedOriginal = false;
    }
    state = next;
    kind = 'hud';
    panel.className = 'hud-card';
    const html = buildHudHtml(state.mode, state.phase, original, state.clock, state);
    // Meter frames leave the controls and their pointer/focus state in place.
    const signature = html.replace(/(<span class="row-meta" data-hud-clock>).*?(<\/span>)/, '$1$2');
    if (signature !== previous) {
        previous = signature;
        panel.innerHTML = html;
        if (original && copiedOriginal) panel.querySelector('[data-hud="copy"]').textContent = 'Copied';
    }
    const clock = panel.querySelector('[data-hud-clock]');
    if (clock) clock.textContent = state.clock;
    panel.querySelector('.hud-bars')?.style.setProperty('--level', state.level);
}

function refreshAnswer({title, text, meta}) {
    kind = 'answer';
    panel.className = 'quick-answer';
    panel.innerHTML = `<div class="hud-head"><span class="hud-label">${escapeHTML(title)}</span>
      <button class="btn btn-ghost btn-sm" data-hud="close" aria-label="Close answer">${hudIcon('close')}</button></div>
      <div class="quick-answer-val">${escapeHTML(text)}</div><div class="row-desc">${escapeHTML(meta)}</div>`;
}

panel.onclick = async event => {
    const action = event.target.closest('[data-hud]')?.dataset.hud;
    if (!action) return;
    if (action === 'toggle-orig' && kind === 'hud') {
        original = !original;
        refreshHud(state);
    } else if (action === 'copy' && original && kind === 'hud') {
        copiedOriginal = await native('copyOriginal');
        if (copiedOriginal && original) event.target.closest('[data-hud="copy"]').textContent = "Copied";
    } else native(action);
};
window.addEventListener('keydown', event => { if (event.key === 'Escape') native('close'); });
window.jarvisUI = {hud: refreshHud, answer: refreshAnswer, appearance: applyMaterial};
