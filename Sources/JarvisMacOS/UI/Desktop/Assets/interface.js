  let toastTimer = null;
  function showToast(message) {
    const el = document.getElementById('toast');
    el.textContent = message;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove('show'), 2200);
  }

  async function copyText(text, source) {
    try {
      if (await native('copy', {text})) return true;
    } catch { /* Leave the transcript selected. */ }
    const selection = window.getSelection();
    if (!selection || !source?.isConnected) return false;
    const range = document.createRange();
    range.selectNodeContents(source);
    selection.removeAllRanges();
    selection.addRange(range);
    return false;
  }

  const copyTimers = new WeakMap();
  async function feedbackForCopy(source, button, status, buttonLabel) {
    if (button.dataset.pending === 'true') return;
    button.dataset.pending = 'true';
    clearTimeout(copyTimers.get(button));
    status.textContent = '';
    const didCopy = await copyText(source.textContent.trim(), source);
    delete button.dataset.pending;
    if (!button.isConnected) return;
    button.textContent = didCopy ? 'Copied' : buttonLabel;
    status.textContent = didCopy ? 'Copied to clipboard.' : 'Text selected. Press ⌘C to copy.';
    status.dataset.copied = String(didCopy);
    if (didCopy) copyTimers.set(button, setTimeout(() => {
      button.textContent = buttonLabel;
      status.textContent = '';
      delete status.dataset.copied;
    }, 2300));
  }

  const viewTitles = {
    assistant: 'Assistant',
    voice: 'Voice & Speech',
    routines: 'Routines',
    activity: 'Activity',
    appearance: 'Appearance',
    settings: 'Settings'
  };

  function switchView(id, notify = true) {
    document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
    document.querySelectorAll('.nav-item').forEach(n => {
      const active = n.dataset.view === id;
      n.classList.toggle('active', active);
      if (active) n.setAttribute('aria-current', 'page');
      else n.removeAttribute('aria-current');
    });
    document.getElementById('view-' + id)?.classList.add('active');
    document.getElementById('toolbarViewTitle').textContent = viewTitles[id] || id;
    syncOrb();
    if (id === 'assistant') commandInput.focus({preventScroll:true});
    if (id === 'activity') refreshActivity();
    if (notify) syncNavigation(id);
  }

  document.querySelectorAll('.nav-item').forEach(btn => {
    btn.addEventListener('click', () => switchView(btn.dataset.view));
  });

  document.getElementById('toggleSidebarBtn').addEventListener('click', (e) => {
    const collapsed = document.getElementById('sidebar').classList.toggle('collapsed');
    e.currentTarget.setAttribute('aria-expanded', String(!collapsed));
  });

  document.getElementById('toggleInspectorBtn').addEventListener('click', (e) => {
    const inspector = document.getElementById('sessionInspector');
    const compact = matchMedia('(max-width: 960px)').matches;
    const visible = compact ? inspector.classList.toggle('show-compact') : !inspector.classList.toggle('hidden');
    if (compact) inspector.classList.remove('hidden');
    e.currentTarget.classList.toggle('active', visible);
    e.currentTarget.setAttribute('aria-expanded', String(visible));
  });

  let modalTrigger;
  const windowChrome = document.querySelectorAll('.app-shell > .titlebar, .app-shell > .workspace, .app-shell > .statusbar');
  function openModal(id, trigger = document.activeElement) {
    closeQuickAnswer();
    const open = document.querySelector('.modal-backdrop.open');
    if (!open) modalTrigger = trigger;
    if (open?.id !== id) open?.classList.remove('open');
    byId(id).classList.add('open');
    for (const region of windowChrome) region.inert = true;
    byId(id).querySelector('input, button')?.focus({preventScroll:true});
  }
  function closeModal(id, tellNative = true) {
    if (!byId(id).classList.contains('open')) return;
    byId(id).classList.remove('open');
    for (const region of windowChrome) region.inert = false;
    if (id === 'fileSearchModal') {
      resetSearchPreview();
      if (tellNative) native('closeSearch');
    }
    if (modalTrigger?.getClientRects().length) modalTrigger.focus({preventScroll:true});
  }
  for (const backdrop of document.querySelectorAll('.modal-backdrop')) {
    backdrop.addEventListener('click', event => {
      if (event.target === backdrop) closeModal(backdrop.id);
    });
  }
  function openFileSearch(event) {
    openModal('fileSearchModal', event?.currentTarget || document.activeElement);
    syncFiles();
    byId('fileSearchInput').focus({preventScroll:true});
  }
  document.getElementById('openFileSearchBtn').onclick = openFileSearch;
  document.getElementById('sidebarSearchBtn').onclick = openFileSearch;

  window.addEventListener('keydown', (e) => {
    const fileOpen = document.getElementById('fileSearchModal').classList.contains('open');
    const modal = document.querySelector('.modal-backdrop.open');
    if (e.key === 'Tab' && modal) {
      const controls = [...modal.querySelectorAll('button, input, select, textarea, [tabindex="0"]')]
        .filter(control => !control.disabled && control.getClientRects().length);
      if (controls.length && e.shiftKey && document.activeElement === controls[0]) {
        e.preventDefault();
        controls.at(-1).focus();
      } else if (controls.length && !e.shiftKey && document.activeElement === controls.at(-1)) {
        e.preventDefault();
        controls[0].focus();
      }
      return;
    }
    if (!modal && e.metaKey && !e.shiftKey && e.key.toLowerCase() === 'o') {
      e.preventDefault();
      native('setting', {key:'verifyAction', value:!byId('verifyCmdToggle').checked});
      return;
    }
    if (modal && !fileOpen && e.key !== 'Escape') return;


    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
      e.preventDefault();
      openFileSearch();
      return;
    }
    if ((e.metaKey || e.ctrlKey) && e.shiftKey && ['KeyD', 'KeyA'].includes(e.code)) {
      e.preventDefault();
      if (modal || e.repeat) return;
      // AppKit handles the global Carbon shortcuts, including in this window.
      return;
    }
    if ((e.metaKey || e.ctrlKey) && ['1','2','3','4','5','6'].includes(e.key)) {
      if (modal) return;
      e.preventDefault();
      const map = ['assistant','voice','routines','activity','appearance','settings'];
      switchView(map[Number(e.key) - 1]);
      return;
    }
    if (e.key === 'Escape') {
      closeModal('routineModal');
      closeModal('fileSearchModal');
      closeQuickAnswer();
      return;
    }

    // File Search Modal keyboard navigation (↑/↓, Space, Enter)
    if (fileOpen) {
      if (e.target instanceof HTMLSelectElement || e.target instanceof HTMLButtonElement) return;
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        moveFileSelection(1);
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        moveFileSelection(-1);
      } else if (e.key === ' ' && document.activeElement !== document.getElementById('fileSearchInput')) {
        e.preventDefault();
        toggleQuickLook();
      } else if (e.key === 'Enter') {
        e.preventDefault();
        if (e.target === byId('fileSearchInput')) submitSearch();
        else fileAction('open');
      }
    }
  });

  function bindSegmentedTabs(segId, prefix) {
    const seg = document.getElementById(segId);
    seg.querySelectorAll('.seg-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        seg.querySelectorAll('.seg-btn').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        document.querySelectorAll(`[id^="${prefix}-"]`).forEach(p => p.classList.add('hidden'));
        document.getElementById(`${prefix}-${btn.dataset.tab}`)?.classList.remove('hidden');
        if (!applyingNavigation) syncNavigation(prefix === 'settings-tab' ? 'settings' : 'voice');
      });
    });
  }
  bindSegmentedTabs('voiceTabSeg', 'voice-tab');
  bindSegmentedTabs('settingsTabSeg', 'settings-tab');

  function renderRoutines() {
    const list = document.getElementById('routinesList');
    if (!routines.length) {
      list.innerHTML = `<div class="row"><span class="row-desc">No routines saved yet. Click "+ New routine" to create one.</span></div>`;
      return;
    }
    list.innerHTML = routines.map(r => {
      const chain = r.actions.map(a => [actionTypes.find(option => option.type === a.type)?.title || a.type, a.target].filter(Boolean).join(' · ')).join(' → ');
      return `
        <div class="row" style="flex-wrap:wrap;">
          <div class="row-info">
            <div style="display:flex; align-items:center; gap:8px;">
              <span class="row-title">${escapeHTML(r.trigger) }</span>
              ${r.offPhrase ? `<span class="status-badge">Off: ${escapeHTML(r.offPhrase) }</span>` : ''}
            </div>
            <span class="row-desc mono" style="font-size:11.5px;">${escapeHTML(chain) }</span>
          </div>
          <div style="display:flex; align-items:center; gap:8px;">
            <label class="switch" title="Enable routine">
              <input type="checkbox" ${r.enabled ? 'checked' : ''} onchange="toggleRoutineEnabled('${r.id}', this.checked)">
              <span class="switch-track"></span>
            </label>
            <button class="btn btn-sm" ${!r.enabled ? 'disabled' : ''} onclick="executeRoutine('${r.id}')">Run</button>
            <button class="btn btn-ghost btn-sm" onclick="openRoutineModal('${r.id}')">Edit</button>
            <button class="btn btn-ghost btn-sm" style="color:var(--status-err);" onclick="deleteRoutine('${r.id}')">Delete</button>
          </div>
        </div>
      `;
    }).join('');
  }

  let currentAccent = '#8ca5ff';
  let currentOrb = 'liquid';

  const orbDescriptions = {
    liquid:  { name: 'Liquid',  desc: 'Reflective chrome' },
    halo:    { name: 'Halo',    desc: 'A dark core with precision orbital rings' },
    aurora:  { name: 'Aurora',  desc: 'Soft layers of moving light' },
    lattice: { name: 'Lattice', desc: 'A sphere of connected points' },
    prism:   { name: 'Prism',   desc: 'Faceted reflective geometry' }
  };

  function setAccent(hex, rgb) {
    currentAccent = hex;
    document.documentElement.style.setProperty('--accent', hex);
    document.documentElement.style.setProperty('--accent-rgb', rgb);
    syncOrb();
  }

  document.getElementById('accentSwatches').querySelectorAll('.swatch-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      document.getElementById('accentSwatches').querySelectorAll('.swatch-btn').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      setAccent(btn.dataset.accent, btn.dataset.rgb);
    });
  });

  byId('orbStyleSelect').onchange = event => {
    currentOrb = event.target.value;
    const {name, desc} = orbDescriptions[currentOrb];
    byId('orbPreviewName').textContent = name;
    byId('orbPreviewDesc').textContent = desc;
    syncOrb();
  };
  byId('animateOrbToggle').onchange = () => syncOrb();
  document.getElementById('textScaleSelect').addEventListener('change', (e) => {
    document.documentElement.style.setProperty('--font-scale', e.target.value);
  });
  document.getElementById('glassOpacitySlider').addEventListener('input', (e) => {
    document.getElementById('glassOpacityVal').textContent = e.target.value + '%';
    document.documentElement.style.setProperty('--glass-opacity', (e.target.value / 100).toFixed(2));
  });
  document.getElementById('borderContrastSlider').addEventListener('input', (e) => {
    document.getElementById('borderContrastVal').textContent = e.target.value + '%';
    const scale = e.target.value / 100;
    document.documentElement.style.setProperty('--border-alpha', (0.08 * scale).toFixed(3));
    document.documentElement.style.setProperty('--border-strong-alpha', (0.14 * scale).toFixed(3));
  });

  function resetAppearance() {
    native('resetAppearance').then(applyAppearance);
    showToast('Appearance reset to defaults');
  }

  const motionPreference = matchMedia("(prefers-reduced-motion: reduce)");
  // Reuse the native orb scenes in a single canvas shared by Assistant and Appearance.
  // The CSS artwork follows the same state and stays visible until a frame is drawn.
  const orbHosts = [byId('orbMain'), byId('orbPreview')];
  const orbStage = (() => {
    let renderer;
    let failed = false;
    let frame = 0;
    let target;
    let lastFrame = 0;
    let simulationTime = 3.1;
    let renderWidth;
    let renderHeight;
    const scenes = new Map();

  const vertex=`uniform float uTime;uniform float uMode;varying vec3 vN;varying vec3 vP;void main(){vec3 p=position;float d=sin(p.x*5.+uTime*.5)*sin(p.y*4.-uTime*.3)*sin(p.z*5.+uTime*.4);if(uMode<.5)p+=normal*d*.025;vP=p;vN=normalize(normalMatrix*normal);gl_Position=projectionMatrix*modelViewMatrix*vec4(p,1.);}`;
  const fragment=`precision highp float;uniform float uTime;uniform vec3 uAccent;uniform float uMode;varying vec3 vN;varying vec3 vP;
  float field(vec3 p){return sin(p.x*3.+sin(p.z*4.)+uTime*.3)*cos(p.y*4.-uTime*.23)+sin(p.z*6.+p.x*3.+uTime*.2)*.4;}
  void main(){vec3 n=normalize(vN);float rim=pow(1.-max(n.z,0.),3.);float key=pow(max(dot(n,normalize(vec3(-.6,.8,.9))),0.),26.);float fill=pow(max(dot(n,normalize(vec3(.8,-.3,.35))),0.),9.);float stripe=sin(vP.y*9.+vP.x*3.+sin(vP.z*4.+uTime*.22)*1.7);vec3 col;
  if(uMode<.5){col=vec3(.018,.023,.035)+uAccent*(.10+fill*.40+rim*.62);col+=vec3(key*.95);vec3 r=reflect(vec3(0.,0.,-1.),n);float ribbon=exp(-pow((r.x+.35+sin(r.y*3.+uTime*.12)*.16)*4.8,2.));float edge=exp(-pow((r.y+.2+r.x*.25)*11.,2.));col+=vec3(ribbon*.25)*(max(n.y,.1)) +uAccent*edge*.22;col+=pow(max(dot(n,normalize(vec3(.1,1.,.5))),0.),60.)*.45;}
  else if(uMode<1.5){col=vec3(.012,.015,.025)+uAccent*(rim*.8+fill*.22)+vec3(key*.8);}
  else{float f=field(vP*1.4);float folds=sin(f*3.2+vP.y*5.-uTime*.3);vec3 mist=mix(uAccent*.32,vec3(.72,.92,1.),smoothstep(-.2,1.4,f));col=mist*(.22+smoothstep(-.8,.8,folds)*.58);col+=uAccent*rim*.8+key*.3;col*=.5+max(n.z,0.)*.5;}
  gl_FragColor=vec4(pow(max(col,vec3(0.)),vec3(.75)),1.);}`;
  function sceneFor(style){if(scenes.has(style))return scenes.get(style);const scene=new THREE.Scene(),camera=new THREE.PerspectiveCamera(36,1,.1,30);camera.position.set(0,0,4.9);const group=new THREE.Group();scene.add(group);const uniforms={uTime:{value:3.1},uMode:{value:style==='liquid'?0:style==='halo'?1:2},uAccent:{value:new THREE.Color(currentAccent)}};const shader=()=>new THREE.ShaderMaterial({vertexShader:vertex,fragmentShader:fragment,uniforms});const accents=[];
    if(['liquid','halo','aurora'].includes(style)){const mesh=new THREE.Mesh(new THREE.SphereGeometry(style==='halo'?.79:1,64,48),shader());group.add(mesh);if(style==='halo'){for(let i=0;i<3;i++){const mat=new THREE.MeshBasicMaterial({color:0xffffff,transparent:true,opacity:i===0?.85:.42});const ring=new THREE.Mesh(new THREE.TorusGeometry(1.15+i*.11,i===0?.014:.008,8,160),mat);ring.rotation.set(.85+i*.35,.3+i*.7,.35);group.add(ring);accents.push(mat);}}}
    else if(style==='lattice'){const geo=new THREE.IcosahedronGeometry(1,3);const mat=new THREE.LineBasicMaterial({color:0xffffff,transparent:true,opacity:.24});group.add(new THREE.LineSegments(new THREE.WireframeGeometry(geo),mat));accents.push(mat);const pointsMat=new THREE.PointsMaterial({color:0xffffff,size:.027,sizeAttenuation:true,transparent:true,opacity:.85});group.add(new THREE.Points(geo,pointsMat));accents.push(pointsMat);const core=new THREE.Mesh(new THREE.SphereGeometry(.87,32,24),new THREE.MeshBasicMaterial({color:0x03050a}));group.add(core);}
    else{const mat=new THREE.MeshStandardMaterial({color:0xffffff,metalness:.66,roughness:.23,flatShading:true});group.add(new THREE.Mesh(new THREE.IcosahedronGeometry(1.02,1),mat));accents.push(mat);scene.add(new THREE.AmbientLight(0x4a5680,.9));const key=new THREE.DirectionalLight(0xffffff,3.8);key.position.set(-2,3,4);scene.add(key);const edge=new THREE.DirectionalLight(0x9cafff,3);edge.position.set(3,-1,-1);scene.add(edge);const soft=new THREE.DirectionalLight(0xffffff,1.2);soft.position.set(1,0,3);scene.add(soft);}
    const result={scene,camera,group,uniforms,accents,style};scenes.set(style,result);return result;}

    function useFallback() {
      failed = true;
      renderer?.domElement.remove();
      orbHosts.forEach(host => host.classList.remove('has-3d'));
    }

    function draw(now) {
      if (failed || !window.THREE || !target || document.hidden || document.documentElement.classList.contains('window-hidden')) return;
      const width = target.clientWidth;
      const height = target.clientHeight;
      if (!width || !height) return;
      try {
        if (!renderer) {
          renderer = new THREE.WebGLRenderer({alpha:true, antialias:true, powerPreference:'low-power'});
          renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 1.5));
          renderer.setClearColor(0, 0);
          renderer.domElement.className = 'orb-canvas';
          renderer.outputColorSpace = THREE.SRGBColorSpace;
          renderer.toneMapping = THREE.ACESFilmicToneMapping;
          renderer.toneMappingExposure = 1.2;
          renderer.debug.onShaderError = useFallback;
          renderer.domElement.addEventListener('webglcontextlost', event => {
            event.preventDefault();
            useFallback();
          });
        }
        if (renderer.domElement.parentElement !== target) target.append(renderer.domElement);
        if (renderWidth !== width || renderHeight !== height) {
          renderer.setSize(width, height, false);
          renderWidth = width;
          renderHeight = height;
        }
        const orb = sceneFor(currentOrb);
        const color = new THREE.Color(currentAccent);
        orb.uniforms.uAccent.value.copy(color);
        orb.uniforms.uTime.value = simulationTime;
        for (const material of orb.accents) material.color.copy(color);
        orb.group.rotation.set(currentOrb === 'lattice' ? simulationTime * .08 : .12, simulationTime * .1,
          currentOrb === 'halo' ? Math.sin(simulationTime * .12) * .3 : .08);
        orb.camera.aspect = width / height;
        orb.camera.updateProjectionMatrix();
        renderer.render(orb.scene, orb.camera);
        if (!failed) target.classList.add('has-3d');
        lastFrame = now;
      } catch {
        useFallback();
      }
    }

    function canAnimate() {
      return target && !failed && window.THREE && !document.hidden && !document.documentElement.classList.contains('window-hidden') &&
        byId('animateOrbToggle').checked && !motionPreference.matches;
    }
    function tick(now) {
      frame = 0;
      if (!canAnimate()) return;
      if (now - lastFrame >= 40) {
        simulationTime += Math.min((now - lastFrame) / 1000, .1);
        draw(now);
      }
      if (canAnimate()) frame = requestAnimationFrame(tick);
    }
    function sync() {
      if (frame) cancelAnimationFrame(frame);
      frame = 0;
      const view = document.querySelector('.view.active')?.id;
      target = view === 'view-assistant' ? orbHosts[0] : view === 'view-appearance' ? orbHosts[1] : null;
      for (const host of orbHosts) {
        host.dataset.style = currentOrb;
        host.classList.remove('has-3d');
      }
      if (target) draw(performance.now());
      if (canAnimate()) frame = requestAnimationFrame(tick);
    }

    return {sync};
  })();
  const syncOrb = orbStage.sync;
  addEventListener('resize', syncOrb);

  motionPreference.addEventListener('change', syncOrb);
  document.addEventListener('visibilitychange', syncOrb);

  const previewState = { original: false };
  function renderInlinePreviewHud() {
    const mode = document.getElementById('previewHudMode').value;
    const phase = document.getElementById('previewHudPhase').value;
    document.getElementById('inlinePreviewHud').innerHTML = buildHudHtml(mode, phase, previewState.original, '0:08');
  }
  document.getElementById('previewHudMode').addEventListener('change', () => { previewState.original = false; renderInlinePreviewHud(); });
  document.getElementById('previewHudPhase').addEventListener('change', () => { previewState.original = false; renderInlinePreviewHud(); });
  byId('inlinePreviewHud').addEventListener('click', event => {
    const button = event.target.closest('[data-hud]');
    const act = button?.dataset.hud;
    if (act === 'finish') {
      byId('previewHudPhase').value = 'result';
      previewState.original = false;
      renderInlinePreviewHud();
      byId('previewHudPhase').focus({preventScroll:true});
    } else if (act === 'toggle-orig') {
      previewState.original = !previewState.original;
      renderInlinePreviewHud();
    } else if (act === 'copy') {
      feedbackForCopy(byId('inlinePreviewHud').querySelector('.hud-transcript'), button,
        byId('inlinePreviewHud').querySelector('.copy-status'), 'Copy text');
    } else if (act === 'run') {
      showQuickAnswer('Quick Answer', new Date().toLocaleTimeString([], {hour:'numeric', minute:'2-digit'}), 'Local system clock');
    }
  });
  renderInlinePreviewHud();

  byId('jumpToGlass').onclick = () => {
    const view = byId('view-appearance');
    const heading = byId('interfaceHeading');
    byId('glassOpacitySlider').focus({preventScroll:true});
    view.scrollTop += heading.getBoundingClientRect().top - view.getBoundingClientRect().top - 12;
  };

  const compactWindow = matchMedia('(max-width: 960px)');
  function updateInspectorButton() {
    const panel = byId('sessionInspector');
    const visible = !panel.classList.contains('hidden') && (!compactWindow.matches || panel.classList.contains('show-compact'));
    const button = byId('toggleInspectorBtn');
    button.setAttribute('aria-expanded', String(visible));
    button.classList.toggle('active', visible);
  }
  compactWindow.addEventListener('change', updateInspectorButton);
  updateInspectorButton();
  let answerTimer;
  function showQuickAnswer(label, value, meta, duration = 5600) {
    clearTimeout(answerTimer);
    document.getElementById('qaLabel').textContent = label;
    document.getElementById('qaValue').textContent = value;
    document.getElementById('qaMeta').textContent = meta;
    byId('quickAnswerPopover').classList.remove('hidden');
    answerTimer = setTimeout(closeQuickAnswer, duration);
  }
  function closeQuickAnswer() {
    clearTimeout(answerTimer);
    document.getElementById('quickAnswerPopover').classList.add('hidden');
  }

