window.jarvisUI = {
    search: formatSearch,
    request: applyFileRequest,
    appearance: applyMaterial,
    begin: ({request, result, controls, scopes}) => {
        populateSearchControls(controls);
        byId('fileFolderSelect').replaceChildren(new Option('All locations', ''), ...scopes.map(item => new Option(item.name, item.path)));
        applyFileRequest(request);
        formatSearch(result);
        byId('fileSearchModal').classList.add('open');
        byId('fileSearchInput').focus();
    }
};
window.addEventListener('keydown', event => {
    if (event.key === 'Escape') { closeFileSearch(); return; }
    if (event.target instanceof HTMLButtonElement || event.target instanceof HTMLSelectElement) return;
    switch (event.key) {
    case 'ArrowDown': event.preventDefault(); moveFileSelection(1); break;
    case 'ArrowUp': event.preventDefault(); moveFileSelection(-1); break;
    case 'Enter':
        event.preventDefault();
        if (event.target === byId('fileSearchInput')) submitSearch();
        else fileAction('open');
        break;
    case ' ':
        if (!(event.target instanceof HTMLInputElement)) { event.preventDefault(); toggleQuickLook(); }
        break;
    default: break;
    }
});
