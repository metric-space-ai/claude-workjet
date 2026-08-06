import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const siteRoot = fileURLToPath(new URL(".", import.meta.url));
const failures = [];

function fail(message) {
  failures.push(message);
}

function walk(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const absolute = join(directory, entry.name);
    return entry.isDirectory() ? walk(absolute) : [absolute];
  });
}

const runtimeFiles = walk(siteRoot).filter((file) => /\.(?:html|css|js)$/.test(file));
const source = runtimeFiles.map((file) => ({
  file,
  name: relative(siteRoot, file),
  text: readFileSync(file, "utf8"),
}));

const bannedSourcePatterns = [
  [/\b(?:repeating-)?(?:linear|radial|conic)-gradient\s*\(/i, "gradients or decorative stripes"],
  [/backdrop-filter\s*:/i, "glass blur"],
  [/filter\s*:\s*[^;]*(?:blur|drop-shadow)/i, "blur or drop-shadow filters"],
  [/text-shadow\s*:/i, "text glow or shadow"],
  [/box-shadow\s*:/i, "ornamental box shadow"],
  [/mix-blend-mode\s*:/i, "blend-mode effects"],
  [/(?:^|[^\w])#(?:000|000000|00000000|fff|ffffff|ffffffff)(?:[^\w]|$)/i, "pure black or white hex colors"],
  [/data-reveal/i, "hidden reveal content"],
  [/\b(?:revolutionary|supercharge|unlock|seamless|streamline|empower|world[ -]?class|enterprise[ -]?grade|game[ -]?changing|cutting[ -]?edge|next[ -]?generation|AI-powered|magic)\b/i, "hype language"],
  [/\b(?:trusted by|customers love|testimonial|five-star|5-star)\b/i, "fabricated social proof language"],
  [/\b(?:eyebrow|kicker|proof-index)\b/i, "editorial kicker or mini-index"],
  [/\b(?:placeholder|will appear here|coming soon)\b/i, "placeholder content"],
  [/<marquee(?:\s|>)/i, "auto-scrolling marquee"],
  [/text-align\s*:\s*justify/i, "justified body text"],
  [/font-style\s*:\s*italic/i, "italic display styling"],
  [/[\u2013\u2014]/, "en or em dashes in page copy"],
  [/animation(?:-name)?\s*:/i, "decorative animation"],
  [/transition\s*:[^;]*(?:width|height|top|right|bottom|left|margin|padding|grid|flex)/i, "layout-property transitions"],
];

for (const { name, text } of source) {
  for (const [pattern, label] of bannedSourcePatterns) {
    if (pattern.test(text)) fail(`${name}: ${label}`);
  }
}

const css = readFileSync(join(siteRoot, "styles.css"), "utf8");
for (const match of css.matchAll(/border-radius\s*:\s*([0-9.]+)px/gi)) {
  if (Number(match[1]) > 8) fail(`styles.css: border radius exceeds 8px (${match[0]})`);
}

for (const match of css.matchAll(/font-size\s*:\s*([^;]+);/gi)) {
  for (const size of match[1].matchAll(/([0-9.]+)rem\b/gi)) {
    if (Number(size[1]) < 0.75) {
      fail(`styles.css: rem text size is below 12px (${match[0]})`);
    }
  }
}

const bodyTypeface = css.match(/--sans\s*:\s*([^;]+);/i)?.[1];
const displayTypeface = css.match(/--display\s*:\s*([^;]+);/i)?.[1];
if (!bodyTypeface || !displayTypeface || bodyTypeface === displayTypeface) {
  fail("styles.css: body and display typography must use two declared families");
}

if (/(?:img|\.capture)[^{]*:hover[^}]*\{[^}]*transform\s*:/is.test(css)) {
  fail("styles.css: image hover transforms are not allowed");
}

const monoAssignments = css.match(/font-family\s*:\s*var\(--mono\)/gi) || [];
if (monoAssignments.length !== 1 || !/code,\s*\npre\s*\{\s*font-family\s*:\s*var\(--mono\)/i.test(css)) {
  fail("styles.css: monospace must be assigned exactly once and only to code and preformatted text");
}

for (const htmlName of ["index.html", "404.html"]) {
  const html = readFileSync(join(siteRoot, htmlName), "utf8");
  const h1Count = (html.match(/<h1(?:\s|>)/g) || []).length;
  if (h1Count !== 1) fail(`${htmlName}: expected exactly one h1, found ${h1Count}`);
  const headingLevels = Array.from(html.matchAll(/<h([1-6])(?:\s|>)/g), (match) => Number(match[1]));
  for (let index = 1; index < headingLevels.length; index += 1) {
    if (headingLevels[index] > headingLevels[index - 1] + 1) {
      fail(`${htmlName}: heading hierarchy skips from h${headingLevels[index - 1]} to h${headingLevels[index]}`);
    }
  }
  if (/\sstyle\s*=/.test(html)) fail(`${htmlName}: inline styles are not allowed`);
  if (/<iframe(?:\s|>)/i.test(html)) fail(`${htmlName}: iframe content is not allowed`);
  if (/<(?:img|script|link)\b[^>]+(?:src|href)=["']https?:/i.test(html)) {
    fail(`${htmlName}: remote runtime assets are not allowed`);
  }
  for (const image of html.matchAll(/<img\b([^>]*)>/gi)) {
    if (!/\bsrc=["'][^"']+["']/i.test(image[1]) || /\bsrc=["'][^"']*(?:placeholder|dummy|example)[^"']*["']/i.test(image[1])) {
      fail(`${htmlName}: image source is missing or looks like a placeholder`);
    }
    if (!/\balt=["'][^"']*["']/i.test(image[1])) fail(`${htmlName}: image is missing alt text`);
  }
}

const index = readFileSync(join(siteRoot, "index.html"), "utf8");
const heroText = index.match(/<h1[^>]*>([^<]+)<\/h1>/i)?.[1]?.trim() || "";
if (heroText.split(/\s+/).filter(Boolean).length > 5) {
  fail("index.html: hero headline is a full sentence set as display type");
}
const screenshots = [
  "workjet-overview.png",
  "workjet-worker-skills.png",
  "workjet-remote-computer.png",
  "workjet-prompt-telemetry.png",
];

for (const filename of screenshots) {
  const screenshot = join(siteRoot, "assets", "screenshots", filename);
  if (!statSync(screenshot).isFile()) {
    fail(`missing authentic screenshot: ${filename}`);
    continue;
  }
  const buffer = readFileSync(screenshot);
  const pngSignature = "89504e470d0a1a0a";
  if (buffer.subarray(0, 8).toString("hex") !== pngSignature) {
    fail(`${filename}: expected PNG data`);
    continue;
  }
  const width = buffer.readUInt32BE(16);
  const height = buffer.readUInt32BE(20);
  if (width < 1000 || height < 1000) {
    fail(`${filename}: capture is below the 1000 by 1000 authenticity floor (${width} by ${height})`);
  }
  if (!index.includes(`assets/screenshots/${filename}`)) {
    fail(`index.html: authentic screenshot is not used: ${filename}`);
  }
}

if (failures.length > 0) {
  console.error("Project-site design contract failed:\n");
  failures.forEach((message) => console.error(`- ${message}`));
  process.exit(1);
}

console.log(`Project-site design contract passed (${runtimeFiles.length} runtime files, ${screenshots.length} authentic captures).`);
