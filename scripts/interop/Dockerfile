# The image the QUIC interoperability runner starts: it builds the interop server and hands it the
# environment the runner sets. `scripts/interop/run_endpoint.sh` is the entry point.
#
#   docker build -f scripts/interop/Dockerfile -t mooncat-interop .
#   docker run --rm -e ROLE=server -e TESTCASE=handshake -e REQUESTS=https://server4:443/ \
#     -p 443:443/udp -p 443:443/tcp mooncat-interop
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git libssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash \
    && ln -s /root/.moon/bin/moon /usr/local/bin/moon

WORKDIR /mooncat
COPY . .

RUN moon version --all \
    && moon update

# The native artifact carries `.exe` on every platform; the name is the one the build writes.
RUN moon build --release --target native src/examples/16-interop-server \
    && cp _build/native/release/build/examples/16-interop-server/16-interop-server.exe \
        /usr/local/bin/mooncat-interop

# The same image carries the client that drives the other direction of the matrix. It lives in
# `integration/`, a module of its own, so that its dependencies never reach the library's.
RUN cd integration/interop-client \
    && moon build --release --target native \
    && cp _build/native/release/build/mooncat-interop-client.exe \
        /usr/local/bin/mooncat-interop-client

COPY scripts/interop/run_endpoint.sh /run_endpoint.sh
RUN chmod +x /run_endpoint.sh

# The runner mounts its own certificate and files; these are only where they are looked for.
ENV MOONCAT_PORT=443
EXPOSE 443/tcp
EXPOSE 443/udp

WORKDIR /
CMD ["/run_endpoint.sh"]
