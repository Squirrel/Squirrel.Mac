# Squirrel.Mac builds with GN against Chromium's //build. `gclient sync` reads
# this file and fetches the build files, the toolchain and the third-party
# libraries; see README.md for the bootstrap steps.

use_relative_paths = True
git_dependencies = 'DEPS'

gclient_gn_args_file = 'build/config/gclient_args.gni'
gclient_gn_args = [
  'build_with_chromium',
  'checkout_android',
  'checkout_src_internal',
]

vars = {
  'build_with_chromium': False,
  'checkout_android': False,
  'checkout_src_internal': False,
  'checkout_clang_coverage_tools': False,

  'chromium_git': 'https://chromium.googlesource.com',
  'github_git': 'https://github.com',

  'build_revision': '2cd94c0abeada712aeea6906d99021913c9fc28d',
  'buildtools_revision': '6f6a5dbf04b734214f3b1f386567d101ec9d607e',
  'clang_revision': '450d823868eaee61e2b2cb986e19aec287f16d58',
  'gn_version': 'git_revision:150a9d6ba0aa7f407aa4feeabc5f03ce9aa7e04b',
  'ninja_version': 'version:3@1.12.1.chromium.4',

  'mantle_revision': '2a8e2123a3931038179ee06105c9e6ec336b12ea',
  'nimble_revision': 'c93f16c25af5770f0d3e6af27c9634640946b068',
  'ohhttpstubs_revision': '08776e99bc851a8832c24db40bfa42bacdf9d520',
  'quick_revision': 'f9d519828bb03dfc8125467d8f7b93131951124c',
  'reactiveobjc_revision': '74ab5baccc6f7202c8ac69a8d1e152c29dc1ea76',
  'sparkle_revision': '79bc9e872948e47877e76f194cb0c8e0412b0b90',
}

deps = {
  'build':
    Var('chromium_git') + '/chromium/src/build.git@' + Var('build_revision'),

  'buildtools':
    Var('chromium_git') + '/chromium/src/buildtools.git@' +
        Var('buildtools_revision'),

  'buildtools/mac': {
    'packages': [
      {
        'package': 'gn/gn/mac-${{arch}}',
        'version': Var('gn_version'),
      }
    ],
    'dep_type': 'cipd',
    'condition': 'host_os == "mac"',
  },

  'buildtools/linux64': {
    'packages': [
      {
        'package': 'gn/gn/linux-${{arch}}',
        'version': Var('gn_version'),
      }
    ],
    'dep_type': 'cipd',
    'condition': 'host_os == "linux"',
  },

  'third_party/llvm-build/Release+Asserts': {
    'dep_type': 'gcs',
    'bucket': 'chromium-browser-clang',
    'objects': [
      {
        'object_name': 'Mac/clang-llvmorg-24-init-3796-g20e97c4b-4.tar.xz',
        'sha256sum': 'ba2b707d83f7a19d81b9403b4ebe8e999d41ae35fead00a142f02b67e197fe2f',
        'size_bytes': 56420628,
        'generation': 1787607010939621,
        'condition': 'host_os == "mac" and host_cpu == "x64"',
      },
      {
        'object_name': 'Mac/llvmobjdump-llvmorg-24-init-3796-g20e97c4b-4.tar.xz',
        'sha256sum': '4ddefa96f6aaa04ac502610fc736528f65dc3e1b997fc4a5380081937f6ffb1a',
        'size_bytes': 5874672,
        'generation': 1787607011035157,
        'condition': 'host_os == "mac" and host_cpu == "x64"',
      },
      {
        'object_name': 'Mac_arm64/clang-llvmorg-24-init-3796-g20e97c4b-4.tar.xz',
        'sha256sum': '264d803970f9b58ddbdc90464ad82e54cef642c58ec371ba5356dfa7342ece4d',
        'size_bytes': 47226204,
        'generation': 1787607020088085,
        'condition': 'host_os == "mac" and host_cpu == "arm64"',
      },
      {
        'object_name': 'Mac_arm64/llvmobjdump-llvmorg-24-init-3796-g20e97c4b-4.tar.xz',
        'sha256sum': 'c67f5dba316d6367be8c153ede456fdbef0dfffad4da10aaf597ff967c07378c',
        'size_bytes': 5610096,
        'generation': 1787607020228775,
        'condition': 'host_os == "mac" and host_cpu == "arm64"',
      },
    ]
  },

  'third_party/ninja': {
    'packages': [
      {
        'package': 'infra/3pp/tools/ninja/${{platform}}',
        'version': Var('ninja_version'),
      }
    ],
    'dep_type': 'cipd',
  },

  'tools/clang':
    Var('chromium_git') + '/chromium/src/tools/clang@' + Var('clang_revision'),

  'vendor/Mantle':
    Var('github_git') + '/Mantle/Mantle.git@' + Var('mantle_revision'),

  'vendor/Nimble':
    Var('github_git') + '/Quick/Nimble.git@' + Var('nimble_revision'),

  'vendor/OHHTTPStubs':
    Var('github_git') + '/github/OHHTTPStubs.git@' + Var('ohhttpstubs_revision'),

  'vendor/Quick':
    Var('github_git') + '/Quick/Quick.git@' + Var('quick_revision'),

  'vendor/ReactiveObjC':
    Var('github_git') + '/ReactiveCocoa/ReactiveObjC.git@' +
        Var('reactiveobjc_revision'),

  'vendor/Sparkle':
    Var('github_git') + '/sparkle-project/Sparkle.git@' +
        Var('sparkle_revision'),
}
