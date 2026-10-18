# Allume Companion promo film

A one-minute film (1920×1080, 60 fps) made with [Remotion](https://www.remotion.dev): React scenes over
the recorded feature masters, with a soundtrack synthesized in Python. Remotion is free for individuals;
see its license before using it for a company.

```bash
npm install
npm run footage   # ../build/masters/*.mov → public/footage/*.mp4 + stills (src/clips.json)
npm run music     # src/timeline.json → public/audio/music.wav
npm run studio    # preview and scrub
npm run render    # → out/allume-companion-promo.mp4
python3 -I scripts/make-web-media.py ../../blog/public/projects/allume-companion   # the landing page's videos
```

The masters come from the companion's demo recordings (`../docs/DEVELOPMENT.md`, "演示视频"):
`scripts/make-demo-board.py`, `scripts/reset-demo-board.py`, `build/record-region`, then
`CROP_TOP=76 MASTER_DIR=build/masters scripts/make-demo-media.sh`. `public/footage`, `public/audio` and
`out/` are generated and not committed.

## How it is put together

- `src/timeline.json`: the beat grid both sides read: 120 BPM, a bar is 2 s (120 frames), 32 bars. Scenes
  and sound effects are placed in bars, so cuts land on the beat.
- `src/clips.json`: which source seconds each scene plays (idle waits cut out) and the bars it plays in;
  the speed follows from the two.
- `src/Promo.tsx`: every element's position is a function of the frame. Nothing fades: things grow from
  a point, fly in from an edge, rise out of a mask, flip, or morph from one rect into another (the icon's
  top card becomes the canvas; the last feature becomes the icon again; the icon bursts into the daily
  board; October shrinks into the year).
- `scripts/make-music.py`: F major, Fmaj7 – Am7 – Dm9 – B♭maj7. Intro pad and arpeggio, drums from bar 4,
  a fake ending with a riser and one beat of silence at bar 17.75, the drop at bar 18, a last chord at 30.

## Story

| Bars | Seconds | What |
|---|---|---|
| 0–4 | 0–8 | The icon assembles (three cards, the filament drawn on), the name, ⌘K; the top card opens into the canvas |
| 4–16 | 8–32 | Arrange, same size, undo, jump, add a todo, finish it: a carousel of cards with the keys typed |
| 16–18 | 32–36 | Fake ending: the cards gather back into the icon; silence |
| 18–26 | 36–52 | The drop: daily notes, a whole year of boards, projects, reminders, every feature on one wall |
| 26–32 | 52–64 | The wall stacks into the icon; name, ⌘K, free and open source, companion.maverickli.org |
