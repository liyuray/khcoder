# KH Coder GUI inventory

Generated from the source by `docs/inventory.py`: the menu tree comes from
`kh_lib/gui_window/main/menu.pm`, the labels from `config/msg.en`, and the
engine columns from what each window actually calls. Regenerate after any UI
change rather than editing this file by hand.

## Scale

| | |
|---|---|
| Windows in `gui_window/` (top level) | 68 |
| Modules under `gui_window/` including sub-packages | 150 |
| Lines of window code | 32,015 |
| Reachable from a menu entry | 37 |
| Dialogs / sub-windows opened from another window | 31 |
| Windows that render an R plot | 16 |

## Menu tree

`mc_*` targets are methods on the main menu rather than separate windows.

| Menu path | Opens |
|---|---|
| Project |  |
| Project > New | `project_new` |
| Project > Open | `project_open` |
| Project > Close | `mc_close_project` |
| Project > Export |  |
| Project > Export > Word Frequency List (for Excel) | `word_list` |
| Project > Export > Document-Word Matrix |  |
| Project > Export > Document-Code Matrix |  |
| Project > Export > Word-Context Matrix |  |
| Project > Export > Extract Partial Text | `txt_pickup` |
| Project > Export > Texts in Arbitrary Units | `txt_html2csv` |
| Project > Export > For KH Coder (*.khc) | `mc_export_project` |
| Project > Import |  |
| Project > Import > Multiple texts in a folder | `import_folder` |
| Project > Import > KH Coder (*.khc) | `mc_import_project` |
| Project > Settings | `sysconfig` |
| Project > Exit |  |
| PRe-Processing |  |
| PRe-Processing > plugin_raw_data_editor2 |  |
| PRe-Processing > Check the Target Text | `mc_datacheck` |
| PRe-Processing > Run Pre-Processing | `mc_morpho_dialog` |
| PRe-Processing > Select Words to Analyze | `dictionary` |
| PRe-Processing > Word Clusters |  |
| PRe-Processing > Word Clusters > use TermExtract | `use_te` |
| PRe-Processing > Word Clusters > Noun Phrases | `mc_noun_phrases` |
| PRe-Processing > Word Clusters > use ChaSen | `mc_hukugo` |
| PRe-Processing > plugin_synonym2 |  |
| PRe-Processing > Check the Result of Word Extraction | `morpho_check` |
| Tools |  |
| Tools > Words |  |
| Tools > Words > Frequency List | `word_search` |
| Tools > Words > Descriptive Stats |  |
| Tools > Words > Descriptive Stats > Term Frequency Distribution | `word_freq` |
| Tools > Words > Descriptive Stats > Document Frequency Distribution | `word_df_freq` |
| Tools > Words > Descriptive Stats > TF-DF Plot | `word_tf_df` |
| Tools > Words > KWIC Concordance | `word_conc` |
| Tools > Words > Word Association | `word_ass` |
| Tools > Words > Correspondence Analysis | `word_corresp` |
| Tools > Words > Multi-Dimensional Scaling | `word_mds` |
| Tools > Words > Hierarchical Cluster Analysis | `word_cls` |
| Tools > Words > Co-Occurrence Network | `word_netgraph` |
| Tools > Words > Self-Organizing Map | `word_som` |
| Tools > Documents |  |
| Tools > Documents > Search Documents | `doc_search` |
| Tools > Documents > Cluster Analysis | `doc_cls` |
| Tools > Documents > Topic Models |  |
| Tools > Documents > Topic Models > Find Optimal N of Topics | `topic_perplexity` |
| Tools > Documents > Topic Models > Fit a Topic Model | `topic_fitting` |
| Tools > Documents > Naive Bayes Classifier |  |
| Tools > Coding |  |
| Tools > Coding > Frequency | `cod_count` |
| Tools > Coding > Crosstab | `cod_outtab` |
| Tools > Coding > Similarity Matrix | `cod_jaccard` |
| Tools > Coding > Correspondence Analysis | `cod_corresp` |
| Tools > Coding > Multi-Dimensional Scaling | `cod_mds` |
| Tools > Coding > Hierarchical Cluster Analysis | `cod_cls` |
| Tools > Coding > Co-Occurrence Network | `cod_netg` |
| Tools > Coding > Self-Organizing Map | `cod_som` |
| Tools > Variables & Headings | `outvar_list` |
| Tools > Export |  |
| Tools > Export > Word Frequency List (for Excel) | `word_list` |
| Tools > Export > Document-Word Matrix |  |
| Tools > Export > Document-Code Matrix |  |
| Tools > Export > Word-Context Matrix |  |
| Tools > Export > Extract Partial Text | `txt_pickup` |
| Tools > Export > Texts in Arbitrary Units | `txt_html2csv` |
| Tools > Export > For KH Coder (*.khc) | `mc_export_project` |
| Tools > Plugin |  |
| Tools > Execute SQL Statements | `sql_select` |
| Help |  |
| Help > book2 |  |
| Help > book1 |  |
| Help > Manual (PDF) |  |
| Help > Manual (PDF) |  |
| Help > Latest Info (Web) |  |
| Help > Show suggest window | `suggest` |
| Help > About | `about` |

