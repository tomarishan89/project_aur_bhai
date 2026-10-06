/**
 * Project Aur Bhai — Sovereign Voice-Orchestrated Mobile Agentic OS
 * Interactive Documentation Application Script
 * 
 * Modules:
 * 1. Lightbox Modal Controller (touch, keyboard & carousel navigation)
 * 2. Declarative Multi-Slide Showcase Engine
 * 3. Seed Capabilities Data & Dynamic Switcher
 * 4. MCP Config Clipboard Copy & Bootstrap
 */

/* ==========================================================================
   1. Lightbox Modal Controller
   ========================================================================== */
let currentLightboxSlides = [];
let currentLightboxIndex = 0;

function openLightbox(srcOrSlides, captionOrIndex) {
  const modal = document.getElementById('lightbox-modal');
  if (!modal) return;

  if (Array.isArray(srcOrSlides)) {
    currentLightboxSlides = srcOrSlides;
    currentLightboxIndex = typeof captionOrIndex === 'number' ? captionOrIndex : 0;
  } else {
    currentLightboxSlides = [{ src: srcOrSlides, caption: captionOrIndex || '' }];
    currentLightboxIndex = 0;
  }

  updateLightboxView();
  modal.classList.add('active');
  document.body.style.overflow = 'hidden';
}

function updateLightboxView() {
  if (!currentLightboxSlides || currentLightboxSlides.length === 0) return;
  const current = currentLightboxSlides[currentLightboxIndex];
  const img = document.getElementById('lightbox-img');
  const captionEl = document.getElementById('lightbox-caption');
  const counterEl = document.getElementById('lightbox-counter');
  const prevBtn = document.getElementById('lightbox-prev');
  const nextBtn = document.getElementById('lightbox-next');

  if (!img) return;

  img.style.opacity = '0.3';
  setTimeout(() => {
    img.src = current.src;
    img.alt = current.caption || 'Enlarged screenshot';
    if (captionEl) captionEl.textContent = current.caption || '';
    img.style.opacity = '1';
  }, 100);

  if (currentLightboxSlides.length > 1) {
    if (counterEl) {
      counterEl.textContent = `${currentLightboxIndex + 1} / ${currentLightboxSlides.length}`;
      counterEl.style.display = 'block';
    }
    if (prevBtn) prevBtn.style.display = 'flex';
    if (nextBtn) nextBtn.style.display = 'flex';
  } else {
    if (counterEl) counterEl.style.display = 'none';
    if (prevBtn) prevBtn.style.display = 'none';
    if (nextBtn) nextBtn.style.display = 'none';
  }
}

function stepLightbox(delta) {
  if (currentLightboxSlides.length <= 1) return;
  currentLightboxIndex = (currentLightboxIndex + delta + currentLightboxSlides.length) % currentLightboxSlides.length;
  updateLightboxView();
}

function closeLightbox() {
  const modal = document.getElementById('lightbox-modal');
  if (modal) {
    modal.classList.remove('active');
  }
  document.body.style.overflow = '';
}

document.addEventListener('keydown', (e) => {
  const modal = document.getElementById('lightbox-modal');
  if (!modal || !modal.classList.contains('active')) return;
  if (e.key === 'Escape') closeLightbox();
  if (e.key === 'ArrowLeft') stepLightbox(-1);
  if (e.key === 'ArrowRight') stepLightbox(1);
});

/* ==========================================================================
   2. Declarative Slideshow Engine
   ========================================================================== */
