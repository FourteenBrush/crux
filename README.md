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

make
```