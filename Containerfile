FROM docker.io/library/rust:1.99.1-alpine3.24 AS build

COPY . /maki/
WORKDIR /maki/

RUN apk update \
  && apk add --no-cache perl make g++

RUN cargo build \
  && mv /maki/target/debug/maki /maki-bin \
  && rm -r -f /maki/

FROM docker.io/library/ubuntu:26.04 AS runtime

ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    PATH=/usr/local/cargo/bin:${PATH}

RUN apt-get update \
  && apt-get install --yes \
    git vim \
    build-essential \
    openjdk-11-jdk-headless openjdk-17-jdk-headless openjdk-21-jdk-headless openjdk-25-jdk-headless \
    maven \
    python3 python3-dev python3-venv python3-pip \
    curl ca-certificates \
  && curl --proto '=https' --tlsv1.2 --location --silent --show-error https://sh.rustup.rs \
  | sh -s -- --yes --profile minimal --no-modify-path

COPY --from=build /maki-bin /usr/local/bin/maki

RUN apt-get autoremove --yes \
  && apt-get clean --yes \
  && rm --recursive --force /tmp/* /var/tmp/* \
  && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
  && find /var/cache -type f -delete

ENTRYPOINT ["/usr/local/bin/maki"]
