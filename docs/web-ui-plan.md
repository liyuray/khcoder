# Plan: a web front end for KH Coder

Companion to [`gui-inventory.md`](gui-inventory.md), which enumerates what the
current Perl/Tk interface actually contains. This document says what to build
instead, in what order, and what is already done.

The Tk interface stays. The web front end is an additional entry point onto the
same engine and the same SQLite projects, so the two can be compared screen by
screen while coverage grows.

## What is already proven

Not a proposal — this part is built and tested.

**The engine runs without a GUI.** `kh_lib/kh_headless.pm` supplies the three
packages the analysis modules call at runtime — `gui_errormsg`, `gui_window`,
`gui_wait` — so Perl/Tk is never loaded. The surface is small because the
engine was already almost free of the GUI:

| Call | Sites |
|---|--:|
| `gui_errormsg->open` | 245 |
| `gui_window->gui_jchar` | 19 |
| `gui_window->gui_bmp` | 4 |
| `gui_window->kchar_patchim` | 3 |
| `gui_window->gui_jg` | 1 |

The engine modules never `use gui_window` or `use Tk`; they call these
packages at runtime and rely on the application having loaded them. That is
what makes the shim possible.

`kh_sysconfig.pm:989` already defines a **`web_if`** flag. It is honoured in
`kh_r_plot.pm` and in `gui_window/r_plot/*`, where it skips the interactive
canvas work — reading plot coordinates for click-to-zoom — while leaving the
plot generation itself alone. `my_threads::single` also checks it. A headless
mode was anticipated by the original author.

**`khc.pl` drives the engine from the command line.** Every command takes
`--json`. This is the operation set a web API would expose, and building it
first meant the API shape was settled against a working engine rather than
guessed at:

    khc.pl projects
    khc.pl new    --target FILE [--column N] [--name TEXT]
    khc.pl prep   --project NAME
    khc.pl stats  --project NAME
    khc.pl words  --project NAME [--limit N] [--query TEXT] [--mode p|c|k|z]
    khc.pl conc   --project NAME --query WORD [--length N]
    khc.pl doc    --project NAME --id N
    khc.pl sql    --project NAME "SELECT ..."

**`t/cli.t` covers it.** 21 tests, pinning the figures the Tk build produces
for the kokoro tutorial (5,064 sentences, 1,215 paragraphs, 5,451 words in use,
する×1710, 先生×595), plus the SQL-dialect regressions from the SQLite port.
The suite builds its own fixture project from `tutorial_jp/kokoro.xls`, so it
exercises project creation and pre-processing end to end.

Run it with:

    cd /khcoder/src && perl t/cli.t

## What the CLI covers now

`khc.pl` reaches 22 of the 44 menu-reachable targets. Beyond the project and
text commands it has `vars`, `assoc`, `cod-freq`, `cod-jaccard`,
`cod-crosstab`, `export`, `check`, `archive`, `restore`, and `plot` with nine
kinds: `cls`, `mds`, `corresp`, `network`, `som`, `cod-cls`, `cod-mds`,
`cod-corresp`, `cod-netg`.

### Two parameters that look like hangs

Both were mine, not the engine's, and both are worth knowing because the
failure mode is a process that appears to hang for over an hour:

- **`som`'s `n_nodes` is the side of a square grid**, so the map has `n_nodes²`
  cells (`plotR/som.pm:217`). The GUI defaults to 20 — 400 cells — under the
  label 「1辺のノード数」, *nodes per side* (`gui_widget/r_som.pm:12`). Passing
  100 asks for 10,000 cells.
- **The network plot's nodes are the matrix rows.** `cod_netg.pm:602` puts the
  codes in rows before plotting; leaving the documents there asks for a graph
  over all 5,064 of them.

Neither is an infinite loop. `Statistics::R::Bridge::pipe::send` bounds its
wait at `$xx > 10000` half-second ticks (`pipe.pm:197`), about 83 minutes, and
the output check at 20 seconds (`pipe.pm:232`); both then give up with
"Could not send the command to R!". A front end should impose its own timeout
rather than inherit that one.

### Plots cannot run concurrently on one project

`kh_r_plot` names its working files by project inside `config/R-bridge/`, so
two plot commands against the same project collide and both stall until one is
killed. This is the concrete form of the package-global state noted under
Risks: an HTTP layer must serialise plot requests per project. It also means a
test suite has to run them one at a time.

## What the CLI exposed

Three things worth knowing before designing the API, all found by building it:

- **Arguments must be decoded.** A Japanese query passed as bytes silently
  matches nothing — no error, just an empty result. Any HTTP layer has the same
  obligation for query parameters and JSON bodies.
