/* ==========================================================================
   KeepAwake (CoffeeORTea) - Authentic macOS Native Menu & App Simulator
   ========================================================================== */

document.addEventListener('DOMContentLoaded', () => {
  initLanguageSwitcher();
  initNativeMenuBarSimulator();
  initAboutModal();
  initBlackoutOverlayDemo();
  initFAQAccordion();
  initModeTabs();
  initCopyButtons();
  initLiveClock();
});

/* --------------------------------------------------------------------------
   1. Language Switcher (ZH / EN)
   -------------------------------------------------------------------------- */
let currentLang = 'zh';

function initLanguageSwitcher() {
  const langBtn = document.getElementById('langToggleBtn');
  if (!langBtn) return;

  langBtn.addEventListener('click', () => {
    currentLang = currentLang === 'zh' ? 'en' : 'zh';
    langBtn.querySelector('.lang-text').textContent = currentLang === 'zh' ? 'EN' : '中文';
    
    // Update all elements with data-zh and data-en
    document.querySelectorAll('[data-zh][data-en]').forEach(el => {
      const targetText = el.getAttribute(`data-${currentLang}`);
      if (targetText) {
        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
          el.placeholder = targetText;
        } else {
          el.textContent = targetText;
        }
      }
    });

    // Refresh menu simulator text strings
    updateMenuSimulatorUI();
  });
}

/* --------------------------------------------------------------------------
   2. Authentic Native macOS Menu Bar & KeepAwake Simulator
   -------------------------------------------------------------------------- */
let isKeepAwakeActive = false; // Starts in Sleep mode
let selectedDuration = '1h';
let isBlackoutActive = false;

const durationNames = {
  'indefinitely': { zh: '保持电脑唤醒', en: 'Keep computer awake', badge: '∞', statusZh: '保持电脑唤醒', statusEn: 'Keep computer awake' },
  '15m': { zh: '15 分钟', en: '15 Minutes', badge: '15m', statusZh: '保持电脑唤醒（剩余 14 分钟）', statusEn: 'Keep awake (14m remaining)' },
  '1h': { zh: '1 小时', en: '1 Hour', badge: '1h', statusZh: '保持电脑唤醒（剩余 58 分钟）', statusEn: 'Keep awake (58m remaining)' },
  '3h': { zh: '3 小时', en: '3 Hours', badge: '3h', statusZh: '保持电脑唤醒（剩余 2 小时 55 分）', statusEn: 'Keep awake (2h 55m remaining)' },
  '8am': { zh: '直到早上 08:00', en: 'Until 8:00 AM', badge: '8AM', statusZh: '保持电脑唤醒（直到早上 08:00）', statusEn: 'Keep awake (Until 8:00 AM)' }
};

