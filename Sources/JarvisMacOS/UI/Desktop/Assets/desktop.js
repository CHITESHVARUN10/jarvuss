const commandInput = byId('commandInput');
const commandStream = byId('commandStream');
const liveListenToggle = byId('liveListenToggle');
const orbListenBtn = byId('orbListenBtn');
let composerMode = 'command';
let activeScope = '';
let applyingNavigation = false;
let settingsGroup = '';
let currentDictView = 'formatted';
let dictation = {formatted: '', original: ''};
let routines = [];
let actionTypes = [];
let editingRoutineId = null;
let activityGeneration = 0;
let lastActivityRange = 'week';
const inspectorMeter = byId('inputLevelMeter');
let previousHistory = '';
let previousRecent = '';
let previousRoutineState = '';
let previousFolderState = '';

for (let index = 0; index < 16; index++) {
    const bar = document.createElement('div');
    bar.className = 'meter-seg';
    inspectorMeter.append(bar);
}

function syncFiles() {
    byId('fileFolderSelect').value = activeScope;
    byId('fileSearchInput').value = '';
    setSearchMode('name');
    byId('fileTypeSelect').value = 'any';
    byId('fileDateSelect').value = 'any';
    clearSearchSize();
    formatSearch({files:[], searching:false, status:'', selectedID:''});
    native('searchState').then(result => {
        if (!byId('fileSearchModal').classList.contains('open')) return;
        if (result.hasContext) applyFileRequest(result.draft);
        formatSearch(result);
    });
}

function prefill(text) {
    commandInput.value = text;
    commandInput.focus();
}

async function runCommand(text) {
    const clean = text.trim();
    if (!clean) return;
    commandInput.value = '';
    commandInput.focus();
    try { await native('command', {text: clean}); }
    catch (error) { showToast(String(error)); }
}

function addCommandResult(result) {
    commandStream.querySelector('.empty-session-msg')?.remove();
    const prompt = document.createElement('div');
    prompt.className = 'stream-entry user';
    prompt.innerHTML = '<div class="user-pill"></div>';
    prompt.firstElementChild.textContent = result.command;
    const reply = document.createElement('div');
    reply.className = 'stream-entry';
    const badge = result.outcome === 'success' ? 'Handled' : result.outcome === 'cancelled' ? 'Cancelled' : 'Needs attention';
    reply.innerHTML = `<div class="exec-card">
        <div class="exec-top"><span class="status-badge ${result.outcome === 'success' ? 'ok' : ''} tabular">${badge} · ${result.ms} ms</span></div>
        <div class="exec-outcome"></div>
        <details class="trace-details"><summary>Command details</summary><div class="exec-tags"></div></details>
      </div>`;
    reply.querySelector('.exec-outcome').textContent = result.message;
    const tags = reply.querySelector('.exec-tags');
    for (const action of result.steps) {
        const tag = document.createElement('span');
        tag.className = 'action-tag';
        tag.textContent = action;
        tags.append(tag);
    }
    if (!result.steps.length) reply.querySelector('details').hidden = true;
    if (result.outcome === 'success' && result.steps.some(action => action.startsWith('File search:'))) {
        const footer = document.createElement('div');
        footer.className = 'exec-foot';
        footer.innerHTML = '<span>File search</span><button class="stream-action-link">Show results ↗</button>';
        footer.querySelector('button').onclick = openFileSearch;
        reply.querySelector('.exec-card').append(footer);
    }
    commandStream.append(prompt, reply);
    while (commandStream.children.length > 100) commandStream.firstElementChild.remove();
    commandStream.scrollTop = commandStream.scrollHeight;
}

