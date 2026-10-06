<template>
  <div class="chat-composer-wrap">
    <!-- Who an `@` being typed could mean. Opens upward: the composer is
         the bottom of the chat box. -->
    <div
      v-if="picker && picker.items.length > 0"
      class="chat-mention-picker"
      role="listbox"
      :aria-label="$t('in_game_chat.mention_picker')">
      <button
        v-for="(member, i) in picker.items"
        :key="member.id"
        type="button"
        role="option"
        class="chat-mention-option"
        :class="{ 'is-active': i === picker.index }"
        :aria-selected="i === picker.index ? 'true' : 'false'"
        @pointerdown.prevent
        @mouseenter="picker.index = i"
        @click="pickMention(member)">
        @{{ member.name }}
      </button>
    </div>

    <div
      ref="editor"
      class="chat-composer"
      contenteditable="true"
      :data-placeholder="placeholder"
      @keydown="onKeyDown"
      @input="updatePicker"
      @blur="closePicker"
      @paste="onPaste"
      @click="onClick" />
  </div>
</template>

<script>
import { MAX_REFS_PER_MESSAGE } from './parseChatMessage';
import { navigateRef } from './refNavigation';
import {
  MENTION_KIND, linkMentions, matchMembers, mentionLabel,
} from './mentions';

// `@` opening a word, and what was typed of a name since (no spaces: a
// longer name is picked from the list, or typed in full and linked on
// send).
const MENTION_QUERY_RE = /(?:^|[^\p{L}\p{N}_@])@([^\s@[\]|]{0,24})$/u;

/**
 * Token-aware chat input. A contenteditable div that holds a mix of
 * text nodes and "chip" spans. Chips are atomic: contenteditable=false
 * so the caret cannot enter them and a single Backspace removes the
 * whole token.
 *
 * Insertion flow:
 *   1. Some other component emits `chat:insertRef` on $root with
 *      { kind, id, label }.
 *   2. This composer listens, appends a chip + trailing space, focuses
 *      itself, and parks the caret at the end so the next keystroke
 *      continues typing immediately.
 *
 * Submission flow:
 *   1. Enter (no shift) → serialize the editor by walking childNodes:
 *      - text nodes contribute their textContent
 *      - chip spans contribute `[[kind:id|label]]`
 *   2. Emit `submit` with the serialized string.
 *   3. Parent calls `clear()` on the public ref after a successful send.
 *
 * Mentions:
 *   Typing `@` opens a picker of faction members (arrows, Enter or Tab,
 *   or a click); the pick replaces what was typed with an `at` chip. A
 *   name typed out in full without the picker becomes the same token on
 *   submit (linkMentions).
 *
 * Paste is forced to plain text — pasting rich HTML into a
 * contenteditable would otherwise inject styled spans, images, etc.
 */
