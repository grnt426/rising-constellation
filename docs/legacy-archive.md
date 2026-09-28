# Legacy match archive

Players browse finished official Legacy matches at **Play → Legacy → View
archive** (`/portal/play/slow/archive`). Each match page has tabs with
charts built from data frozen at import time.

## Data flow

```
nightly S3 tarballs ─┐                         ┌─ archive_matches      (one per match: result, map, totals)
end-game snapshots  ─┼─ RC.Archive.Importer ───┼─ archive_faction_days (faction × day metrics, jsonb)
player_events       ─┤   (SnapshotStats +      ├─ archive_players      (final stats + score series)
player_stats        ─┘    EventStats)          └─ archive_unlocks      (patent / lex pick counts)
```

- **Snapshots** (`RC.Archive.SnapshotStats`): one sample per match day, the
  latest snapshot at or before the victory. They provide income (gross, net and
  by source), systems and dominions, victory tracks, per-system averages,
  malware, fleets, agents, lex slots, unlocks, and the ownership map. The
  nightly tarballs are **deleted from S3 after 30 days**. Import a match within
  that window, or its snapshot series will have gaps.
- **Events** (`RC.Archive.EventStats`): these come from permanent DB rows and
  are cut at the victory timestamp.
  - `player_events` box rows give bombards, pillages, captures, spy and
    Siderian operations, and battles.
  - `player_stats` gives score, net income and systems for every day.
- Metric keys are documented in both modules' moduledocs. New metrics only need
  code changes and a re-import, never a migration.

## Running an import

On the prod host, as `rc`:

```
deploy/bin/rc-archive-import <instance_id>             # keeps current published flag (new = hidden)
deploy/bin/rc-archive-import <instance_id> --publish
```

The script streams the relevant tarballs, keeps only that instance's
snapshots, adds any on-disk end-of-game snapshots
(`/var/lib/rc-snapshots`, `/home/rc/archive-keep/<iid>/`), and runs
`RC.Release.import_archive/3` in a separate `rc eval` VM. Re-running
replaces the archive of that instance.

New imports are **unpublished**. Admins see them marked "Draft" and can
publish from the match page, or with:

```
bin/rc eval 'RC.Release.publish_archive(121)'
```

Locally: put snapshot files under `tmp/snapshots/<iid>/` and run
`mix legacy_archive.import <iid> tmp/snapshots/<iid> [--publish]`.

## Spreadsheet export

The match page has an **Export to Excel** button that calls
`GET /api/archive/matches/:id/export`, which returns an `.xlsx` workbook
(`RC.Archive.Export`, built by the dependency-free `RC.Archive.Xlsx`
writer). It contains these sheets: About (facts, units, caveats), Factions,
Faction days (one column per metric), Players, Player score by day,
Unlocks, Sectors, and Systems (ownership per snapshot day plus activity
counts).

Players are limited to **1 export per minute and 10 per rolling hour per
account**. `RC.Archive.ExportLimiter` enforces this with a sliding log
rather than Hammer's fixed windows, so the limit can't double up across a
window boundary. A request over the limit gets a 429 with `retry-after`.
Unknown or unpublished matches 404 before the limiter runs, and admins are
exempt. The limiter state is per node and resets on restart.

## Gotchas

- **Keep the victory-time snapshot.** Autosaves keep running through the
  post-victory grace period, and only the newest 10 stay on disk. The
  snapshot closest to the victory is therefore pruned within about 2.5h. Copy
  it to `/home/rc/archive-keep/<iid>/` right after the match ends. If it is
  gone, the importer uses the earliest post-victory snapshot and the page shows
  a notice.
- Box events can be deleted by players (`delete_read`). In practice the
  attacker-side counts matched the `*_started` rows almost exactly on i121.
- Income metrics are stored per ut. The UI multiplies by
  `summary.ut_per_hour` (20 at slow speed).
