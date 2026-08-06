(() => {
  const root = document.documentElement;
  root.classList.add('js');

  const navLinks = Array.from(document.querySelectorAll('.site-nav a[href^="#"]'));
  const navSections = navLinks
    .map((link) => document.querySelector(link.getAttribute('href')))
    .filter(Boolean);
  let framePending = false;

  const updatePage = () => {
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

  const queueUpdate = () => {
    if (framePending) return;
    framePending = true;
    window.requestAnimationFrame(updatePage);
  };

  updatePage();
  window.addEventListener('scroll', queueUpdate, { passive: true });
  window.addEventListener('resize', queueUpdate);
})();