byId('sendCommandBtn').onclick = () => runCommand(commandInput.value);
commandInput.addEventListener('keydown', event => {
    if (event.key === 'Enter' && !event.isComposing) runCommand(commandInput.value);
});
byId('newSessionBtn').onclick = () => native('newSession').then(() => {
    commandStream.innerHTML = '<div class="empty-session-msg">No commands in this session.</div>';
    commandInput.value = '';
    commandInput.focus();
});
byId('composerModeSeg').addEventListener('click', event => {
    const selected = event.target.closest('[data-mode]');
    if (!selected) return;
    composerMode = selected.dataset.mode;
    for (const button of byId('composerModeSeg').querySelectorAll('button')) button.classList.toggle('active', button === selected);
    commandInput.placeholder = composerMode === 'dictation' ? 'Type a command or press Record to dictate…' : 'Type a command or ask Jarvis…';
});
function startOrFinishHud(mode) { native('record', {mode}); }
byId('recordHudBtn').onclick = () => startOrFinishHud(composerMode);
orbListenBtn.onclick = () => native('live', {enabled: !liveListenToggle.checked});
liveListenToggle.onchange = () => native('live', {enabled: liveListenToggle.checked});
byId('volSlider').oninput = event => drawText('volLabel', event.target.value + '%');
byId('volSlider').onchange = event => native('volume', {level: Number(event.target.value)});

const toggles = {
    verifyCmdToggle: 'verifyAction', verifyActionToggle: 'verifyAction', verifyLiveToggle: 'verifyLive',
    spokenReplyToggle: 'spoken', loginToggle: 'login', rustPipelineToggle: 'rust', formatToggle: 'format',
    pasteToggle: 'paste', originalToggle: 'original'
};
for (const [id, key] of Object.entries(toggles)) {
    byId(id).onchange = event => native('setting', {key, value: event.target.checked});
}
for (const [id, key] of Object.entries({speechEngine:'engine', speechLanguage:'locale', recordLimit:'recordLimit', resultDuration:'resultDuration'})) {
    byId(id).onchange = event => native('setting', {key, value: event.target.value});
}
for (const [id, key] of Object.entries({
    orbStyleSelect:'orb', animateOrbToggle:'motion', textScaleSelect:'scale', glassOpacitySlider:'glass', borderContrastSlider:'contrast'
})) {
    byId(id).addEventListener('change', event => native('appearance', {
        key, value: event.target.type === 'checkbox' ? event.target.checked : event.target.value
    }));
}
for (const button of byId('accentSwatches').querySelectorAll('.swatch-btn')) {
    button.addEventListener('click', () => native('appearance', {key:'accent', value:button.textContent.trim().toLowerCase()}));
}

function applyAppearance(appearance) {
    const {hex, rgb, orb, motion, scale, glass, contrast} = appearance;
    applyMaterial(appearance);
    currentAccent = hex;
    currentOrb = orb;
    if (byId('orbStyleSelect').value !== orb) byId('orbStyleSelect').value = orb;
    byId('animateOrbToggle').checked = motion;
    drawText('orbPreviewName', orbDescriptions[orb].name);
    drawText('orbPreviewDesc', orbDescriptions[orb].desc);
    byId('textScaleSelect').value = scale;
    const glassPercent = Math.round(100 * glass);
    byId('glassOpacitySlider').min = Math.min(40, glassPercent);
    byId('glassOpacitySlider').max = Math.max(96, glassPercent);
    byId('glassOpacitySlider').value = glassPercent;
    drawText('glassOpacityVal', Math.round(100 * glass) + '%');
    byId('borderContrastSlider').value = Math.round(100 * contrast);
    drawText('borderContrastVal', Math.round(100 * contrast) + '%');
    for (const button of byId('accentSwatches').querySelectorAll('.swatch-btn')) {
        const active = button.dataset.accent === hex;
        button.classList.toggle('active', active);
        button.setAttribute('aria-pressed', active);
    }
    for (const range of byId('view-appearance').querySelectorAll('input[type="range"]')) paintRange(range);
    syncOrb();
}

