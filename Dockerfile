# Stage 1: Prepare the OS and install dependencies
FROM --platform=linux/amd64 ubuntu:22.04 AS base

# Install common OS dependencies
RUN apt-get update -yqq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -yqq \
        apt-utils \
        cmake \
        clang \
        libtool \
        gcc \
        git \
        curl \
        libssl-dev \
        build-essential \
        automake \
        autoconf \
        libncurses5-dev \
        elixir \
        erlang-base \
        erlang-public-key \
        erlang-asn1 \
        erlang-ssl \
        erlang-dev \
        erlang-inets \
        erlang-eunit \
        erlang-common-test \
        rebar3 \
        iputils-ping && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

WORKDIR /opt/

# Clone the project from the Git repository (this step will rerun if the code changes)
RUN git clone -b dev https://github.com/thepower/tpnode.git

# Stage 2: Build the application
FROM base AS build

WORKDIR /opt/tpnode

RUN git -C /opt/tpnode pull || git clone -b dev https://github.com/thepower/tpnode.git /opt/tpnode

# Install project dependencies and compile the application
RUN rebar3 get-deps && \
    rebar3 compile && \
    rebar3 as prod release 

# Clean up unnecessary files
RUN rm -rf _build/prod/rel/thepower/lib/*/doc && \
    rm -rf _build/prod/rel/thepower/lib/*/examples

# Stage 3: Create a minimal image for running the application
FROM --platform=linux/amd64 ubuntu:22.04 AS runtime

# Install runtime dependencies
RUN apt-get update -yqq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -yqq --no-install-recommends \
        ca-certificates \
        libncurses5 \
        libssl-dev \
        iputils-ping && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

WORKDIR /opt/thepower

# Copy the compiled application from the build stage
COPY --from=build /opt/tpnode/_build/prod/rel/thepower /opt/thepower

# Expose necessary ports
EXPOSE 1080 1443 1800

# Set the startup command
CMD ["/opt/thepower/bin/thepower", "foreground"]