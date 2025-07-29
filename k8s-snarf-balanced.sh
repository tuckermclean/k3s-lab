#!/bin/bash
exec "$(dirname "$0")/k8s-snarf.sh" balanced "$@"   