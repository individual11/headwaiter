# Roadmap

Roughly in order. Open an issue to argue for something, or if you want to build one.

**Daily use**
- Open in editor
- A marker for orphaned servers (the terminal or agent that started them is gone)
- Stop all, per project and globally
- CPU and memory per server
- Show which terminal or agent started each server

**Bigger features**
- Start and restart a server from its stored command
- Output logs for servers Headwaiter started
- Global hotkey
- A group for watchers and builds that don't listen on a port
- More runtimes: PHP/Laravel, JVM/Spring Boot, Rust, local databases, Elixir/Phoenix, .NET
- Apple `container`, once it has a stable API to read

**Out of scope**
- Port lookup for any process ("who has port 3000?")

**Help wanted: real captures.** Docker, Go, most Python setups, turbo and nx are mostly covered by hand-written tests. See [CONTRIBUTING](../CONTRIBUTING.md#captures) for how to send one safely.
