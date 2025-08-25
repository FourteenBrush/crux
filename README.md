# Crux

A WIP Minecraft Server, being written in Odin

Linux only for now

## Architecture design

Worker thread(s) use epoll to (de)serialize packets from client, main thread is solely responsable
for processing packets.

## Building

```sh
git clone ...etc
git submodule update --init --recursive

# Currently expects a tracy.so file at build time in the lib/tracy directory, and a libTracyClient.so.0.11.2
# somewhere visible to the executable, used for runtime profiling (those two can be the same file)
make
```

## Outline for threaded communication

There is one (or multiple) network threads, which are responsable for io operations on the connected clients (packet decoding, transmission and such).
The main thread is solely responsable for processing those packets, and updating the game state accordingly.

Store a packet queue per player, where the network thread would then cross a thread boundary and exchange packets with the main thread.
The main thread would be already aware of game associated client data (how do we map ClientConnections to game player data, use user uuids?).

This may form an issue when clients are disconnected from a network worker, but the main thread isn't aware.
Is it even supposed to be aware, those two threads communicate using messages right?

Cant we make the networks threads responsable for holding client data