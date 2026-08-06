# Workjet design contract

This contract covers the public project site in `site/`. It turns Workjet's visual direction into reviewable constraints so later edits do not drift into generic agent-product styling.

## Thesis

Workjet should feel mechanical, concentrated, and legible. The interface earns trust by exposing real configuration and runtime evidence. It does not simulate complexity with decorative dashboards.

## Visual system

- Use SF Pro Text with native sans-serif fallbacks for prose, labels, and navigation. Use Avenir Next with Avenir and Segoe UI fallbacks for headings and the wordmark. This two-family hierarchy is intentional and local to the operating system. Monospace is reserved for commands, paths, refs, and code.
- Use the graphite, blue, and orange OKLCH tokens in `site/styles.css`. Do not introduce pure black, pure white, gradients, translucent glass, blur, glow, or ornamental shadows.
- Build hierarchy with type size, spacing, alignment, and rules. Do not use a repeated card grid as the default composition.
- Keep corners restrained. The approved rectangular radii are 5px, 6px, and 8px. Circles are reserved for actual status marks and ordered workflow markers.
- Motion must explain state. The current site needs only the skip-link transition and navigation-state transition. Do not animate layout properties or hide primary content behind reveal effects.
- Do not place tracked uppercase kicker or eyebrow labels above headings. Do not add editorial mini-indices to proof sections. Ordered workflow numbers are allowed because they communicate execution sequence.

## Content system

- Lead with the concrete product boundary: native macOS control for declared local and remote coding workers.
- Use specific nouns and verifiable statements. Do not use hype, vague AI claims, invented metrics, customer logos, testimonials, or unsupported provider affiliations.
- Keep body text to readable line lengths. Use one page-level heading and descriptive section headings.
- Name unknown, unavailable, and unverified states directly. A completion receipt is evidence for review, not proof of correctness.

## Image contract

- Product imagery must be an authentic capture from Workjet. Do not use generated dashboards, stock imagery, fake terminal output, or reconstructed application chrome.
- Screenshots may be cropped only to remove test-window chrome, recording indicators, or empty capture margins. Do not alter the product state shown inside the app.
- Keep alt text synchronized with the visible state. Decorative brand marks use empty alt text when an adjacent label already names Workjet.

## Accessibility and resilience

- Preserve semantic landmarks, keyboard navigation, visible focus, the skip link, and reduced-motion handling.
- Color cannot be the only status signal. Maintain sufficient text and rule contrast against the graphite surfaces.
- The complete page must remain readable with JavaScript disabled and at 320 CSS pixels wide.
- Runtime assets remain local. The page must not depend on analytics, cookies, remote scripts, web fonts, or third-party image hosts.

## Enforcement

Run this before committing site changes:

```sh
node site/check-design.mjs
npx --yes impeccable@3.5.0 detect site/
```

CI also serves the page and runs the pinned Impeccable detector at 1280 by 800 and 390 by 844. The checkers reject mechanically detectable regressions. Visual review at desktop and mobile widths remains mandatory because composition, hierarchy, and authenticity cannot be fully linted.