export default {
  name: 'chat-composer',
  props: {
    placeholder: { type: String, default: '' },
    // Who can be mentioned: [{ id, name }], the faction's other members.
    members: { type: Array, default: () => [] },
  },
  data() {
    return {
      // null, or { node, start, end, items, index }: the text node and
      // offsets of the `@query` being typed, and who it could mean.
      picker: null,
    };
  },
  mounted() {
    this.$root.$on('chat:insertRef', this.onInsertRef);
    // The Three.js map handles `pointerdown` with preventDefault, which
    // suppresses the corresponding `mousedown`. We listen to pointerdown
    // (capture phase) so canvas clicks still reach this handler and
    // blur the composer. We scope the "outside" check to .chat-container
    // so clicks inside chat-messages (to scroll) don't blur.
    document.addEventListener('pointerdown', this.onDocumentPointerDown, true);
  },
  beforeDestroy() {
    this.$root.$off('chat:insertRef', this.onInsertRef);
    document.removeEventListener('pointerdown', this.onDocumentPointerDown, true);
  },
  methods: {
    /** Public: parent calls this after a successful send. */
    clear() {
      const editor = this.$refs.editor;
      if (!editor) return;
      // Truly empty so the `:empty::before` placeholder shows. The
      // browser will inject its own bogus <br> on next focus; we strip
      // it in appendChip() before adding real content.
      editor.innerHTML = '';
      this.closePicker();
    },

    /** Public: focus the editor (used after insert). */
    focus() {
      const editor = this.$refs.editor;
      if (editor) editor.focus();
    },

    onDocumentPointerDown(e) {
      const editor = this.$refs.editor;
      if (!editor) return;
      // Walk up to find the .chat-container wrapper this composer lives
      // in. If the click is anywhere inside that container, leave focus
      // alone; otherwise blur so global hotkeys take over again.
      const container = this.$el && this.$el.closest && this.$el.closest('.chat-container');
      if (!container) return;
      if (container.contains(e.target)) return;
      if (document.activeElement === editor) editor.blur();
    },

    onClick(e) {
      // Delegated chip-click: if the click landed on (or inside) a
      // composer chip, navigate to the referenced entity. Otherwise
      // let the browser do its normal caret-positioning thing.
      const chip = e.target.closest && e.target.closest('.composer-chip');
      if (chip) {
        e.preventDefault();
        const { kind, id } = chip.dataset;
        navigateRef(this, kind, id);
        return;
      }

      // Caret-rescue: when the user clicks past the last chip (in the
      // empty trailing area of the editor), browsers sometimes fail to
      // place a caret anywhere — clicks just bounce off the chips with
      // no editable insertion point. After the browser's native click
      // handling runs, check whether a caret actually landed inside the
      // editor. If not, force it to the end so the user can keep typing.
      setTimeout(() => {
        const editor = this.$refs.editor;
        if (!editor) return;
        const sel = window.getSelection && window.getSelection();
        const anchor = sel && sel.anchorNode;
        if (!anchor || !editor.contains(anchor)) {
          this.moveCaretToEnd(editor);
          editor.focus();
        }
      }, 0);
    },

    onKeyDown(e) {
      // The mention picker takes the keys that choose from it.
      if (this.picker && this.picker.items.length > 0) {
        const { items, index } = this.picker;

        if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
          e.preventDefault();
          const step = e.key === 'ArrowDown' ? 1 : -1;
          this.picker.index = (index + step + items.length) % items.length;
          return;
        }
        if (e.key === 'Enter' || e.key === 'Tab') {
          e.preventDefault();
          this.pickMention(items[index]);
          return;
        }
        if (e.key === 'Escape') {
          e.preventDefault();
          e.stopPropagation();
          this.closePicker();
          return;
        }
      }

      // Enter submits; Shift+Enter intentionally does nothing yet
      // (chat is single-paragraph by convention — the server caps
      // at 1000 chars anyway).
      if (e.key === 'Enter') {
        e.preventDefault();
        this.submit();
      }
    },

    // After every edit: is the caret right behind an `@word`?
    updatePicker() {
      const editor = this.$refs.editor;
      const sel = window.getSelection && window.getSelection();

      if (!editor || !sel || !sel.isCollapsed || !sel.anchorNode
        || sel.anchorNode.nodeType !== Node.TEXT_NODE || !editor.contains(sel.anchorNode)) {
        this.closePicker();
        return;
      }

      const node = sel.anchorNode;
      const end = sel.anchorOffset;
      const match = MENTION_QUERY_RE.exec(node.textContent.slice(0, end));

      if (!match) {
        this.closePicker();
        return;
      }

      const query = match[1];
      this.picker = {
        node,
        start: end - query.length - 1,
        end,
        items: matchMembers(query, this.members),
        index: 0,
      };
    },

    closePicker() {
      this.picker = null;
    },

    // Replace the `@query` being typed with the member's chip.
    pickMention(member) {
      const editor = this.$refs.editor;
      const picker = this.picker;
      this.closePicker();
      if (!editor || !picker || !editor.contains(picker.node)) return;

      if (editor.querySelectorAll('.composer-chip').length >= MAX_REFS_PER_MESSAGE) {
        this.$toastError(this.$t('in_game_chat.too_many_refs', { max: MAX_REFS_PER_MESSAGE }));
        return;
      }

      const range = document.createRange();
      range.setStart(picker.node, picker.start);
      range.setEnd(picker.node, Math.min(picker.end, picker.node.textContent.length));
      range.deleteContents();

      // The space first, then the chip in front of it. A no-break space:
      // the editor drops a plain one sitting at the end of the line as
      // soon as the next word is typed (serialize sends it as a space).
      const space = document.createTextNode(' ');
      range.insertNode(space);
      range.insertNode(this.buildChip(MENTION_KIND, String(member.id), mentionLabel(member.name)));
      this.ensureTrailingBr(editor);

      const caret = document.createRange();
      caret.setStart(space, 1);
      caret.collapse(true);
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(caret);
      editor.focus();
    },

    onPaste(e) {
      // Strip formatting / nested elements — we only want plain text.
      e.preventDefault();
      const text = (e.clipboardData || window.clipboardData).getData('text/plain');
      if (text) {
        // execCommand is deprecated but is the only cross-browser way
        // to insert at the current selection inside contenteditable
        // without writing a full Range-based insert routine.
        document.execCommand('insertText', false, text);
      }
    },

    onInsertRef(payload) {
      const editor = this.$refs.editor;
      if (!editor) return;

      const chipCount = editor.querySelectorAll('.composer-chip').length;
      if (chipCount >= MAX_REFS_PER_MESSAGE) {
        const msg = this.$t
          ? this.$t('in_game_chat.too_many_refs', { max: MAX_REFS_PER_MESSAGE })
          : `You can include at most ${MAX_REFS_PER_MESSAGE} links per message.`;
        if (this.$toastError) this.$toastError(msg);
        return;
      }

      const { kind, id, label } = payload;
      // A label rides inside the `[[kind:id|label]]` token: keep the
      // token's own delimiters out of it.
      const safeLabel = label ? String(label).replace(/[[\]|]/g, ' ').trim() : null;
      this.appendChip(editor, kind, String(id), safeLabel || null);
      this.moveCaretToEnd(editor);
      editor.focus();
    },

    appendChip(editor, kind, id, label) {
      // Chrome/Safari inject a "bogus" <br> into contenteditable divs
      // when they're empty/focused. If we leave it in, our first chip
      // lands AFTER the <br> and visually appears on the second line.
      // Strip any leading <br>s before adding real content.
      this.stripLeadingBr(editor);

      const chip = this.buildChip(kind, id, label);

      // Detach any pre-existing trailing <br> so we can re-add it after
      // the new chip + trailing space.
      this.stripTrailingBr(editor);

      // Prepend a separator if the user is typing right up against the
      // chip ("helloCHIP" reads worse than "hello CHIP"). The trailing
      // space added below handles the next-character case symmetrically.
      if (this.needsLeadingSpace(editor)) {
        editor.appendChild(document.createTextNode(' '));
      }

      editor.appendChild(chip);
      // Trailing space lets the user immediately keep typing without
      // having to nudge past the chip themselves.
      editor.appendChild(document.createTextNode(' '));

      // Critical: an explicit trailing <br> is the canonical fix for
      // "the caret refuses to land past the last node in a
      // contenteditable." Browsers respect a final <br> as a real
      // landing pad. The serializer treats <br> as whitespace and
      // strips trailing whitespace via .trim() so it never leaks into
      // the sent message.
      this.ensureTrailingBr(editor);
    },

    buildChip(kind, id, label) {
      const chip = document.createElement('span');
      chip.className = `composer-chip composer-chip-${kind}`;
      chip.setAttribute('contenteditable', 'false');
      chip.dataset.kind = kind;
      chip.dataset.id = id;
      if (label != null) chip.dataset.label = label;

      const icon = document.createElement('span');
      icon.className = 'chat-ref-icon';
      icon.textContent = this.iconForKind(kind);

      const labelSpan = document.createElement('span');
      labelSpan.className = 'chat-ref-label';
      labelSpan.textContent = label || `${kind}:${id}`;

      chip.appendChild(icon);
      chip.appendChild(labelSpan);

      return chip;
    },

    stripLeadingBr(editor) {
      while (editor.firstChild && editor.firstChild.nodeName === 'BR') {
        editor.removeChild(editor.firstChild);
      }
    },

    stripTrailingBr(editor) {
      while (editor.lastChild && editor.lastChild.nodeName === 'BR') {
        editor.removeChild(editor.lastChild);
      }
    },

    ensureTrailingBr(editor) {
      if (!editor.lastChild || editor.lastChild.nodeName !== 'BR') {
        editor.appendChild(document.createElement('br'));
      }
    },

    needsLeadingSpace(editor) {
      if (editor.childNodes.length === 0) return false;
      const last = editor.childNodes[editor.childNodes.length - 1];
      if (last.nodeType === Node.TEXT_NODE) {
        // Empty/whitespace-only text node = no extra space needed.
        return last.textContent.length > 0 && !/\s$/.test(last.textContent);
      }
      if (last.nodeType === Node.ELEMENT_NODE && last.tagName === 'BR') {
        // Stripped above before this check is called, but defensive.
        return false;
      }
      // Last node is something else (another chip, etc.) — separate it.
      return true;
    },

    iconForKind(kind) {
      // Kept in sync with the icons in refs/ChatRef*.vue tooltips. We
      // duplicate rather than import a shared map so the composer can
      // render chips for kinds whose ref component hasn't shipped yet.
      switch (kind) {
        case 'sys': return '◈';
        case 'spot': return '◉';
        case 'at': return '@';
        default: return '?';
      }
    },

    moveCaretToEnd(editor) {
      const range = document.createRange();
      const last = editor.lastChild;
      if (last && last.nodeName === 'BR') {
        // Park BEFORE the trailing <br>. Setting the caret after a
        // trailing <br> sometimes puts it in a "ghost" position where
        // typed characters don't appear; before-the-br is the safe
        // landing zone.
        range.setStartBefore(last);
        range.setEndBefore(last);
      } else {
        range.selectNodeContents(editor);
        range.collapse(false);
      }
      const sel = window.getSelection();
      if (sel) {
        sel.removeAllRanges();
        sel.addRange(range);
      }
    },

    submit() {
      const editor = this.$refs.editor;
      if (!editor) return;
      const text = this.serialize(editor).trim();
      if (text.length === 0) return;
      this.$emit('submit', text);
    },

    serialize(editor) {
      let out = '';
      editor.childNodes.forEach((node) => {
        if (node.nodeType === Node.TEXT_NODE) {
          // A contenteditable keeps a space next to a chip, or at the end
          // of a line, as a no-break space: on the wire it is a space.
          // Then, a member's name typed out after `@` is a mention too.
          out += linkMentions(node.textContent.replace(/ /g, ' '), this.members);
        } else if (node.nodeType === Node.ELEMENT_NODE) {
          if (node.classList && node.classList.contains('composer-chip')) {
            const { kind, id, label } = node.dataset;
            out += label
              ? `[[${kind}:${id}|${label}]]`
              : `[[${kind}:${id}]]`;
          } else if (node.tagName === 'BR') {
            // Contenteditable inserts <br> on some browsers — treat as
            // whitespace so we don't lose word separation.
            out += ' ';
          } else {
            out += node.textContent;
          }
        }
      });
      return out;
    },
  },
};
</script>
