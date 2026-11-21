const byId = id => document.getElementById(id);
const drawText = (id, text) => { byId(id).textContent = text; };

let selectedFileIdx = -1;
let fileSearchMode = 'name';
let isSearching = false;
let files = [];
let sizeFilter = {minBytes: 0, maxBytes: 0};
byId('searchMount').outerHTML = `<div class="modal-backdrop" id="fileSearchModal">
  <div class="modal-sheet wide" role="dialog" aria-modal="true" aria-label="File search">
    <div class="modal-head">
      <div style="display:flex; align-items:center; gap:10px;">
        <strong>Jarvis · File Search</strong>
        <span class="status-badge tabular" id="fileCountBadge" role="status"></span>
      </div>
      <button class="btn btn-ghost btn-sm" onclick="closeFileSearch()" aria-label="Close">✕</button>
    </div>
    <div style="padding:12px 18px; border-bottom:1px solid var(--border); display:flex; flex-direction:column; gap:10px;">
      <div style="display:flex; gap:8px;">
        <input type="text" class="input" id="fileSearchInput" maxlength="512" aria-label="Search files" placeholder="Search file names…" style="flex:1; height:34px;" />
        <button class="btn btn-primary" style="height:34px;" id="submitSearchBtn" onclick="submitSearch()">Search</button>
      </div>
      <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px;">
        <div style="display:flex; align-items:center; gap:10px;">
          <div class="segmented" id="fileSearchModeSeg">
            <button class="seg-btn active" data-match="name">Name</button>
            <button class="seg-btn" data-match="content">Contents</button>
          </div>
          <select class="select" id="fileFolderSelect" aria-label="Folder">
            <option value="">All locations</option>
            <option value="Downloads" selected>Downloads</option>
            <option value="Desktop">Desktop</option>
            <option value="Projects">Projects</option>
          </select>
        </div>
        <button class="btn btn-sm" id="toggleFileFilterBtn" onclick="toggleFileFilters()">Filters</button>
      </div>
      <div id="fileFilterBar" class="hidden" style="display:flex; flex-wrap:wrap; align-items:center; gap:10px; padding-top:4px;">
        <span class="row-desc">File type</span>
        <select class="select" id="fileTypeSelect" aria-label="File type"></select>
        <select class="select" id="fileDateSelect" aria-label="Modified date"></select>
        <span class="row-desc hidden" id="sizeFilter"></span>
        <button class="btn btn-ghost btn-sm hidden" id="clearSizeFilter" onclick="clearSearchSize()">Clear size filter</button>
      </div>
    </div>
    <div style="max-height:280px; overflow-y:auto;">
      <table class="file-table">
        <thead>
          <tr><th>#</th><th>Name</th><th>Modified</th><th style="text-align:right;">Size</th></tr>
        </thead>
        <tbody id="fileSearchBody"></tbody>
      </table>
    </div>
    <div class="quicklook-box hidden" id="quickLookBox"></div><p class="row-desc file-status" id="fileStatus" role="status"></p>
    <div class="modal-foot">
      <div>
        <strong id="selectedFileName" style="font-size:12.5px;">No file selected</strong>
        <div style="font-size:11px; color:var(--text-tertiary);">↑/↓ Select · Space Preview · ↩ Open</div>
      </div>
      <div style="display:flex; gap:8px;">
        <button class="btn btn-sm" onclick="fileAction('finder')">Finder</button>
        <button class="btn btn-sm" onclick="toggleQuickLook()">Preview</button>
        <button class="btn btn-primary btn-sm" onclick="fileAction('open')">Open</button>
      </div>
    </div>
  </div>
</div>`;

function populateSearchControls({kinds, dates}) {
    byId('fileTypeSelect').replaceChildren(...kinds.map(item => new Option(item.title, item.value)));
    byId('fileDateSelect').replaceChildren(...dates.map(item => new Option(item.title, item.value)));
}

function closeFileSearch() {
    resetSearchPreview();
    if (document.body.classList.contains('standalone-search')) native('closeSearch');
    else closeModal('fileSearchModal');
}

