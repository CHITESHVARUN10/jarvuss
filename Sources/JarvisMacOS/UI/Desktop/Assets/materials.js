  const escapeHTML = value => String(value).replace(/[&<>"']/g, character => ({
    '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'
  })[character]);
  const previewDictation = {
    formatted: "Let's move the design review to Thursday at 10 AM. Please send the updated prototype before the meeting so everyone has time to review the layout and native controls.",
    original: "lets move the design review to thursday at ten am please send the updated prototype before the meeting so everyone has time to review the layout and native controls"
  };
  const previewBars = Array.from({length:64}, (_, index) => {
    const envelope = Math.sin(index * Math.PI / 63);
    const height = 3 + 32 * (.45 + .55 * envelope) * (.3 + .7 * Math.abs(Math.sin(index * .52)));
    return '<span class="hud-bar" style="--bar-size:' + height.toFixed(1) + 'px;--bar-delay:' + (index * -.057).toFixed(3) + 's"></span>';
  }).join('');
  const hudIcons = {
    mic: '<rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3m-3 0h6"/>',
    command: '<path d="m13 2-8 12h6l-1 8 9-12h-6l1-8Z"/>',
    transcript: '<path d="M3 5h18M3 10h12M3 15h18M3 20h12"/>',
    lock: '<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 1 1 8 0v3"/>',
    close: '<path d="m6 6 12 12M18 6 6 18"/>'
  };
  const hudIcon = name => '<svg class="hud-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + hudIcons[name] + '</svg>';

  function buildHudPreview(mode, phase, showOriginal) {
    const command = mode === 'command';
    const shortcut = command ? '⌘⇧A' : '⌘⇧D';
    let title;
    let icon = command ? 'command' : 'mic';
    let meta = '';
    let body = '';
    let foot;
    if (phase === 'recording') {
      title = command ? 'Command · listening' : 'Dictation · recording';
      meta = '<span class="row-meta">0:08 / 5:00</span>';
      body = '<div class="hud-bars" aria-hidden="true">' + previewBars + '</div>';
      const hint = command ? hudIcon('command') + 'Say your command' : hudIcon('lock') + 'Audio stays on this Mac';
      foot = '<span class="row-desc">' + hint + '</span><div style="display:flex;align-items:center;gap:7px"><span class="kbd">' + shortcut
        + '</span><button class="btn btn-sm" data-hud="finish">Finish</button></div>';
    } else if (phase === 'processing') {
      title = command ? 'Command · working' : 'Dictation · polishing';
      foot = '<span class="row-desc"><span class="hud-preview-spinner" aria-hidden="true"></span>Transcribing on this Mac…</span>';
    } else if (command) {
      title = 'Command ready';
      body = '<p class="hud-transcript">What’s the time?</p>';
      foot = '<span class="row-desc">Sample command</span><button class="btn btn-primary btn-sm" data-hud="run">Preview answer</button>';
    } else {
      const transcript = previewDictation[showOriginal ? 'original' : 'formatted'];
      title = showOriginal ? 'Original transcript' : 'Dictation ready';
      icon = 'transcript';
      meta = '<span class="row-meta">' + transcript.trim().split(/\s+/).filter(Boolean).length + ' words</span>';
      body = '<p class="hud-transcript">' + escapeHTML(transcript) + '</p>';
      foot = '<div style="display:flex;gap:6px;flex-wrap:wrap"><button class="btn btn-primary btn-sm" data-hud="copy">Copy text</button><button class="btn btn-ghost btn-sm" data-hud="toggle-orig">'
        + (showOriginal ? 'Show formatted' : 'View original') + '</button></div><span class="copy-status" role="status"></span>';
    }
    return '<div class="hud-head"><span class="hud-label">' + hudIcon(icon) + title + '</span>' + meta + '</div>' + body + '<div class="hud-foot">' + foot + '</div>';
  }