function syncVoice(voice) {
    const {ready, count, phase, index, phrase, phrases, matches, repetitions, awaiting, notice, resetting} = voice;
    const active = phase === 'active' || phase === 'preparing';
    for (const id of ['voiceProfileBadge', 'inspectorVoiceBadge']) {
        drawText(id, ready ? 'Profile ready' : 'Not set');
        byId(id).classList.toggle('ok', ready);
    }
    drawText('voiceProfileBadge', ready ? `Profile ready · ${count} samples` : 'No voice profile yet');
    byId('startEnrollBtn').disabled = active || ready || resetting;
    byId('retrainVoiceBtn').disabled = active || !ready || resetting;
    byId('clearVoiceBtn').disabled = active || (!ready && count === 0) || resetting;
    drawText('startEnrollBtn', phase === 'paused' ? 'Resume enrollment' : 'Start enrollment');
    byId('enrollFlow').classList.toggle('hidden', !active);
    byId('enrollmentStatus').classList.toggle('hidden', active || !notice);
    drawText('enrollmentStatus', notice);
    drawText('enrollStepHeader', phase === 'preparing' ? 'Preparing enrollment' : `Phrase ${index + 1} of ${phrases}`);
    drawText('enrollPhrase', phase === 'preparing' ? '' : phrase);
    drawText('enrollHint', `${matches} of ${repetitions} samples · ${notice}`);
    byId('enrollProgressFill').style.width = `${100 * (index * repetitions + matches) / (phrases * repetitions)}%`;
    byId('enrollProgress').setAttribute('aria-valuemax', phrases * repetitions);
    byId('enrollProgress').setAttribute('aria-valuenow', index * repetitions + matches);
    byId('capturePhraseBtn').hidden = !awaiting;
    drawText('capturePhraseBtn', index + 1 === phrases ? 'Finish enrollment' : 'Next phrase');
}
function startEnrollment(retrain = false) { native('enrollment', {operation: retrain ? 'retrain' : 'start'}); }
function cancelEnrollment() { native('enrollment', {operation: 'pause'}); }
function clearEnrollment() { native('enrollment', {operation: 'clear'}); }

function renderLastDictation() {
    const text = dictation[currentDictView];
    drawText('lastDictText', text || 'No dictation yet.');
    drawText('dictWordCount', text ? text.trim().split(/\s+/).length + ' words' : '');
    byId('copyDictBtn').disabled = !text;
    drawText('copyDictBtn', 'Copy');
    drawText('copyDictStatus', '');
    for (const button of byId('dictViewSeg').querySelectorAll('button')) button.classList.toggle('active', button.dataset.mode === currentDictView);
}
byId('dictViewSeg').addEventListener('click', event => {
    const button = event.target.closest('[data-mode]');
    if (!button) return;
    currentDictView = button.dataset.mode;
    renderLastDictation();
});
function copyLastDictation() {
    return feedbackForCopy(byId('lastDictText'), byId('copyDictBtn'), byId('copyDictStatus'), 'Copy');
}

function toggleRoutineEnabled(id, enabled) {
    native('toggleRoutine', {id, enabled}).catch(error => {
        renderRoutines();
        showToast(String(error));
    });
}
function deleteRoutine(id) { native('deleteRoutine', {id}).catch(error => showToast(String(error))); }
function executeRoutine(id) {
    switchView('assistant');
    native('runRoutine', {id}).catch(error => showToast(String(error)));
}

function appendRoutineActionRow(type = 'open_app', target = '', requires = false, id = null) {
    const row = document.createElement('div');
    row.className = 'routine-action-row';
    row.style.cssText = 'display:flex;gap:8px;align-items:center;';
    if (id) row.dataset.id = id;
    const options = actionTypes.filter(option => option.selectable || option.type === type).map(option =>
        `<option value="${escapeHTML(option.type)}">${escapeHTML(option.title)}</option>`).join('');
    row.innerHTML = `<select class="select act-type" aria-label="Action type" style="width:140px;height:32px;">${options}</select>
        <input type="text" class="input act-target" aria-label="Action target" style="flex:1;height:32px;">
        <label class="btn btn-ghost btn-sm" title="Require the previous step to succeed"><input class="act-depends" type="checkbox" aria-label="Require previous step to succeed"></label>
        <button class="btn btn-ghost btn-sm" type="button" aria-label="Remove action">✕</button>`;
    const picker = row.querySelector('select');
    picker.value = type;
    const targetField = row.querySelector('.act-target');
    targetField.value = target;
    row.querySelector('.act-depends').checked = requires;
    const update = () => {
        const selected = actionTypes.find(option => option.type === picker.value);
        targetField.placeholder = selected?.placeholder || '';
        targetField.disabled = selected?.requiresValue === false;
    };
    picker.onchange = update;
    update();
    row.querySelector('button').onclick = () => row.remove();
    byId('routineActionsContainer').append(row);
}

