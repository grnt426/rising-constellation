import viewport from '@/utils/viewport';

// Tooltips on a phone open on press-and-hold, never on a tap.
//
// With v-tooltip's 'click' trigger (what phones had), every tap on a
// button with a tooltip ran the button AND opened its tooltip, which
// then stayed up over whatever the button had just opened ("Reports"
// over the Reports tab) until another tap somewhere. A tap is the
// action; holding is how a phone asks "what is this?" (Android's own
// tooltips work this way). So at phone widths the directive's trigger
// is 'manual' (main.js) and this module drives the tooltips:
//   - hold a finger on anything with a tooltip: it opens, and the click
//     the release may produce is swallowed (you asked, you didn't act);
//   - a tap on an inert hint (the "?" that has no other job,
//     role="note") toggles it, since a tap is all anyone tries there;
//   - the next touch anywhere outside the bubble puts it away.
// Elements with their own hold gesture opt out with `data-long-press`
// (the build tiles: holding one opens its card).
// <v-popover> / HoverPopover sites are separate components and keep
// their tap-to-open popovers (PopoverTriggerMixin).

const LONG_PRESS_MS = 500;
const SLOP_PX = 10;
// the click a release produces lands within a frame or two of it
const SWALLOW_CLICK_MS = 400;

let press = null;
let shown = null;
let swallow = null;

function tooltipHost(node) {
  let el = node;
  while (el && el !== document.body && el.nodeType === 1) {
    if (el._tooltip) return el;
    el = el.parentElement;
  }
  return null;
}

function hideShown() {
  if (shown) {
    shown.tooltip.hide();
    shown = null;
  }
}

function showFor(host) {
  hideShown();
  host._tooltip.show();
  shown = { tooltip: host._tooltip, host };
}

function cancelPress() {
  if (press) clearTimeout(press.timer);
  press = null;
}

function insideBubble(target) {
  const node = shown && shown.tooltip._tooltipNode;
  return !!(node && node.contains(target));
}

function onPointerDown(event) {
  if (!viewport.isMobile || event.pointerType === 'mouse') return;

  if (shown && !insideBubble(event.target)) hideShown();
  cancelPress();
  swallow = null;

  if (event.target.closest && event.target.closest('[data-long-press]')) return;
  const host = tooltipHost(event.target);
  if (!host) return;

  press = {
    x: event.clientX,
    y: event.clientY,
    timer: setTimeout(() => {
      press = null;
      if (!host.isConnected || !host._tooltip) return;
      showFor(host);
      // armed until the finger lifts, however long it is held
      swallow = { host, until: Infinity };
    }, LONG_PRESS_MS),
  };
}

// The finger lifts: the hold is over, and the click it may produce
// follows right away.
function onPointerUp() {
  cancelPress();
  if (swallow && swallow.until === Infinity) swallow.until = Date.now() + SWALLOW_CLICK_MS;
}

function onPointerMove(event) {
  if (!press) return;
  if (Math.abs(event.clientX - press.x) > SLOP_PX
    || Math.abs(event.clientY - press.y) > SLOP_PX) {
    cancelPress();
  }
}

function onClickCapture(event) {
  if (!viewport.isMobile) return;

  const held = swallow;
  swallow = null;
  if (held && Date.now() < held.until && held.host.contains(event.target)) {
    event.stopPropagation();
    event.preventDefault();
    return;
  }

  const host = tooltipHost(event.target);
  if (host && host.matches('[role="note"]')) {
    if (shown && shown.host === host) hideShown();
    else showFor(host);
  }
}

let installed = false;

export default function installTouchTooltips() {
  if (installed || typeof document === 'undefined') return;
  installed = true;

  const opts = { capture: true, passive: true };
  document.addEventListener('pointerdown', onPointerDown, opts);
  document.addEventListener('pointermove', onPointerMove, opts);
  document.addEventListener('pointerup', onPointerUp, opts);
  document.addEventListener('pointercancel', onPointerUp, opts);
  window.addEventListener('click', onClickCapture, true);
  // a scroll carries the anchor away from its bubble
  window.addEventListener('scroll', hideShown, { capture: true, passive: true });
}
