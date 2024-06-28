##
# Build stage
FROM --platform=linux/amd64 ubuntu:22.04 AS build

# Install some libs
RUN apt-get update -yqq && \
    apt-get install -yqq cmake clang libtool gcc git curl libssl-dev \
    build-essential automake autoconf libncurses5-dev elixir iputils-ping \
    erlang-base erlang-public-key erlang-asn1 erlang-ssl erlang-dev erlang-inets \
    erlang-eunit erlang-common-test rebar3

# Set working directory
WORKDIR /opt/thepower

COPY . .

# Build binaries
RUN rebar3 compile
RUN rebar3 release
RUN rebar3 tar

RUN mkdir -p build

# TODO: Copy only necessary resources for runtime: bin lib releases
RUN cp -r bin build/

##
# Runtime stage: image for tpnode binary
FROM erlang:22.3.4-slim AS runtime

# Set working directory
WORKDIR /opt/thepower

# Copy tpnode binaries and config: bin, lib and releases
COPY --from=build /opt/thepower/build/ .

# TODO: confirm the behaviour of the binary to choose the accurate entrypoint
ENTRYPOINT ["./bin/thepower"]