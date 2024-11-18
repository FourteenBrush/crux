# Crux

A WIP Minecraft Server, being written in Odin

Linux only for now

## Architecture design

Worker thread(s) use epoll to receieve data from clients;
That data is pushed into a buffer, shared with the main thread;
Main thread locks this buffer and reads packets from it, dispatches them to packet processor;
