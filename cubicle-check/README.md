# Windows check (from the Cubicle game)

Builds this branch's extension on Windows and runs two Godot clients against a local livekit-server:
20 s publishing and subscribing mic audio and a generated video track, then quitting; and leaving
and rejoining. Every client must exit with code 0. See `.github/workflows/cubicle-windows-check.yml`.
