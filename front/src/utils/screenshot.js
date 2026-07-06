// Capture a DOM element to a PNG and put it on the clipboard, falling back
// to a regular download when the clipboard can't hold images (insecure
// context, missing ClipboardItem support, or permission denied).
//
// html2canvas is loaded lazily so the ~200KB library stays out of the main
// bundle until the first screenshot is taken.

// html2canvas mishandles our vue-svgicon icons: they're sized and colored
// entirely via CSS (no width/height attributes, fill: currentColor from
// stylesheets), and html2canvas serializes each inline <svg> standalone —
// losing those styles — then fails to paint several of them at all
// (notably the absolutely-positioned ones, e.g. the population yield-box
// and tile-lock icons). Verified fix: pre-rasterize every <svg> to a PNG
// data URL using its live computed styles, then swap the cloned <svg> for
// an <img> — plain images are html2canvas's best-supported path.
function rasterizeSvg(svg) {
  return new Promise((resolve) => {
    const computed = window.getComputedStyle(svg);
    const w = parseFloat(computed.width) || 16;
    const h = parseFloat(computed.height) || 16;

    const copy = svg.cloneNode(true);
    copy.setAttribute('width', w);
    copy.setAttribute('height', h);
    copy.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
    copy.style.fill = computed.fill;
    copy.style.color = computed.color;

    const url = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(new XMLSerializer().serializeToString(copy))}`;
    const img = new Image();
    img.onload = () => {
      // 2x for sharpness on the capture canvas
      const canvas = document.createElement('canvas');
      canvas.width = Math.max(1, w * 2);
      canvas.height = Math.max(1, h * 2);
      canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
      resolve(canvas.toDataURL('image/png'));
    };
    img.onerror = () => resolve(null);
    img.src = url;
  });
}

const SVG_LAYOUT_PROPS = [
  'width', 'height', 'position', 'top', 'right', 'bottom', 'left',
  'verticalAlign', 'margin', 'display',
];

export async function captureElementToBlob(element, backgroundColor) {
  const { default: html2canvas } = await import(/* webpackChunkName: "html2canvas" */ 'html2canvas');

  element.dataset.rcScreenshotRoot = '1';

  try {
    const sourceSvgs = Array.from(element.querySelectorAll('svg'));
    const pngs = await Promise.all(sourceSvgs.map(rasterizeSvg));

    const canvas = await html2canvas(element, {
      backgroundColor,
      useCORS: true,
      logging: false,
      // capture the full (possibly scrolled-away) content, not the viewport clip
      width: element.scrollWidth,
      height: element.scrollHeight,
      windowWidth: Math.max(document.documentElement.clientWidth, element.scrollWidth),
      windowHeight: Math.max(document.documentElement.clientHeight, element.scrollHeight),
      onclone(clonedDoc) {
        const cloneRoot = clonedDoc.querySelector('[data-rc-screenshot-root]');
        if (!cloneRoot) return;
        // clone and source subtrees have identical traversal order
        Array.from(cloneRoot.querySelectorAll('svg')).forEach((svg, i) => {
          if (!pngs[i] || !sourceSvgs[i]) return;
          const computed = window.getComputedStyle(sourceSvgs[i]);
          const img = clonedDoc.createElement('img');
          img.src = pngs[i];
          SVG_LAYOUT_PROPS.forEach((prop) => { img.style[prop] = computed[prop]; });
          svg.parentNode.replaceChild(img, svg);
        });
      },
    });

    return await new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
  } finally {
    delete element.dataset.rcScreenshotRoot;
  }
}

export async function copyPngToClipboard(blob) {
  if (!blob) return false;
  if (!navigator.clipboard || !window.ClipboardItem || !window.isSecureContext) return false;

  try {
    await navigator.clipboard.write([new window.ClipboardItem({ 'image/png': blob })]);
    return true;
  } catch (e) {
    return false;
  }
}

export function downloadBlob(blob, filename) {
  if (!blob) return false;

  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 10000);
  return true;
}
