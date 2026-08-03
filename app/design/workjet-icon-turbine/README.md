# Workjet turbine mark exploration

Four native-vector directions for a Workjet mark built around one sequence: **open intake / suction → compression in a dense core → focused afterburner thrust**. The geometry is intentionally abstract. None of the marks depicts a literal turbine, aircraft, letter, gear, or AI sparkle.

Color is semantic rather than structural: cyan marks intake, Workjet blue marks compression, and violet-to-coral marks thrust. Every direction is designed to survive with all colored parts flattened to one solid menu-bar color. The small white core counter is an app-icon detail; at 16 px it may disappear without changing the outer silhouette.

## Directions

### 01 — Vortex Throat

- **Metaphor:** Two generous intake curls pull work into a hexagonal pressure throat. A blunt, narrow outlet shows energy becoming controlled execution rather than an arrow or projectile.
- **16 px readability:** The large top/bottom masses and 24-unit central air gap stay distinct. The compressed core and outlet read as one strong waist at menu-bar size; the white counter is optional micro-detail.
- **Possible confusion:** At a glance the opposing curls could suggest a clamp, sound funnel, or stylized fish. Keeping the exhaust blunt and the inlet visibly open avoids a paper-plane reading.

### 02 — Compression Stack

- **Metaphor:** A clearly left-to-right sequence: a broad two-lipped suction funnel narrows through a secondary pressure gate, loads one compact chamber, and releases one blunt afterburner pulse.
- **16 px readability:** The inlet has a wide 36-unit mouth and the paired walls never become thin fins. The compression gate overlaps the chamber, so the middle reads as one dense mass rather than tiny mechanical detail.
- **Possible confusion:** The bilateral funnel can suggest an audio horn. Its blunt rectangular mouth and rounded outlet deliberately avoid the pointed outline of a rocket, play button, or paper plane.

### 03 — Radial Plenum

- **Metaphor:** A wide inlet feeds a closed radial pressure vessel. The circular void is the compressed core, not a literal rotor; a single side port turns the stored pressure into focused thrust.
- **16 px readability:** The smooth annulus has a 40-unit wall, a large central counter, and no teeth or blades. In monochrome, the attached inlet and short outlet prevent it from reducing to a generic ring.
- **Possible confusion:** The vessel may suggest a camera lens or bearing. Preserve the strong left intake and off-axis blunt outlet; never add radial teeth, repeated blades, or a broken C-shaped rim.

### 04 — Thrust Chamber

- **Metaphor:** A wide, quiet two-lipped inlet narrows into a protected chamber. Two blunt pulse planes at the outlet suggest an afterburner translating accumulated work into a decisive result.
- **16 px readability:** This has the simplest contour: two broad lips, one narrow waist, one short pulse. The 34-unit intake gap and chunky chamber hold up cleanly at 16 px.
- **Possible confusion:** The bilateral lips can resemble a cable connector or audio horn, while the paired pulse may hint at a media-control icon. Avoid adding more pulse bars or sharpening the outlet.

## Comparison and recommendation

[`comparison.svg`](./comparison.svg) presents each direction on a dark app tile plus a small, single-color silhouette. Reading order is 01–04 from upper-left to lower-right.

**Recommended starting point: 01 — Vortex Throat.** It carries the full intake/compression/thrust story with the fewest repeated elements and has a distinctive asymmetric silhouette. **03 — Radial Plenum** is the strongest compact alternative when the compression core should dominate.

## Production notes

- Source viewBox: `0 0 256 256`; no raster assets, embedded images, masks, or external fonts.
- Keep a minimum 16-unit negative-space channel when redrawing; that maps to one device pixel at 16 px.
- For the macOS menu bar, flatten the intake, core, and exhaust fills to one template color and omit the white counter.
- For an app icon, place the colored mark at roughly 72–78% of a rounded-square tile; do not add bevels, turbine blades, sparks, or a pointed nose.
