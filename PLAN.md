# Plan: mark files as reviewed

## Goal

Add a checklist state to `review.nvim` so a reviewer can mark the file currently
shown by CodeDiff as reviewed, see that state in the CodeDiff explorer, and
resume the checklist after restarting Neovim.

This state is local review metadata. It must not stage files, modify the working
tree, or attempt to synchronize GitHub's "Viewed" state.

## Intended behavior

- A configurable key toggles the current file between reviewed and unreviewed.
  Use `r` in readonly mode and `<localleader>cr` in edit mode by default.
- Add explicit `:Review check` and `:Review uncheck` commands as idempotent
  alternatives to the toggle key.
- A reviewed file has a check mark in the CodeDiff explorer. Preserve the
  existing filename, status, statistics, selection highlight, and any custom
  file formatter.
- Treat the same path in the staged and unstaged groups as two review entries;
  checking one must not check the other.
- Persist reviewed state with the existing per-repository review data. `C` /
  `:Review export` leaves it intact, while `q` / `:Review close` and
  `:Review clear` archive and clear it together with comments.
- A mark applies to the exact old/new contents that the reviewer saw. If either
  side changes, automatically make the file unreviewed the next time CodeDiff
  refreshes or selects it. This prevents a live coding agent from silently
  changing an already-reviewed file.
- Checking a file does not automatically move to the next file, hide it, or
  affect comment export. Those can be separate follow-up features.

## State model and migration

1. Evolve the persisted JSON from the current raw `file -> comments` map into a
   versioned envelope:

   ```json
   {
     "version": 2,
     "comments": {},
     "reviewed_files": {
       "unstaged\u0000lua/review/init.lua": {
         "file": "lua/review/init.lua",
         "group": "unstaged",
         "original_hash": "...",
         "modified_hash": "...",
         "reviewed_at": 0
       }
     }
   }
   ```

2. Make `storage.load()` normalize both formats. Existing files without a
   `version` field are version 1 and become `{ comments = old_data,
   reviewed_files = {} }` in memory. Write only version 2 after the next
   mutation.
3. Extend `store.lua` without changing its existing comment API. Add reviewed
   state plus pure methods to mark, unmark, query, list, and count entries.
   `reset()`, `archive_and_clear()`, and `clear()` must reset comments and
   reviewed files atomically.
4. Key records by normalized repository-relative path and CodeDiff group. The
   group distinction is required because CodeDiff can display one path under
   both `Changes` and `Staged Changes`.
5. Fingerprint both diff buffers with `vim.fn.sha256()` over their complete
   contents. Hash both sides so changing the base revision also invalidates the
   mark. Define one canonical encoding that distinguishes an empty buffer from
   a missing side, and cover added/deleted files in tests.

## Review controller

Create `lua/review/reviewed.lua` to keep checklist behavior out of the
comment-oriented modules.

It should:

- Resolve the active entry from the current CodeDiff explorer selection,
  including `path`, `old_path`, and `group`; fall back to the modified path and
  then the original path for added, deleted, and renamed files.
- Read the corresponding CodeDiff buffers only after the selection has
  finished loading, then build the old/new fingerprint.
- Implement `check_current()`, `uncheck_current()`, and `toggle_current()`.
  Outside an active Review/CodeDiff explorer session, notify the user and leave
  storage untouched.
- Validate the selected entry on `CodeDiffOpen` and `CodeDiffFileSelect`. If its
  stored fingerprint no longer matches, remove the stale mark and redraw the
  explorer.
- Expose a small predicate used by explorer rendering, such as
  `is_reviewed(path, group)`.
- Redraw with the explorer's public tree render operation after a state change;
  do not trigger a Git refresh or move focus.

The async callbacks need to capture the tabpage and selected path/group, then
re-check both before mutating state. This avoids applying a delayed fingerprint
to a file selected afterward.

## CodeDiff explorer integration

Use CodeDiff's documented `explorer.formatters.file` extension point; no change
to `codediff.nvim` should be necessary.

1. Install an idempotent formatter decorator after CodeDiff has been set up.
2. Delegate to the user's configured file formatter, or CodeDiff's exported
   default formatter when none is configured.
3. Deep-copy the returned layout before adding the reviewed indicator so a
   formatter that reuses tables is not mutated.
4. Add the indicator as its own fixed right-side region before the existing Git
   status. Show it only when the active review store contains the matching
   normalized `path + group` entry.
