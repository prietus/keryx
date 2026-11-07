#!/bin/sh
# Builds the site and publishes it to keryx.priet.us.
set -eu
cd "$(dirname "$0")"
python3 gen_commands.py
mkdocs build --strict
rsync -az --delete build/ teraflops@mail.priet.us:/srv/sites/keryx-site/site/
