# Aegisub AppImage Builder

This script automates the compilation and packaging of Aegisub (arch1t3cht/Aegisub,
migration03-02 branch) into a portable Linux AppImage.

It supports building on Fedora, Ubuntu[^1], Debian[^1], and compatible derivative
distributions (such as Linux Mint or Pop!\_OS).

[^1]: Untested, build at your own risk!

## Features

- Automatic installation of system build dependencies (via dnf or apt).
- Custom compilation of LuaJIT with Lua 5.2 compatibility.
- Cache directory for all downloads to speed up subsequent builds.
- Robust exit traps that clean up temporary directories on termination.
- Default bundling of:
  - DependencyControl (automation manager)
  - Unanimated's Aegisub scripts collection (typesetting macros)
  - Hunspell dictionaries for English (en_US) and Indonesian (id_ID)
  - Aegisub-DiscordRPC (with built-in privacy protection that redacts video file
    paths and names)

## Usage

Make the script executable and run it:

```bash
chmod +x build.sh
./build.sh
```

The final AppImage will be output in the current directory with a unique,
versioned filename. For example:
`Aegisub-3.4.1-arch1t3cht-migration03-02+appimage.build.52383d99-x86_64.AppImage`

## Command Line Options

- `--skip-deps`
  Skip automatic system dependency installation (useful if packages are already
  configured).

- `--skip-luajit`
  Skip building LuaJIT and look for an existing /usr/local/bin/luajit version.

- `--add-dict LOCALE:AFF_URL;DIC_URL`
  Bundle an additional Hunspell dictionary. The argument requires a locale code
  followed by the URL to the `.aff` file and the `.dic` file separated by a semicolon.
  Can be used multiple times.

- `--clean`
  Clean the build workspace, custom LuaJIT installation, and prompt to remove
  development packages.

- `--help`, `-h`
  Display usage instructions.

## Custom Dictionary Example

To bundle French and German dictionaries with the AppImage:

```bash
./build.sh \
  --add-dict "fr_FR:https://raw.githubusercontent.com/LibreOffice/dictionaries/master/fr_FR/fr.aff;https://raw.githubusercontent.com/LibreOffice/dictionaries/master/fr_FR/fr.dic" \
  --add-dict "de_DE:https://raw.githubusercontent.com/LibreOffice/dictionaries/master/de/de.aff;https://raw.githubusercontent.com/LibreOffice/dictionaries/master/de/de.dic"
```

## Applied Upstream Patches

To guarantee AppImage compatibility and user privacy, this script patches official
solutions during the build:

- **Aegisub (libaegisub/unix/path.cpp)**
  Patches the internal data directories to resolve resources relative to
  the AppImage's execution path (e.g. `data = data.parent_path() / "share" / "aegisub"`).

- **Aegisub-DiscordRPC (discord-rpc.lua)**
  - AppImage Compatibility: Adds a fallback block to load `libdiscord-rpc.so`
    relative to the `$APPDIR` environment variable if standard dynamic library
    lookup fails.
  - Privacy Patch: Replaces the default behavior of broadcasting your subtitle's
    video filename and directory path. The rich presence instead broadcasts a
    generic `"Active editing session"`, exposing only the current active line
    index and frame number (e.g., `"Line: 42 | Frame: 1008"`).

- **linuxdeploy GTK plugin (AppRun & hooks)**
  - Patches `GIO_MODULE_DIR=""` to prevent segmentation faults caused by loading
    incompatible host GIO modules.
  - Disables hardcoded `GDK_BACKEND=x11` and `GTK_THEME` overrides to allow native
    Wayland rendering and use the user's host GTK themes.
  - Merges the AppImage GSettings schema directories with the host schemas (`GSETTINGS_SCHEMA_DIR`).

- **Library Blacklisting (Conflict Prevention)**
  - Automatically blacklists and deletes `libngtcp2` and `libnghttp3` from
    the AppImage's internal libraries. This prevents version and symbol mismatch
    errors (such as `undefined symbol: ngtcp2_conn_get_stream_user_data`) when
    Aegisub automation scripts (like `libDownloadManager.so`) load and link
    against the host system's `libcurl`.

- **LuaJIT**
  - Compiles LuaJIT from source with `LUAJIT_ENABLE_LUA52COMPAT` enabled.
    Fedora's stock LuaJIT package does not compile this, which breaks automation
    scripts relying on Lua 5.2 features.

## Acknowledgements

This builder script downloads, compiles, or bundles resources from the following
upstream projects:

- Aegisub: https://github.com/arch1t3cht/Aegisub
- DependencyControl: https://github.com/TypesettingTools/DependencyControl
- Aegisub-DiscordRPC: https://github.com/mnh48/Aegisub-DiscordRPC
- Unanimated's Aegisub scripts collection: https://github.com/unanimated/luaegisub
- ffi-experiments: https://github.com/TypesettingTools/ffi-experiments
- luajson: https://github.com/harningt/luajson
- LuaJIT: https://github.com/LuaJIT/LuaJIT
- linuxdeploy: https://github.com/linuxdeploy/linuxdeploy

## Disclaimer

This build script is provided on an "as-is" basis. There is no guarantee that
the script or the resulting AppImage will compile or run successfully on
your specific machine configuration. The author assumes no liability for any errors,
system changes, or issues that occur during or as a result of using this script.

## License

This AppImage builder script (`build.sh`) is licensed under
the [MIT License](LICENSE).

Please note that this license applies **only** to the build script itself.
The builder downloads, compiles, and packages third-party dependencies, libraries,
and assets (such as Aegisub, LuaJIT, Discord RPC, Hunspell, and additional scripts)
which are subject to their own respective upstream licenses. Users building or
redistributing the final AppImage must respect the licensing terms of each
individual dependent project.
