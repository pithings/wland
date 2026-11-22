# wland demo image: the wlandr relay, its page, and real Wayland apps
# (chromium, pcmanfm, l3afpad) running inside the container as wland clients.
#
#   docker build -f docker/Dockerfile -t wland .
#   docker run --rm -p 8080:8080 wland        # then open http://localhost:8080
#
# Arguments pick the apps, one command line each (default: chromium pcmanfm):
#   docker run --rm -p 8080:8080 wland "chromium https://example.org"
#
# The relay runs the compositor (wlandr --profile session), so the apps keep
# running across page reloads. -e WLAND_PROFILE=passthrough: the page does,
# and a reload starts the apps again.
#
# Multi-arch: the builder runs on the build machine and zig cross-compiles
# wlandr for every target; TARGETARCH picks which binary the image gets.

# --- builder: static wlandr + the page (npm run build → dist/) --------------
FROM --platform=$BUILDPLATFORM docker.io/library/node:26-trixie-slim AS build

ARG ZIG_VERSION=0.16.0
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*
# zig for the BUILD machine's arch (checksums: ziglang.org/download/index.json)
RUN set -eu; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64)  sum=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;; \
      aarch64) sum=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;; \
      *) echo "no zig checksum for $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/zig.tar.xz "https://ziglang.org/download/$ZIG_VERSION/zig-$arch-linux-$ZIG_VERSION.tar.xz"; \
    echo "$sum  /tmp/zig.tar.xz" | sha256sum -c -; \
    mkdir /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:$PATH

WORKDIR /src
COPY package.json pnpm-lock.yaml ./
RUN npx -y pnpm@12 install --frozen-lockfile
COPY . .
# obuild: zig build + zig build release (static wlandr, x64 and arm64), lib/ → dist/
RUN npm run build

# Only what the image needs: the target's wlandr and the files the page
# loads (dist/ also holds the Node API, the CLI, headless, .d.mts types and
# the brotli'd binaries the npm package ships).
ARG TARGETARCH
RUN set -eu; \
    case "$TARGETARCH" in amd64) arch=x64 ;; arm64) arch=arm64 ;; *) echo "unsupported TARGETARCH $TARGETARCH" >&2; exit 1 ;; esac; \
    install -D -m 0755 "zig-out/release/wlandr-linux-$arch" /out/wlandr; \
    mkdir -p /out/web; \
    cp dist/index.html dist/wland.wasm dist/*.mjs /out/web/; \
    rm /out/web/cli.mjs /out/web/index.mjs /out/web/headless.mjs; \
    for f in $(grep -ohE 'from "\./[^"]+"' /out/web/*.mjs /out/web/index.html | cut -d'"' -f2 | sort -u); do \
      [ -f "/out/web/$f" ] || { echo "the page imports $f, which was not copied" >&2; exit 1; }; \
    done

# --- the image ---------------------------------------------------------------
FROM docker.io/library/debian:trixie-slim

# Files dpkg never unpacks (on top of the slim image's own docs/man/locale
# excludes, /etc/dpkg/dpkg.cfg.d/docker). Each is owned by a package that
# chromium hard-depends on but that this image never loads:
#
#  - Mesa's drivers and the LLVM/z3 they compile shaders with (~190M):
#    chromium runs with --disable-gpu and wland has no GPU client path, so
#    nothing creates a GL context or a GBM device. libgbm.so itself stays
#    (chromium links it); it only dlopens gbm/dri_gbm.so → libgallium when
#    a device is opened.
#  - chromium's Vulkan validation layer and mock driver: a debugging aid and
#    a test driver, loaded only when explicitly asked for.
#  - Adwaita's cursor theme: wland implements cursor-shape-v1, so chromium
#    and GTK name a shape and the browser draws the cursor.
COPY <<'EOF' /etc/dpkg/dpkg.cfg.d/wland
path-exclude /usr/lib/*/libLLVM*.so*
path-exclude /usr/lib/*/libgallium-*.so
path-exclude /usr/lib/*/libz3.so*
path-exclude /usr/lib/*/dri/*
path-exclude /usr/lib/*/gbm/*
path-exclude /usr/lib/chromium/libVkLayer_khronos_validation.so*
path-exclude /usr/lib/chromium/libVkICD_mock_icd.so*
path-exclude /usr/share/icons/Adwaita/cursors/*
EOF

# pcmanfm and l3afpad: a file manager and a text editor on the GTK 3 chromium
# already brings (~8M with libfm, <1M); no terminal in the image.
# dbus-x11 is not used directly: GTK 3 (chromium's toolkit) pulls dconf,
# which needs *a* session bus package, and without this apt picks
# dbus-user-session — systemd, libpam-systemd, systemd-sysv and the system
# bus (~18M). With it, dbus-run-session (tools/wland-run's fallback) is
# what's left.
RUN apt-get update \
 && apt-get install -y --no-install-recommends chromium pcmanfm l3afpad fonts-dejavu-core dbus-x11 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /var/cache/debconf/*-old /var/log/apt/* /var/log/dpkg.log

# Debian's chromium wrapper sources /etc/chromium.d/*, so these apply however
# chromium is started (by the entrypoint or by hand). The last three
# are what tools/wland-run adds too: no setuid sandbox in a container, no GPU
# path in wland, a 64M /dev/shm.
COPY <<'EOF' /etc/chromium.d/wland
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --ozone-platform=wayland --no-first-run --no-sandbox --disable-gpu --disable-dev-shm-usage"
EOF
# --no-sandbox is deliberate here: no "unsupported command-line flag" bar
COPY <<'EOF' /etc/chromium/policies/managed/wland.json
{ "CommandLineFlagSecurityWarningsEnabled": false }
EOF

# Text files open in l3afpad from the file manager (it is the only handler
# installed; this keeps it so if an image built on this one adds another).
COPY <<'EOF' /etc/xdg/mimeapps.list
[Default Applications]
text/plain=l3afpad.desktop
text/markdown=l3afpad.desktop
EOF

# UTF-8 file names; built into glibc, no locales package
ENV LANG=C.UTF-8
# who runs the compositor (docker/entrypoint.sh): session | passthrough
ENV WLAND_PROFILE=session

COPY --from=build /out/wlandr /usr/local/bin/wlandr
COPY --from=build /out/web /usr/local/share/wland/web
COPY tools/wland-run /usr/local/bin/wland-run
COPY docker/entrypoint.sh /usr/local/bin/wland-entrypoint

RUN useradd --uid 1000 --create-home --shell /bin/bash wland
# what the file manager opens on: the home directory, with a note in it
COPY --chown=1000:1000 docker/README.txt /home/wland/README.txt
USER 1000
WORKDIR /home/wland
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/wland-entrypoint"]
CMD ["chromium", "pcmanfm"]