function initNativeMenuBarSimulator() {
  const trigger = document.getElementById('menuTrigger');
  const dropdown = document.getElementById('simDropdown');
  const mainSwitch = document.getElementById('simMainSwitch');
  const durationMenuItem = document.getElementById('simDurationMenuItem');
  const durationSubmenu = document.getElementById('simDurationSubmenu');
  const blackoutMenuItem = document.getElementById('simBlackoutMenuItem');
  const submenuItems = document.querySelectorAll('.ns-submenu .submenu-item');

  if (!trigger || !dropdown) return;

  // Toggle Dropdown Menu visibility
  trigger.addEventListener('click', (e) => {
    e.stopPropagation();
    dropdown.classList.toggle('active');
    trigger.classList.toggle('active');
  });

  // Main NSSwitch Toggle Action
  if (mainSwitch) {
    mainSwitch.addEventListener('click', () => {
      isKeepAwakeActive = !isKeepAwakeActive;
      if (!isKeepAwakeActive) {
        isBlackoutActive = false; // Disable Blackout when turned off
      }

      // Hide interactive click hint on user interaction
      const hint = document.getElementById('switchClickHint');
      if (hint) hint.classList.add('hidden');
      mainSwitch.classList.remove('pulse-attention');

      updateMenuSimulatorUI();
    });
  }

  // Duration Submenu Items Click Action
  submenuItems.forEach(item => {
    item.addEventListener('click', (e) => {
      e.stopPropagation();
      if (!isKeepAwakeActive) return;

      const durationKey = item.getAttribute('data-duration');
      if (durationKey && durationNames[durationKey]) {
        selectedDuration = durationKey;
        if (durationSubmenu) durationSubmenu.classList.remove('visible');
        updateMenuSimulatorUI();
      }
    });
  });

  // Blackout Mode Menu Item Click Action
  if (blackoutMenuItem) {
    blackoutMenuItem.addEventListener('click', (e) => {
      e.stopPropagation();
      if (!isKeepAwakeActive) return;

      isBlackoutActive = !isBlackoutActive;
      updateMenuSimulatorUI();
    });
  }

  // Submenu Hover & 400ms Delay Hide Handlers
  let submenuHideTimer = null;

  function openSubmenu() {
    if (durationMenuItem && durationMenuItem.classList.contains('disabled')) return;
    if (submenuHideTimer) {
      clearTimeout(submenuHideTimer);
      submenuHideTimer = null;
    }
    if (durationSubmenu) durationSubmenu.classList.add('visible');
    if (durationMenuItem) durationMenuItem.classList.add('hover-active');
  }

  function closeSubmenuWithDelay() {
    if (submenuHideTimer) clearTimeout(submenuHideTimer);
    submenuHideTimer = setTimeout(() => {
      if (durationSubmenu) durationSubmenu.classList.remove('visible');
      if (durationMenuItem) durationMenuItem.classList.remove('hover-active');
      submenuHideTimer = null;
    }, 400); // 400ms delay buffer
  }

  if (durationMenuItem) {
    durationMenuItem.addEventListener('mouseenter', openSubmenu);
    durationMenuItem.addEventListener('mouseleave', closeSubmenuWithDelay);
  }

  if (durationSubmenu) {
    durationSubmenu.addEventListener('mouseenter', openSubmenu);
    durationSubmenu.addEventListener('mouseleave', closeSubmenuWithDelay);
  }

  updateMenuSimulatorUI();
}

