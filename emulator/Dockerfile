FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    curl git xvfb x11vnc fluxbox sudo xterm \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash pi && echo "pi ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER pi
WORKDIR /home/pi

ENV DISPLAY=:0

COPY --chown=pi:pi ./scripts/install.sh ./install.sh

EXPOSE 5900

CMD Xvfb :0 -screen 0 1920x1080x24 & \
    while ! xdpyinfo -display :0 >/dev/null 2>&1; do sleep 0.5; done && \
    fluxbox & \
    x11vnc -display :0 -forever -passwd PiKiosk -rfbport 5900 & \
    echo "Ready - run ./install.sh to test"  && \
    bash