function initSlideshow(container) {
  if (!container) return;
  const viewport = container.querySelector('.slideshow-viewport');
  if (!viewport) return;

  // Clear any previously generated controls
  container.querySelectorAll('.slide-nav-btn, .slide-badge, .slide-dots, .slide-caption-text').forEach(el => el.remove());

  // Collect raw images
  const rawImgs = Array.from(viewport.querySelectorAll('img'));
  const count = rawImgs.length;
  container.setAttribute('data-slides-count', count);

  // Rule: 0 images -> Hide container cleanly (no slide show)
  if (count === 0) {
    container.style.display = 'none';
    return;
  }
  container.style.display = 'flex';

  const slidesData = rawImgs.map(img => ({
    src: img.getAttribute('src'),
    alt: img.getAttribute('alt') || '',
    caption: img.getAttribute('data-caption') || img.getAttribute('alt') || ''
  }));

  // Ensure each image is inside a .slide-item wrapper
  rawImgs.forEach((img, idx) => {
    let item = img.closest('.slide-item');
    if (!item) {
      item = document.createElement('div');
      item.className = 'slide-item';
      img.parentNode.insertBefore(item, img);
      item.appendChild(img);
    }
    item.classList.toggle('active', idx === 0);
  });

  const slideItems = Array.from(viewport.querySelectorAll('.slide-item'));
  let activeIdx = 0;

  function showSlide(index) {
    activeIdx = (index + count) % count;
    slideItems.forEach((item, idx) => {
      item.classList.toggle('active', idx === activeIdx);
    });
    const badge = container.querySelector('.slide-badge');
    if (badge) badge.textContent = `${activeIdx + 1} / ${count}`;
    const dots = container.querySelectorAll('.slide-dot');
    dots.forEach((d, idx) => d.classList.toggle('active', idx === activeIdx));
    const captionEl = container.querySelector('.slide-caption-text');
    if (captionEl) captionEl.textContent = slidesData[activeIdx].caption;
  }

  // Clicking viewport opens Lightbox at current slide
  viewport.onclick = (e) => {
    if (e.target.closest('.slide-nav-btn')) return;
    openLightbox(slidesData, activeIdx);
  };

  // Rule: 1 image -> Show single highlighted image, NO slideshow controls
  if (count === 1) {
    if (slidesData[0].caption) {
      const captionEl = document.createElement('div');
      captionEl.className = 'slide-caption-text';
      captionEl.textContent = slidesData[0].caption;
      container.appendChild(captionEl);
    }
    return;
  }

  // Rule: >= 2 images -> Interactive Slideshow
  // 1. Badge (1 / N)
  const badge = document.createElement('div');
  badge.className = 'slide-badge';
  badge.textContent = `1 / ${count}`;
  viewport.appendChild(badge);

  // 2. Previous & Next buttons
  const prevBtn = document.createElement('button');
  prevBtn.className = 'slide-nav-btn prev';
  prevBtn.innerHTML = '&#8249;';
  prevBtn.setAttribute('aria-label', 'Previous Slide');
  prevBtn.onclick = (e) => {
    e.stopPropagation();
    showSlide(activeIdx - 1);
  };

  const nextBtn = document.createElement('button');
  nextBtn.className = 'slide-nav-btn next';
  nextBtn.innerHTML = '&#8250;';
  nextBtn.setAttribute('aria-label', 'Next Slide');
  nextBtn.onclick = (e) => {
    e.stopPropagation();
    showSlide(activeIdx + 1);
  };

  viewport.appendChild(prevBtn);
  viewport.appendChild(nextBtn);

  // 3. Dot pagination
  const dotsContainer = document.createElement('div');
  dotsContainer.className = 'slide-dots';
  for (let i = 0; i < count; i++) {
    const dot = document.createElement('button');
    dot.className = 'slide-dot' + (i === 0 ? ' active' : '');
    dot.setAttribute('aria-label', `Go to slide ${i + 1}`);
    dot.onclick = (e) => {
      e.stopPropagation();
      showSlide(i);
    };
    dotsContainer.appendChild(dot);
  }
  container.appendChild(dotsContainer);

  // 4. Caption strip below
  const captionEl = document.createElement('div');
  captionEl.className = 'slide-caption-text';
  captionEl.textContent = slidesData[0].caption;
  container.appendChild(captionEl);

  // 5. Touch swipe gestures
  let touchStartX = 0;
  let touchStartY = 0;
  viewport.addEventListener('touchstart', (e) => {
    touchStartX = e.changedTouches[0].screenX;
    touchStartY = e.changedTouches[0].screenY;
  }, { passive: true });

  viewport.addEventListener('touchend', (e) => {
    const diffX = e.changedTouches[0].screenX - touchStartX;
    const diffY = e.changedTouches[0].screenY - touchStartY;
    if (Math.abs(diffX) > 40 && Math.abs(diffX) > Math.abs(diffY)) {
      if (diffX < 0) {
        showSlide(activeIdx + 1);
      } else {
        showSlide(activeIdx - 1);
      }
    }
  }, { passive: true });
}

function initAllSlideshows() {
  document.querySelectorAll('[data-slideshow]').forEach(el => {
    // Skip capabilities slideshow since it is dynamically updated by switchBhai
    if (el.id !== 'capabilities-slideshow') {
      initSlideshow(el);
    }
  });
}