function openRoutineModal(id = null) {
    const routine = routines.find(item => item.id === id);
    if (id && !routine) return;
    editingRoutineId = id;
    drawText('routineModalTitle', routine ? `Edit routine · ${routine.trigger}` : 'New routine');
    drawText('saveRoutineBtn', routine ? 'Save changes' : 'Create routine');
    byId('routineTriggerInput').value = routine?.trigger || '';
    byId('routineOffInput').value = routine?.offPhrase || '';
    byId('routineConditionalCheck').checked = false;
    byId('routineActionsContainer').replaceChildren();
    if (routine) {
        for (const action of routine.actions) appendRoutineActionRow(action.type, action.target, action.requires, action.id);
    } else appendRoutineActionRow();
    openModal('routineModal');
    byId('routineTriggerInput').focus();
}

async function saveRoutine() {
    const button = byId('saveRoutineBtn');
    button.disabled = true;
    try {
        const trigger = byId('routineTriggerInput').value.trim();
        const off = byId('routineOffInput').value.trim();
        const requireAll = byId('routineConditionalCheck').checked;
        const actions = [...byId('routineActionsContainer').children].map((row, index) => ({
            id: row.dataset.id || '',
            type: row.querySelector('select').value,
            target: row.querySelector('.act-target').disabled ? '' : row.querySelector('.act-target').value.trim(),
            requires: index > 0 && (requireAll || row.querySelector('.act-depends').checked)
        }));
        await native('saveRoutine', {id: editingRoutineId || '', trigger, off, actions});
        closeModal('routineModal');
    } catch (error) { showToast(String(error)); }
    finally { button.disabled = false; }
}

