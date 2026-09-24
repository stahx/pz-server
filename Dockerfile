FROM --platform=linux/amd64 debian:bookworm-slim

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
      tini \
      tzdata \
 && sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen \
 && locale-gen \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash pz

RUN mkdir -p "$STEAMCMD_DIR" "$SERVER_DIR" \
 && curl -sSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    | tar -xz -C "$STEAMCMD_DIR" \
 && chown -R pz:pz "$STEAMCMD_DIR" "$SERVER_DIR"

RUN mkdir -p "$ZOMBOID_DIR" && chown -R pz:pz /home/pz

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/console.sh /usr/local/bin/console
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/console

USER pz
WORKDIR /home/pz

EXPOSE 16261/udp 16262/udp

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
