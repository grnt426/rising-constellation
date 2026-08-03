// Stable settings objects for <v-scrollbar> (vue-custom-scrollbar).
//
// The wrapper deep-watches its `settings` prop and reacts to any identity
// change by destroying and re-creating its PerfectScrollbar instance.
// An inline `:settings="{ ... }"` literal in a template produces a new
// object on every parent re-render, so any store tick or hover-driven
// render while the user is dragging the scrollbar thumb destroys the
// instance mid-drag — perfect-scrollbar's document-level mousemove/mouseup
// listeners are unbound and the drag silently dies. (That is why dragging
// only kept working while the cursor stayed on the rail itself: nothing
// re-renders from there.) Sharing frozen singletons keeps the prop
// identity stable so the watcher never fires; frozen objects are also
// skipped by Vue's observer.

// Vertical panel lists (system view content, production queues).
export const VERTICAL_SCROLL_SETTINGS = Object.freeze({
  wheelPropagation: false,
});

// Horizontal card strips (mini-panels): wheel scrolls the X axis.
export const HORIZONTAL_SCROLL_SETTINGS = Object.freeze({
  wheelPropagation: false,
  suppressScrollY: true,
  useBothWheelAxes: true,
});
