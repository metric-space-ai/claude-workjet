(() => {
  const root = document.documentElement;
  root.classList.add('js');

  const navLinks = Array.from(document.querySelectorAll('.site-nav a[href^="#"]'));
  const navSections = navLinks
    .map((link) => document.querySelector(link.getAttribute('href')))
    .filter(Boolean);
  let framePending = false;

  const updateNavigation = () => {
    let activeId = '';
    const headerGap = 150;
    navSections.forEach((section) => {
      if (section.getBoundingClientRect().top <= headerGap) {
        activeId = section.id;
      }
    });

    navLinks.forEach((link) => {
      if (link.getAttribute('href') === `#${activeId}`) {
        link.setAttribute('aria-current', 'location');
      } else {
        link.removeAttribute('aria-current');
      }
    });

    framePending = false;
  };

  const queueNavigationUpdate = () => {
    if (framePending) return;
    framePending = true;
    window.requestAnimationFrame(updateNavigation);
  };

  updateNavigation();
  window.addEventListener('scroll', queueNavigationUpdate, { passive: true });
  window.addEventListener('resize', queueNavigationUpdate);

  const sequence = document.querySelector('[data-sequence]');
  if (!sequence) return;

  const markers = Array.from(sequence.querySelectorAll('[data-stage-marker]'));
  const appearingItems = Array.from(sequence.querySelectorAll('[data-appear-stage], [data-line-stage]'));
  const playToggle = sequence.querySelector('[data-play-toggle]');
  const replay = sequence.querySelector('[data-replay]');
  const status = sequence.querySelector('[data-sequence-status]');
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const stageNames = ['Contract connected', 'Claude is orchestrator', 'Worker selected', 'Route executing', 'Review ready'];
  const finalStage = stageNames.length - 1;
  const stageDelay = 1050;
  let currentStage = finalStage;
  let timer = 0;
  let playing = false;

  const clearTimer = () => {
    if (timer) {
      window.clearTimeout(timer);
      timer = 0;
    }
  };

  const setButtonState = () => {
    if (reducedMotion.matches) {
      playToggle.textContent = 'Play';
      playToggle.disabled = true;
      playToggle.setAttribute('aria-label', 'System sequence is static because reduced motion is enabled');
      replay.disabled = true;
      replay.setAttribute('aria-label', 'Replay is unavailable because reduced motion is enabled');
      return;
    }

    playToggle.disabled = false;
    replay.disabled = false;
    playToggle.textContent = playing ? 'Pause' : 'Play';
    playToggle.setAttribute('aria-label', playing ? 'Pause system sequence' : 'Play system sequence');
    replay.setAttribute('aria-label', 'Replay system sequence from the contract stage');
  };

  const renderStage = (stage) => {
    currentStage = Math.max(0, Math.min(stage, finalStage));
    sequence.dataset.stage = String(currentStage);

    markers.forEach((marker) => {
      const markerStage = Number(marker.dataset.stageMarker);
      if (markerStage === currentStage) {
        marker.setAttribute('aria-current', 'step');
      } else {
        marker.removeAttribute('aria-current');
      }
    });

    appearingItems.forEach((item) => {
      const itemStage = Number(item.dataset.appearStage ?? item.dataset.lineStage);
      item.dataset.reached = itemStage <= currentStage ? 'true' : 'false';
    });

    status.textContent = stageNames[currentStage];
  };

  const scheduleNextStage = () => {
    clearTimer();
    if (!playing || reducedMotion.matches) return;

    if (currentStage >= finalStage) {
      playing = false;
      setButtonState();
      return;
    }

    timer = window.setTimeout(() => {
      renderStage(currentStage + 1);
      scheduleNextStage();
    }, stageDelay);
  };

  const play = () => {
    if (reducedMotion.matches) return;
    if (currentStage >= finalStage) renderStage(0);
    playing = true;
    setButtonState();
    scheduleNextStage();
  };

  const pause = () => {
    playing = false;
    clearTimer();
    setButtonState();
  };

  const replaySequence = () => {
    if (reducedMotion.matches) return;
    clearTimer();
    renderStage(0);
    playing = true;
    setButtonState();
    scheduleNextStage();
  };

  const applyMotionPreference = () => {
    clearTimer();
    if (reducedMotion.matches) {
      sequence.dataset.motion = 'reduced';
      playing = false;
      renderStage(finalStage);
      setButtonState();
      return;
    }

    sequence.dataset.motion = 'active';
    renderStage(0);
    playing = true;
    setButtonState();
    scheduleNextStage();
  };

  playToggle.addEventListener('click', () => {
    if (playing) pause();
    else play();
  });
  replay.addEventListener('click', replaySequence);
  reducedMotion.addEventListener('change', applyMotionPreference);

  applyMotionPreference();
})();
