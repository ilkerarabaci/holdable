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

# Pinned Blender LTS (has glTF export + USD import built in). Override at build
# time with --build-arg if the patch URL moves.
ARG BLENDER_MAJOR=4.2
ARG BLENDER_VERSION=4.2.3
RUN curl -fSL "https://download.blender.org/release/Blender${BLENDER_MAJOR}/blender-${BLENDER_VERSION}-linux-x64.tar.xz" \
        -o /tmp/blender.tar.xz \
    && mkdir -p /opt/blender \
    && tar -xf /tmp/blender.tar.xz -C /opt/blender --strip-components=1 \
    && rm /tmp/blender.tar.xz
ENV PATH="/opt/blender:${PATH}"

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py convert.py ./

ENV PORT=8080
EXPOSE 8080
# Shell form so ${PORT} expands (Cloud Run sets it). Long timeout: a Blender
# conversion can take a while; few workers since each spawns a heavy subprocess.
CMD gunicorn -b 0.0.0.0:${PORT} -w 2 -t 300 server:app