/* ==========================================================================
   3. Seed Capabilities Data & Dynamic Switcher
   ========================================================================== */
const bhaiData = {
  accountant: {
    title: "Accountant 💰",
    desc: "Structured expense logging directly into an on-device SQLite database. Automatically categorizes food, travel, and bills while hosting a live glassmorphism spending breakdown dashboard.",
    chips: ["C2 Verified", "Category: Finance", "SQLite Vault", "HTML5 Dashboard"],
    prompt: '"Bhai, log 450 rupees for lunch with team"',
    preview: `
<div style="color: var(--accent-cyan); margin-bottom: 0.5rem;">[DATABASE_VIEW: expenses]</div>
<div>2026-08-26 13:20 | Food & Dining | ₹450.00 | Lunch with team</div>
<div>2026-08-26 09:15 | Transport     | ₹120.00 | Metro recharge</div>
<div style="margin-top: 1rem; color: var(--accent-emerald);">✔ Live chart updated at http://localhost:8080/vault/expenses.html</div>`,
    screenshots: [
      { src: 'screenshots/accountant_mobile.jpg', caption: 'Accountant · Voice Expense Logging on Device' },
      { src: 'screenshots/accountant_web_dashboard.jpg', caption: 'Accountant · Live Expense Breakdown Dashboard on Desktop' }
    ]
  },
  telemeter: {
    title: "Telemeter 📊",
    desc: "Captures high-frequency inertial sensor data and hardware telemetry into an encrypted ring buffer. Serves a real-time charting dashboard on your local Wi-Fi.",
    chips: ["C2 Verified", "Category: Sensors", "Inertial Telemetry", "Real-Time Canvas"],
    prompt: '"Bhai, start telemetry recording and open dashboard on desktop"',
    preview: `
<div style="color: var(--accent-cyan); margin-bottom: 0.5rem;">[SENSOR_STREAM: 50Hz]</div>
<div>ACCEL_Z: 9.81 m/s² | GYRO_Y: +0.02 rad/s | TEMP: 31.4°C</div>
<div>BUFFER: 120 samples ring-buffered | SQLite Vault write clean</div>
<div style="margin-top: 1rem; color: var(--accent-emerald);">✔ Desktop auto-switched to http://192.168.1.50:8080/vault/locator.html</div>`,
    screenshots: [
      { src: 'screenshots/telemetry_mobile.jpg', caption: 'Mobile Telemetry · 50Hz Inertial Sensor Stream' },
      { src: 'screenshots/telemetry_web_live_graphs.jpg', caption: 'Desktop Browser · Shelf HTTP Server Live Charts' },
      { src: 'screenshots/telemetry_web_dashboard.jpg', caption: 'Multi-Metric Desktop Dashboard · All Sensor Channels' }
    ]
  },
  calculator: {
    title: "Calculator 🧮",
    desc: "Pure JavaScript mathematics engine supporting trigonometric calculations, matrix power operators (^), and instant spoken acoustic feedback.",
    chips: ["C2 Verified", "Category: Math", "QuickJS Sandbox", "Instant Spoken Voice"],
    prompt: '"Ask Calculator what is 2 to the power of 12 plus sqrt(625)"',
    preview: `
<div style="color: var(--accent-cyan); margin-bottom: 0.5rem;">[QUICKJS_EVAL]</div>
<div>EXPR: (2 ** 12) + Math.sqrt(625)</div>
<div>RESULT: 4121</div>
<div style="margin-top: 1rem; color: var(--accent-emerald);">✔ TTS Spoken: "Result is 4121, Bhai!"</div>`,
    screenshots: [
      { src: 'screenshots/calculator_mobile.jpg', caption: 'Calculator · QuickJS Arithmetic Evaluation & Spoken TTS' }
    ]
  },
  notetaker: {
    title: "Note Taker 📝",
    desc: "Acoustic speech-to-note engine with automatic hashtag extraction (#ideas, #todo) and local Markdown document export.",
    chips: ["C2 Verified", "Category: Productivity", "Tag Extraction", "Markdown Vault"],
    prompt: '"Bhai, take a note: buy groceries tomorrow #todo #home"',
    preview: `
<div style="color: var(--accent-cyan); margin-bottom: 0.5rem;">[VAULT_ASSET: note_20260826.md]</div>
<div># Note: Buy groceries tomorrow</div>
<div>Tags: #todo #home | Created: 2026-08-26T09:30:00Z</div>
<div style="margin-top: 1rem; color: var(--accent-emerald);">✔ Markdown exported to sovereign vault</div>`,
    screenshots: [
      { src: 'screenshots/notetaker_mobile.jpg', caption: 'Note Taker · Acoustic Notes with Hashtags & Markdown Vault' }
    ]
  },
  iwish: {
    title: "I Wish 🌟",
    desc: "Built-in sovereign feedback loop. Captures user feature wishes, categorizes them locally, and feeds an offline AI clustering triage pipeline to guide roadmap prioritization.",
    chips: ["C2 Verified", "Category: Feedback", "Priority Scoring", "Offline AI Triage"],
    prompt: '"Bhai, I wish we had an offline currency converter with live cached rates"',
    preview: `
<div style="color: var(--accent-cyan); margin-bottom: 0.5rem;">[WISH_INGEST]</div>
<div>WISH: "Offline currency converter" | CATEGORY: agent | TAGS: #finance #offline</div>
<div>TRIAGE SCORE: 12.0 (Freq: 2 x Fit: 3 x Act: 2) -> Weekly Roadmap Digest</div>
<div style="margin-top: 1rem; color: var(--accent-emerald);">✔ TTS: "Noted Bhai! Saved to your wishlist."</div>`,
    screenshots: [] // 0 images -> completely hides slideshow
  }
};

