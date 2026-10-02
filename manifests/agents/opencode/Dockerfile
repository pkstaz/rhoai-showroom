FROM registry.access.redhat.com/ubi9/nodejs-22:latest

ENV HOME=/tmp

WORKDIR /opt/app

RUN npm install opencode-ai@latest --no-audit --no-fund \
    && ./node_modules/.bin/opencode --version

EXPOSE 4096

CMD ["/opt/app/node_modules/.bin/opencode", "serve", "--hostname", "0.0.0.0", "--port", "4096", "--cors", "https://app.opencode.ai"]
