/**
 * CHEWY PATCH (scout panel layout): drag one `/scout` board onto another.
 *
 * The server owns the order — it renders `style="order:N"` on every
 * panel and this hook never moves a node. LiveView re-sorts a
 * container's children to match the server's markup on the next patch,
 * and these pages tick every 30s, so a client-side move would snap back
 * within half a minute of being made.
 *
 * `draggable` is armed on mousedown over the `⠿` handle and disarmed on
 * dragend, rather than set on the section: a permanently draggable
 * section makes every table cell in it unselectable, and the boards are
 * read by copying ids out of them.
 */

type DropPosition = 'before' | 'after';

const EDGE_TOP = 'inset 0 2px 0 0 var(--p, #38bdf8)';
const EDGE_BOTTOM = 'inset 0 -2px 0 0 var(--p, #38bdf8)';

const panels = (el: HTMLElement): HTMLElement[] =>
  Array.from(el.querySelectorAll<HTMLElement>(':scope > [data-panel-key]'));

const clearEdge = (panel: HTMLElement) => {
  panel.style.boxShadow = '';
};

const ScoutPanelStack = {
  mounted() {
    this.bind();
  },

  updated() {
    this.bind();
  },

  bind() {
    panels(this.el).forEach((panel: HTMLElement & { _scoutDrag?: boolean }) => {
      // Panels are keyed by DOM id, so LiveView reuses the element and
      // its listeners across patches. Binding twice would push the drop
      // event twice and undo the move.
      if (panel._scoutDrag) return;
      panel._scoutDrag = true;

      const handle = panel.querySelector<HTMLElement>('[data-drag-handle]');
      if (!handle) return;

      handle.addEventListener('mousedown', () => {
        panel.draggable = true;
      });

      panel.addEventListener('dragstart', (event: DragEvent) => {
        const key = panel.dataset.panelKey;
        if (!key) return;
        event.dataTransfer?.setData('text/plain', key);
        if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move';
        panel.style.opacity = '0.5';
      });

      panel.addEventListener('dragend', () => {
        panel.draggable = false;
        panel.style.opacity = '';
        panels(this.el).forEach(clearEdge);
      });

      panel.addEventListener('dragover', (event: DragEvent) => {
        event.preventDefault();
        if (event.dataTransfer) event.dataTransfer.dropEffect = 'move';
        const rect = panel.getBoundingClientRect();
        const top = event.clientY < rect.top + rect.height / 2;
        panel.style.boxShadow = top ? EDGE_TOP : EDGE_BOTTOM;
      });

      panel.addEventListener('dragleave', () => clearEdge(panel));

      panel.addEventListener('drop', (event: DragEvent) => {
        event.preventDefault();
        clearEdge(panel);

        const key = event.dataTransfer?.getData('text/plain');
        const target = panel.dataset.panelKey;
        if (!key || !target || key === target) return;

        const rect = panel.getBoundingClientRect();
        const position: DropPosition =
          event.clientY < rect.top + rect.height / 2 ? 'before' : 'after';

        this.pushEvent('layout_drop', { key, target, position });
      });
    });
  },
};

export default ScoutPanelStack;