const settingsNames = {
    behavior:'Assistant behavior', display:'Display & sound', files:'Files & projects',
    services:'Local services', safeguards:'Advanced & safeguards'
};
function openSettingsSub(key) {
    if (!settingsNames[key]) return;
    switchView('settings');
    byId('settingsTabSeg').querySelector('[data-tab="general"]').click();
    settingsGroup = key;
    byId('settingsGeneralMain').classList.add('hidden');
    byId('settingsGeneralSub').classList.remove('hidden');
    renderSettingsSub();
}
function closeSettingsSub() {
    settingsGroup = '';
    byId('settingsGeneralMain').classList.remove('hidden');
    byId('settingsGeneralSub').classList.add('hidden');
}
let currentState;
function renderSettingsSub() {
    if (!currentState || !settingsGroup) return;
    const target = byId('settingsSubContent');
    if (target.contains(document.activeElement) && target.dataset.group === settingsGroup) return;
    const {preferences, setup, folders} = currentState;
    const row = (title, desc, control) => `<div class="row"><div class="row-info"><span class="row-title">${title}</span><span class="row-desc">${desc}</span></div>${control}</div>`;
    const button = (title, action, payload = {}) => `<button class="btn btn-sm" data-action="${action}" data-payload="${escapeHTML(JSON.stringify(payload))}">${title}</button>`;
    const toggle = (title, key) => `<label class="switch"><input aria-label="${title}" data-setting="${key}" type="checkbox" ${preferences[key] ? 'checked' : ''}><span class="switch-track"></span></label>`;
    const more = button('More controls', 'settingsDetails', {group: settingsGroup});
    const groups = {
        behavior: [
            row('Spoken replies', 'Read command confirmations aloud.', toggle('Spoken replies', 'spoken')),
            row('Follow-up window', 'Seconds to wait for a follow-up command.', `<input aria-label="Follow-up window" class="input" type="number" min="1" max="10" value="${preferences.timeout}" data-setting="timeout">`),
            row('Assistant preferences', 'Voice verification, hands-free mode, and memory.', more)
        ],
        display: [
            row('Output volume', 'Control the current system output.', `<input aria-label="Output volume" type="range" min="0" max="100" data-volume value="${currentState.volume.level ?? 0}" ${currentState.volume.writable ? '' : 'disabled'}>`),
            row('Display controls', 'Brightness, contrast, sound output, and display recovery.', more)
        ],
        files: [
            ...folders.filter(folder => folder.custom).map(folder => row(escapeHTML(folder.name), escapeHTML(folder.path), '')),
            row('Project roots and aliases', 'Choose where Jarvis looks for projects.', button('Add project root', 'chooseFolder', {kind:'project'})),
            row('Search locations', 'Choose folders for Spotlight file search.', button('Add search folder', 'chooseFolder', {kind:'search'})),
            row('Manage locations', 'Edit aliases, remove locations, and inspect indexed folders.', more)
        ],
        services: [
            row('Native helper', 'Voice authentication and event storage.', escapeHTML(setup.helper)),
            row('PostgreSQL', escapeHTML(setup.postgres), button('Configure', 'setupDetails', {topic:'postgres'})),
            row('Ollama', escapeHTML(setup.ollama), button('Details', 'setupDetails', {topic:'ollama'}))
        ],
        safeguards: [
            row('Event logging', 'Store local command activity in configured storage.', toggle('Event logging', 'eventLog')),
            row('Dictation diagnostics', 'Record development logs for raw input and timings.', toggle('Dictation diagnostics', 'dictationLog')),
            row('Command safeguards', 'Diagnostics, review, and command limits.', more)
        ]
    };
    const html = `<div class="section-label" style="margin-top:0;">${settingsNames[settingsGroup]}</div><div class="group-card">${groups[settingsGroup].join('')}</div>`;
    if (target.dataset.html === html) return;
    target.dataset.html = html;
    target.dataset.group = settingsGroup;
    target.innerHTML = html;
    for (const range of target.querySelectorAll('input[type="range"]')) paintRange(range);
}
byId('settingsSubContent').addEventListener('click', event => {
    const button = event.target.closest('[data-action]');
    if (button) native(button.dataset.action, JSON.parse(button.dataset.payload));
});
byId('settingsSubContent').addEventListener('change', event => {
    const control = event.target;
    if (control.dataset.setting) native('setting', {key:control.dataset.setting, value:control.type === 'checkbox' ? control.checked : control.value});
    if (control.hasAttribute('data-volume')) native('volume', {level:Number(control.value)});
});
function toggleTestRunner() {
    const isHidden = byId('testRunnerPanel').classList.toggle('hidden');
    drawText('testRunnerToggleBtn', isHidden ? 'Start test runner' : 'Close test runner');
    if (!isHidden) byId('testRunnerInput').focus();
}
async function runIntentTest() {
    const input = byId('testRunnerInput').value.trim();
    if (!input) return;
    drawText('testRunnerStatus', 'Evaluating…');
    try {
        const result = await native('testIntent', {text:input});
        drawText('testRunnerStatus', `${result.outcome} · ${result.elapsedMs} ms`);
        drawText('testRunnerJson', JSON.stringify(result, null, 2));
    } catch (error) { drawText('testRunnerStatus', String(error)); }
}
byId('testRunnerInput').onkeydown = event => { if (event.key === 'Enter') runIntentTest(); };

async function refreshActivity() {
    const generation = ++activityGeneration;
    const data = await native('activity', {range:lastActivityRange});
    if (generation !== activityGeneration) return;
    for (const [id, value] of Object.entries(data.values)) drawText(id, value);
    const bars = byId('activityBars');
    const tooltip = byId('chartTooltip');
    const badge = byId('chartDefaultBadge');
    bars.replaceChildren();
    badge.textContent = data.bars.length ? 'Hover a bar to inspect' : 'No recorded usage';
    for (const item of data.bars) {
        const bar = document.createElement('div');
        bar.className = 'bar-col';
        bar.tabIndex = 0;
        bar.innerHTML = `<div class="bar-fill" style="height:${item.pct}%"></div><div class="bar-date">${escapeHTML(item.date)}</div>`;
        const show = () => {
            badge.classList.add('hidden');
            tooltip.innerHTML = `<strong>${escapeHTML(item.date)}</strong><span>${escapeHTML(item.speak)} speaking</span><span>${item.sess} sessions</span><span>${item.words.toLocaleString()} words</span>`;
            tooltip.classList.add('visible');
        };
        const hide = () => {
            badge.classList.remove('hidden');
            tooltip.classList.remove('visible');
        };
        bar.onfocus = bar.onmouseenter = show;
        bar.onblur = bar.onmouseleave = hide;
        bars.append(bar);
    }
}
byId('activityRangeSeg').onclick = event => {
    const button = event.target.closest('[data-range]');
    if (!button) return;
    for (const item of byId('activityRangeSeg').querySelectorAll('button')) item.classList.toggle('active', item === button);
    lastActivityRange = button.dataset.range;
    refreshActivity();
};

