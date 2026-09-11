# Copy to .gclient and run `gclient sync` to fetch the build dependencies.
solutions = [
  {
    "name": ".",
    "url": "https://github.com/Squirrel/Squirrel.Mac.git",
    "deps_file": "DEPS",
    "managed": False,
  },
]
