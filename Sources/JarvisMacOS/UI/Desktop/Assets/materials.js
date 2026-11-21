  const escapeHTML = value => String(value).replace(/[&<>"']/g, character => ({
    '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'
  })[character]);
  const previewDictation = {
    formatted: "Let's move the design review to Thursday at 10 AM. Please send the updated prototype before the meeting so everyone has time to review the layout and native controls.",
    original: "lets move the design review to thursday at ten am please send the updated prototype before the meeting so everyone has time to review the layout and native controls"
  };
  const waveBars = Array.from({length:30}, (_, index) => {
    const envelope = Math.sin((index + 1) * Math.PI / 31);
    const height = 4 + 27 * envelope * (.32 + .68 * Math.sin(index * .71) ** 2);
    return '<span class="hud-bar" style="--bar-size:' + height.toFixed(1) + 'px;--bar-delay:' + (index * -.057).toFixed(3) + 's"></span>';
  }).join('');
  const hudIcons = {
    mic: '<rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3m-3 0h6"/>',
    command: '<path d="m13 2-8 12h6l-1 8 9-12h-6l1-8Z"/>',
    close: '<path d="m6 6 12 12M18 6 6 18"/>'
  };
  const hudIcon = name => '<svg class="hud-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + hudIcons[name] + '</svg>';

  function buildHudHtml(mode, phase, showOriginal, secondsText, state = null) {
    const command = mode === 'command';
    const name = command ? 'Command' : 'Dictation';
    const shortcut = command ? '⌘⇧A' : '⌘⇧D';
    const isPreview = state === null;
    const title = phase === 'error' ? name + ' unavailable' : phase === 'recording' ? name + ' recording' : phase === 'processing'
      ? 'Transcribing ' + name.toLowerCase() : command ? 'Command ready' : showOriginal ? 'Original transcript' : 'Dictation ready';
    const transcript = state ? (showOriginal ? state.original : state.text) : command ? 'What’s the time?' : previewDictation[showOriginal ? 'original' : 'formatted'];
    let body;
    let foot;
    if (phase === 'error') {
      body = '<p class="hud-transcript">' + escapeHTML(state.text) + '</p>';
      foot = '<button class="btn btn-primary btn-sm" data-hud="retry">Retry</button>';
    } else if (phase === 'recording') {
      body = '<div class="hud-bars" aria-hidden="true">' + waveBars + '</div>';
      if (state?.partial) body += '<p class="hud-transcript">' + escapeHTML(state.partial) + '</p>';
      foot = '<span class="row-desc">' + (state ? escapeHTML(state.notice) : 'Sample recording · mic off') + '</span><div style="display:flex;align-items:center;gap:7px"><span class="kbd">' + shortcut + '</span><button class="btn btn-primary btn-sm" data-hud="finish">Finish</button></div>';
    } else if (phase === 'processing') {
      body = '<div class="hud-progress" aria-hidden="true"><div class="hud-progress-bar"></div></div>';
      foot = '<span class="row-desc">' + (state ? escapeHTML(state.notice) : 'Preparing the sample transcript…') + '</span>';
    } else {
      body = '<p class="hud-transcript">' + escapeHTML(transcript) + '</p>';
      foot = state
        ? '<div class="hud-result-actions"><button class="btn btn-primary btn-sm" data-hud="copy">' + (state.copied ? 'Copied' : 'Copy text') + '</button>'
          + (state.original ? '<button class="btn btn-ghost btn-sm" data-hud="toggle-orig">' + (showOriginal ? 'Show formatted' : 'View original') + '</button>' : '')
          + (state.inserted ? '<button class="btn btn-ghost btn-sm" data-hud="undo">Undo insert</button>' : '')
          + (state.needsAccess ? '<button class="btn btn-ghost btn-sm" data-hud="access">Accessibility settings</button>' : '')
          + '</div><span class="copy-status" role="status">' + escapeHTML(state.notice) + '</span>'
        : command ? '<span class="row-desc">Sample command</span><button class="btn btn-primary btn-sm" data-hud="run">Preview answer</button>'
        : '<div style="display:flex;gap:6px;flex-wrap:wrap"><button class="btn btn-primary btn-sm" data-hud="copy">Copy text</button><button class="btn btn-ghost btn-sm" data-hud="toggle-orig">' + (showOriginal ? 'Show formatted' : 'View original') + '</button></div><span class="copy-status" role="status"></span>';
    }
    const meta = phase === 'recording' ? '<span class="row-meta" data-hud-clock>' + secondsText + '</span>'
      : phase === 'result' && !command ? '<span class="row-meta">' + transcript.trim().split(/\s+/).filter(Boolean).length + ' words</span>' : '';
    const close = isPreview ? '' : '<button class="btn btn-ghost btn-sm" data-hud="close" aria-label="Close recording panel">' + hudIcon('close') + '</button>';
    return '<div class="hud-head"><span class="hud-label">' + hudIcon(command?'command':'mic') + title + '</span><div style="display:flex;align-items:center;gap:7px">' + meta + close + '</div></div>' + body + '<div class="hud-foot">' + foot + '</div>';
  }