function renderCapabilitiesSlideshow(screenshotsList) {
  const wrap = document.getElementById('capabilities-slideshow-wrap');
  const container = document.getElementById('capabilities-slideshow');
  if (!wrap || !container) return;

  const viewport = container.querySelector('.slideshow-viewport');
  if (!viewport) return;
  viewport.innerHTML = '';

  if (!screenshotsList || screenshotsList.length === 0) {
    wrap.style.display = 'none';
    container.style.display = 'none';
    return;
  }

  wrap.style.display = 'block';
  container.style.display = 'flex';

  screenshotsList.forEach(item => {
    const img = document.createElement('img');
    img.src = item.src;
    img.alt = item.caption || 'Capability screenshot';
    img.setAttribute('data-caption', item.caption || '');
    img.setAttribute('loading', 'lazy');
    viewport.appendChild(img);
  });

  initSlideshow(container);
}

function switchBhai(key, triggerBtn) {
  const data = bhaiData[key];
  if (!data) return;

  document.querySelectorAll('.tab-btn').forEach(btn => btn.classList.remove('active'));
  if (triggerBtn) {
    triggerBtn.classList.add('active');
  } else if (typeof event !== 'undefined' && event && event.target) {
    event.target.classList.add('active');
  }

  const titleEl = document.getElementById('bhai-title');
  const descEl = document.getElementById('bhai-desc');
  const promptEl = document.getElementById('bhai-prompt');
  const previewEl = document.getElementById('bhai-preview');
  const chipsContainer = document.getElementById('bhai-chips');

  if (titleEl) titleEl.innerHTML = data.title;
  if (descEl) descEl.textContent = data.desc;
  if (promptEl) promptEl.textContent = data.prompt;
  if (previewEl) previewEl.innerHTML = data.preview;

  if (chipsContainer) {
    chipsContainer.innerHTML = '';
    data.chips.forEach((c, idx) => {
      const span = document.createElement('span');
      span.className = 'chip' + (idx === 0 ? ' cyan' : '');
      span.textContent = c;
      chipsContainer.appendChild(span);
    });
  }

  // Update dynamic capabilities slideshow
  renderCapabilitiesSlideshow(data.screenshots);
}

/* ==========================================================================
   4. MCP Config Copy & Bootstrap
   ========================================================================== */
function copyMcpConfig() {
  const codeEl = document.getElementById('mcp-code-block');
  if (!codeEl) return;
  const code = codeEl.innerText;
  navigator.clipboard.writeText(code).then(() => {
    const btn = document.querySelector('.copy-btn');
    if (btn) {
      btn.textContent = 'Copied! ✔';
      setTimeout(() => { btn.textContent = 'Copy Config'; }, 2000);
    }
  });
}

// Initialize all slideshows and default capability reliably
function bootSlideshows() {
  initAllSlideshows();
  renderCapabilitiesSlideshow(bhaiData.accountant.screenshots);
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', bootSlideshows);
} else {
  bootSlideshows();
}
