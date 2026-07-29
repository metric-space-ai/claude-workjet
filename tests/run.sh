#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zsh "$ROOT/tests/dispatcher_test.zsh"
zsh "$ROOT/tests/wrapper_rework_test.zsh"