function updateMenuSimulatorUI() {
  const simEmoji = document.getElementById('simEmoji');
  const simBadge = document.getElementById('simBadge');
  const mainSwitch = document.getElementById('simMainSwitch');
  const sleepLabel = document.getElementById('simSleepLabel');
  const coffeeLabel = document.getElementById('simCoffeeLabel');
  const statusText = document.getElementById('simStatusText');
  const durationMenuItem = document.getElementById('simDurationMenuItem');
  const durationSubmenu = document.getElementById('simDurationSubmenu');
  const durationTitle = document.getElementById('simDurationTitle');
  const blackoutMenuItem = document.getElementById('simBlackoutMenuItem');
  const blackoutCheck = document.getElementById('simBlackoutCheck');
  const macScreenBody = document.getElementById('macScreenBody');
  const widgetTitle = document.getElementById('screenWidgetTitle');
  const widgetDesc = document.getElementById('screenWidgetDesc');
  const submenuItems = document.querySelectorAll('.ns-submenu .submenu-item');

  const durationObj = durationNames[selectedDuration] || durationNames['1h'];

  if (isKeepAwakeActive) {
    // ☕️ Coffee Active State
    if (simEmoji) simEmoji.textContent = '☕️';
    if (simBadge) simBadge.textContent = durationObj.badge;
    if (mainSwitch) mainSwitch.classList.add('on');
    if (sleepLabel) sleepLabel.classList.remove('active');
    if (coffeeLabel) coffeeLabel.classList.add('active');

    if (statusText) {
      statusText.textContent = currentLang === 'zh' ? durationObj.statusZh : durationObj.statusEn;
    }

    if (durationMenuItem) durationMenuItem.classList.remove('disabled');
    if (blackoutMenuItem) blackoutMenuItem.classList.remove('disabled');

    if (widgetTitle) {
      widgetTitle.textContent = currentLang === 'zh' ? 'KeepAwake 唤醒激活中' : 'KeepAwake Active';
    }
    if (widgetDesc) {
      widgetDesc.textContent = currentLang === 'zh' 
        ? `防休眠策略：${durationObj.zh} (caffeinate 活跃)` 
        : `Assertion mode: ${durationObj.en} (caffeinate live)`;
    }
  } else {
    // 💤 Sleep Inactive State
    if (simEmoji) simEmoji.textContent = '🍵';
    if (simBadge) simBadge.textContent = 'OFF';
    if (mainSwitch) mainSwitch.classList.remove('on');
    if (sleepLabel) sleepLabel.classList.add('active');
    if (coffeeLabel) coffeeLabel.classList.remove('active');

    if (statusText) {
      statusText.textContent = currentLang === 'zh' ? '按系统设置休眠' : 'Normal system sleep';
    }

    if (durationMenuItem) {
      durationMenuItem.classList.add('disabled');
      durationMenuItem.classList.remove('hover-active');
    }
    if (durationSubmenu) durationSubmenu.classList.remove('visible');
    if (blackoutMenuItem) blackoutMenuItem.classList.add('disabled');

    if (widgetTitle) {
      widgetTitle.textContent = currentLang === 'zh' ? 'KeepAwake 就绪' : 'KeepAwake Ready';
    }
    if (widgetDesc) {
      widgetDesc.textContent = currentLang === 'zh' 
        ? '当前状态：按系统默认策略自动休眠' 
        : 'Current status: System default sleep policy';
    }
  }

  // Update Duration Submenu Title & Checkmarks
  if (durationTitle) {
    const curName = currentLang === 'zh' ? durationObj.zh : durationObj.en;
    const prefix = currentLang === 'zh' ? '设置时长  ' : 'Set Duration  ';
    durationTitle.textContent = `${prefix}${curName}`;
  }

  submenuItems.forEach(item => {
    const dKey = item.getAttribute('data-duration');
    const checkSpan = item.querySelector('.sub-check');
    if (dKey === selectedDuration) {
      item.classList.add('active');
      if (checkSpan) checkSpan.textContent = '✓';
    } else {
      item.classList.remove('active');
      if (checkSpan) checkSpan.textContent = '';
    }
  });

  // Update Blackout Checkmark & Screen Display
  if (blackoutCheck) {
    blackoutCheck.textContent = isBlackoutActive ? '✓' : '';
  }

  if (macScreenBody) {
    macScreenBody.classList.toggle('blackout-active', isBlackoutActive);
  }
}

/* --------------------------------------------------------------------------
   3. Native macOS NSAlert About Modal Window
   -------------------------------------------------------------------------- */
function initAboutModal() {
  const aboutMenuItem = document.getElementById('simAboutMenuItem');
  const aboutModal = document.getElementById('macAboutModal');
  const closeBtn = document.getElementById('closeAboutModalBtn');

  if (!aboutMenuItem || !aboutModal) return;

  aboutMenuItem.addEventListener('click', (e) => {
    e.stopPropagation();
    aboutModal.classList.add('active');
  });

  if (closeBtn) {
    closeBtn.addEventListener('click', () => {
      aboutModal.classList.remove('active');
    });
  }

  // Close modal when clicking dark overlay outside alert box
  aboutModal.addEventListener('click', (e) => {
    if (e.target === aboutModal) {
      aboutModal.classList.remove('active');
    }
  });
}

/* --------------------------------------------------------------------------
   4. Blackout Fullscreen Demo Overlay & Rapid Wake Trigger
   -------------------------------------------------------------------------- */
