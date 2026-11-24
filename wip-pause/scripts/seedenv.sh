#!/bin/bash
BIN=$1; shift
ulimit -v 4000000
env "$@" timeout 900 $BIN 2>&1