## Windows, and the engine behind each

`SQL` counts `mysql_exec->do/select` call sites in that window. A window with
a high count carries analysis logic that a web port has to preserve, not just
re-skin.

| Window | LOC | SQL | Plot | Export | Engine modules | Reached from |
|---|--:|--:|:-:|:-:|---|---|
| `word_corresp` | 1983 | 6 | yes |  | `kh_r_plot`, `mysql_crossout`, `mysql_outvar` | Tools > Words > Correspondence Analysis |
| `doc_cls` | 1293 | 0 | yes |  | `kh_r_plot`, `mysql_crossout`, `mysql_outvar` | Tools > Documents > Cluster Analysis |
| `word_mds` | 1189 | 1 | yes |  | `kh_r_plot`, `mysql_crossout` | Tools > Words > Multi-Dimensional Scaling |
| `cod_corresp` | 1183 | 5 | yes |  | `kh_cod`, `kh_r_plot`, `mysql_getheader`, `mysql_outvar` | Tools > Coding > Correspondence Analysis |
| `outvar_list` | 1078 | 2 |  | yes | `mysql_outvar` | Tools > Variables & Headings |
| `word_search` | 996 | 2 |  |  | `mysql_words` | Tools > Words > Frequency List |
| `topic_result` | 983 | 1 |  |  | `mysql_outvar` | _(sub-window)_ |
| `topic_stats` | 936 | 5 |  |  | `kh_cod`, `mysql_getheader`, `mysql_outvar` | _(sub-window)_ |
| `word_cls` | 910 | 1 | yes |  | `kh_r_plot`, `mysql_crossout` | Tools > Words > Hierarchical Cluster Analysis |
| `word_conc` | 898 | 1 |  |  | `mysql_conc` | Tools > Words > KWIC Concordance |
| `word_ass` | 804 | 3 |  |  | `kh_cod`, `mysql_crossout` | Tools > Words > Word Association |
| `suggest` | 797 | 0 |  |  | — | Help > Show suggest window |
| `bayes_view_log` | 787 | 1 |  |  | `kh_nbayes` | _(sub-window)_ |
| `doc_search` | 751 | 0 |  |  | `kh_cod`, `mysql_getdoc` | Tools > Documents > Search Documents |
| `cod_netg` | 736 | 4 | yes |  | `kh_cod`, `kh_r_plot`, `mysql_getheader`, `mysql_outvar` | Tools > Coding > Co-Occurrence Network |
| `doc_cls_res` | 735 | 3 |  |  | `mysql_outvar`, `mysql_words` | _(sub-window)_ |
| `cod_outtab` | 725 | 0 | yes |  | `kh_cod`, `kh_r_plot`, `mysql_outvar` | Tools > Coding > Crosstab |
| `import_folder` | 632 | 2 |  |  | — | Project > Import > Multiple texts in a folder |
| `dictionary` | 628 | 0 |  |  | — | PRe-Processing > Select Words to Analyze |
| `word_netgraph` | 601 | 5 | yes |  | `kh_r_plot`, `mysql_crossout`, `mysql_getheader`, `mysql_outvar` | Tools > Words > Co-Occurrence Network |
| `bayes_view_knb` | 596 | 0 |  |  | `kh_nbayes` | _(sub-window)_ |
| `word_conc_coloc` | 596 | 1 |  |  | — | _(sub-window)_ |
| `r_plot` | 572 | 0 |  |  | `mysql_words` | _(sub-window)_ |
| `cod_jaccard` | 571 | 1 |  |  | `kh_cod` | Tools > Coding > Similarity Matrix |
| `topic_perplexity` | 547 | 1 | yes |  | `kh_r_plot`, `mysql_crossout` | Tools > Documents > Topic Models > Find Optimal N of Topics |
| `doc_view` | 518 | 2 |  |  | `mysql_a_word`, `mysql_getdoc` | _(sub-window)_ |
| `project_new` | 472 | 0 |  |  | — | Project > New |
| `cod_som` | 438 | 1 | yes |  | `kh_cod`, `kh_r_plot` | Tools > Coding > Self-Organizing Map |
| `cod_mds` | 430 | 1 | yes |  | `kh_cod`, `kh_r_plot` | Tools > Coding > Multi-Dimensional Scaling |
| `cod_cls` | 421 | 1 | yes |  | `kh_cod`, `kh_r_plot` | Tools > Coding > Hierarchical Cluster Analysis |
| `topic_fitting` | 412 | 2 |  |  | `mysql_crossout` | Tools > Documents > Topic Models > Fit a Topic Model |
| `bayes_learn` | 394 | 0 |  |  | `kh_nbayes`, `mysql_outvar` | _(sub-window)_ |
| `contxt_out` | 372 | 0 |  |  | `mysql_crossout` | _(sub-window)_ |
| `word_conc_opt` | 351 | 0 |  |  | — | _(sub-window)_ |
| `sql_select` | 339 | 2 |  |  | — | Tools > Execute SQL Statements |
| `txt_pickup` | 335 | 1 |  |  | `kh_cod`, `mysql_getheader` | Project > Export > Extract Partial Text<br>Tools > Export > Extract Partial Text |
| `project_open` | 324 | 0 |  |  | — | Project > Open |
| `word_df_freq` | 281 | 0 | yes |  | `kh_r_plot`, `mysql_words` | Tools > Words > Descriptive Stats > Document Frequency Distribution |
| `doc_cls_res_opt` | 277 | 0 |  |  | — | _(sub-window)_ |
| `project_edit` | 276 | 0 |  |  | — | _(sub-window)_ |
| `word_som` | 271 | 1 | yes |  | `kh_r_plot`, `mysql_crossout` | Tools > Words > Self-Organizing Map |
| `word_freq` | 259 | 0 | yes |  | `kh_r_plot`, `mysql_words` | Tools > Words > Descriptive Stats > Term Frequency Distribution |
| `morpho_check` | 256 | 0 |  |  | — | PRe-Processing > Check the Result of Word Extraction |
| `force_color` | 255 | 4 |  |  | — | _(sub-window)_ |
| `bayes_predict` | 252 | 0 |  |  | `kh_nbayes`, `mysql_outvar` | _(sub-window)_ |
| `cod_count` | 242 | 0 |  |  | `kh_cod` | Tools > Coding > Frequency |
| `about` | 239 | 0 |  |  | — | Help > About |
| `word_tf_df` | 231 | 1 | yes |  | `kh_r_plot`, `mysql_words` | Tools > Words > Descriptive Stats > TF-DF Plot |
| `datacheck` | 225 | 0 |  |  | — | _(sub-window)_ |
| `main` | 204 | 0 |  |  | — | _(sub-window)_ |
| `hukugo` | 183 | 0 |  |  | `mysql_hukugo` | _(sub-window)_ |
| `noun_phrases` | 183 | 0 |  |  | `mysql_hukugo`, `mysql_nounphrases` | _(sub-window)_ |
| `word_list` | 173 | 0 |  |  | `kh_cod`, `mysql_words` | Project > Export > Word Frequency List (for Excel)<br>Tools > Export > Word Frequency List (for Excel) |
| `stop_words` | 170 | 0 |  |  | — | _(sub-window)_ |
| `word_ass_opt` | 165 | 0 |  |  | — | _(sub-window)_ |
| `cls_height` | 160 | 0 |  |  | — | _(sub-window)_ |
| `word_conc_coloc_opt` | 160 | 0 |  |  | — | _(sub-window)_ |
| `word_search_opt` | 145 | 0 |  |  | — | _(sub-window)_ |
| `morpho_detail` | 134 | 0 |  |  | — | _(sub-window)_ |
| `outvar_read` | 129 | 0 |  |  | — | _(sub-window)_ |
| `word_df_freq_plot` | 123 | 0 |  |  | — | _(sub-window)_ |
| `word_freq_plot` | 123 | 0 |  |  | — | _(sub-window)_ |
| `txt_html2csv` | 112 | 0 |  |  | — | Project > Export > Texts in Arbitrary Units<br>Tools > Export > Texts in Arbitrary Units |
| `sysconfig` | 104 | 0 |  |  | — | Project > Settings |
| `doc_cls_res_sav` | 96 | 0 |  |  | `mysql_outvar` | _(sub-window)_ |
| `r_plot_opt` | 91 | 0 |  |  | — | _(sub-window)_ |
| `cod_out` | 82 | 0 |  |  | — | _(sub-window)_ |
| `morpho_crossout` | 81 | 0 |  |  | `mysql_crossout` | _(sub-window)_ |

## Coupling to Tk

The analysis engine is nearly free of the GUI. Outside `gui_window/` and
`gui_widget/`, the only things the core modules reach for are:

- `gui_errormsg->open` — three message types in use: `file`, `mysql`, `msg`.
- `gui_window->gui_jchar` — one call site, an encoding helper.
- `gui_window->kchar_patchim` — two call sites, Korean character handling.

`kh_sysconfig.pm:989` already defines a **`web_if`** flag, honoured in
`kh_r_plot.pm` and the `r_plot/*` modules to skip GUI-only steps. A headless
mode was anticipated by the original author; it is off by default.