function renderFolders(folders) {
    const list = byId('workspaceFolders');
    list.replaceChildren();
    const select = byId('fileFolderSelect');
    const current = select.value;
    select.replaceChildren(new Option('All locations', ''));
    const choices = [{name:'All locations', path:''}, ...folders];
    if (!choices.some(folder => folder.path === current)) select.add(new Option(current, current));
    for (const folder of choices) {
        if (folder.path) select.add(new Option(folder.name, folder.path));
        const button = document.createElement('button');
        button.className = 'folder-opt';
        const name = document.createElement('span');
        name.textContent = folder.name;
        name.title = folder.path;
        const mark = document.createElement('span');
        button.append(name, mark);
        const update = () => {
            button.classList.toggle('active', activeScope === folder.path);
            mark.textContent = activeScope === folder.path ? '✓' : '';
        };
        button.onclick = () => { activeScope = folder.path; renderFolders(folders); };
        update();
        list.append(button);
    }
    select.value = current;
}

function updateDesktop(state) {
    const {assistant, voice, preferences, model, setup, build, volume, history} = state;
    currentState = state;
    liveListenToggle.checked = assistant.live;
    liveListenToggle.disabled = voice.phase === 'active' || voice.phase === 'preparing';
    orbListenBtn.disabled = liveListenToggle.disabled;
    orbListenBtn.setAttribute('aria-pressed', assistant.live);
    orbListenBtn.setAttribute('aria-label', assistant.live ? 'Stop live listening' : 'Start live listening');
    drawText('presenceTitle', assistant.title);
    drawText('presenceSubtitle', assistant.subtitle);
    byId('presenceWave').classList.toggle('active', assistant.live);
    byId('micStatusDot').classList.toggle('standby', !assistant.live && !assistant.mic);
    drawText('micStatusText', assistant.footer);
    for (const [id, key] of Object.entries(toggles)) byId(id).checked = preferences[key];
    for (const [id, key] of Object.entries({speechEngine:'engine', speechLanguage:'locale', recordLimit:'recordLimit', resultDuration:'resultDuration'})) controlValue(id, preferences[key]);
    byId('simThreshSlider').value = voice.threshold;
    drawText('simThreshVal', voice.threshold.toFixed(2));
    paintRange(byId('simThreshSlider'));
    syncVoice(voice);
    byId('volSlider').disabled = !volume.writable;
    if (!byId('volSlider').matches(':active')) {
        byId('volSlider').value = volume.level ?? 0;
        paintRange(byId('volSlider'));
        drawText('volLabel', volume.level === null ? '—' : `${volume.level}%`);
    }

    if (JSON.stringify(state.dictation) !== JSON.stringify(dictation)) {
        dictation = state.dictation;
        if (!dictation.original) currentDictView = 'formatted';
        byId('dictViewSeg').querySelector('[data-mode="original"]').disabled = !dictation.original;
        renderLastDictation();
    }
    const routineState = JSON.stringify(state.routines);
    actionTypes = state.actionTypes;
    if (previousRoutineState !== routineState) {
        previousRoutineState = routineState;
        routines = state.routines;
        renderRoutines();
    }
    const folderState = JSON.stringify(state.folders);
    if (previousFolderState !== folderState) {
        previousFolderState = folderState;
        renderFolders(state.folders);
    }
    const recentState = JSON.stringify(state.recent);
    if (recentState !== previousRecent) {
        previousRecent = recentState;
        byId('recentCmdList').replaceChildren(...state.recent.map(text => {
            const button = document.createElement('button');
            button.className = 'recent-cmd-item';
            button.textContent = text;
            button.onclick = () => prefill(text);
            return button;
        }));
    }

    drawText('statusActivityCount', state.logCount);
    const serializedHistory = JSON.stringify(history);
    if (serializedHistory !== previousHistory) {
        previousHistory = serializedHistory;
        byId('activityLogList').replaceChildren(...history.map(text => {
            const row = document.createElement('div');
            row.className = 'row';
            const description = document.createElement('span');
            description.className = 'row-desc';
            description.textContent = text;
            row.append(description);
            return row;
        }));
    }

    drawText('modelUpdateDesc', `Installed: ${model.installed || 'Not installed'}${model.latest ? ' · Latest: ' + model.latest : ''} · ${model.message}`);
    byId('checkModelBtn').disabled = model.busy;
    drawText('checkModelBtn', model.busy ? 'Checking…' : 'Check for updates');
    drawText('installModelBtn', model.downloading ? `Downloading · ${model.progress}%` : model.installed ? 'Install update' : 'Download model');
    byId('installModelBtn').classList.toggle('hidden', !model.update && !!model.installed && !model.downloading);
    byId('installModelBtn').disabled = model.busy;
    byId('cancelModelBtn').classList.toggle('hidden', !model.busy);
    byId('setupIntentBtn').disabled = model.busy;
    byId('stopRunnerBtn').classList.toggle('hidden', !state.testRunning);
    drawText('setupIntentBtn', model.downloading ? `Downloading · ${model.progress}%` : model.installed ? 'Update' : 'Download');
    for (const topic of ['microphone', 'accessibility', 'whisper', 'postgres', 'helper', 'spotify', 'ollama']) drawText('setup-' + topic, setup[topic]);
    const progress = setup.essentials;
    drawText('setupTitle', progress === 3 ? 'Your essentials are ready' : 'Set up Jarvis');
    drawText('setupReady', progress === 3 ? '✓ Ready to dictate' : `${progress} of 3 ready`);
    byId('setupReady').classList.toggle('ok', progress === 3);
    byId('setupProgress').style.width = `${100 * progress / 3}%`;
    for (const [id, value] of Object.entries(build)) drawText(id, value);
    renderSettingsSub();


}

