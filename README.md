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