# DownloadHQ

A browser without ads that saves media from the pages you open, and keeps
YouTube playlists on your device for offline playback. It tracks each
playlist, flags videos added since the last check, and downloads the ones you
pick as audio (m4a) or video (mp4, capped resolution). Runs on Android, Linux
and Windows. No backend: all state is a few JSON files on the device.

App id `com.irrelevant.downloadhq`. It used to be PLM (`com.nayeem.plm`): on
desktop the old library, settings and tools are copied over on first launch;
on Android the new id is a separate app, so the old one's data stays with it.

Built on [yt-dlp](https://github.com/yt-dlp/yt-dlp).

## Features

- **Opens on the browser.** The home page (YouTube by default, change it in
  Settings or from the browser menu) loads straight away.
- **Built-in ad blocker** on every page and frame, with uBlock Origin's
  default filter lists: uBlock filters (ads, privacy, quick fixes), EasyList,
  EasyPrivacy and Peter Lowe's list, plus optional AdGuard Mobile Ads and
  EasyList Cookie notices. Lists refresh every 4 days. The shield in the
  toolbar shows what was blocked and pauses blocking for one site. See
  [Ad blocking](#ad-blocking).
- **SponsorBlock** for YouTube downloads: mark sponsor segments as chapters
  or cut them out. Chapters are embedded; subtitles optionally.
- **Share to DownloadHQ** (Android): share a link from the YouTube app or any
  browser and it opens in the in-app browser, ready to save.
- Add a playlist by link. The first check imports everything; later checks mark
  new arrivals **NEW**, with a count badge on the Library tab.
- Select and download, or **Skip** videos you don't want (they stay hidden
  until you bring them back).
- Per-playlist settings: audio or video, max quality, auto-download new videos.
- Videos removed from the playlist or made private on YouTube stay in your
  library if you downloaded them.
- Download queue with a concurrency limit, progress, speed, ETA, cancel and retry.
- Built-in player (audio and video) with a queue, shuffle, and a mini player.
- Checks for new videos on launch, when you come back to the app, and every N
  hours while it is open.
- Desktop: installs and updates yt-dlp, ffmpeg and deno itself (Settings → Tools).
- If you delete files outside the app, it notices and marks them not downloaded.
- **Browse tab**: a built-in browser. Every page you open is checked by yt-dlp
  in the background (YouTube, SoundCloud, Bandcamp, Internet Archive, and the
  [other sites yt-dlp supports](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md)).
  The bar under the page shows what it found. Tap **Save**, choose audio or video
  and a quality, and download. Pages that list many items (channels, albums,
  playlists) let you pick which ones. On a YouTube playlist you can also
  **track** it for new videos. Grabs go to a "From the web" collection.

## Architecture

```
lib/
  domain/     models, sync_diff (pure: merge remote listing into local state)
              adblock (pure: filter list parser, rule matching, page script)
  engine/     YtDlpEngine interface
              ytdlp_cli.dart      pure: flags in, parsed output out (shared)
              process_engine.dart desktop adapter (spawns the yt-dlp binary)
              android_engine.dart Android adapter (platform channel)
              desktop_tools.dart  finds and installs yt-dlp / ffmpeg / deno
  data/       JsonStore (atomic writes) + repositories
  services/   LibraryService, DownloadQueue, AutoSync, ToolsService,
              PlaybackService, GrabService, AdblockService, ShareService
              (no widgets)
  app/        bootstrap.dart (composition root, the only platform switch), theme
  ui/         screens and widgets; they read services, they don't do IO
android/.../MainActivity.kt   thin bridge: run(args) on youtubedl-android,
                              plus shared links
```

Dependencies only point one way: ui → services → engine/data → domain. All
yt-dlp flag handling lives in `ytdlp_cli.dart`, so both platforms send the same
command.

## Running

### Linux

```
sudo apt install libmpv-dev mpv libwebkit2gtk-4.1-dev   # player + in-app browser
flutter run -d linux
```

Then open Settings → Tools and install anything that's missing. Tools you
already have on your PATH are used as they are.

### Windows

`flutter run -d windows`. Install the tools from Settings in the same way.

### Android

`flutter build apk --release --split-per-abi`, then install the arm64 APK.
yt-dlp, Python and ffmpeg come bundled through
[youtubedl-android](https://github.com/yausername/youtubedl-android). On first
launch they take a few seconds to unpack.

**YouTube needs a JavaScript runtime** (see yt-dlp's
[EJS wiki](https://github.com/yt-dlp/yt-dlp/wiki/EJS)). Android doesn't have
one and it can't be installed while the app runs, so it has to be packaged into
the APK:

1. Get an Android arm64 build of `deno` (or of `qjs`, from QuickJS-NG ≥ 0.12).
2. Save it as `android/app/src/main/jniLibs/arm64-v8a/libdeno.so` (or
   `libqjs.so`).
3. Rebuild. DownloadHQ detects it and passes `--js-runtimes` for you. Settings → Tools
   shows whether it was found.

Without a JS runtime, some YouTube formats, or all of them, may fail to
download. Seal took the same approach
([Seal#2640](https://github.com/JunkFood02/Seal/issues/2640)).

## Ad blocking

uBlock Origin itself can't run here: Android WebView, WebKitGTK and WebView2
(as the plugin exposes it) load no browser extensions and give the app no hook
for a page's sub-requests. DownloadHQ reads uBlock's filter lists and enforces
them in three layers:

1. **Navigations**: pages, pop-ups, redirects and (where the platform reports
   them) frames to a blocked host are refused. This layer checks the full
   list, about 100,000 hosts with the default lists. `intent://` and
   `market://` redirects are refused too.
2. **Page requests**: a script injected at document start into every frame
   blocks `fetch`, XHR, beacons, `window.open` without a tap, and
   script/iframe/img sources pointed at ad hosts. It carries the 12,000 most
   useful hosts (ad lists before privacy lists), to stay light on phones.
3. **Site rules**: that site's cosmetic rules (`example.com##.ad`, with `~`
   exclusions, `example.*` and `#@#` exceptions) and uBlock scriptlets
   (`set`, `aopr`, `aopw`, `acs`, `json-prune`, `nostif`, `nosiif`, `aeld`,
   `nowoif`, `ra`). On YouTube, ad fields are pruned from player responses
   before the player sees them, Shorts ads are dropped, and any ad that still
   plays is skipped.

Not supported: uBlock's procedural and HTML filters (`:has-text`, `^script`),
generic cosmetic filters from EasyList (13,000+ of them; too slow for every
page), path-level network rules, `$domain=`-limited rules, and
`trusted-*` / `replace` scriptlets.

## Tests

```
flutter test                                   # pure logic; the ad block page script runs in node if installed
dart run tool/smoke.dart /tmp/dhq <playlist>   # desktop engine against live YouTube
dart run tool/adblock_bench.dart lists/*.txt   # ad block engine on real filter lists
```

## Not done yet (deliberately)

- Android background playback and lock-screen controls (would need `audio_service`).
- Checking for new videos while the app is closed (would need WorkManager).
- Private playlists and sign-in (would need cookies). Sites that require an
  account (Vimeo now does) say so in the Browse bar.