window.jarvisUI = {
    state: updateDesktop,
    result: addCommandResult,
    search: formatSearch,
    openSearch: request => {
        if (!byId('fileSearchModal').classList.contains('open')) {
            openModal('fileSearchModal');
            byId('fileSearchInput').focus();
        }
        applyFileRequest(request);
    },
    closeSearch: () => closeModal('fileSearchModal', false),
    appearance: applyAppearance,
    meter: level => {
        for (const [index, bar] of [...inspectorMeter.children].entries()) bar.classList.toggle('lit', index < Math.round(level * inspectorMeter.children.length));
    },
    navigate,
    settingsGroup: key => {
        if (key && key !== settingsGroup) openSettingsSub(key);
    },
    visibility: visible => { document.documentElement.classList.toggle('window-hidden', !visible); syncOrb(); },
    answer: ({title, text, meta, duration}) => showQuickAnswer(title, text, meta, duration),
    activityChanged: () => { if (byId('view-activity').classList.contains('active')) refreshActivity(); },
    toast: showToast
};

function syncNavigation(section) {
    const segmented = section === 'settings' ? 'settingsTabSeg' : section === 'voice' ? 'voiceTabSeg' : '';
    const tab = segmented ? byId(segmented).querySelector('.seg-btn.active')?.dataset.tab : '';
    native('navigate', {section, tab: tab || ''});
}

function navigate({section, tab}) {
    const segment = section === 'settings' ? 'settingsTabSeg' : section === 'voice' ? 'voiceTabSeg' : null;
    applyingNavigation = true;
    try {
        if (segment && tab && byId(segment).querySelector('.seg-btn.active')?.dataset.tab !== tab) {
            byId(segment).querySelector(`[data-tab="${tab}"]`)?.click();
        }
        if (!byId('view-' + section).classList.contains('active')) switchView(section, false);
    } finally { applyingNavigation = false; }
}

function initialControls({appearance, search, state, results}) {
    populateSearchControls(search);
    applyAppearance(appearance);
    updateDesktop(state);
    navigate(state.nav);
    for (const result of results) addCommandResult(result);
    commandInput.focus({preventScroll:true});
    renderLastDictation();
    renderInlinePreviewHud();
    byId('dictViewSeg').querySelector('[data-mode="original"]').disabled = !dictation.original;
}
native('ready').then(initialControls).catch(error => showToast(String(error)));