function clearSearchSize() {
    sizeFilter = {minBytes: 0, maxBytes: 0};
    renderSizeFilter();
}
function renderSizeFilter() {
    const {minBytes, maxBytes} = sizeFilter;
    const hasSize = minBytes > 0 || maxBytes > 0;
    byId('sizeFilter').classList.toggle('hidden', !hasSize);
    byId('clearSizeFilter').classList.toggle('hidden', !hasSize);
    drawText('sizeFilter', [
        minBytes ? '≥ ' + minBytes.toLocaleString() + ' B' : '',
        maxBytes ? '≤ ' + maxBytes.toLocaleString() + ' B' : ''
    ].filter(Boolean).join(' · '));
}
function formatSearch(result) {
    files = result.files;
    isSearching = result.searching;
    drawText('submitSearchBtn', isSearching ? 'Cancel' : 'Search');
    selectedFileIdx = files.findIndex(file => file.id === result.selectedID);
    drawText('fileCountBadge', result.searching ? 'Searching…' : `${files.length} ${files.length === 1 ? 'result' : 'results'}`);
    drawText('fileStatus', result.status);
    const tbody = byId('fileSearchBody');
    const activeFile = document.activeElement?.dataset.file;
    tbody.replaceChildren();
    files.forEach((file, index) => {
        const row = tbody.insertRow();
        row.tabIndex = 0;
        row.dataset.file = file.id;
        row.innerHTML = `<td>${index + 1}</td><td><strong>${escapeHTML(file.name)}</strong><div class="row-desc">${escapeHTML(file.folder)}</div></td><td>${escapeHTML(file.date)}</td><td style="text-align:right">${escapeHTML(file.size)}</td>`;
        row.onclick = () => selectFileByIndex(index);
        row.ondblclick = () => fileAction('open');
        if (file.id === activeFile) row.focus({preventScroll:true});
    });
    applyFileSelection();
}
function applyFileSelection() {
    for (const [index, row] of [...byId('fileSearchBody').rows].entries()) {
        const selected = index === selectedFileIdx;
        row.classList.toggle('selected', selected);
        row.setAttribute('aria-selected', selected);
    }
    drawText('selectedFileName', files[selectedFileIdx]?.name || 'No file selected');
    for (const button of byId('fileSearchModal').querySelectorAll('.modal-foot button')) button.disabled = selectedFileIdx < 0;
    updateQuickLook();
}
function selectFileByIndex(index) {
    if (!files[index]) return;
    selectedFileIdx = index;
    applyFileSelection();
    byId('fileSearchBody').rows[index].scrollIntoView({block:'nearest'});
    native('selectFile', {id: files[index].id});
}
function moveFileSelection(delta) {
    selectFileByIndex(Math.max(0, Math.min(files.length - 1, selectedFileIdx + delta)));
}
function toggleQuickLook() {
    if (selectedFileIdx < 0) return;
    byId('quickLookBox').classList.toggle('hidden');
    updateQuickLook();
}
function updateQuickLook() {
    const box = byId('quickLookBox');
    const file = files[selectedFileIdx];
    if (!file) { box.classList.add('hidden'); return; }
    if (box.classList.contains('hidden')) return;
    box.innerHTML = `<strong>${escapeHTML(file.name)}</strong> · <span class="mono">${escapeHTML(file.id)}</span>
        <div style="margin-top:4px;display:flex;justify-content:space-between;align-items:center;gap:8px">
            <span>${escapeHTML(file.date)} · ${escapeHTML(file.size)}</span>
            <button class="btn btn-sm" onclick="fileAction('preview')">Open Quick Look</button>
        </div>`;
}
function toggleFileFilters() { byId('fileFilterBar').classList.toggle('hidden'); }
function fileAction(operation) {
    if (selectedFileIdx < 0) return;
    native('fileAction', {operation, index: selectedFileIdx + 1}).then(result => {
        if (!result.success) drawText('fileStatus', result.message);
    });
}
function setSearchMode(mode) {
    fileSearchMode = mode;
    for (const btn of byId('fileSearchModeSeg').querySelectorAll('button')) btn.classList.toggle('active', btn.dataset.match === mode);
    byId('fileSearchInput').placeholder = mode === 'content' ? 'Search document contents…' : 'Search file names…';
}
byId('fileSearchModeSeg').onclick = event => {
    const mode = event.target.closest('[data-match]')?.dataset.match;
    if (mode) setSearchMode(mode);
};
let searchTimer;
function resetSearchPreview() {
    clearTimeout(searchTimer);
    byId('quickLookBox').classList.add('hidden');
}

function submitSearch() {
    if (isSearching) native('cancelSearch');
    else searchFiles();
}
function searchFiles() {
    clearTimeout(searchTimer);
    native('search', {
        query: byId('fileSearchInput').value.trim(), mode: fileSearchMode,
        scope: byId('fileFolderSelect').value, kind: byId('fileTypeSelect').value,
        date: byId('fileDateSelect').value, ...sizeFilter
    }).catch(error => drawText('fileStatus', String(error)));
}
function applyFileRequest({query, scope, mode, kind, date, minBytes, maxBytes}) {
    if (byId('fileSearchInput').value !== query) byId('fileSearchInput').value = query;
    if (scope && ![...byId('fileFolderSelect').options].some(option => option.value === scope)) {
        byId('fileFolderSelect').add(new Option(scope, scope));
    }
    byId('fileFolderSelect').value = scope;
    setSearchMode(mode);
    byId('fileTypeSelect').value = kind;
    byId('fileDateSelect').value = date;
    sizeFilter = {minBytes, maxBytes};
    renderSizeFilter();
    if (kind !== 'any' || date !== 'any' || minBytes || maxBytes) byId('fileFilterBar').classList.remove('hidden');
}


byId('fileSearchInput').addEventListener('input', event => {
    clearTimeout(searchTimer);
    const text = event.target.value.trim();
    if (fileSearchMode === 'name' && text.length >= 2) searchTimer = setTimeout(searchFiles, 350);
});
