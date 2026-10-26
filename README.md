# Zomboid Workshop Manager

A macOS app for **publishing and updating Project Zomboid mods on the Steam Workshop without opening the game**. It works with the projects you already have in `~/Zomboid/Workshop`, uses the same files the game does (`workshop.txt`, `preview.png`, `Contents/`), and keeps your Workshop page text in sync with Steam.

## Why

The in-game uploader means launching the game, digging through menus, and hoping the upload worked. It also has problems that are easy to miss:

- **Page edits made on the Steam website get lost.** The game uploads the title, description, tags and visibility from `workshop.txt` every time. If you fixed your description on the website, your next upload quietly undoes it.
- **"Workshop ID / Mod ID" lines pile up.** The game adds those lines to the end of your description on every upload. If they ever get copied back into `workshop.txt`, every upload adds another copy.
- **You can't see what you're about to upload.** Nothing tells you which files differ from what's on Steam, which is also why players get kicked with checksum errors when your local copy and the Workshop don't match.

## What it does

- **Publish new items.** Creates the Workshop item, writes the new id into `workshop.txt`, and uploads.
- **Update existing items** with a change note and live upload progress.
- **Edit the page:** title, description (Steam BBCode), tags from the game's own tag list, visibility, and preview image. Saved to `workshop.txt`, then sent to Steam.
- **Check before upload** with the same rules the game uses: preview size and dimensions, the folder layout in `Contents/`, `mod.info` ids, map folders, and blocked file types.
- **Show changed files.** Compares `Contents/` with the latest Steam upload, file by file.
- **Keep page text in sync.** Every 10 minutes it compares `workshop.txt` with the live Steam page. It remembers the last synced version, so it can tell whether the page was edited on Steam, edited locally, or both. When the page changes on Steam you get a Mac notification, and you choose which way to sync. Uploads are blocked until the page is synced, so a Steam edit is never overwritten by accident.
- **Cleans up the ID lines.** It ignores them when comparing, never copies them into `workshop.txt`, and offers to remove copies already there.
- Backs up `workshop.txt` before every change, to `~/Library/Application Support/Zomboid Workshop Manager/backups/`.
- Stays in the menu bar after you close the window, so the sync checks keep running. Optionally opens at login.

## Requirements

- macOS 14 or later
- Project Zomboid installed through Steam. The app uses the Steam library (`libsteam_api.dylib`) that ships with the game.
- The Steam client running and logged in as the account that owns your Workshop items
- Xcode or the Xcode Command Line Tools to build

## Build and install

```bash
git clone https://github.com/lilPZmods/zomboid-workshop-manager.git
cd zomboid-workshop-manager
./build.sh        # builds and copies the app to /Applications
```

If your game or projects aren't in the default locations, change them in **Zomboid Workshop Manager → Settings**.

## How it talks to Steam

Each Steam action (checking pages, uploading, downloading, creating, deleting) runs in a short-lived helper process: the app runs its own executable with `--steam <operation>`. The helper loads the game's Steam library, does one job and exits. Steam shows you as "in Project Zomboid" only for those few seconds, and a Steam problem can't crash the app. You can run the helper yourself:

```bash
"/Applications/Zomboid Workshop Manager.app/Contents/MacOS/Zomboid Workshop Manager" --steam query <workshop id>
```

Uploads make the same Steamworks calls in the same order as the game's uploader (`zombie.core.znet.SteamWorkshop`): title, description with the ID lines added, visibility, tags, content folder, preview, then the change note.

## Links from other apps

`zomboid-workshop-manager://item/<workshop id>` opens the app on that project. [Zomboid Server Monitor](https://github.com/lilPZmods/zomboid-server-monitor) uses this link for its "Upload" fix.

## License

MIT. See [LICENSE](LICENSE).

Project Zomboid is a trademark of The Indie Stone. Steam and the Steam Workshop are trademarks of Valve Corporation. This project isn't affiliated with either.
