FROM rust:1.77.0

WORKDIR app

ENV DEBIAN_FRONTEND=noninteractive

RUN set -ex;\
    apt-get update; \
    apt-get install --no-install-recommends --assume-yes \
      curl git jq pkg-config ssh \
      libssl-dev lld protobuf-compiler

# Set up a directory to store Cargo files.
ENV CARGO_HOME=/app/.cargo
ENV PATH="$PATH:$CARGO_HOME/bin"
# Switch to `lld` as the linker.
ENV RUSTFLAGS="-C link-arg=-fuse-ld=lld"

# Install Rust tools.
COPY rust-toolchain.toml .
RUN rustup show
RUN cargo install cargo-chef cargo-nextest critcmp grcov just

COPY Cargo.toml Cargo.lock .

RUN mkdir bin

# Build the binaries and tests
RUN --mount=type=cache,target=/app/.cargo/git --mount=type=cache,target=/app/.cargo/registry \
    --mount=type=cache,target=./target \
    --mount=type=bind,source=./crates,target=./crates \
    set -ex; \
    cargo build --all-targets; \
    cargo nextest archive --archive-file=./bin/nextest.tar.zst

# Copy the binaries out of the cache
RUN --mount=type=cache,target=./target \
    find target/debug -maxdepth 1 -type f -executable -exec cp '{}' bin \;
