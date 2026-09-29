FROM --platform=linux/amd64 debian:bookworm-slim

ARG RCON_CLI_VERSION=0.10.3
# sha256 of rcon-${RCON_CLI_VERSION}-amd64_linux.tar.gz; bump it together with the version.
ARG RCON_CLI_SHA256=6962a641ebf9a5957bd0cda1b8acf3e34a23686ae709f6c6a14ac3898521a5cc

ENV DEBIAN_FRONTEND=noninteractive \
    STEAM_APP_ID=380870 \
    STEAMCMD_DIR=/opt/steamcmd \
    SERVER_DIR=/opt/pzserver \
    ZOMBOID_DIR=/home/pz/Zomboid \
    SCREEN_NAME=pz-server \
    LANG=en_US.UTF-8

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      lib32gcc-s1 \
      locales \
      procps \
      screen \
      sqlite3 \
      tini \
      tzdata \
      unzip \
 && sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen \
 && locale-gen \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/rcon.tar.gz "https://github.com/gorcon/rcon-cli/releases/download/v${RCON_CLI_VERSION}/rcon-${RCON_CLI_VERSION}-amd64_linux.tar.gz" \
 && echo "${RCON_CLI_SHA256}  /tmp/rcon.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/rcon.tar.gz --wildcards --strip-components=1 -C /usr/local/bin '*/rcon' \
 && rm /tmp/rcon.tar.gz \
 && mv /usr/local/bin/rcon /usr/local/bin/rcon-cli \
 && chmod +x /usr/local/bin/rcon-cli

RUN useradd --create-home --shell /bin/bash pz

RUN mkdir -p "$STEAMCMD_DIR" "$SERVER_DIR" \
 && curl -sSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    | tar -xz -C "$STEAMCMD_DIR" \
 && chown -R pz:pz "$STEAMCMD_DIR" "$SERVER_DIR"

RUN mkdir -p "$ZOMBOID_DIR" && chown -R pz:pz /home/pz

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/console.sh /usr/local/bin/console
COPY scripts/rcon.sh /usr/local/bin/rcon
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/console /usr/local/bin/rcon

USER pz
WORKDIR /home/pz

EXPOSE 16261/udp 16262/udp 27015/tcp

# Healthy once the game runs in its screen session and has logged SERVER STARTED.
# The start period covers a first start, which downloads ~7 GB before the game boots.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30m --retries=3 \
  CMD screen -list | grep -q "$SCREEN_NAME" && grep -aq 'SERVER STARTED' "$ZOMBOID_DIR/console-screen.log"

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
