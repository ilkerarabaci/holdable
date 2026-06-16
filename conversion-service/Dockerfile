# Holdable model-conversion service.
# Converts formats the app can't parse natively (.blend, USD) into .glb using
# headless Blender. STEP/IGES (FreeCAD) is added in a later phase.
#
# Runs anywhere a container runs — locally via Docker Desktop for dev, and
# Cloud Run for production (it's stateless and listens on $PORT).
FROM python:3.12-slim

# Headless Blender still links a handful of X/GL libs even with --background.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl xz-utils \
        libx11-6 libxi6 libxxf86vm1 libxfixes3 libxrender1 libxkbcommon0 \
        libgl1 libsm6 libice6 \
    && rm -rf /var/lib/apt/lists/*

# Pinned Blender (has glTF export + USD import built in). Override at build time
# with --build-arg if the patch URL moves. Bumped 4.2.3 → 5.0.1: Blender can't
# read files saved by a NEWER version, and users now save with Blender 5.x
# (a 5.0 .blend made 4.2.3 fail with "not a blend file"). 5.0.1 reads 5.0 files.
ARG BLENDER_MAJOR=5.0
ARG BLENDER_VERSION=5.0.1
RUN curl -fSL "https://download.blender.org/release/Blender${BLENDER_MAJOR}/blender-${BLENDER_VERSION}-linux-x64.tar.xz" \
        -o /tmp/blender.tar.xz \
    && mkdir -p /opt/blender \
    && tar -xf /tmp/blender.tar.xz -C /opt/blender --strip-components=1 \
    && rm /tmp/blender.tar.xz
ENV PATH="/opt/blender:${PATH}"

# FreeCAD (OpenCASCADE) for STEP/IGES tessellation — provides `freecadcmd`.
RUN apt-get update && apt-get install -y --no-install-recommends freecad \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py convert_core.py job_worker.py convert.py convert_step.py ./

ENV PORT=8080
EXPOSE 8080
# Shell form so ${PORT} expands (Cloud Run sets it). Worker timeout must exceed
# the longest conversion (CONVERT_TIMEOUT_S) — heavy scenes can take many
# minutes. One worker: each conversion spawns a heavy Blender subprocess and the
# service runs at Cloud Run concurrency=1 anyway.
CMD gunicorn -b 0.0.0.0:${PORT} -w 1 -t 1800 server:app
