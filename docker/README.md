# Running KH Coder in Docker

This build has no database server. Each project is a single SQLite file under
`config/<project>/`, so there is nothing to start, nothing to shut down, and no
Docker volume to manage.

## Build

    docker build -t khcoder:latest docker/

Nothing is compiled: the CPAN modules are pure Perl and the CRAN packages come
from a pinned Posit snapshot as binaries. The toolchain lives only in the
builder stage and never reaches the final image (~740MB).

## Run

    ./docker/run.sh                 # a shell in /khcoder/src
    ./docker/run.sh perl kh_coder.pl

`run.sh` gives the container an X cookie of its own instead of opening the
display to every local user with `xhost +local:`, and runs the container as the
invoking user so project files are not left owned by root.

`tutorial_jp/` and `work/`, if present next to this source tree, are mounted at
`/khcoder/tutorial_jp` and `/khcoder/work`.

## Diagnostics

Setting `KHC_SQL_AUDIT=1` makes a failing SQL statement report and continue
rather than stop the program, so one run surfaces every problem instead of the
first. Diagnostics only -- results after an error are not trustworthy.
