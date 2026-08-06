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
  [/\b(?:linear|radial|conic)-gradient\s*\(/i, "gradients"],
  [/backdrop-filter\s*:/i, "glass blur"],
  [/filter\s*:\s*[^;]*(?:blur|drop-shadow)/i, "blur or drop-shadow filters"],
  [/text-shadow\s*:/i, "text glow or shadow"],
  [/box-shadow\s*:/i, "ornamental box shadow"],
  [/mix-blend-mode\s*:/i, "blend-mode effects"],
  [/(?:^|[^\w])#(?:000|000000|00000000|fff|ffffff|ffffffff)(?:[^\w]|$)/i, "pure black or white hex colors"],
  [/data-reveal/i, "hidden reveal content"],
  [/\b(?:revolutionary|supercharge|unlock|seamless|game[ -]?changing|cutting[ -]?edge|next[ -]?generation|AI-powered|magic)\b/i, "hype language"],
  [/\b(?:trusted by|customers love|testimonial|five-star|5-star)\b/i, "fabricated social proof language"],
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

const monoAssignments = css.match(/font-family\s*:\s*var\(--mono\)/gi) || [];
if (monoAssignments.length !== 1 || !/code,\s*\npre\s*\{\s*font-family\s*:\s*var\(--mono\)/i.test(css)) {
  fail("styles.css: monospace must be assigned exactly once and only to code and preformatted text");
}

for (const htmlName of ["index.html", "404.html"]) {
  const html = readFileSync(join(siteRoot, htmlName), "utf8");
  const h1Count = (html.match(/<h1(?:\s|>)/g) || []).length;
  if (h1Count !== 1) fail(`${htmlName}: expected exactly one h1, found ${h1Count}`);
  if (/\sstyle\s*=/.test(html)) fail(`${htmlName}: inline styles are not allowed`);
  if (/<iframe(?:\s|>)/i.test(html)) fail(`${htmlName}: iframe content is not allowed`);
  if (/<(?:img|script|link)\b[^>]+(?:src|href)=["']https?:/i.test(html)) {
    fail(`${htmlName}: remote runtime assets are not allowed`);
  }
}

const index = readFileSync(join(siteRoot, "index.html"), "utf8");
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
