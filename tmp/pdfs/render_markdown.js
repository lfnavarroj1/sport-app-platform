const fs = require("fs");
const path = require("path");

const [inputPath, outputPath] = process.argv.slice(2);
if (!inputPath || !outputPath) {
  throw new Error("Usage: node render_markdown.js <input.md> <output.html>");
}

const source = fs.readFileSync(inputPath, "utf8").replace(/\r\n/g, "\n");
const lines = source.split("\n");

function escapeHtml(value) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function slugify(value) {
  return value
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function inline(value) {
  let text = escapeHtml(value);
  const codeTokens = [];
  text = text.replace(/`([^`]+)`/g, (_, code) => {
    const token = `@@CODE_${codeTokens.length}@@`;
    codeTokens.push(`<code>${code}</code>`);
    return token;
  });
  text = text.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>');
  text = text.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  text = text.replace(/\*([^*]+)\*/g, "<em>$1</em>");
  codeTokens.forEach((code, index) => {
    text = text.replace(`@@CODE_${index}@@`, code);
  });
  return text;
}

function isTableSeparator(line) {
  return /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line);
}

function tableCells(line) {
  return line
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((cell) => cell.trim());
}

const headings = [];
for (const line of lines) {
  const match = line.match(/^(#{2,3})\s+(.+)$/);
  if (match) headings.push({ level: match[1].length, text: match[2], id: slugify(match[2]) });
}

const body = [];
let paragraph = [];
let listType = null;
let listItems = [];

function flushParagraph() {
  if (!paragraph.length) return;
  body.push(`<p>${inline(paragraph.join(" "))}</p>`);
  paragraph = [];
}

function flushList() {
  if (!listType) return;
  body.push(`<${listType}>${listItems.map((item) => `<li>${inline(item)}</li>`).join("")}</${listType}>`);
  listType = null;
  listItems = [];
}

for (let index = 0; index < lines.length; index += 1) {
  const line = lines[index];

  if (line.startsWith("```")) {
    flushParagraph();
    flushList();
    const language = line.slice(3).trim();
    const code = [];
    index += 1;
    while (index < lines.length && !lines[index].startsWith("```")) {
      code.push(lines[index]);
      index += 1;
    }
    body.push(`<pre data-language="${escapeHtml(language)}"><code>${escapeHtml(code.join("\n"))}</code></pre>`);
    continue;
  }

  if (/^#\s+/.test(line)) {
    flushParagraph();
    flushList();
    continue;
  }

  const heading = line.match(/^(#{2,3})\s+(.+)$/);
  if (heading) {
    flushParagraph();
    flushList();
    const level = heading[1].length;
    const id = slugify(heading[2]);
    body.push(`<h${level} id="${id}">${inline(heading[2])}</h${level}>`);
    continue;
  }

  if (line.includes("|") && index + 1 < lines.length && isTableSeparator(lines[index + 1])) {
    flushParagraph();
    flushList();
    const headers = tableCells(line);
    index += 2;
    const rows = [];
    while (index < lines.length && lines[index].includes("|") && lines[index].trim() !== "") {
      rows.push(tableCells(lines[index]));
      index += 1;
    }
    index -= 1;
    body.push(
      `<table><thead><tr>${headers.map((cell) => `<th>${inline(cell)}</th>`).join("")}</tr></thead>` +
      `<tbody>${rows.map((row) => `<tr>${row.map((cell) => `<td>${inline(cell)}</td>`).join("")}</tr>`).join("")}</tbody></table>`,
    );
    continue;
  }

  const unordered = line.match(/^\s*-\s+(.+)$/);
  const ordered = line.match(/^\s*\d+\.\s+(.+)$/);
  if (unordered || ordered) {
    flushParagraph();
    const nextType = unordered ? "ul" : "ol";
    if (listType && listType !== nextType) flushList();
    listType = nextType;
    listItems.push((unordered || ordered)[1]);
    continue;
  }

  if (line.trim() === "") {
    flushParagraph();
    flushList();
    continue;
  }

  paragraph.push(line.trim());
}

flushParagraph();
flushList();

const toc = headings
  .map((heading) => `<li class="level-${heading.level}"><a href="#${heading.id}">${inline(heading.text)}</a></li>`)
  .join("");

const html = `<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Proyectos de Google Cloud de SportApp</title>
<style>
  @page { size: A4; margin: 18mm 17mm 19mm 17mm; }
  * { box-sizing: border-box; }
  html { font-family: "Segoe UI", Arial, sans-serif; color: #172033; background: #fff; }
  body { margin: 0; font-size: 10.3pt; line-height: 1.48; }
  .cover {
    min-height: 258mm;
    display: flex;
    flex-direction: column;
    justify-content: center;
    padding: 22mm 13mm;
    background: linear-gradient(145deg, #102a43 0%, #174b72 64%, #1f7a8c 100%);
    color: white;
    page-break-after: always;
  }
  .cover .eyebrow { font-size: 11pt; letter-spacing: 0.14em; text-transform: uppercase; opacity: 0.82; }
  .cover h1 { font-size: 31pt; line-height: 1.12; margin: 14mm 0 7mm; font-weight: 720; }
  .cover .subtitle { max-width: 130mm; font-size: 15pt; line-height: 1.45; color: #d9edf4; }
  .cover .rule { width: 32mm; height: 2.5mm; background: #66d9c8; margin: 8mm 0; border-radius: 3px; }
  .cover .meta { margin-top: 28mm; font-size: 10pt; color: #c7dce8; }
  .toc { page-break-after: always; padding-top: 4mm; }
  .toc h2 { border: 0; margin-top: 0; font-size: 23pt; }
  .toc ol { list-style: none; padding: 0; margin-top: 10mm; }
  .toc li { margin: 3.2mm 0; border-bottom: 1px dotted #b7c3ce; padding-bottom: 1.5mm; }
  .toc li.level-3 { margin-left: 8mm; font-size: 9.5pt; }
  .toc a { color: #174b72; text-decoration: none; }
  main { padding-bottom: 5mm; }
  h2 { color: #123f5e; font-size: 20pt; margin: 12mm 0 4mm; padding-bottom: 2mm; border-bottom: 1.4px solid #5fb9ad; break-after: avoid; }
  h3 { color: #1f6472; font-size: 13.5pt; margin: 8mm 0 2.5mm; break-after: avoid; }
  p { margin: 0 0 4mm; orphans: 3; widows: 3; }
  ul, ol { margin: 2mm 0 5mm 6mm; padding-left: 6mm; }
  li { margin: 1.5mm 0; }
  strong { color: #102a43; }
  code { font-family: Consolas, "Courier New", monospace; font-size: 9pt; color: #8a2c3b; background: #f4f6f8; padding: 0.2mm 1mm; border-radius: 2px; }
  pre { margin: 4mm 0 6mm; padding: 4mm; border-left: 3px solid #2d8c83; border-radius: 3px; background: #f3f7f8; color: #20323d; white-space: pre-wrap; overflow-wrap: anywhere; break-inside: avoid; }
  pre code { padding: 0; color: inherit; background: transparent; font-size: 8.6pt; line-height: 1.45; }
  table { width: 100%; border-collapse: collapse; margin: 4mm 0 7mm; font-size: 8.9pt; break-inside: avoid; }
  th { padding: 2.7mm 2.4mm; text-align: left; color: white; background: #174b72; font-weight: 650; }
  td { padding: 2.4mm; vertical-align: top; border-bottom: 1px solid #d4dde4; }
  tbody tr:nth-child(even) { background: #f5f8fa; }
  a { color: #126b78; }
  .page-footer { position: fixed; left: 0; right: 0; bottom: -12mm; text-align: center; font-size: 8pt; color: #718096; }
  .section-start { page-break-before: always; }
</style>
</head>
<body>
  <section class="cover">
    <div class="eyebrow">SportApp - Plataforma</div>
    <div class="rule"></div>
    <h1>Proyectos de Google Cloud</h1>
    <div class="subtitle">Separación entre el plano de gestión y la infraestructura operativa de producción.</div>
    <div class="meta">Documento de arquitectura y operación<br>Versión 2026-10-18</div>
  </section>
  <section class="toc">
    <h2>Contenido</h2>
    <ol>${toc}</ol>
  </section>
  <main>${body.join("\n")}</main>
  <div class="page-footer">SportApp - Arquitectura GCP</div>
</body>
</html>`;

fs.writeFileSync(outputPath, html, "utf8");
