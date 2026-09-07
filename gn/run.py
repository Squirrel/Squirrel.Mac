#!/usr/bin/env python3
# Runs its arguments as a command; GN actions can only invoke Python.
import subprocess
import sys

sys.exit(subprocess.call(sys.argv[1:]))