5. Add configurable presentation under a `reviewed` config section, initially
   `icon = "✓"` and `hl = "ReviewReviewed"`, and define the default highlight
   in `highlights.lua`.
6. Keep the decorator inactive when no `review.nvim` CodeDiff session is open,
   so ordinary CodeDiff sessions retain their normal appearance.
7. Add a health check for the formatter API relied upon by the integration.

If the current CodeDiff formatter contract cannot safely be decorated, stop
and add a small public decoration hook upstream rather than depending on node
internals such as `node._line`.

## Commands, API, and keymaps

- Add `check` and `uncheck` entries to `plugin/review.lua`, command completion,
  and help text.
- Export `check_current()`, `uncheck_current()`, and
  `toggle_current_reviewed()` from `lua/review/init.lua`.
- Add `toggle_file_reviewed` and `readonly_toggle_file_reviewed` to
  `ReviewKeymaps`, their defaults, buffer-local mappings, and the Review help
  popup.
- Keep mappings on the two diff buffers, consistent with the existing comment
  actions. Do not take over keys in the explorer buffer.
- After marking, notify with the normalized path and progress, for example
  `Reviewed api.lua (2/5)`. Count unique visible explorer entries, not files
  that are no longer part of the current diff.

## Lifecycle details

- Load checklist state alongside comments before opening CodeDiff.
- On `CodeDiffFileSelect`, validate only after CodeDiff has installed the new
  buffers; retain the current deferred setup pattern.
- On repeated `CodeDiffOpen` events (layout changes and live refreshes), avoid
  reinstalling the formatter wrapper or duplicating keymaps.
- When files disappear from a live diff, leave their records persisted until
  close/clear but exclude them from progress. This lets a temporarily
  disappearing file recover its mark if the exact comparison returns.
- Closing without a successful export currently does not clear comments. Keep
  checklist clearing aligned with whatever final close semantics the comment
  store uses, rather than introducing a second policy.

## Tests

### Unit tests

- `tests/test_storage.lua`: version 1 migration, version 2 round-trip, malformed
  reviewed entries, and archive contents.
- `tests/test_store.lua`: mark/unmark/idempotency, staged-vs-unstaged identity,
  counts, fingerprint mismatch, and reset/archive behavior.
- Add `tests/test_reviewed.lua`: active-target resolution, path normalization,
  fingerprints for normal/added/deleted buffers, stale async callback guards,
  and no-session behavior.
- Add formatter tests proving that the indicator appears only for reviewed
  entries and that custom layouts are delegated to without mutation.
- Extend `tests/test_help.lua` and config tests for enabled, customized, and
  disabled mappings.
- Extend health tests for the CodeDiff formatter dependency.

### End-to-end tests

- Open a two-file review, mark the first file, and assert its explorer row gets
  a check while the second does not.
- Navigate away and back and verify the mark remains; toggle it off and verify
  the explorer redraws without moving focus.
- Verify staged and unstaged entries for the same path are independent.
- Reopen Neovim without closing the review data and verify persistence.
- Change an already-reviewed file, let CodeDiff refresh, select it, and verify
  the mark is invalidated.
- Verify `C` retains checklist state and `q` / `:Review clear` archives and
  clears it.
- Add or update deterministic screenshots for the explorer indicator and help
  popup.

## Documentation and verification

- Update `README.md` workflow, keymap/config tables, command list, persistence
  description, and explicitly state that reviewed state is local and not GitHub
  synchronization.
- Update `doc/review.txt`, regenerate `doc/tags`, and mention that content
  changes invalidate reviewed marks.
- Run `make test`, `make test-e2e`, and `make test-all` from `review.nvim`.
- Manually smoke-test working-tree, staged, commit-range, branch, added,
  deleted, and renamed-file reviews with the explorer in both list and tree
  modes.

## Completion criteria

- A reviewer can mark and unmark the selected file without changing Git state.
- The reviewed indicator survives navigation and Neovim restart.
- A changed diff cannot remain marked reviewed after it is selected/refreshed.
- Staged and unstaged instances of the same path remain independent.
- Existing comment files migrate without data loss, and close/clear archives
  both comments and checklist state.
- Custom CodeDiff file formatters continue to work.
- Unit and end-to-end suites pass with no changes required in `codediff.nvim`.
