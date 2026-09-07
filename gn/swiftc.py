#!/usr/bin/env python3
"""Compiles a Swift module to one object file plus its Objective-C header.

Chromium's macOS toolchain has no Swift tool, so swift_module() targets run
this script as an action and hand the object file to the regular linker.
"""

import argparse
import os
import re
import subprocess
import sys


TEXTUAL_HEADERS = {
    'ObjectiveC': ['objc/NSObject.h', 'objc/message.h', 'objc/runtime.h'],
}


def fix_generated_header(path):
    """Gives the generated header a non-modules fallback for its @imports.

    swiftc guards the frameworks it imports with __has_feature(objc_modules)
    and Chromium's toolchain compiles Objective-C without -fmodules, so add an
    #else branch with plain #imports of the same frameworks.
    """
    with open(path, encoding='utf8') as f:
        lines = f.readlines()
    out = []
    imports = None
    depth = 0
    for line in lines:
        if line.startswith('#if __has_feature(objc_modules)'):
            imports = []
            depth = 1
        elif imports is not None:
            if line.startswith('#if'):
                depth += 1
            elif line.startswith('#endif'):
                depth -= 1
                if depth == 0:
                    out.append('#else\n')
                    for module in imports:
                        for header in TEXTUAL_HEADERS.get(
                                module, ['%s/%s.h' % (module, module)]):
                            out.append('#import <%s>\n' % header)
                    imports = None
            else:
                match = re.match(r'@import (\w+);', line)
                if match:
                    imports.append(match.group(1))
        out.append(line)
    with open(path, 'w', encoding='utf8') as f:
        f.writelines(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--module-name', required=True)
    parser.add_argument('--object', required=True)
    parser.add_argument('--module', required=True)
    parser.add_argument('--header', required=True)
    parser.add_argument('--module-cache', required=True)
    parser.add_argument('--sdk', required=True)
    parser.add_argument('--target', required=True)
    args, rest = parser.parse_known_args()
    sources = [arg for arg in rest if arg.endswith('.swift')]
    swift_flags = [arg for arg in rest if not arg.endswith('.swift')]

    for output in (args.object, args.module, args.header):
        os.makedirs(os.path.dirname(output) or '.', exist_ok=True)

    subprocess.check_call([
        'xcrun', 'swiftc', '-c', '-parse-as-library', '-whole-module-optimization',
        '-module-name', args.module_name,
        '-sdk', os.path.realpath(args.sdk),
        '-target', args.target,
        '-module-cache-path', args.module_cache,
        '-emit-module', '-emit-module-path', args.module,
        '-emit-objc-header', '-emit-objc-header-path', args.header,
        '-o', args.object,
    ] + swift_flags + sources)

    fix_generated_header(args.header)


if __name__ == '__main__':
    sys.exit(main())
