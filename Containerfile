FROM docker.io/library/rust:1.99.1-alpine3.24 AS build

COPY . /maki/
WORKDIR /maki/

RUN apk update \
  && apk add --no-cache perl make g++

RUN cargo build \
  && mv /maki/target/debug/maki /maki-bin \
  && rm -r -f /maki/

FROM docker.io/library/ubuntu:26.04 AS runtime

RUN apt-get update \
  && apt-get install --yes git vim

COPY --from=build /maki-bin /usr/local/bin/maki

RUN apt-get autoremove --yes \
  && apt-get clean --yes \
  && rm --recursive --force /tmp/* /var/tmp/* \
  && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \ 
  && find /var/cache -type f -delete

ENTRYPOINT ["/usr/local/bin/maki"]