- **`mysql_words::search` needs a match mode.** `conv_query` only quotes the
  query when the mode is one of `p`/`c`/`k`/`z`; anything else yields an
  unquoted token that SQLite reads as a column name.
- **Concordance results come from `_format($start)`**, a page at a time, not
  from a field on the returned object. Paging is already the engine's model,
  which suits an HTTP API well.

## Architecture

    browser  ──HTTP/JSON──►  khcd.pl  ──►  kh_headless  ──►  engine  ──►  SQLite
                             (HTTP::Server::Simple, one process per project)

- **Reuse the command layer.** `khc.pl`'s command table is the API. The server
  should call the same subs rather than re-implementing them; move them into
  `kh_lib/kh_api.pm` and have both front ends dispatch into it.
- **One engine process, not one per request.** Opening a project costs a
  `kh_project->open` and the config load. Keep the process warm and serialise
  requests per project; SQLite in WAL mode already handles concurrent readers.
- **Long operations need a job.** Pre-processing the kokoro data takes tens of
  seconds and streams progress to stdout. `prep` should return a job id and a
  poll endpoint rather than holding a request open.
- **Serve plots as files.** The R bridge writes an image and the engine hands
  back a path; the browser fetches it. `web_if` already skips the interactive
  coordinate reading, so this path is close to working today.
- **No new runtime dependency if possible.** `libhttp-server-simple-perl` is a
  Debian package; the JSON writer in `khc.pl` is 15 lines and already avoids a
  JSON module.

## Phasing

Sizes come from `gui-inventory.md`. "Screens" counts windows reachable from a
menu; the 31 dialogs are folded into their parents.

| Phase | Covers | Notes |
|---|---|---|
| **0 — done** | headless shim, CLI, tests | `kh_headless.pm`, `khc.pl`, `t/cli.t` |
| **1** | project list / open / create, pre-processing, main-window stats | The whole Project menu plus Pre-Processing. Already reachable from the CLI; this is the HTTP wrapper and a first page. |
| **2** | Frequency List, KWIC Concordance, Search Documents, Document view | The four highest-traffic screens, and all four are plain tables — no R, no plotting. `word_search` 996 LOC, `word_conc` 898, `doc_search` 751. |
| **3** | Word Association, Coding frequency and crosstab, Variables & Headings | Still tabular, but they pull in `kh_cod` and `mysql_outvar` and need a coding-rule editor. |
| **4** | The 16 plot windows — correspondence analysis, MDS, cluster, co-occurrence network, SOM, topic models | The bulk of the remaining work: `word_corresp` 1,983 LOC, `doc_cls` 1,293, `word_mds` 1,189, `cod_corresp` 1,183. Each is a large option panel over a comparatively small R call. Deliver the plot first, the option panel incrementally. |
| **5** | Export (Excel/CSV/SPSS), project import/export, settings, SQL console | Mostly file production, which a browser handles as a download. |

Phases 1–2 give something genuinely usable. Phase 4 is where the remaining
effort concentrates and is worth reassessing once 1–3 are in hand.

## Risks

- **The option panels are the work, not the analysis.** `word_corresp` is
  1,983 lines, of which the R call is a small part; the rest is the option UI
  and result handling. Porting these one control at a time is what makes
  phase 4 long.
- **Plot interactivity.** The Tk build lets you click a plot to zoom, driven by
  the coordinate files that `web_if` currently skips. Matching that in a browser
  means either shipping those coordinates as an overlay or accepting a static
  image at first.
- **Coding rules** are a small language read from a file. The web UI needs an
  editor and a validator for it; `kh_cod` already parses it.
- **Concurrency.** The engine keeps state in package globals (`mysql_conc`
  caches the last query, `$::project_obj` is global). One project per process,
  serialised, avoids this. Do not make requests concurrent within a project
  without auditing that state first.
- **Long text in the browser.** `doc_search` can return thousands of documents;
  the engine already pages, and the API should not undo that.
- **`web_if` does more than skip the canvas.** In `plotR::network` and
  `plotR::som` the branch that builds the plots at all is guarded by
  `web_if == 0`, so the flag has to be turned *off* while a plot runs even
  though no window is created. Worth checking before relying on it elsewhere.
- **The data check silently drops characters** that EUC-JP cannot represent,
  per the author's own notes. That is data loss, and a web front end that
  accepts arbitrary uploads should warn about it or avoid the auto-fix path.

## Not in scope

The Tk interface is not being removed. Anything that only makes sense with a
local desktop — the file-picker dialogs, the font chooser, the R plot canvas —
has a browser equivalent that is different by nature rather than a port.
