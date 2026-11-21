function native(action, payload = {}) {
    return window.webkit.messageHandlers.jarvis.postMessage({action, payload});
}

function controlValue(id, value) {
    const control = document.getElementById(id);
    if (control && document.activeElement !== control) control.value = value;
}

function applyMaterial({hex, rgb, glass, contrast, scale}) {
    const style = document.documentElement.style;
    style.setProperty('--accent', hex);
    style.setProperty('--accent-rgb', rgb);
    style.setProperty('--glass-opacity', glass);
    style.setProperty('--font-scale', scale);
    style.setProperty('--border-alpha', .08 * contrast);
    style.setProperty('--border-strong-alpha', .14 * contrast);
}


// WebKit's native slider comes from macOS appearance. Keep its geometry and
// keyboard behavior while drawing the approved accent and track in CSS.
function paintRange(range) {
    const min = Number(range.min || 0);
    const max = Number(range.max || 100);
    const fraction = max > min ? (Number(range.value) - min) / (max - min) : 0;
    range.style.setProperty('--range-fill', 100 * Math.min(1, Math.max(0, fraction)) + '%');
}
document.addEventListener('input', event => {
    if (event.target.matches('input[type="range"]')) paintRange(event.target);
});