function initBlackoutOverlayDemo() {
  const demoBtn = document.getElementById('triggerBlackoutDemoBtn');
  const demoOverlay = document.getElementById('demoOverlay');
  const closeBtn = document.getElementById('closeOverlayBtn');

  if (!demoBtn || !demoOverlay) return;

  let keyCount = 0;
  let keyTimer = null;

  let startX = null;
  let startY = null;
  const WAKE_DISTANCE_PX = 50;

  function openDemo() {
    demoOverlay.classList.add('active');
    keyCount = 0;
    startX = null;
    startY = null;
    
    window.addEventListener('mousemove', handleMouseMoveExit);
    window.addEventListener('keydown', handleKeyPressExit);
  }

  function closeDemo() {
    demoOverlay.classList.remove('active');
    window.removeEventListener('mousemove', handleMouseMoveExit);
    window.removeEventListener('keydown', handleKeyPressExit);
    clearTimeout(keyTimer);
    keyCount = 0;
  }

  function handleMouseMoveExit(e) {
    if (startX === null || startY === null) {
      startX = e.clientX;
      startY = e.clientY;
      return;
    }

    const diffX = e.clientX - startX;
    const diffY = e.clientY - startY;
    const distance = Math.sqrt(diffX * diffX + diffY * diffY);

    if (distance > WAKE_DISTANCE_PX) {
      closeDemo();
    }
  }

  function handleKeyPressExit() {
    keyCount++;
    if (keyTimer) clearTimeout(keyTimer);

    if (keyCount >= 3) {
      closeDemo();
    } else {
      keyTimer = setTimeout(() => { keyCount = 0; }, 2000);
    }
  }

  demoBtn.addEventListener('click', openDemo);
  if (closeBtn) closeBtn.addEventListener('click', closeDemo);
}

/* --------------------------------------------------------------------------
   5. FAQ Accordion
   -------------------------------------------------------------------------- */
function initFAQAccordion() {
  const faqItems = document.querySelectorAll('.faq-item');

  faqItems.forEach(item => {
    const question = item.querySelector('.faq-question');
    if (!question) return;

    question.addEventListener('click', () => {
      const isActive = item.classList.contains('active');
      faqItems.forEach(other => other.classList.remove('active'));
      if (!isActive) {
        item.classList.add('active');
      }
    });
  });
}

/* --------------------------------------------------------------------------
   6. Mode Tabs (For Human vs For Agent)
   -------------------------------------------------------------------------- */
function initModeTabs() {
  const tabHuman = document.getElementById('tabForHuman');
  const tabAgent = document.getElementById('tabForAgent');
  const panelHuman = document.getElementById('panelForHuman');
  const panelAgent = document.getElementById('panelForAgent');

  if (!tabHuman || !tabAgent || !panelHuman || !panelAgent) return;

  tabHuman.addEventListener('click', () => {
    tabHuman.classList.add('active');
    tabAgent.classList.remove('active');
    panelHuman.classList.add('active');
    panelAgent.classList.remove('active');
  });

  tabAgent.addEventListener('click', () => {
    tabAgent.classList.add('active');
    tabHuman.classList.remove('active');
    panelAgent.classList.add('active');
    panelHuman.classList.remove('active');
  });
}

/* --------------------------------------------------------------------------
   7. Copy Buttons
   -------------------------------------------------------------------------- */
function initCopyButtons() {
  const copyBtns = document.querySelectorAll('.copy-btn-trigger');

  copyBtns.forEach(btn => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const textToCopy = btn.getAttribute('data-copy');
      if (!textToCopy) return;

      navigator.clipboard.writeText(textToCopy).then(() => {
        const textSpan = btn.querySelector('span');
        const originalText = textSpan ? textSpan.textContent : '';

        if (textSpan) {
          textSpan.textContent = currentLang === 'zh' ? '✓ 已复制！' : '✓ Copied!';
        }

        btn.style.transform = 'scale(1.05)';

        setTimeout(() => {
          if (textSpan) textSpan.textContent = originalText;
          btn.style.transform = '';
        }, 2000);
      }).catch(err => {
        console.error('Failed to copy: ', err);
      });
    });
  });
}

/* --------------------------------------------------------------------------
   7. Live Clock Helper
   -------------------------------------------------------------------------- */
function initLiveClock() {
  const clockEl = document.getElementById('liveClock');
  if (!clockEl) return;

  function updateClock() {
    const now = new Date();
    const hrs = String(now.getHours()).padStart(2, '0');
    const mins = String(now.getMinutes()).padStart(2, '0');
    clockEl.textContent = `${hrs}:${mins}`;
  }

  updateClock();
  setInterval(updateClock, 10000);
}
