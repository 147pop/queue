FROM alpine:3.22

RUN apk add --no-cache \
    chromium \
    xvfb \
    x11vnc \
    novnc \
    websockify \
    ttf-dejavu \
    font-noto-emoji \
    ca-certificates \
    tini \
    nodejs \
    && ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html \
    && adduser -D -h /home/chrome chrome

COPY entrypoint.sh /entrypoint.sh
COPY login.mjs /login.mjs
COPY monitor.mjs /monitor.mjs
RUN chmod +x /entrypoint.sh

USER chrome
ENV HOME=/home/chrome

EXPOSE 6080

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
